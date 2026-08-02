import AppKit

/// The default binding table, transcribed from §7.2, plus the bindings the
/// commands added by §9 need.
///
/// Read mode's single-letter bindings are only reachable in `.read` scope
/// because there is no caret there to swallow them — that is the whole reason
/// §7.2 can spend the bare letter keys at all.
enum KeybindingDefaults {
    /// A command may carry more than one binding: `↓` and `j` both scroll.
    static let table: [Command: [KeyBinding]] = [
        // Global (§7.2)
        .toggleReadLive:      [KeyBinding("e", .command)],
        .sourceMode:          [KeyBinding("e", [.command, .shift])],
        .toggleSidebar:       [KeyBinding("0", .command)],
        .outlineQuickOpen:    [KeyBinding("o", [.command, .shift])],
        .taskPanel:           [KeyBinding("t", .command)],
        .versionTimeline:     [KeyBinding("v", [.command, .shift])],
        .nextChange:          [KeyBinding("down", .option)],
        .previousChange:      [KeyBinding("up", .option)],
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
        .copyAsMarkdown:      [KeyBinding("c", .command)],
        .copyAsRichText:      [KeyBinding("c", [.command, .shift])],
        .copySection:         [KeyBinding("c", [.command, .option])],
        .printDocument:       [KeyBinding("p", .command)],
        .exportHTML:          [KeyBinding("p", [.command, .shift])],

        // Read mode single keys (§7.2)
        .pageDown:            [KeyBinding("space")],
        .pageUp:              [KeyBinding("space", .shift)],
        .scrollDown:          [KeyBinding("down")],
        .scrollUp:            [KeyBinding("up")],
        .nextHeading:         [KeyBinding("n")],
        .previousHeading:     [KeyBinding("p")],
        .zoomLevel1:          [KeyBinding("1")],
        .zoomLevel2:          [KeyBinding("2")],
        .zoomLevel3:          [KeyBinding("3")],
        .zoomLevel4:          [KeyBinding("4")],
        .zoomLevel5:          [KeyBinding("5")],
        .cycleFocusable:      [KeyBinding("tab")],
        .activateFocused:     [KeyBinding("return")],

        // Files and editing
        .newDocument:         [KeyBinding("n", .command)],
        .open:                [KeyBinding("o", .command)],
        .save:                [KeyBinding("s", .command)],
        .saveAs:              [KeyBinding("s", [.command, .shift])],
        .close:               [KeyBinding("w", .command)],
        .toggleBold:          [KeyBinding("b", .command)],
        .toggleItalic:        [KeyBinding("i", .command)],
        .insertLink:          [KeyBinding("k", .command)],
        .selectNextOccurrence:[KeyBinding("d", .command)],
        .increaseTextSize:    [KeyBinding("=", .command), KeyBinding("+", .command)],
        .decreaseTextSize:    [KeyBinding("-", .command)],
        .resetTextSize:       [KeyBinding("0", [.command, .option])],
        .preferences:         [KeyBinding(",", .command)],
        .outlinePanel:        [KeyBinding("1", [.command, .option])],
        .goBack:              [KeyBinding("[", .command)],
        .goForward:           [KeyBinding("]", .command)],
        .exportPDF:           [KeyBinding("p", [.command, .option])],
        .compareFiles:        [KeyBinding("d", [.command, .shift])],
        .tidyDocument:        [KeyBinding("t", [.command, .shift])],
        .focusMode:           [KeyBinding("f", [.command, .control])],
    ]

    /// `[` / `]` change navigation and `g` / `G` document ends collide with
    /// `⌘[`-style history in Read mode only, so they live in the read layer.
    static let readModeExtras: [Command: [KeyBinding]] = [
        .previousChange: [KeyBinding("[")],
        .nextChange:     [KeyBinding("]")],
        .outlineQuickOpen: [KeyBinding("o")],
        .taskPanel:      [KeyBinding("t")],
        .find:           [KeyBinding("f")],
        .toggleReadLive: [KeyBinding("e")],
    ]

    /// Off by default behind a toggle (§7.2).
    static let vimLayer: [Command: [KeyBinding]] = [
        .scrollDown:    [KeyBinding("j")],
        .scrollUp:      [KeyBinding("k")],
        .documentStart: [KeyBinding("g")],
        .documentEnd:   [KeyBinding("g", .shift)],
    ]
}

/// Loads, resolves, and persists key bindings.  One table in, one lookup out.
final class KeybindingStore {
    static let shared = KeybindingStore()

    private(set) var bindings: [Command: [KeyBinding]] = [:]
    /// Reverse index, rebuilt whenever bindings change.
    private var lookup: [CommandScope: [KeyBinding: Command]] = [:]
    private var overrides: [Command: [KeyBinding]] = [:]

    var vimKeysEnabled: Bool = false {
        didSet { guard vimKeysEnabled != oldValue else { return }; rebuild(); persist() }
    }

    private init() {
        load()
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
        persist()
    }

    func resetToDefaults() {
        overrides.removeAll()
        rebuild()
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

    private struct Stored: Codable {
        var vimKeysEnabled: Bool
        var overrides: [String: [KeyBinding]]
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.keybindingsFile),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return }
        vimKeysEnabled = stored.vimKeysEnabled
        overrides = stored.overrides.reduce(into: [:]) { result, entry in
            guard let command = Command(rawValue: entry.key) else { return }
            result[command] = entry.value
        }
    }

    private func persist() {
        AppPaths.ensure(AppPaths.supportDirectory)
        let stored = Stored(
            vimKeysEnabled: vimKeysEnabled,
            overrides: overrides.reduce(into: [:]) { $0[$1.key.rawValue] = $1.value }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        try? data.write(to: AppPaths.keybindingsFile, options: .atomic)
    }
}
