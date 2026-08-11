import AppKit
import MarkdownRender

/// The menu bar, built entirely from the `Command` table (§7.2).
///
/// No menu item carries a hand-written key equivalent: every shortcut shown is
/// read back out of `KeybindingStore`, so remapping a binding in Settings
/// updates the menu, and a menu item can never advertise a shortcut that
/// doesn't work.
///
/// Every menu — including Application, Window, and Help — is built from
/// `groups(in:)`, so a command declared for a menu cannot silently fail to
/// appear.  `CommandTableTests` asserts exactly that.
/// Main-actor by nature, and now by declaration: every member here builds or
/// inspects `NSMenu`/`NSMenuItem`, and two of them reach main-actor singletons
/// (`UpdateCheckMenuItem.shared`, `HelpLinkTarget.shared`).  Without the
/// annotation those reads are a Swift 6 error waiting to happen; with it, the
/// isolation matches what the code has always required.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        // Touching the shared instance starts the observation that revalidates
        // "Check for Updates…" when the updater's state changes.
        _ = UpdateCheckMenuItem.shared
        let root = NSMenu()
        for menu in Command.Menu.allCases {
            root.addItem(menuItem(for: menu))
        }
        return root
    }

    /// Commands deliberately kept out of the menu bar.  Empty today; it exists
    /// so that hiding a command is a decision recorded here rather than an
    /// omission nobody notices.  `CommandTableTests` allows exactly these.
    static let commandsHiddenFromMenuBar: Set<Command> = []

    // MARK: - Menu description

    /// One separated run inside a menu.
    ///
    /// Commands come from the table.  "Standard" runs are AppKit actions the
    /// responder chain already implements — Cut, Paste and Match Style,
    /// Spelling, Enter Full Screen — which the command table deliberately does
    /// not duplicate, because they are not ours to rebind.
    private enum MenuGroup {
        case commands([Command])
        case submenu(title: String, commands: [Command])
        case standard([StandardItem])
        case standardSubmenu(title: String, items: [StandardItem])
        /// A submenu whose contents a delegate supplies when it opens.
        case dynamicSubmenu(title: String, delegate: NSMenuDelegate)
        /// The one submenu macOS fills in for us.
        case services
    }

    /// A menu item for an action the app does not own.
    private struct StandardItem {
        var title: String
        var selector: Selector?
        var keyEquivalent: String = ""
        var modifiers: NSEvent.ModifierFlags = .command
        var target: AnyObject?
        var representedObject: Any?

        static let separator = StandardItem(title: "-", selector: nil)

        func makeMenuItem() -> NSMenuItem {
            guard let selector else { return .separator() }
            let item = NSMenuItem(title: title, action: selector, keyEquivalent: keyEquivalent)
            if !keyEquivalent.isEmpty { item.keyEquivalentModifierMask = modifiers }
            item.target = target
            item.representedObject = representedObject
            return item
        }

        /// Explicitly isolated: a nested type does not inherit the enclosing
        /// one's actor, and this reaches `HelpLinkTarget.shared`.
        @MainActor
        static func link(_ title: String, _ url: String) -> StandardItem {
            StandardItem(
                title: title,
                selector: #selector(HelpLinkTarget.openLink(_:)),
                target: HelpLinkTarget.shared,
                representedObject: url
            )
        }
    }

    /// Grouping inside each menu.  Kept explicit rather than derived from the
    /// enum's declaration order so separators land where they read well.
    private static func groups(in menu: Command.Menu) -> [MenuGroup] {
        switch menu {
        case .application:
            return [
                .standard([StandardItem(
                    title: "About Downright",
                    selector: #selector(NSApplication.orderFrontStandardAboutPanel(_:))
                )]),
                // Follows About per the updater spec.  Validation now comes
                // from the command's precondition, not a bespoke target.
                .commands([.checkForUpdates]),
                .commands([.preferences, .showKeybindings, .toggleLightDark]),
                .services,
                .standard([
                    StandardItem(title: "Hide Downright", selector: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
                    StandardItem(
                        title: "Hide Others",
                        selector: #selector(NSApplication.hideOtherApplications(_:)),
                        keyEquivalent: "h", modifiers: [.command, .option]
                    ),
                    StandardItem(title: "Show All", selector: #selector(NSApplication.unhideAllApplications(_:))),
                ]),
                .standard([StandardItem(
                    title: "Quit Downright",
                    selector: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"
                )]),
            ]

        case .file:
            return [
                .commands([.newDocument, .open]),
                .dynamicSubmenu(title: "Open Recent", delegate: RecentsMenuDelegate.shared),
                .commands([.save, .saveAs, .close]),
                // The app's own version history.  macOS's Revert To / Browse
                // All Versions are NSDocument features Downright does not use.
                .commands([.versionTimeline]),
                .commands([.revealInFinder, .openInEditor, .compareFiles]),
                .standard([StandardItem(
                    title: "Page Setup…",
                    selector: #selector(NSApplication.runPageLayout(_:)),
                    keyEquivalent: "p", modifiers: [.command, .shift]
                )]),
                .commands([.printDocument, .exportPDF, .exportHTML, .exportSelectionAsImage]),
            ]

        case .edit:
            return [
                .standard([
                    StandardItem(title: "Undo", selector: Selector(("undo:")), keyEquivalent: "z"),
                    StandardItem(
                        title: "Redo", selector: Selector(("redo:")),
                        keyEquivalent: "z", modifiers: [.command, .shift]
                    ),
                ]),
                .standard([
                    StandardItem(title: "Cut", selector: #selector(NSText.cut(_:)), keyEquivalent: "x"),
                    StandardItem(title: "Copy", selector: #selector(NSText.copy(_:)), keyEquivalent: "c"),
                    StandardItem(title: "Paste", selector: #selector(NSText.paste(_:)), keyEquivalent: "v"),
                    // The likeliest paste in a byte-exact Markdown editor.
                    StandardItem(
                        title: "Paste and Match Style",
                        selector: #selector(NSTextView.pasteAsPlainText(_:)),
                        keyEquivalent: "v", modifiers: [.command, .shift]
                    ),
                    StandardItem(title: "Delete", selector: #selector(NSText.delete(_:))),
                    StandardItem(title: "Select All", selector: #selector(NSText.selectAll(_:)), keyEquivalent: "a"),
                ]),
                .commands([.copyAsMarkdown, .copyAsRichText, .copyAsPlainText, .copySection, .copySectionLink]),
                .submenu(
                    title: "Find",
                    commands: [.find, .findNext, .findPrevious, .useSelectionForFind, .findReplace, .findInSiblings]
                ),
                .standardSubmenu(title: "Spelling and Grammar", items: [
                    StandardItem(
                        title: "Show Spelling and Grammar",
                        selector: #selector(NSText.showGuessPanel(_:)), keyEquivalent: ":"
                    ),
                    StandardItem(
                        title: "Check Document Now",
                        selector: #selector(NSText.checkSpelling(_:)), keyEquivalent: ";"
                    ),
                    .separator,
                    StandardItem(
                        title: "Check Spelling While Typing",
                        selector: #selector(NSTextView.toggleContinuousSpellChecking(_:))
                    ),
                    StandardItem(
                        title: "Check Grammar With Spelling",
                        selector: #selector(NSTextView.toggleGrammarChecking(_:))
                    ),
                    StandardItem(
                        title: "Correct Spelling Automatically",
                        selector: #selector(NSTextView.toggleAutomaticSpellingCorrection(_:))
                    ),
                ]),
                // Off by default so source bytes survive typing (§6.4); this is
                // where the user turns them on if they want them.
                .standardSubmenu(title: "Substitutions", items: [
                    StandardItem(
                        title: "Show Substitutions",
                        selector: #selector(NSTextView.orderFrontSubstitutionsPanel(_:))
                    ),
                    .separator,
                    StandardItem(title: "Smart Copy/Paste", selector: #selector(NSTextView.toggleSmartInsertDelete(_:))),
                    StandardItem(
                        title: "Smart Quotes",
                        selector: #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:))
                    ),
                    StandardItem(
                        title: "Smart Dashes",
                        selector: #selector(NSTextView.toggleAutomaticDashSubstitution(_:))
                    ),
                    StandardItem(title: "Smart Links", selector: #selector(NSTextView.toggleAutomaticLinkDetection(_:))),
                    StandardItem(
                        title: "Data Detectors",
                        selector: #selector(NSTextView.toggleAutomaticDataDetection(_:))
                    ),
                    StandardItem(
                        title: "Text Replacement",
                        selector: #selector(NSTextView.toggleAutomaticTextReplacement(_:))
                    ),
                ]),
                .standardSubmenu(title: "Transformations", items: [
                    StandardItem(title: "Make Upper Case", selector: #selector(NSResponder.uppercaseWord(_:))),
                    StandardItem(title: "Make Lower Case", selector: #selector(NSResponder.lowercaseWord(_:))),
                    StandardItem(title: "Capitalize", selector: #selector(NSResponder.capitalizeWord(_:))),
                ]),
                .submenu(title: "Speech", commands: [.speakDocument, .stopSpeaking]),
            ]

        case .format:
            return [
                .commands([.toggleBold, .toggleItalic, .toggleStrikethrough, .toggleInlineCode, .insertLink]),
                .commands([
                    .convertToParagraph, .convertToBulletList, .convertToNumberedList,
                    .convertToTaskList, .convertToBlockquote,
                ]),
                .commands([.indentList, .outdentList, .toggleTaskAtCaret]),
                .commands([
                    .promoteHeading, .demoteHeading,
                    .headingLevel1, .headingLevel2, .headingLevel3,
                    .headingLevel4, .headingLevel5, .headingLevel6, .headingToBody,
                ]),
            ]

        case .view:
            return [
                .standard([
                    StandardItem(title: "Show/Hide Toolbar", selector: #selector(NSWindow.toggleToolbarShown(_:))),
                    StandardItem(title: "Customize Toolbar…", selector: #selector(NSWindow.runToolbarCustomizationPalette(_:))),
                    StandardItem(
                        title: "Enter Full Screen",
                        selector: #selector(NSWindow.toggleFullScreen(_:)),
                        keyEquivalent: "f", modifiers: [.control, .command]
                    ),
                ]),
                .commands([.sourceMode]),
                .commands([.zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4, .zoomLevel5, .zoomIn, .zoomOut]),
                .commands([.increaseTextSize, .decreaseTextSize, .resetTextSize]),
                .commands([.taskPanel]),
                .commands([.commandPalette, .documentLens, .readerProfiles]),
                .commands([.documentHealth, .renderTargets, .visualDebugger, .reviewPanel]),
                .commands([.workspace, .localAI]),
                .commands([.focusMode, .typewriterScrolling, .statusBar]),
                .dynamicSubmenu(title: "Theme", delegate: ThemeMenuDelegate.shared),
                .commands([.reloadTheme]),
            ]

        case .navigate:
            return [
                .commands([.previousHeading, .nextHeading]),
                .commands([.previousLink, .nextLink, .followLinkAtCaret]),
                .commands([.goToLine]),
                .commands([.previousChange, .nextChange, .markChangesReviewed]),
                .commands([.goBack, .goForward]),
                .commands([.scrollUp, .scrollDown, .pageUp, .pageDown]),
                .commands([.documentStart, .documentEnd]),
            ]

        case .document:
            return [
                .commands([.tidyDocument]),
                .commands([.moveBlockUp, .moveBlockDown]),
                .commands([.foldSection, .unfoldSection, .foldAll, .unfoldAll]),
                .commands([.sortListAlphabetically, .sortListByState, .insertTableOfContents]),
                .commands([.frontMatterEditor, .tableEditor, .assetDoctor]),
            ]

        case .window:
            return [
                .standard([
                    StandardItem(title: "Minimize", selector: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"),
                    StandardItem(title: "Zoom", selector: #selector(NSWindow.performZoom(_:))),
                ]),
                .commands([.splitView, .pinWindow]),
                .standard([
                    StandardItem(
                        title: "Show Previous Tab", selector: #selector(NSWindow.selectPreviousTab(_:)),
                        keyEquivalent: "\t", modifiers: [.control, .shift]
                    ),
                    StandardItem(
                        title: "Show Next Tab", selector: #selector(NSWindow.selectNextTab(_:)),
                        keyEquivalent: "\t", modifiers: [.control]
                    ),
                    StandardItem(title: "Move Tab to New Window", selector: #selector(NSWindow.moveTabToNewWindow(_:))),
                    StandardItem(title: "Merge All Windows", selector: #selector(NSWindow.mergeAllWindows(_:))),
                    StandardItem(title: "Show Tab Bar", selector: #selector(NSWindow.toggleTabBar(_:))),
                ]),
                .standard([StandardItem(
                    title: "Bring All to Front", selector: #selector(NSApplication.arrangeInFront(_:))
                )]),
            ]

        case .help:
            // Titles here are what the Help menu's search field indexes, so
            // they are written the way a user would ask for them.
            return [
                .standard([
                    // The start window retires its tour button after a few
                    // launches; this is where it goes to stay reachable.
                    StandardItem(
                        title: "Take the Tour",
                        selector: #selector(AppDelegate.takeTour(_:))
                    ),
                    StandardItem(
                        title: "Downright Help",
                        selector: #selector(HelpLinkTarget.openLink(_:)),
                        keyEquivalent: "?",
                        target: HelpLinkTarget.shared,
                        representedObject: "https://github.com/ezzy1630/Downright#readme"
                    ),
                    .link("Markdown Reference", "https://commonmark.org/help/"),
                ]),
                .standard([
                    .link("Report an Issue", "https://github.com/ezzy1630/Downright/issues/new"),
                    StandardItem(
                        title: "Downright on GitHub",
                        selector: #selector(AppDelegate.openProjectPage(_:))
                    ),
                ]),
            ]
        }
    }

    // MARK: - Building

    private static func menuItem(for menu: Command.Menu) -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: menu.title)
        submenu.autoenablesItems = true

        for group in groups(in: menu) {
            if !submenu.items.isEmpty { submenu.addItem(.separator()) }
            switch group {
            case .commands(let commands):
                for command in commands { submenu.addItem(commandItem(command)) }
            case .submenu(let title, let commands):
                submenu.addItem(hostItem(title: title, items: commands.map(commandItem)))
            case .standard(let items):
                for standard in items { submenu.addItem(standard.makeMenuItem()) }
            case .services:
                submenu.addItem(servicesItem())
            case .standardSubmenu(let title, let items):
                submenu.addItem(hostItem(title: title, items: items.map { $0.makeMenuItem() }))
            case .dynamicSubmenu(let title, let delegate):
                let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
                let child = NSMenu(title: title)
                child.delegate = delegate
                host.submenu = child
                submenu.addItem(host)
            }
        }

        switch menu {
        case .window: NSApp.windowsMenu = submenu
        case .help: NSApp.helpMenu = submenu
        default: break
        }

        item.submenu = submenu
        return item
    }

    private static func hostItem(title: String, items: [NSMenuItem]) -> NSMenuItem {
        let host = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let child = NSMenu(title: title)
        child.autoenablesItems = true
        for item in items { child.addItem(item) }
        host.submenu = child
        return host
    }

    private static func servicesItem() -> NSMenuItem {
        let services = NSMenu(title: "Services")
        let item = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        item.submenu = services
        NSApp.servicesMenu = services
        return item
    }

    // MARK: - Items

    static func commandItem(_ command: Command) -> NSMenuItem {
        let item = NSMenuItem(
            title: command.title,
            action: #selector(CommandResponder.performDownrightCommand(_:)),
            keyEquivalent: ""
        )
        item.representedObject = command.rawValue
        item.tag = commandTag(command)
        applyKeyEquivalent(to: item, command: command)
        return item
    }

    static func commandTag(_ command: Command) -> Int {
        (Command.allCases.firstIndex(of: command) ?? 0) + 1000
    }

    static func command(for item: NSMenuItem) -> Command? {
        (item.representedObject as? String).flatMap(Command.init(rawValue:))
    }

    /// Menu validation, derived from the command table's preconditions.
    ///
    /// Both `AppDelegate` and `DocumentWindowController` route their
    /// `NSMenuItemValidation` here, so "is Save available?" has one answer.
    /// Items that carry no command are left to whoever owns them.
    static func validate(_ item: NSMenuItem, in context: CommandContext) -> Bool {
        guard let command = command(for: item) else { return true }
        return command.isEnabled(in: context)
    }

    /// Rebuilds shortcut display after the user remaps a binding.
    static func refreshKeyEquivalents(in menu: NSMenu) {
        for item in menu.items {
            if let command = command(for: item) { applyKeyEquivalent(to: item, command: command) }
            if let submenu = item.submenu { refreshKeyEquivalents(in: submenu) }
        }
    }

    private static func applyKeyEquivalent(to item: NSMenuItem, command: Command) {
        // Only ⌘/⌃ bindings become menu key equivalents: a bare `n` in the
        // menu bar would fire while the user is typing in Live mode.
        guard let binding = KeybindingStore.shared.primaryBinding(for: command),
              binding.modifiers.contains(.command) || binding.modifiers.contains(.control)
        else {
            item.keyEquivalent = ""
            item.keyEquivalentModifierMask = []
            return
        }
        item.keyEquivalent = binding.menuKeyEquivalent
        item.keyEquivalentModifierMask = binding.modifiers
    }
}

/// Any object in the responder chain that can run a `Command`.
@MainActor
@objc protocol CommandResponder {
    @objc func performDownrightCommand(_ sender: Any?)
}

// MARK: - Update check revalidation

/// Keeps "Check for Updates…" honest.  The item itself is an ordinary command
/// item now; this only forces a menu revalidation pass whenever the updater's
/// state changes, so `canCheckForUpdates` (KVO-backed by Sparkle) reaches the
/// menu without polling.
@MainActor
final class UpdateCheckMenuItem: NSObject {
    static let shared = UpdateCheckMenuItem()
    private var stateObserver: NSObjectProtocol?

    private override init() {
        super.init()
        stateObserver = NotificationCenter.default.addObserver(
            forName: UpdateCoordinator.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMenu() }
        }
    }

    deinit {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    }

    private func refreshMenu() {
        NSApp.mainMenu?.update()
    }
}

// MARK: - Help links

/// Target for the Help menu's documentation links.  A menu item's URL lives in
/// its `representedObject`, so adding a link is one line in `groups(in:)`.
@MainActor
final class HelpLinkTarget: NSObject {
    static let shared = HelpLinkTarget()

    @objc func openLink(_ sender: NSMenuItem) {
        guard let string = sender.representedObject as? String,
              let url = URL(string: string) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Dynamic submenus

final class RecentsMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = RecentsMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let recents = DocumentStateStore.shared.recents(limit: 15)
        guard !recents.isEmpty else {
            let empty = NSMenuItem(title: "No Recent Documents", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        for recent in recents {
            let item = NSMenuItem(
                title: recent.displayName,
                action: #selector(AppDelegate.openRecentDocument(_:)),
                keyEquivalent: ""
            )
            item.representedObject = recent.path
            // The first heading is a far better identifier than the filename
            // for agent output, which is full of `output.md` and `plan.md`.
            if !recent.firstHeading.isEmpty {
                item.toolTip = recent.firstHeading
            }
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Clear Menu", action: #selector(AppDelegate.clearRecentDocuments(_:)), keyEquivalent: ""))
    }
}

final class ThemeMenuDelegate: NSObject, NSMenuDelegate {
    static let shared = ThemeMenuDelegate()

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let follow = NSMenuItem(
            title: "Follow macOS Appearance",
            action: #selector(AppDelegate.toggleFollowSystemAppearance(_:)),
            keyEquivalent: ""
        )
        follow.state = Preferences.shared.values.followsSystemAppearance ? .on : .off
        menu.addItem(follow)
        menu.addItem(.separator())

        menu.addItem(themePicker(
            title: "Light Theme",
            themes: ThemeStore.shared.themes.filter { $0.appearance != .dark },
            selectedName: Preferences.shared.values.themeName,
            action: #selector(AppDelegate.selectLightTheme(_:))
        ))
        menu.addItem(themePicker(
            title: "Dark Theme",
            themes: ThemeStore.shared.themes.filter { $0.appearance != .light },
            selectedName: Preferences.shared.values.darkThemeName,
            action: #selector(AppDelegate.selectDarkTheme(_:))
        ))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Import VS Code Theme…", action: #selector(AppDelegate.importTheme(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal Themes Folder", action: #selector(AppDelegate.revealThemesFolder(_:)), keyEquivalent: ""))
    }

    private func themePicker(
        title: String,
        themes: [Theme],
        selectedName: String,
        action: Selector
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        for theme in themes {
            let item = NSMenuItem(title: theme.name, action: action, keyEquivalent: "")
            item.representedObject = theme.name
            item.state = theme.name == selectedName ? .on : .off
            submenu.addItem(item)
        }
        parent.submenu = submenu
        return parent
    }
}
