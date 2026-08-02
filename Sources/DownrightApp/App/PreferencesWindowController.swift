import AppKit
import MarkdownCore
import MarkdownRender

/// Settings, including the keybinding editor §7.2 promises.
///
/// The keys pane is generated from the `Command` table, so a command added
/// anywhere in the app is remappable here without touching this file.
@MainActor
final class PreferencesWindowController: NSWindowController {
    convenience init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let panes: [(String, String, [PreferenceRow])] = [
            ("General", "gearshape", PreferencesForms.general()),
            ("Appearance", "circle.lefthalf.filled", PreferencesForms.appearance()),
            ("Typography", "textformat", PreferencesForms.typography()),
            ("Editor", "square.and.pencil", PreferencesForms.editor()),
            ("History", "clock.arrow.circlepath", PreferencesForms.history()),
        ]
        for (title, symbol, rows) in panes {
            let pane = PreferencesPane(title: title, symbol: symbol, rows: rows)
            tabs.addTabViewItem(NSTabViewItem(viewController: pane))
        }
        tabs.addTabViewItem(NSTabViewItem(viewController: KeybindingsPane()))

        let window = NSWindow(contentViewController: tabs)
        window.title = "Downright Settings"
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 760, height: 600))
        self.init(window: window)
    }
}

// MARK: - Form rows

/// A row in a settings pane.  Keeping the panes declarative means a new
/// preference is one line here, not a layout exercise.
enum PreferenceRow {
    case toggle(String, help: String?, get: () -> Bool, set: (Bool) -> Void)
    case stepper(String, help: String?, range: ClosedRange<Double>, step: Double, get: () -> Double, set: (Double) -> Void)
    case choice(String, help: String?, options: [String], get: () -> Int, set: (Int) -> Void)
    case text(String, help: String?, get: () -> String, set: (String) -> Void)
    case section(String)
    case note(String)
}

final class PreferencesPane: NSViewController {
    private let rows: [PreferenceRow]
    private let paneTitle: String
    private let symbol: String

    init(title: String, symbol: String, rows: [PreferenceRow]) {
        self.paneTitle = title
        self.symbol = symbol
        self.rows = rows
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        for row in rows { stack.addArrangedSubview(control(for: row)) }

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
        ])
        view = scroll
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let item = tabBarItem { item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: paneTitle) }
    }

    private var tabBarItem: NSTabViewItem? {
        (parent as? NSTabViewController)?.tabViewItems.first { $0.viewController === self }
    }

    private func control(for row: PreferenceRow) -> NSView {
        switch row {
        case .section(let title):
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label

        case .note(let text):
            let label = NSTextField(wrappingLabelWithString: text)
            label.font = .systemFont(ofSize: 11)
            label.textColor = .tertiaryLabelColor
            label.preferredMaxLayoutWidth = 520
            return label

        case .toggle(let title, let help, let get, let set):
            let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            button.state = get() ? .on : .off
            let handler = ActionHandler { set(button.state == .on) }
            button.target = handler
            button.action = #selector(ActionHandler.run)
            objc_setAssociatedObject(button, &PreferencesPane.handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
            return labelled(button, help: help)

        case .stepper(let title, let help, let range, let step, let get, let set):
            let field = NSTextField(string: String(format: "%g", get()))
            field.formatter = NumberFormatter()
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let stepper = NSStepper()
            stepper.minValue = range.lowerBound
            stepper.maxValue = range.upperBound
            stepper.increment = step
            stepper.doubleValue = get()
            let updateValue: (Double) -> Void = { value in
                let value = min(range.upperBound, max(range.lowerBound, value))
                stepper.doubleValue = value
                field.stringValue = String(format: "%g", value)
                set(value)
            }
            let stepperHandler = ActionHandler { updateValue(stepper.doubleValue) }
            let fieldHandler = ActionHandler {
                guard let value = Double(field.stringValue) else {
                    field.stringValue = String(format: "%g", stepper.doubleValue)
                    return
                }
                updateValue(value)
            }
            stepper.target = stepperHandler
            stepper.action = #selector(ActionHandler.run)
            field.target = fieldHandler
            field.action = #selector(ActionHandler.run)
            objc_setAssociatedObject(stepper, &PreferencesPane.handlerKey, stepperHandler, .OBJC_ASSOCIATION_RETAIN)
            objc_setAssociatedObject(field, &PreferencesPane.handlerKey, fieldHandler, .OBJC_ASSOCIATION_RETAIN)

            let row = NSStackView(views: [NSTextField(labelWithString: title), field, stepper])
            row.orientation = .horizontal
            row.spacing = 8
            return labelled(row, help: help)

        case .choice(let title, let help, let options, let get, let set):
            let popup = NSPopUpButton()
            popup.addItems(withTitles: options)
            popup.selectItem(at: min(get(), max(0, options.count - 1)))
            let handler = ActionHandler { set(popup.indexOfSelectedItem) }
            popup.target = handler
            popup.action = #selector(ActionHandler.run)
            objc_setAssociatedObject(popup, &PreferencesPane.handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)

            let row = NSStackView(views: [NSTextField(labelWithString: title), popup])
            row.orientation = .horizontal
            row.spacing = 8
            return labelled(row, help: help)

        case .text(let title, let help, let get, let set):
            let field = NSTextField(string: get())
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
            let handler = ActionHandler { set(field.stringValue) }
            field.target = handler
            field.action = #selector(ActionHandler.run)
            objc_setAssociatedObject(field, &PreferencesPane.handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)

            let row = NSStackView(views: [NSTextField(labelWithString: title), field])
            row.orientation = .horizontal
            row.spacing = 8
            return labelled(row, help: help)
        }
    }

    private func labelled(_ control: NSView, help: String?) -> NSView {
        guard let help else { return control }
        let hint = NSTextField(wrappingLabelWithString: help)
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor
        hint.preferredMaxLayoutWidth = 520
        let stack = NSStackView(views: [control, hint])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        return stack
    }

    private static var handlerKey: UInt8 = 0
}

final class ActionHandler: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func run() { block() }
}

// MARK: - Form definitions

enum PreferencesForms {
    static func general() -> [PreferenceRow] {
        [
            .section("On open"),
            .toggle("Restore windows from the last session", help: nil,
                    get: { Preferences.shared.values.restoreSession },
                    set: { value in Preferences.shared.update { $0.restoreSession = value } }),

            .section("Agent workflow"),
            .toggle("Watch files for external changes", help: "Marks up what changed while you were reading (§8.1).",
                    get: { Preferences.shared.values.watchFiles },
                    set: { value in Preferences.shared.update { $0.watchFiles = value } }),
            .toggle("Resolve file paths in documents",
                    help: "Underlines paths the agent claims to have touched that aren't there (§8.4).",
                    get: { Preferences.shared.values.resolvePathTokens },
                    set: { value in Preferences.shared.update { $0.resolvePathTokens = value } }),
            .choice("Open code files in",
                    help: nil,
                    options: ExternalEditor.allCases.map(\.title),
                    get: { ExternalEditor.allCases.firstIndex(of: Preferences.shared.values.externalEditor) ?? 0 },
                    set: { index in
                        guard ExternalEditor.allCases.indices.contains(index) else { return }
                        Preferences.shared.update { $0.externalEditor = ExternalEditor.allCases[index] }
                    }),
            .text("Extra sibling folders",
                  help: "Comma-separated, scanned one level down from the document (§8.7).",
                  get: { Preferences.shared.values.siblingScanDirectories.joined(separator: ", ") },
                  set: { value in
                      Preferences.shared.update {
                          $0.siblingScanDirectories = value
                              .split(separator: ",")
                              .map { $0.trimmingCharacters(in: .whitespaces) }
                              .filter { !$0.isEmpty }
                      }
                  }),
            .toggle("Keep the sibling sidebar open",
                    help: "Pin the document's related files beside the editor.",
                    get: { Preferences.shared.values.siblingSidebarVisible },
                    set: { value in Preferences.shared.update { $0.siblingSidebarVisible = value } }),
        ]
    }

    static func typography() -> [PreferenceRow] {
        [
            .section("Body"),
            .note("These values persist through Preferences.effectiveTypography. Applying them to open document surfaces is owned by the render/controller lane."),
            .choice("Preset", help: "Reading is New York, Working is SF Pro Text (§11.1).",
                    options: TypographyConfig.BodyPreset.allCases.map(\.title),
                    get: {
                        TypographyConfig.BodyPreset.allCases
                            .firstIndex(of: Preferences.shared.values.typography.preset) ?? 0
                    },
                    set: { index in
                        guard TypographyConfig.BodyPreset.allCases.indices.contains(index) else { return }
                        Preferences.shared.update {
                            $0.typography.preset = TypographyConfig.BodyPreset.allCases[index]
                        }
                    }),
            .stepper("Size", help: nil, range: 11...24, step: 1,
                     get: { Double(Preferences.shared.values.typography.bodySize) },
                     set: { value in Preferences.shared.update { $0.typography.bodySize = CGFloat(value) } }),
            .stepper("Text size adjustment", help: "A quick app-wide nudge, also available from the View menu.",
                     range: -4...10, step: 1,
                     get: { Double(Preferences.shared.values.textSizeAdjustment) },
                     set: { value in Preferences.shared.update { $0.textSizeAdjustment = CGFloat(value) } }),
            .choice("Type scale", help: "One ratio drives every heading size (§11.1).",
                    options: ["1.200", "1.250", "1.333"],
                    get: {
                        let ratio = Preferences.shared.values.typography.scaleRatio
                        return ratio < 1.22 ? 0 : (ratio < 1.29 ? 1 : 2)
                    },
                    set: { index in
                        let ratios: [CGFloat] = [1.2, 1.25, 1.333]
                        guard ratios.indices.contains(index) else { return }
                        Preferences.shared.update {
                            $0.typography.scaleRatio = ratios[index]
                        }
                    }),
            .stepper("Line height", help: nil, range: 1.2...2.0, step: 0.05,
                     get: { Double(Preferences.shared.values.typography.lineHeightMultiple) },
                     set: { value in Preferences.shared.update { $0.typography.lineHeightMultiple = CGFloat(value) } }),
            .stepper("Measure (characters)", help: "Capped at 68–72; full-width text is the single most common thing markdown viewers get wrong (§11.1).",
                     range: 60...80, step: 1,
                     get: { Double(Preferences.shared.values.typography.measureCharacters) },
                     set: { value in Preferences.shared.update { $0.typography.measureCharacters = CGFloat(value) } }),

            .section("Code"),
            .text("Monospace family", help: nil,
                  get: { Preferences.shared.values.typography.monoFamily },
                  set: { value in Preferences.shared.update { $0.typography.monoFamily = value } }),
            .toggle("Ligatures", help: nil,
                    get: { Preferences.shared.values.typography.monoLigatures },
                    set: { value in Preferences.shared.update { $0.typography.monoLigatures = value } }),

            .section("Detail"),
            .toggle("Hanging punctuation and optical margins", help: "Makes text look set rather than merely laid out (§11.1).",
                    get: { Preferences.shared.values.typography.opticalMargins },
                    set: { value in Preferences.shared.update { $0.typography.opticalMargins = value } }),
            .stepper("Math scale", help: "Math sized optically against body text (§11.3).",
                     range: 0.8...1.3, step: 0.05,
                     get: { Double(Preferences.shared.values.typography.mathScale) },
                     set: { value in Preferences.shared.update { $0.typography.mathScale = CGFloat(value) } }),
        ]
    }

    static func appearance() -> [PreferenceRow] {
        [
            .section("Themes"),
            .choice("Light theme", help: "Used when macOS is in Light appearance.",
                    options: ThemeStore.shared.themes.filter { $0.appearance != .dark }.map(\.name),
                    get: {
                        let names = ThemeStore.shared.themes.filter { $0.appearance != .dark }.map(\.name)
                        return names.firstIndex(of: Preferences.shared.values.themeName) ?? 0
                    },
                    set: { index in
                        let names = ThemeStore.shared.themes.filter { $0.appearance != .dark }.map(\.name)
                        guard names.indices.contains(index) else { return }
                        Preferences.shared.update { $0.themeName = names[index] }
                    }),
            .choice("Dark theme", help: "Used when macOS is in Dark appearance.",
                    options: ThemeStore.shared.themes.filter { $0.appearance != .light }.map(\.name),
                    get: {
                        let names = ThemeStore.shared.themes.filter { $0.appearance != .light }.map(\.name)
                        return names.firstIndex(of: Preferences.shared.values.darkThemeName) ?? 0
                    },
                    set: { index in
                        let names = ThemeStore.shared.themes.filter { $0.appearance != .light }.map(\.name)
                        guard names.indices.contains(index) else { return }
                        Preferences.shared.update { $0.darkThemeName = names[index] }
                    }),
            .toggle("Follow system appearance", help: "Switch between the selected light and dark themes automatically.",
                    get: { Preferences.shared.values.followsSystemAppearance },
                    set: { value in Preferences.shared.update { $0.followsSystemAppearance = value } }),
        ]
    }

    static func editor() -> [PreferenceRow] {
        [
            .section("Typing"),
            .toggle("Typewriter scrolling", help: nil,
                    get: { Preferences.shared.values.typewriterScrolling },
                    set: { value in Preferences.shared.update { $0.typewriterScrolling = value } }),
            .toggle("Use typographic substitutions", help: "Convert smart quotes and dashes while typing. Off keeps Markdown source exact.",
                    get: { Preferences.shared.values.typographicSubstitution },
                    set: { value in Preferences.shared.update { $0.typographicSubstitution = value } }),
            .section("Display"),
            .toggle("Show spaces and tabs", help: "Draw whitespace markers in the visible viewport.",
                    get: { Preferences.shared.values.showInvisibles },
                    set: { value in Preferences.shared.update { $0.showInvisibles = value } }),
            .toggle("Reveal syntax at every cursor", help: "Show inline markers for secondary insertion cursors too.",
                    get: { Preferences.shared.values.revealMarkersAtAllCursors },
                    set: { value in Preferences.shared.update { $0.revealMarkersAtAllCursors = value } }),
            .toggle("Focus mode on open", help: "Hide surrounding chrome and panels for a single-column writing surface.",
                    get: { Preferences.shared.values.focusMode },
                    set: { value in Preferences.shared.update { $0.focusMode = value } }),
            .choice("Default mode", help: "The presentation used when opening a document.",
                    options: RenderMode.userFacingModes.map(\.title),
                    get: {
                        RenderMode.userFacingModes.firstIndex(of: Preferences.shared.values.defaultMode) ?? 0
                    },
                    set: { index in
                        guard RenderMode.userFacingModes.indices.contains(index) else { return }
                        Preferences.shared.update { $0.defaultMode = RenderMode.userFacingModes[index] }
                    }),
            .section("Performance"),
            .stepper("Collapse long code after", help: "Lines. Used when a document is opened in the reading projection.",
                     range: 1...10_000, step: 1,
                     get: { Double(Preferences.shared.values.codeBlockCollapseThreshold) },
                     set: { value in Preferences.shared.update { $0.codeBlockCollapseThreshold = Int(value) } }),
            .stepper("Large-file threshold", help: "Megabytes. Above this, layout uses a line-count estimate instead of eagerly laying out the whole file.",
                     range: 1...1024, step: 1,
                     get: { Double(Preferences.shared.values.largeFileThresholdMegabytes) },
                     set: { value in Preferences.shared.update { $0.largeFileThresholdMegabytes = Int(value) } }),
        ]
    }

    static func history() -> [PreferenceRow] {
        [
            .section("Local time travel (§8.3)"),
            .note("""
            Every external write is snapshotted to a content-addressed store, \
            deduplicated by hash. Agents don't commit and git doesn't help you \
            here — this is what makes ⌘⇧V possible.
            """),
            .stepper("Keep versions for", help: "Days.", range: 1...365, step: 1,
                     get: { Double(Preferences.shared.values.historyMaximumDays) },
                     set: { value in Preferences.shared.update { $0.historyMaximumDays = Int(value) } }),
            .stepper("Maximum size", help: "Megabytes.", range: 50...5000, step: 50,
                     get: { Double(Preferences.shared.values.historyMaximumMegabytes) },
                     set: { value in Preferences.shared.update { $0.historyMaximumMegabytes = Int(value) } }),
            .note("Currently using \(ByteCountFormatter.string(fromByteCount: Int64(SnapshotStore.shared.totalBytes()), countStyle: .file))."),
        ]
    }
}

// MARK: - Keybindings pane (§7.2)

final class KeybindingsPane: NSViewController {
    private let table = NSTableView()
    private var commands: [Command] = Command.allCases.sorted {
        ($0.menu.rawValue, $0.title) < ($1.menu.rawValue, $1.title)
    }
    private var recordingRow: Int?
    private var keyMonitor: Any?

    override func loadView() {
        title = "Keys"

        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(beginRecording)

        for (identifier, title, width) in [
            ("menu", "Menu", 90.0), ("command", "Command", 260.0), ("binding", "Shortcut", 140.0),
        ] {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
            column.title = title
            column.width = width
            table.addTableColumn(column)
        }

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true

        let hint = NSTextField(labelWithString: "Double-click a shortcut to record a new one. ⌫ clears it.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        let reset = NSButton(title: "Reset All", target: self, action: #selector(resetAll))
        let vim = NSButton(checkboxWithTitle: "Vim-style navigation keys", target: self, action: #selector(toggleVim))
        vim.state = Preferences.shared.values.vimKeys ? .on : .off

        let footer = NSStackView(views: [vim, NSView(), reset])
        footer.orientation = .horizontal

        let stack = NSStackView(views: [scroll, hint, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
        view = stack
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let item = (parent as? NSTabViewController)?.tabViewItems.first(where: { $0.viewController === self }) {
            item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keys")
        }
    }

    @objc private func beginRecording() {
        let row = table.clickedRow
        guard row >= 0, row < commands.count else { return }
        recordingRow = row
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<3))

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let row = self.recordingRow else { return event }
            defer { self.endRecording() }

            if event.keyCode == 53 { return nil }                      // ⎋ cancels
            if event.keyCode == 51 {                                   // ⌫ clears
                KeybindingStore.shared.setBinding(nil, for: self.commands[row])
                return nil
            }
            guard let key = KeyBinding.key(for: event) else { return nil }
            let binding = KeyBinding(key, event.modifierFlags.intersection(.deviceIndependentFlagsMask))

            let conflicts = KeybindingStore.shared.conflicts(for: binding, excluding: self.commands[row])
            if !conflicts.isEmpty {
                let alert = NSAlert()
                alert.messageText = "\(binding.displayString) is already used"
                alert.informativeText = "Assigned to \(conflicts.map(\.title).joined(separator: ", ")). Reassign it?"
                alert.addButton(withTitle: "Reassign")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                for conflict in conflicts { KeybindingStore.shared.setBinding(nil, for: conflict) }
            }
            KeybindingStore.shared.setBinding(binding, for: self.commands[row])
            return nil
        }
    }

    private func endRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recordingRow = nil
        table.reloadData()
        if let menu = NSApp.mainMenu { MainMenu.refreshKeyEquivalents(in: menu) }
    }

    @objc private func resetAll() {
        KeybindingStore.shared.resetToDefaults()
        table.reloadData()
    }

    @objc private func toggleVim(_ sender: NSButton) {
        Preferences.shared.update { $0.vimKeys = sender.state == .on }
        table.reloadData()
    }
}

extension KeybindingsPane: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let command = commands[row]
        let text: String
        switch tableColumn?.identifier.rawValue {
        case "menu": text = command.menu.title
        case "command": text = command.title
        default:
            if recordingRow == row {
                text = "Press a shortcut…"
            } else {
                text = KeybindingStore.shared.bindings(for: command)
                    .map(\.displayString).joined(separator: "  ")
            }
        }
        let field = NSTextField(labelWithString: text)
        field.font = tableColumn?.identifier.rawValue == "binding"
            ? .monospacedSystemFont(ofSize: 11, weight: .regular)
            : .systemFont(ofSize: 12)
        if recordingRow == row && tableColumn?.identifier.rawValue == "binding" {
            field.textColor = .controlAccentColor
        } else if KeybindingStore.shared.isOverridden(command) {
            field.textColor = .controlAccentColor
        }
        return field
    }
}
