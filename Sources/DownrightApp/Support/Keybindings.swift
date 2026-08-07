import AppKit

/// The default binding table, transcribed from §7.2, plus the bindings the
/// commands added by §9 need.
///
/// Read mode's single-letter bindings are only reachable in `.read` scope
/// because there is no caret there to swallow them — that is the whole reason
/// §7.2 can spend the bare letter keys at all.
///
/// Chords are chosen so nothing shadows a macOS convention: ⌘0 is Actual Size,
/// ⌘⇧P is Page Setup, ⌘⇧V is Paste and Match Style, ⌃⌘F is Enter Full Screen,
/// and ⌘T / ⌘⇧T stay free for the tab chords users reach for reflexively.
enum KeybindingDefaults {
    /// A command may carry more than one binding: `↓` and `j` both scroll.
    static let table: [Command: [KeyBinding]] = [
        // Global (§7.2)
        .sourceMode:          [KeyBinding("e", [.command, .shift])],
        .useSelectionForFind: [KeyBinding("e", .command)],
        .outlineQuickOpen:    [KeyBinding("o", [.command, .shift])],
        .versionTimeline:     [KeyBinding("v", [.command, .option])],
        .commandPalette:      [KeyBinding("k", [.command, .shift])],
        .nextChange:          [KeyBinding("down", [.command, .control])],
        .previousChange:      [KeyBinding("up", [.command, .control])],
        .find:                [KeyBinding("f", .command)],
        .findNext:            [KeyBinding("g", .command)],
        .findPrevious:        [KeyBinding("g", [.command, .shift])],
        .findInSiblings:      [KeyBinding("f", [.command, .shift])],
        .findReplace:         [KeyBinding("f", [.command, .option])],
        .promoteHeading:      [KeyBinding("left", [.command, .option])],
        .demoteHeading:       [KeyBinding("right", [.command, .option])],
        .moveBlockUp:         [KeyBinding("up", [.command, .option])],
        .moveBlockDown:       [KeyBinding("down", [.command, .option])],
        .splitView:           [KeyBinding("backslash", .command)],
        .copyAsMarkdown:      [KeyBinding("c", [.command, .shift])],
        .copySection:         [KeyBinding("c", [.command, .option])],
        .printDocument:       [KeyBinding("p", .command)],
        .exportHTML:          [KeyBinding("e", [.command, .control])],

        // Panels share one ⌥⌘-number family, the way a navigator normally does.
        .outlinePanel:        [KeyBinding("1", [.command, .option])],
        .documentLens:        [KeyBinding("2", [.command, .option])],
        .taskPanel:           [KeyBinding("3", [.command, .option])],
        .toggleSidebar:       [KeyBinding("0", [.command, .option])],

        // Structural zoom shares one ⌃⌘ family, reachable while editing (§5.2).
        .zoomLevel1:          [KeyBinding("1", [.command, .control])],
        .zoomLevel2:          [KeyBinding("2", [.command, .control])],
        .zoomLevel3:          [KeyBinding("3", [.command, .control])],
        .zoomLevel4:          [KeyBinding("4", [.command, .control])],
        .zoomLevel5:          [KeyBinding("5", [.command, .control])],
        .zoomIn:              [KeyBinding("=", [.command, .control])],
        .zoomOut:             [KeyBinding("-", [.command, .control])],
        .nextHeading:         [KeyBinding("n", [.command, .control])],
        .previousHeading:     [KeyBinding("p", [.command, .control])],

        // Read mode single keys (§7.2)
        .pageDown:            [KeyBinding("space")],
        .pageUp:              [KeyBinding("space", .shift)],
        .scrollDown:          [KeyBinding("down")],
        .scrollUp:            [KeyBinding("up")],

        // Files and editing
        .newDocument:         [KeyBinding("n", .command)],
        .open:                [KeyBinding("o", .command)],
        .save:                [KeyBinding("s", .command)],
        .saveAs:              [KeyBinding("s", [.command, .shift])],
        .close:               [KeyBinding("w", .command)],
        .toggleBold:          [KeyBinding("b", .command)],
        .toggleItalic:        [KeyBinding("i", .command)],
        .insertLink:          [KeyBinding("k", .command)],
        // Ticking a box is a headline action, so it gets a one-modifier chord.
        .toggleTaskAtCaret:   [KeyBinding("l", .command)],
        // Tab in a list item; the text view decides whether the caret is in one
        // and otherwise types a tab.
        .indentList:          [KeyBinding("tab")],
        .outdentList:         [KeyBinding("tab", .shift)],
        // ⌘⇧= reports "+" on a US layout, so the second chord needs ⇧ to match.
        .increaseTextSize:    [KeyBinding("=", .command), KeyBinding("+", [.command, .shift])],
        .decreaseTextSize:    [KeyBinding("-", .command)],
        .resetTextSize:       [KeyBinding("0", .command)],
        .preferences:         [KeyBinding(",", .command)],
        .goBack:              [KeyBinding("[", .command)],
        .goForward:           [KeyBinding("]", .command)],
        .exportPDF:           [KeyBinding("p", [.command, .option])],
        .compareFiles:        [KeyBinding("d", [.command, .shift])],
        .tidyDocument:        [KeyBinding("t", [.command, .control])],
        .focusMode:           [KeyBinding("return", [.command, .shift])],
    ]

    /// `[` / `]` change navigation and `g` / `G` document ends collide with
    /// `⌘[`-style history in Read mode only, so they live in the read layer.
    /// The bare heading and zoom keys are here for the same reason: their ⌃⌘
    /// equivalents above are what works while a caret is in the document.
    static let readModeExtras: [Command: [KeyBinding]] = [
        .previousChange: [KeyBinding("[")],
        .nextChange:     [KeyBinding("]")],
        .outlineQuickOpen: [KeyBinding("o")],
        .taskPanel:      [KeyBinding("t")],
        .find:           [KeyBinding("f")],
        .nextHeading:    [KeyBinding("n")],
        .previousHeading: [KeyBinding("p")],
        .zoomLevel1:     [KeyBinding("1")],
        .zoomLevel2:     [KeyBinding("2")],
        .zoomLevel3:     [KeyBinding("3")],
        .zoomLevel4:     [KeyBinding("4")],
        .zoomLevel5:     [KeyBinding("5")],
    ]

    /// Off by default behind a toggle (§7.2).
    static let vimLayer: [Command: [KeyBinding]] = [
        .scrollDown:    [KeyBinding("j")],
        .scrollUp:      [KeyBinding("k")],
        .documentStart: [KeyBinding("g")],
        .documentEnd:   [KeyBinding("g", .shift)],
    ]
}

/// The outcome of reading the keybindings file.  "Absent" and "corrupt" are
/// different events and must not share a code path: the first is the normal
/// first-run case, the second is a file the user may have hand-edited and must
/// never be overwritten behind their back.
enum KeybindingLoad {
    case absent
    case loaded(vimKeysEnabled: Bool, overrides: [Command: [KeyBinding]])
    case unreadable(Error)

    /// Wire format.  Hand-editable by design (§7.2).
    struct Stored: Codable {
        var vimKeysEnabled: Bool
        var overrides: [String: [KeyBinding]]
    }

    static func read(contentsOf url: URL) -> KeybindingLoad {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            // Any read failure other than "no such file" is still a reason not
            // to clobber the file, so only a missing file counts as absent.
            let cocoa = error as NSError
            let missing = cocoa.domain == NSCocoaErrorDomain
                && [NSFileReadNoSuchFileError, NSFileNoSuchFileError].contains(cocoa.code)
            return missing ? .absent : .unreadable(error)
        }
        return decode(data)
    }

    static func decode(_ data: Data) -> KeybindingLoad {
        do {
            let stored = try JSONDecoder().decode(Stored.self, from: data)
            var overrides: [Command: [KeyBinding]] = [:]
            for (name, bindings) in stored.overrides {
                // A command that no longer exists is not corruption: it is an
                // older file naming a command this build removed.
                guard let command = Command(rawValue: name) else { continue }
                overrides[command] = bindings
            }
            return .loaded(vimKeysEnabled: stored.vimKeysEnabled, overrides: overrides)
        } catch {
            return .unreadable(error)
        }
    }
}

/// Loads, resolves, and persists key bindings.  One table in, one lookup out.
final class KeybindingStore {
    static let shared = KeybindingStore()

    private(set) var bindings: [Command: [KeyBinding]] = [:]
    /// Reverse index, rebuilt whenever bindings change.
    private var lookup: [CommandScope: [KeyBinding: Command]] = [:]
    private var overrides: [Command: [KeyBinding]] = [:]

    /// Set when the keybindings file exists but could not be read.  While this
    /// is non-nil the store refuses to write, so a file the user can still
    /// repair by hand is never replaced by defaults.
    private(set) var loadFailure: Error?
    /// Last write failure, if any.  Bindings stay correct in memory.
    private(set) var lastPersistenceError: Error?

    /// Installed by the app so the failure reaches the user.  Assigning it
    /// after a failure has already been recorded reports it immediately, which
    /// it must, because loading happens during `shared`'s initialiser.
    var onLoadFailure: ((Error) -> Void)? {
        didSet {
            if let loadFailure { onLoadFailure?(loadFailure) }
        }
    }

    var vimKeysEnabled: Bool = false {
        didSet { guard vimKeysEnabled != oldValue else { return }; rebuild(); persist() }
    }

    /// Reading the file assigns the same properties the user's edits do.  The
    /// hold stops that round-tripping straight back to disk — and stops the
    /// vim flag's `didSet` writing the file before the overrides are in place.
    private var isLoading = false

    private init() {
        isLoading = true
        load()
        isLoading = false
        rebuild()
    }

    // MARK: Lookup

    func bindings(for command: Command) -> [KeyBinding] {
        bindings[command] ?? []
    }

    func primaryBinding(for command: Command) -> KeyBinding? {
        bindings[command]?.first
    }

    /// Resolves a key event to a command within a mode.
    func command(for event: NSEvent, scope: CommandScope) -> Command? {
        guard let key = KeyBinding.key(for: event) else { return nil }
        let binding = KeyBinding(key, event.modifierFlags.intersection(.deviceIndependentFlagsMask))
        return lookup[scope]?[binding]
    }

    // MARK: Editing

    func setBinding(_ binding: KeyBinding?, for command: Command) {
        if let binding {
            overrides[command] = [binding]
        } else {
            overrides[command] = []
        }
        rebuild()
        // Recording a shortcut is an explicit instruction to write the file,
        // so it also clears a stale "do not touch this file" hold.
        loadFailure = nil
        persist()
    }

    func resetToDefaults() {
        overrides.removeAll()
        rebuild()
        loadFailure = nil
        persist()
    }

    func isOverridden(_ command: Command) -> Bool { overrides[command] != nil }

    /// Commands whose binding collides with `binding` in any shared scope.
    func conflicts(for binding: KeyBinding, excluding command: Command) -> [Command] {
        Command.allCases.filter { other in
            other != command
                && !other.scopes.isDisjoint(with: command.scopes)
                && bindings(for: other).contains(binding)
        }
    }

    // MARK: Building

    private func rebuild() {
        var resolved = KeybindingDefaults.table
        for (command, extras) in KeybindingDefaults.readModeExtras {
            resolved[command, default: []].append(contentsOf: extras)
        }
        if vimKeysEnabled {
            for (command, extras) in KeybindingDefaults.vimLayer {
                resolved[command, default: []].append(contentsOf: extras)
            }
        }
        for (command, override) in overrides {
            resolved[command] = override
        }
        bindings = resolved

        // A later command must not silently steal an earlier one's binding, so
        // build the reverse index in a defined order and keep the first claim.
        var built: [CommandScope: [KeyBinding: Command]] = [:]
        for scope in CommandScope.allCases { built[scope] = [:] }
        for command in Command.allCases {
            for binding in resolved[command] ?? [] {
                for scope in command.scopes where built[scope]?[binding] == nil {
                    built[scope]?[binding] = command
                }
            }
        }
        lookup = built
    }

    // MARK: Persistence

    private func load() {
        switch KeybindingLoad.read(contentsOf: AppPaths.keybindingsFile) {
        case .absent:
            return
        case .loaded(let vim, let stored):
            overrides = stored
            vimKeysEnabled = vim
        case .unreadable(let error):
            loadFailure = error
            onLoadFailure?(error)
        }
    }

    private func persist() {
        guard !isLoading, loadFailure == nil else { return }
        AppPaths.ensure(AppPaths.supportDirectory)
        let stored = KeybindingLoad.Stored(
            vimKeysEnabled: vimKeysEnabled,
            overrides: overrides.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(stored).write(to: AppPaths.keybindingsFile, options: .atomic)
            lastPersistenceError = nil
        } catch {
            lastPersistenceError = error
        }
    }
}
