import AppKit
import MarkdownRender

/// The menu bar, built entirely from the `Command` table (§7.2).
///
/// No menu item carries a hand-written key equivalent: every shortcut shown is
/// read back out of `KeybindingStore`, so remapping a binding in Settings
/// updates the menu, and a menu item can never advertise a shortcut that
/// doesn't work.
enum MainMenu {
    static func build() -> NSMenu {
        let root = NSMenu()
        root.addItem(applicationMenuItem())
        for menu in [Command.Menu.file, .edit, .format, .view, .navigate, .document] {
            root.addItem(menuItem(for: menu))
        }
        root.addItem(windowMenuItem())
        root.addItem(helpMenuItem())
        return root
    }

    // MARK: - Application menu

    private static func applicationMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Downright")

        menu.addItem(withTitle: "About Downright", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(commandItem(.preferences))
        menu.addItem(commandItem(.showKeybindings))
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        menu.addItem(servicesItem)
        menu.addItem(.separator())

        menu.addItem(withTitle: "Hide Downright", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(
            title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h"
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(hideOthers)
        menu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Downright", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        item.submenu = menu
        return item
    }

    // MARK: - Derived menus

    private static func menuItem(for menu: Command.Menu) -> NSMenuItem {
        let item = NSMenuItem()
        let submenu = NSMenu(title: menu.title)
        submenu.autoenablesItems = true

        if menu == .edit {
            for standardItem in standardEditItems() { submenu.addItem(standardItem) }
        }

        for group in groups(in: menu) {
            if !submenu.items.isEmpty { submenu.addItem(.separator()) }
            for command in group {
                submenu.addItem(commandItem(command))
            }
        }

        if menu == .file {
            submenu.addItem(.separator())
            let recents = NSMenuItem(title: "Open Recent", action: nil, keyEquivalent: "")
            recents.submenu = NSMenu(title: "Open Recent")
            recents.submenu?.delegate = RecentsMenuDelegate.shared
            submenu.addItem(recents)
        }
        if menu == .view {
            submenu.addItem(.separator())
            submenu.addItem(themeMenuItem())
        }

        item.submenu = submenu
        return item
    }

    private static func standardEditItems() -> [NSMenuItem] {
        let undo = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        let cut = NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        let copy = NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        let paste = NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        let selectAll = NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        return [undo, redo, .separator(), cut, copy, paste, selectAll]
    }

    /// Grouping inside each menu.  Kept explicit rather than derived from the
    /// enum's declaration order so separators land where they read well.
    private static func groups(in menu: Command.Menu) -> [[Command]] {
        switch menu {
        case .file:
            return [
                [.newDocument, .open],
                [.save, .saveAs, .close],
                [.revealInFinder, .openInEditor, .compareFiles],
                [.printDocument, .exportPDF, .exportHTML, .exportSelectionAsImage],
            ]
        case .edit:
            return [
                [.copyAsMarkdown, .copyAsRichText, .copyAsPlainText, .copySection, .copySectionLink],
                [.speakDocument, .stopSpeaking],
                [.find, .findNext, .findPrevious, .useSelectionForFind, .findReplace, .findInSiblings],
                [.addCursorAbove, .addCursorBelow, .selectNextOccurrence, .splitSelectionIntoLines],
            ]
        case .format:
            return [
                [.toggleBold, .toggleItalic, .toggleStrikethrough, .toggleInlineCode, .insertLink],
                [.convertToParagraph, .convertToBulletList, .convertToNumberedList, .convertToTaskList, .convertToBlockquote],
                [.indentList, .outdentList, .toggleTaskAtCaret],
            ]
        case .view:
            return [
                [.sourceMode],
                [.zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4, .zoomLevel5],
                [.increaseTextSize, .decreaseTextSize, .resetTextSize],
                [.outlinePanel, .taskPanel, .toggleSidebar, .versionTimeline],
                [.commandPalette, .documentLens, .readerProfiles],
                [.documentHealth, .renderTargets, .visualDebugger, .reviewPanel],
                [.workspace, .localAI],
                [.focusMode, .typewriterScrolling, .reloadTheme],
            ]
        case .navigate:
            return [
                [.outlineQuickOpen],
                [.previousHeading, .nextHeading],
                [.previousChange, .nextChange],
                [.goBack, .goForward],
                [.documentStart, .documentEnd],
            ]
        case .document:
            return [
                [.tidyDocument],
                [.promoteHeading, .demoteHeading, .moveBlockUp, .moveBlockDown],
                [.foldSection, .unfoldSection, .foldAll, .unfoldAll],
                [.sortListAlphabetically, .sortListByState, .insertTableOfContents],
            ]
        case .window:
            return [[.splitView, .pinWindow]]
        case .help:
            return [[.showKeybindings]]
        }
    }

    private static func windowMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Window")
        menu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(commandItem(.splitView))
        menu.addItem(commandItem(.pinWindow))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        item.submenu = menu
        NSApp.windowsMenu = menu
        return item
    }

    private static func helpMenuItem() -> NSMenuItem {
        let item = NSMenuItem()
        let menu = NSMenu(title: "Help")
        menu.addItem(commandItem(.showKeybindings))
        menu.addItem(commandItem(.toggleVimKeys))
        menu.addItem(.separator())
        let repoItem = NSMenuItem(title: "Downright on GitHub", action: #selector(AppDelegate.openProjectPage(_:)), keyEquivalent: "")
        menu.addItem(repoItem)
        item.submenu = menu
        NSApp.helpMenu = menu
        return item
    }

    private static func themeMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "Theme")
        menu.delegate = ThemeMenuDelegate.shared
        item.submenu = menu
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
        if let binding = KeybindingStore.shared.primaryBinding(for: command),
           binding.modifiers.contains(.command) || binding.modifiers.contains(.control) {
            // Only ⌘/⌃ bindings become menu key equivalents: a bare `n` in the
            // menu bar would fire while the user is typing in Live mode.
            item.keyEquivalent = binding.menuKeyEquivalent
            item.keyEquivalentModifierMask = binding.modifiers
        }
        return item
    }

    static func commandTag(_ command: Command) -> Int {
        (Command.allCases.firstIndex(of: command) ?? 0) + 1000
    }

    static func command(for item: NSMenuItem) -> Command? {
        (item.representedObject as? String).flatMap(Command.init(rawValue:))
    }

    /// Rebuilds shortcut display after the user remaps a binding.
    static func refreshKeyEquivalents(in menu: NSMenu) {
        for item in menu.items {
            if let command = command(for: item) {
                if let binding = KeybindingStore.shared.primaryBinding(for: command),
                   binding.modifiers.contains(.command) || binding.modifiers.contains(.control) {
                    item.keyEquivalent = binding.menuKeyEquivalent
                    item.keyEquivalentModifierMask = binding.modifiers
                } else {
                    item.keyEquivalent = ""
                }
            }
            if let submenu = item.submenu { refreshKeyEquivalents(in: submenu) }
        }
    }
}

/// Any object in the responder chain that can run a `Command`.
@MainActor
@objc protocol CommandResponder {
    @objc func performDownrightCommand(_ sender: Any?)
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
        for theme in ThemeStore.shared.themes {
            let item = NSMenuItem(title: theme.name, action: #selector(AppDelegate.selectTheme(_:)), keyEquivalent: "")
            item.representedObject = theme.name
            item.state = theme.name == ThemeStore.shared.current.name ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(MainMenu.commandItem(.reloadTheme))
        menu.addItem(NSMenuItem(title: "Import VS Code Theme…", action: #selector(AppDelegate.importTheme(_:)), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Reveal Themes Folder", action: #selector(AppDelegate.revealThemesFolder(_:)), keyEquivalent: ""))
    }
}
