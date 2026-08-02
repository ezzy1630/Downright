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
    case toggleReadLive, sourceMode, splitView, pinWindow, focusMode, typewriterScrolling
    case toggleSidebar, outlineQuickOpen, outlinePanel, taskPanel, versionTimeline, compareFiles
    case frontMatterEditor, tableEditor, assetDoctor
    case commandPalette, documentLens, readerProfiles
    case documentHealth, renderTargets, visualDebugger, reviewPanel, workspace, localAI

    // Navigation
    case nextHeading, previousHeading, nextChange, previousChange
    case scrollDown, scrollUp, pageDown, pageUp, documentStart, documentEnd
    case goBack, goForward, cycleFocusable, activateFocused

    // Structural zoom (§5.2)
    case zoomLevel1, zoomLevel2, zoomLevel3, zoomLevel4, zoomLevel5, zoomIn, zoomOut

    // Find (§9.4)
    case find, findNext, findPrevious, findReplace, findInSiblings, useSelectionForFind

    // Restructuring (§9.2)
    case promoteHeading, demoteHeading, moveBlockUp, moveBlockDown
    case foldSection, unfoldSection, foldAll, unfoldAll
    case convertToParagraph, convertToBulletList, convertToNumberedList
    case convertToTaskList, convertToBlockquote
    case sortListAlphabetically, sortListByState, insertTableOfContents, tidyDocument

    // Editing (§6.4)
    case toggleBold, toggleItalic, insertLink, toggleStrikethrough, toggleInlineCode
    case addCursorBelow, addCursorAbove, selectNextOccurrence, splitSelectionIntoLines
    case indentList, outdentList, toggleTaskAtCaret

    // Files and export (§9.5)
    case newDocument, open, save, saveAs, revealInFinder, openInEditor, close
    case copyAsMarkdown, copyAsRichText, copyAsPlainText, copySection, copySectionLink
    case printDocument, exportHTML, exportPDF, exportSelectionAsImage
    case increaseTextSize, decreaseTextSize, resetTextSize
    case speakDocument, stopSpeaking

    // App
    case preferences, reloadTheme, showKeybindings, toggleVimKeys

    var title: String {
        switch self {
        case .toggleReadLive: return "Exit Source Focus"
        case .sourceMode: return "Source Focus"
        case .splitView: return "Split View"
        case .pinWindow: return "Pin Window"
        case .focusMode: return "Focus Mode"
        case .typewriterScrolling: return "Typewriter Scrolling"
        case .toggleSidebar: return "Contents"
        case .outlineQuickOpen: return "Search Contents…"
        case .outlinePanel: return "Outline"
        case .taskPanel: return "Tasks"
        case .versionTimeline: return "Version Timeline"
        case .compareFiles: return "Compare Files…"
        case .frontMatterEditor: return "Front Matter…"
        case .tableEditor: return "Edit Table…"
        case .assetDoctor: return "Asset Doctor"
        case .commandPalette: return "Command Palette…"
        case .documentLens: return "Document Lens"
        case .readerProfiles: return "Reader Profiles…"
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
        case .scrollDown: return "Scroll Down"
        case .scrollUp: return "Scroll Up"
        case .pageDown: return "Page Down"
        case .pageUp: return "Page Up"
        case .documentStart: return "Top of Document"
        case .documentEnd: return "End of Document"
        case .goBack: return "Back"
        case .goForward: return "Forward"
        case .cycleFocusable: return "Cycle Links"
        case .activateFocused: return "Open Focused Link"
        case .zoomLevel1: return "Zoom: Top Level"
        case .zoomLevel2: return "Zoom: Two Levels"
        case .zoomLevel3: return "Zoom: All Headings"
        case .zoomLevel4: return "Zoom: Skeleton"
        case .zoomLevel5: return "Zoom: Everything"
        case .zoomIn: return "Zoom In"
        case .zoomOut: return "Zoom Out"
        case .find: return "Find…"
        case .findNext: return "Find Next"
        case .findPrevious: return "Find Previous"
        case .findReplace: return "Find and Replace…"
        case .findInSiblings: return "Find in Sibling Files…"
        case .useSelectionForFind: return "Use Selection for Find"
        case .promoteHeading: return "Promote Heading"
        case .demoteHeading: return "Demote Heading"
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
        case .insertLink: return "Link…"
        case .toggleStrikethrough: return "Strikethrough"
        case .toggleInlineCode: return "Inline Code"
        case .addCursorBelow: return "Add Cursor Below"
        case .addCursorAbove: return "Add Cursor Above"
        case .selectNextOccurrence: return "Select Next Occurrence"
        case .splitSelectionIntoLines: return "Split Selection into Lines"
        case .indentList: return "Indent"
        case .outdentList: return "Outdent"
        case .toggleTaskAtCaret: return "Toggle Task"
        case .newDocument: return "New"
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
        case .toggleVimKeys: return "Vim-style Keys"
        }
    }

    /// Where the command appears in the menu bar.
    enum Menu: String, CaseIterable {
        case file, edit, format, view, navigate, document, window, help

        var title: String { rawValue.capitalized }
    }

    var menu: Menu {
        switch self {
        case .newDocument, .open, .save, .saveAs, .close, .revealInFinder, .openInEditor,
             .printDocument, .exportHTML, .exportPDF, .exportSelectionAsImage, .compareFiles:
            return .file
        case .copyAsMarkdown, .copyAsRichText, .copyAsPlainText, .copySection, .copySectionLink,
             .find, .findNext, .findPrevious, .findReplace, .findInSiblings, .useSelectionForFind,
             .addCursorBelow, .addCursorAbove, .selectNextOccurrence, .splitSelectionIntoLines,
             .speakDocument, .stopSpeaking:
            return .edit
        case .toggleBold, .toggleItalic, .insertLink, .toggleStrikethrough, .toggleInlineCode,
             .convertToParagraph, .convertToBulletList, .convertToNumberedList, .convertToTaskList,
             .convertToBlockquote, .indentList, .outdentList, .toggleTaskAtCaret:
            return .format
        case .toggleReadLive, .sourceMode, .zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4,
             .zoomLevel5, .zoomIn, .zoomOut, .increaseTextSize, .decreaseTextSize, .resetTextSize,
             .focusMode, .typewriterScrolling, .toggleSidebar, .outlinePanel, .taskPanel,
             .versionTimeline, .reloadTheme, .commandPalette, .documentLens,
             .readerProfiles, .documentHealth, .renderTargets, .visualDebugger,
             .reviewPanel, .workspace, .localAI:
            return .view
        case .nextHeading, .previousHeading, .nextChange, .previousChange, .scrollDown, .scrollUp,
             .pageDown, .pageUp, .documentStart, .documentEnd, .goBack, .goForward,
             .outlineQuickOpen, .cycleFocusable, .activateFocused:
            return .navigate
        case .promoteHeading, .demoteHeading, .moveBlockUp, .moveBlockDown, .foldSection,
             .unfoldSection, .foldAll, .unfoldAll, .sortListAlphabetically, .sortListByState,
             .insertTableOfContents, .tidyDocument, .frontMatterEditor, .tableEditor,
             .assetDoctor:
            return .document
        case .splitView, .pinWindow:
            return .window
        case .preferences, .showKeybindings, .toggleVimKeys:
            return .help
        }
    }

    /// Modes in which the command is dispatchable.
    var scopes: Set<CommandScope> {
        switch self {
        case .toggleBold, .toggleItalic, .insertLink, .toggleStrikethrough, .toggleInlineCode,
             .addCursorBelow, .addCursorAbove, .selectNextOccurrence, .splitSelectionIntoLines,
             .indentList, .outdentList:
            return [.live]
        case .scrollDown, .scrollUp, .pageDown, .pageUp, .documentStart, .documentEnd,
             .cycleFocusable, .activateFocused, .nextHeading, .previousHeading,
             .zoomLevel1, .zoomLevel2, .zoomLevel3, .zoomLevel4, .zoomLevel5:
            // Single-letter bindings only work where there is no caret to
            // capture them (§7.2); the ⌘-modified equivalents stay global.
            return [.read]
        default:
            return [.read, .live, .source]
        }
    }
}

enum CommandScope: String, Codable, CaseIterable {
    case read, live, source
}

// MARK: - Key bindings

/// A single chord.  Parsed from and serialised to a stable string form so the
/// keybindings file is hand-editable.
struct KeyBinding: Codable, Hashable {
    var key: String                  // "e", "space", "left", "["
    var modifiers: NSEvent.ModifierFlags

    init(_ key: String, _ modifiers: NSEvent.ModifierFlags = []) {
        self.key = key
        self.modifiers = modifiers
    }

    // MARK: Serialisation

    init?(parsing string: String) {
        var flags: NSEvent.ModifierFlags = []
        var key: String?
        for part in string.lowercased().split(separator: "+").map(String.init) {
            switch part {
            case "cmd", "command": flags.insert(.command)
            case "shift": flags.insert(.shift)
            case "opt", "option", "alt": flags.insert(.option)
            case "ctrl", "control": flags.insert(.control)
            default: key = part
            }
        }
        guard let key, !key.isEmpty else { return nil }
        self.key = key
        self.modifiers = flags
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
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let parsed = KeyBinding(parsing: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad key binding \(raw)"))
        }
        self = parsed
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(serialized)
    }

    static func == (a: KeyBinding, b: KeyBinding) -> Bool {
        a.key == b.key && a.modifiers.intersection(.deviceIndependentFlagsMask) == b.modifiers.intersection(.deviceIndependentFlagsMask)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(key)
        hasher.combine(modifiers.intersection(.deviceIndependentFlagsMask).rawValue)
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
