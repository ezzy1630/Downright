import AppKit

/// Every command in the app, in one declarative table (§7.2).
///
/// The menu bar, the keybinding editor, the command palette, and the context
/// menus are all *derived* from this table.  That is the point: a binding you
/// can see in the menu is by construction the binding the keyboard layer
/// dispatches, and adding a command in one place makes it remappable, listed,
/// and discoverable without touching four files.
enum Command: String, CaseIterable, Codable {
    // Modes and views
    case sourceMode, splitView, pinWindow, focusMode, typewriterScrolling
    case statusBar
    case taskPanel, versionTimeline, compareFiles
    case frontMatterEditor, tableEditor, assetDoctor
    case commandPalette, documentLens, readerProfiles
    case documentHealth, renderTargets, visualDebugger, reviewPanel, workspace, localAI

    // Navigation
    case nextHeading, previousHeading, nextChange, previousChange
    /// Clears every change mark and moves the review baseline forward (§8.1).
    /// The only other way to reach this was the Review / Keep mine / Take
    /// theirs bar, which is raised by a live external write and dismissed with
    /// it — so a reader who came back to a rewritten file later had no way at
    /// all to put the highlighting out.
    case markChangesReviewed
    case followLinkAtCaret, nextLink, previousLink
    case scrollDown, scrollUp, pageDown, pageUp, documentStart, documentEnd
    case goBack, goForward

    // Structural zoom (§5.2)
    case zoomLevel1, zoomLevel2, zoomLevel3, zoomLevel4, zoomLevel5, zoomIn, zoomOut

    // Find (§9.4)
    case find, findNext, findPrevious, findReplace, findInSiblings, useSelectionForFind

    // Restructuring (§9.2)
    case promoteHeading, demoteHeading
    case headingLevel1, headingLevel2, headingLevel3, headingLevel4, headingLevel5, headingLevel6
    case headingToBody, moveBlockUp, moveBlockDown
    case foldSection, unfoldSection, foldAll, unfoldAll
    case convertToParagraph, convertToBulletList, convertToNumberedList
    case convertToTaskList, convertToBlockquote
    case sortListAlphabetically, sortListByState, insertTableOfContents, tidyDocument

    // Editing (§6.4)
    case toggleBold, toggleItalic, insertLink, toggleStrikethrough, toggleInlineCode
    case indentList, outdentList, toggleTaskAtCaret

    // Files and export (§9.5)
    case newDocument, open, save, saveAs, revealInFinder, openInEditor, close
    case copyAsMarkdown, copyAsRichText, copyAsPlainText, copySection, copySectionLink
    case printDocument, exportHTML, exportPDF, exportSelectionAsImage
    case increaseTextSize, decreaseTextSize, resetTextSize
    case speakDocument, stopSpeaking

    // App
    case preferences, reloadTheme, showKeybindings, checkForUpdates
    /// Toggles between the light and dark theme without opening Settings.
    case toggleLightDark
    /// Jumps to a line number in the document.
    case goToLine

    var title: String {
        switch self {
        case .sourceMode: return "Source Focus"
        case .splitView: return "Split View"
        case .pinWindow: return "Pin Window"
        case .focusMode: return "Focus Mode"
        case .typewriterScrolling: return "Typewriter Scrolling"
        case .statusBar: return "Status Bar"
        case .taskPanel: return "Tasks"
        case .versionTimeline: return "Version Timeline"
        case .compareFiles: return "Compare Files…"
        case .frontMatterEditor: return "Front Matter"
        case .tableEditor: return "Edit Table…"
        case .assetDoctor: return "Asset Doctor"
        case .commandPalette: return "Command Palette…"
        case .documentLens: return "Document Lens"
        case .readerProfiles: return "Reader Profiles"
        case .documentHealth: return "Document Health"
        case .renderTargets: return "Render Targets"
        case .visualDebugger: return "Visual Debugger"
        case .reviewPanel: return "Review"
        case .workspace: return "Workspace"
        case .localAI: return "On-Device AI"
        case .nextHeading: return "Next Heading"
        case .previousHeading: return "Previous Heading"
        case .nextChange: return "Next Change"
        case .previousChange: return "Previous Change"
        case .markChangesReviewed: return "Mark Changes Reviewed"
        case .followLinkAtCaret: return "Open Link at Caret"
        case .nextLink: return "Next Link"
        case .previousLink: return "Previous Link"
        case .scrollDown: return "Scroll Down"
        case .scrollUp: return "Scroll Up"
        case .pageDown: return "Page Down"
        case .pageUp: return "Page Up"
        case .documentStart: return "Top of Document"
        case .documentEnd: return "End of Document"
        case .goBack: return "Back"
        case .goForward: return "Forward"
        case .zoomLevel1: return "Detail: Top-Level Headings"
        case .zoomLevel2: return "Detail: Headings Through Level 2"
        case .zoomLevel3: return "Detail: All Headings"
        case .zoomLevel4: return "Detail: Outline and Summaries"
        case .zoomLevel5: return "Detail: Full Document"
        case .zoomIn: return "Show More Detail"
        case .zoomOut: return "Show Less Detail"
        case .find: return "Find…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .findReplace: return "Find and Replace…"
        case .findInSiblings: return "Find in Sibling Files…"
        case .useSelectionForFind: return "Use Selection for Find"
        case .promoteHeading: return "Promote Heading"
        case .demoteHeading: return "Demote Heading"
        case .headingLevel1: return "Heading 1"
        case .headingLevel2: return "Heading 2"
        case .headingLevel3: return "Heading 3"
        case .headingLevel4: return "Heading 4"
        case .headingLevel5: return "Heading 5"
        case .headingLevel6: return "Heading 6"
        case .headingToBody: return "Body Text"
        case .moveBlockUp: return "Move Block Up"
        case .moveBlockDown: return "Move Block Down"
        case .foldSection: return "Fold Section"
        case .unfoldSection: return "Unfold Section"
        case .foldAll: return "Fold All"
        case .unfoldAll: return "Unfold All"
        case .convertToParagraph: return "Convert to Paragraph"
        case .convertToBulletList: return "Convert to Bullet List"
        case .convertToNumberedList: return "Convert to Numbered List"
        case .convertToTaskList: return "Convert to Task List"
        case .convertToBlockquote: return "Convert to Blockquote"
        case .sortListAlphabetically: return "Sort List Alphabetically"
        case .sortListByState: return "Sort List by Checkbox"
        case .insertTableOfContents: return "Insert Table of Contents"
        case .tidyDocument: return "Tidy Document…"
        case .toggleBold: return "Bold"
        case .toggleItalic: return "Italic"
        case .insertLink: return "Link"
        case .toggleStrikethrough: return "Strikethrough"
        case .toggleInlineCode: return "Inline Code"
        case .indentList: return "Indent"
        case .outdentList: return "Outdent"
        case .toggleTaskAtCaret: return "Toggle Task"
        case .newDocument: return "New…"
        case .open: return "Open…"
        case .save: return "Save"
        case .saveAs: return "Save As…"
        case .revealInFinder: return "Reveal in Finder"
        case .openInEditor: return "Open in Editor"
        case .close: return "Close"
        case .copyAsMarkdown: return "Copy as Markdown"
        case .copyAsRichText: return "Copy as Rich Text"
        case .copyAsPlainText: return "Copy as Plain Text"
        case .copySection: return "Copy Section"
        case .copySectionLink: return "Copy Link to Section"
        case .printDocument: return "Print…"
        case .exportHTML: return "Export HTML…"
        case .exportPDF: return "Export PDF…"
        case .exportSelectionAsImage: return "Export Selection as Image…"
        case .increaseTextSize: return "Bigger Text"
        case .decreaseTextSize: return "Smaller Text"
        case .resetTextSize: return "Actual Size"
        case .speakDocument: return "Speak Selection or Document"
        case .stopSpeaking: return "Stop Speaking"
        case .preferences: return "Settings…"
        case .reloadTheme: return "Reload Themes"
        case .showKeybindings: return "Keyboard Shortcuts…"
        case .checkForUpdates: return "Check for Updates…"
        case .toggleLightDark: return "Toggle Light/Dark Theme"
        case .goToLine: return "Go to Line…"
        }
    }

    /// Where the command appears in the menu bar.
    ///
    /// `MainMenu` builds every menu from this, and the keybinding editor shows
    /// it in the "Menu" column, so a command placed here is a promise about
    /// where the user will find it.  `CommandTableTests` holds us to it.
    enum Menu: String, CaseIterable {
        case application, file, edit, format, view, navigate, document, window, help

        var title: String {
            // The app menu is named after the app, not after the enum case;
            // "Application" would be a lie in both the menu bar and Settings.
            self == .application ? "Downright" : rawValue.capitalized
        }
    }

    var menu: Menu {
        switch self {
        case .newDocument, .open, .save, .saveAs, .close, .revealInFinder, .openInEditor,
             .printDocument, .exportHTML, .exportPDF, .exportSelectionAsImage, .compareFiles,
             .versionTimeline:
            return .file
        case .copyAsMarkdown, .copyAsRichText, .copyAsPlainText, .copySection, .copySectionLink,
             .find, .findNext, .findPrevious, .findReplace, .findInSiblings, .useSelectionForFind,
             .speakDocument, .stopSpeaking:
            return .edit
        case .toggleBold, .toggleItalic, .insertLink, .toggleStrikethrough, .toggleInlineCode,
             .convertToParagraph, .convertToBulletList, .convertToNumberedList, .convertToTaskList,
             .convertToBlockquote, .indentList, .outdentList, .toggleTaskAtCaret,
             .promoteHeading, .demoteHeading, .headingLevel1, .headingLevel2, .headingLevel3,
             .headingLevel4, .headingLevel5, .headingLevel6, .headingToBody:
            return .format
        case .sourceMode, .zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4,
             .zoomLevel5, .zoomIn, .zoomOut, .increaseTextSize, .decreaseTextSize, .resetTextSize,
             .focusMode, .typewriterScrolling, .statusBar, .taskPanel,
             .reloadTheme, .commandPalette, .documentLens,
             .readerProfiles, .documentHealth, .renderTargets, .visualDebugger,
             .reviewPanel, .workspace, .localAI:
            return .view
        case .nextHeading, .previousHeading, .nextChange, .previousChange,
             .markChangesReviewed,
             .followLinkAtCaret, .nextLink, .previousLink, .scrollDown, .scrollUp,
             .pageDown, .pageUp, .documentStart, .documentEnd, .goBack, .goForward:
            return .navigate
        case .moveBlockUp, .moveBlockDown, .foldSection,
             .unfoldSection, .foldAll, .unfoldAll, .sortListAlphabetically, .sortListByState,
             .insertTableOfContents, .tidyDocument, .frontMatterEditor, .tableEditor,
             .assetDoctor:
            return .document
        case .splitView, .pinWindow:
            return .window
        case .preferences, .showKeybindings, .checkForUpdates, .toggleLightDark:
            // Settings…, Keyboard Shortcuts…, and Check for Updates… live in
            // the app menu on macOS, and that is what the editor must say.
            // Toggle Light/Dark is here too — it's an app-wide toggle, not a
            // per-document setting.
            return .application
        case .goToLine:
            return .navigate
        }
    }

    /// Modes in which the command is dispatchable.
    var scopes: Set<CommandScope> {
        switch self {
        case .toggleBold, .toggleItalic, .insertLink, .toggleStrikethrough, .toggleInlineCode,
             .indentList, .outdentList:
            return [.live]
        default:
            return [.read, .live, .source]
        }
    }

    /// What must hold before this command can do its job.  Menu validation is
    /// derived from this, so an item is never enabled in a state where running
    /// it would be a no-op.
    var requires: CommandPrecondition {
        switch self {
        case .newDocument, .open, .preferences, .showKeybindings,
             .reloadTheme, .compareFiles, .toggleLightDark:
            return .always
        case .checkForUpdates:
            return .updateCheck
        case .save:
            return .unsavedChanges
        case .findNext, .findPrevious:
            return .findQuery
        case .goBack:
            return .backHistory
        case .goForward:
            return .forwardHistory
        case .stopSpeaking:
            return .speaking
        case .tableEditor:
            return .tableAtCaret
        case .revealInFinder, .openInEditor, .versionTimeline, .copySectionLink, .findInSiblings:
            return .documentWithFile
        case .useSelectionForFind, .exportSelectionAsImage:
            return .selection
        case .nextChange, .previousChange, .markChangesReviewed:
            return .changeMarks
        default:
            return .document
        }
    }

    func isEnabled(in context: CommandContext) -> Bool {
        requires.isSatisfied(in: context)
    }
}

enum CommandScope: String, Codable, CaseIterable {
    case read, live, source
}

// MARK: - Preconditions

/// The one condition a command needs before it can run.  A typed value rather
/// than a hand-written `validateMenuItem` switch, so the menu bar, the palette,
/// and any future toolbar all agree by construction.
enum CommandPrecondition: String, CaseIterable {
    /// Runs with no document open — the start-window state.
    case always
    /// Needs a document window.
    case document
    /// Needs a document that exists on disk (paths, siblings, history).
    case documentWithFile
    /// Needs a non-empty selection.
    case selection
    /// Needs a configured, idle updater.
    case updateCheck
    case unsavedChanges
    case findQuery
    case backHistory
    case forwardHistory
    case speaking
    case tableAtCaret
    /// Needs at least one live change mark to walk or to retire.
    case changeMarks

    func isSatisfied(in context: CommandContext) -> Bool {
        switch self {
        case .always: return true
        case .document: return context.hasDocument
        case .changeMarks: return context.hasDocument && context.hasChangeMarks
        case .documentWithFile: return context.hasDocument && context.documentHasFile
        case .selection: return context.hasDocument && context.hasSelection
        case .updateCheck: return context.canCheckForUpdates
        case .unsavedChanges:
            return context.hasDocument && (context.hasUnsavedChanges || !context.documentHasFile)
        case .findQuery: return context.hasDocument && context.hasFindQuery
        case .backHistory: return context.hasDocument && context.canGoBack
        case .forwardHistory: return context.hasDocument && context.canGoForward
        case .speaking: return context.hasDocument && context.isSpeaking
        case .tableAtCaret: return context.hasDocument && context.caretIsInTable
        }
    }
}

/// The facts a `CommandPrecondition` is evaluated against.  Callers assemble
/// one from whatever they own; the policy above stays pure and testable.
struct CommandContext: Equatable {
    var hasDocument: Bool
    var documentHasFile: Bool
    var hasSelection: Bool
    var canCheckForUpdates: Bool
    var hasUnsavedChanges: Bool
    var hasFindQuery: Bool
    var canGoBack: Bool
    var canGoForward: Bool
    var isSpeaking: Bool
    var caretIsInTable: Bool
    /// At least one unexpired change mark is on the page.
    var hasChangeMarks: Bool

    init(
        hasDocument: Bool = false,
        documentHasFile: Bool = false,
        hasSelection: Bool = false,
        canCheckForUpdates: Bool = false,
        hasUnsavedChanges: Bool = false,
        hasFindQuery: Bool = false,
        canGoBack: Bool = false,
        canGoForward: Bool = false,
        isSpeaking: Bool = false,
        caretIsInTable: Bool = false,
        hasChangeMarks: Bool = false
    ) {
        self.hasDocument = hasDocument
        self.documentHasFile = documentHasFile
        self.hasSelection = hasSelection
        self.canCheckForUpdates = canCheckForUpdates
        self.hasUnsavedChanges = hasUnsavedChanges
        self.hasFindQuery = hasFindQuery
        self.canGoBack = canGoBack
        self.canGoForward = canGoForward
        self.isSpeaking = isSpeaking
        self.caretIsInTable = caretIsInTable
        self.hasChangeMarks = hasChangeMarks
    }

    /// No document anywhere — what the app menu sees while only the start
    /// window is up.
    static func applicationOnly(canCheckForUpdates: Bool) -> CommandContext {
        CommandContext(canCheckForUpdates: canCheckForUpdates)
    }
}

// MARK: - Key bindings

/// A single chord.
///
/// Serialised as `{"key": "+", "modifiers": ["command"]}`.  The old
/// `"cmd++"` string form is still *read* so existing files keep working, but
/// it is never written: it could not represent `+` without ambiguity, and a
/// binding it failed to parse took the whole keybindings file down with it.
struct KeyBinding: Codable, Hashable {
    var key: String                  // "e", "space", "left", "[", "+"
    var modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiers = KeyBinding.normalized(modifiers)
    }

    /// Modifier bits that actually mean something to a shortcut.  Caps Lock and
    /// Fn are sticky state, not a chord, and an enabled Caps Lock must not make
    /// `⌘S` stop matching.  Applied on construction and on every equality/hash
    /// so a stored binding and an incoming event always agree.
    static func normalized(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection([.command, .shift, .option, .control, .numericPad])
    }

    /// The modifier names used on disk.  A typed value, so an unknown name is
    /// a decode error the user is told about rather than a silently dropped
    /// modifier that changes what their shortcut does.
    enum Modifier: String, Codable, CaseIterable {
        case control, option, shift, command, numericPad

        var flag: NSEvent.ModifierFlags {
            switch self {
            case .control: return .control
            case .option: return .option
            case .shift: return .shift
            case .command: return .command
            case .numericPad: return .numericPad
            }
        }

        /// Stable order, so the file does not churn between writes.
        static func names(in flags: NSEvent.ModifierFlags) -> [Modifier] {
            allCases.filter { flags.contains($0.flag) }
        }

        static func flags(_ names: [Modifier]) -> NSEvent.ModifierFlags {
            names.reduce(into: NSEvent.ModifierFlags()) { $0.insert($1.flag) }
        }
    }

    // MARK: Serialisation

    private enum CodingKeys: String, CodingKey { case key, modifiers }

    /// Legacy string form, kept for reading old files and for diagnostics.
    ///
    /// `"cmd++"` (⌘ plus the `+` key) is the case that used to be unreadable:
    /// splitting on `+` and dropping empty parts left no key at all.
    init?(parsing string: String) {
        var parts = string.lowercased()
            .split(separator: "+", omittingEmptySubsequences: false)
            .map(String.init)
        // "+" → ["", ""] and "cmd++" → ["cmd", "", ""]: two empty tails are the
        // literal `+` key, not two empty components.
        if parts.count >= 2, parts[parts.count - 1].isEmpty, parts[parts.count - 2].isEmpty {
            parts.removeLast(2)
            parts.append("+")
        }
        guard let key = parts.popLast(), !key.isEmpty else { return nil }
        var flags: NSEvent.ModifierFlags = []
        for part in parts {
            switch part {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: return nil
            }
        }
        self.init(key, flags)
    }

    var serialized: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option) { parts.append("opt") }
        if modifiers.contains(.shift) { parts.append("shift") }
        if modifiers.contains(.command) { parts.append("cmd") }
        parts.append(key)
        return parts.joined(separator: "+")
    }

    init(from decoder: Decoder) throws {
        if let container = try? decoder.singleValueContainer(),
           let raw = try? container.decode(String.self) {
            guard let parsed = KeyBinding(parsing: raw) else {
                throw DecodingError.dataCorrupted(
                    .init(codingPath: decoder.codingPath, debugDescription: "bad key binding \"\(raw)\"")
                )
            }
            self = parsed
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let key = try container.decode(String.self, forKey: .key)
        guard !key.isEmpty else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "key binding has an empty key")
            )
        }
        let modifiers = try container.decodeIfPresent([Modifier].self, forKey: .modifiers) ?? []
        self.init(key, Modifier.flags(modifiers))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(key, forKey: .key)
        try container.encode(Modifier.names(in: modifiers), forKey: .modifiers)
    }

    static func == (a: KeyBinding, b: KeyBinding) -> Bool {
        a.key == b.key && KeyBinding.normalized(a.modifiers) == KeyBinding.normalized(b.modifiers)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(KeyBinding.normalized(modifiers).rawValue)
    }

    // MARK: Display

    /// `⌘⇧O`, `⌥↓`, `space`.
    var displayString: String {
        var out = ""
        if modifiers.contains(.control) { out += "⌃" }
        if modifiers.contains(.option) { out += "⌥" }
        if modifiers.contains(.shift) { out += "⇧" }
        if modifiers.contains(.command) { out += "⌘" }
        out += KeyBinding.displayKey(key)
        return out
    }

    static func displayKey(_ key: String) -> String {
        switch key {
        case "space": return "Space"
        case "left": return "←"
        case "right": return "→"
        case "up": return "↑"
        case "down": return "↓"
        case "return", "enter": return "↩"
        case "tab": return "⇥"
        case "escape", "esc": return "⎋"
        case "delete", "backspace": return "⌫"
        case "backslash": return "\\"
        default: return key.count == 1 ? key.uppercased() : key.capitalized
        }
    }

    /// The `keyEquivalent` string AppKit wants for a menu item.
    var menuKeyEquivalent: String {
        switch key {
        case "space": return " "
        case "left": return String(UnicodeScalar(NSLeftArrowFunctionKey)!)
        case "right": return String(UnicodeScalar(NSRightArrowFunctionKey)!)
        case "up": return String(UnicodeScalar(NSUpArrowFunctionKey)!)
        case "down": return String(UnicodeScalar(NSDownArrowFunctionKey)!)
        case "return", "enter": return "\r"
        case "tab": return "\t"
        case "backslash": return "\\"
        default: return key
        }
    }

    /// Normalised key name for an incoming event, so lookup is a dictionary hit.
    static func key(for event: NSEvent) -> String? {
        switch Int(event.keyCode) {
        case 49: return "space"
        case 123: return "left"
        case 124: return "right"
        case 125: return "down"
        case 126: return "up"
        case 36, 76: return "return"
        case 48: return "tab"
        case 53: return "escape"
        case 51: return "delete"
        case 116: return "pageup"
        case 121: return "pagedown"
        default:
            guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return nil }
            return characters.lowercased()
        }
    }
}
