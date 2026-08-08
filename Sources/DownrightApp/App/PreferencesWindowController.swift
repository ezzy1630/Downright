import AppKit
import MarkdownCore
import MarkdownRender

/// The panes of the Settings window, in the order they appear.
///
/// A typed value rather than a title string: "Keyboard Shortcuts…" has to be
/// able to name the pane it opens, and the search field has to be able to jump
/// to one.
enum SettingsPane: String, CaseIterable {
    case general, appearance, typography, editor, history, updates, keys

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .typography: return "Typography"
        case .editor: return "Editor"
        case .history: return "History"
        case .updates: return "Updates"
        case .keys: return "Keys"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "circle.lefthalf.filled"
        case .typography: return "textformat"
        case .editor: return "square.and.pencil"
        case .history: return "clock.arrow.circlepath"
        case .updates: return "arrow.down.circle"
        case .keys: return "keyboard"
        }
    }
}

/// A pane that participates in the settings search.
@MainActor
protocol PreferenceSearchable: AnyObject {
    /// Words the user typed; empty means "show everything".
    var searchQuery: String { get set }
    /// How many rows survive the current query.
    var searchMatchCount: Int { get }
}

/// Settings, including the keybinding editor.
///
/// The keys pane is generated from the `Command` table, so a command added
/// anywhere in the app is remappable here without touching this file.
@MainActor
final class PreferencesWindowController: NSWindowController {
    private let tabs: NSTabViewController
    private var panes: [(pane: SettingsPane, controller: NSViewController)] = []
    private let searchField = NSSearchField()
    private var tabSelectionObserver: NSKeyValueObservation?

    convenience init() {
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        let window = NSWindow(contentViewController: tabs)
        window.title = "Downright Settings"
        window.styleMask.insert(.resizable)
        window.setContentSize(NSSize(width: 760, height: 620))
        // Resizable, but not to the point of self-harm.  The forms lay out at a
        // fixed leading inset with wrapping help text under each control, so a
        // narrow window clips labels rather than reflowing them, and a short one
        // hides the keys pane's table behind its own footer.  This floor is the
        // narrowest width at which the longest setting label still fits on one
        // line, and the shortest height that leaves the keys table more rows
        // than chrome.
        window.contentMinSize = NSSize(width: 620, height: 420)
        window.setFrameAutosaveName("DownrightSettingsWindow")
        self.init(window: window, tabs: tabs)
    }

    private init(window: NSWindow, tabs: NSTabViewController) {
        self.tabs = tabs
        super.init(window: window)

        for pane in SettingsPane.allCases {
            let controller = PreferencesWindowController.controller(for: pane)
            if pane == .keys { _ = controller.view }
            controller.title = pane.title
            panes.append((pane, controller))
            let item = NSTabViewItem(viewController: controller)
            // `NSTabViewItem(viewController:)` copies the controller's `title`
            // once, when it is built, and never reads it again — a pane that
            // names itself later (the keys pane did, in `loadView()`, which does
            // not run until the tab is first selected) shows up in the toolbar
            // as "DownrightApp.KeybindingsPane".  `SettingsPane` already owns
            // the titles, so the label is taken from there rather than left to
            // the order in which two objects happen to be constructed.
            item.label = pane.title
            item.identifier = pane.rawValue
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
            tabs.addTabViewItem(item)
            // AppKit may re-read the controller title while adopting the item.
            item.label = pane.title
        }
        let saved = UserDefaults.standard.integer(forKey: "settings.selectedPane")
        tabs.selectedTabViewItemIndex = SettingsPane.allCases.indices.contains(saved) ? saved : 0
        tabSelectionObserver = tabs.observe(\.selectedTabViewItemIndex, options: [.new]) {
            [weak self] _, _ in
            MainActor.assumeIsolated { self?.selectedPaneDidChange() }
        }
        installSearchField(in: window)
        resizeWindow(for: SettingsPane.allCases[tabs.selectedTabViewItemIndex], animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// The controller behind a pane.  One place builds them, so a pane cannot
    /// be assembled one way here and another way in a test.
    static func controller(for pane: SettingsPane) -> NSViewController {
        pane == .keys
            ? KeybindingsPane()
            : PreferencesPane(pane: pane, rows: PreferencesForms.rows(for: pane))
    }

    /// The names the tab toolbar shows, for the regression test that keeps a
    /// pane from advertising its class name.
    var tabLabelsForTesting: [String] { tabs.tabViewItems.map(\.label) }

    func select(_ pane: SettingsPane) {
        guard let index = panes.firstIndex(where: { $0.pane == pane }) else { return }
        tabs.selectedTabViewItemIndex = index
    }

    private func selectedPaneDidChange() {
        let index = tabs.selectedTabViewItemIndex
        guard SettingsPane.allCases.indices.contains(index) else { return }
        UserDefaults.standard.set(index, forKey: "settings.selectedPane")
        resizeWindow(for: SettingsPane.allCases[index], animated: true)
    }

    private func resizeWindow(for pane: SettingsPane, animated: Bool) {
        let height: CGFloat = switch pane {
        case .appearance, .updates: 460
        case .history: 500
        case .general, .editor, .typography: 620
        case .keys: 680
        }
        window?.setContentSize(NSSize(width: 760, height: height))
    }

    // MARK: - Search

    /// Seven panes and about thirty controls is more than anyone should have to
    /// scan by eye.  The rows are already declarative data, so filtering them
    /// costs one pass — and because every pane filters at once, a query also
    /// tells the user which pane the setting lives in.
    private func installSearchField(in window: NSWindow) {
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Search settings"
        searchField.sendsSearchStringImmediately = false
        searchField.sendsWholeSearchString = false
        searchField.target = self
        searchField.action = #selector(searchChanged)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)
        NSLayoutConstraint.activate([
            container.heightAnchor.constraint(equalToConstant: 38),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 24),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -24),
            searchField.centerYAnchor.constraint(equalTo: container.centerYAnchor),
        ])

        let accessory = NSTitlebarAccessoryViewController()
        accessory.view = container
        accessory.layoutAttribute = .bottom
        window.addTitlebarAccessoryViewController(accessory)
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue.trimmingCharacters(in: .whitespaces)
        for entry in panes {
            (entry.controller as? PreferenceSearchable)?.searchQuery = query
        }
        guard !query.isEmpty else { return }
        // Jump to the first pane that has something to show, so a query that
        // matches one setting lands the user on it rather than on an empty pane.
        if let hit = panes.firstIndex(where: {
            ($0.controller as? PreferenceSearchable).map { $0.searchMatchCount > 0 } ?? false
        }) {
            tabs.selectedTabViewItemIndex = hit
        }
    }
}

// MARK: - Form rows

/// A row in a settings pane.  Keeping the panes declarative means a new
/// preference is one line in `PreferencesForms`, not a layout exercise — and it
/// is what lets the search filter them.
enum PreferenceRow {
    case toggle(String, help: String?, get: () -> Bool, set: (Bool) -> Void)
    case stepper(String, help: String?, range: ClosedRange<Double>, step: Double, get: () -> Double, set: (Double) -> Void)
    case choice(String, help: String?, options: [String], get: () -> ChoiceSelection, set: (Int) -> Void)
    case text(String, help: String?, get: () -> String, set: (String) -> Void)
    case button(String, () -> Void)
    case section(String)
    case note(String)
    case themePreview

    /// What a popup should show.
    ///
    /// A stored value that is no longer in the list — a theme whose file was
    /// deleted, an editor that was uninstalled — must stay visible.  Falling
    /// back to the first item makes the popup disagree with the setting behind
    /// it, and the user has no way to tell.
    enum ChoiceSelection {
        case index(Int)
        case missing(String)
    }

    /// Header rows carry no control of their own and survive a search only when
    /// something under them does.
    var isSection: Bool {
        if case .section = self { return true }
        return false
    }

    /// Every word the user might type to find this row.
    var searchableText: String {
        switch self {
        case .toggle(let title, let help, _, _),
             .text(let title, let help, _, _):
            return [title, help ?? ""].joined(separator: " ")
        case .stepper(let title, let help, _, _, _, _):
            return [title, help ?? ""].joined(separator: " ")
        case .choice(let title, let help, let options, _, _):
            return ([title, help ?? ""] + options).joined(separator: " ")
        case .button(let title, _):
            return title
        case .section(let title):
            return title
        case .note(let text):
            return text
        case .themePreview:
            return "theme preview colors typography sample"
        }
    }
}

/// Pure filtering, so the search behaviour is testable without a window.
enum PreferenceRowFilter {
    /// Keeps rows matching every word of the query, then drops section headers
    /// that ended up with nothing beneath them.  A query that matches a section
    /// title keeps that whole section.
    static func apply(_ rows: [PreferenceRow], query: String) -> [PreferenceRow] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return rows }

        func matches(_ row: PreferenceRow) -> Bool {
            let text = row.searchableText.lowercased()
            return words.allSatisfy(text.contains)
        }

        var kept: [PreferenceRow] = []
        var sectionMatched = false
        for row in rows {
            if row.isSection {
                sectionMatched = matches(row)
                kept.append(row)
                continue
            }
            if sectionMatched || matches(row) { kept.append(row) }
        }
        // Trailing pass: a header with no rows under it is noise.
        var pruned: [PreferenceRow] = []
        for (index, row) in kept.enumerated() {
            if row.isSection {
                let hasContent = kept[(index + 1)...].prefix { !$0.isSection }.isEmpty == false
                guard hasContent else { continue }
            }
            pruned.append(row)
        }
        return pruned
    }
}

private final class FlippedStackView: NSStackView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class ThemePreviewView: NSView {
    private let heading = NSTextField(labelWithString: "A clear document")
    private let body = NSTextField(labelWithString: "Readable prose, a link, and `inline code`.")
    private let accent = NSTextField(labelWithString: "downright.md")
    private var observer: NSObjectProtocol?

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        for label in [heading, body, accent] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            heading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            heading.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            body.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            body.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 10),
            accent.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            accent.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 8),
        ])
        observer = NotificationCenter.default.addObserver(
            forName: Preferences.didChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        refresh()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Theme preview")
        setAccessibilityElement(true)
    }

    required init?(coder: NSCoder) { nil }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    override var intrinsicContentSize: NSSize { NSSize(width: 520, height: 112) }

    private func refresh() {
        let name = Preferences.shared.values.themeName
        guard let theme = ThemeStore.shared.themes.first(where: { $0.name == name }) else { return }
        let appearance = NSAppearance(named: theme.appearance == .dark ? .darkAqua : .aqua)
            ?? NSApp.effectiveAppearance
        let sheet = StyleSheet(theme: theme, appearance: appearance)
        layer?.backgroundColor = sheet.background.cgColor
        layer?.borderColor = sheet.rule.cgColor
        heading.font = sheet.headingFont(level: 2)
        heading.textColor = sheet.headingColor(level: 2)
        body.font = sheet.bodyFont()
        body.textColor = sheet.text
        accent.font = sheet.monoFont()
        accent.textColor = sheet.link
    }
}

@MainActor
final class PreferencesPane: NSViewController, PreferenceSearchable {
    private let pane: SettingsPane
    /// Rows are re-read, not snapshotted.  A theme imported since the window
    /// was built, a history folder that has grown, an updater that has checked
    /// since — all of it is stale the moment it is captured.
    private let makeRows: () -> [PreferenceRow]
    private let stack = FlippedStackView()
    private let emptyLabel = NSTextField(labelWithString: "No settings match your search.")

    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            guard isViewLoaded else { return }
            rebuild()
            // A filtered pane is a different list.  The clip view clamps itself
            // when the rows no longer fill the window, but a query that still
            // overflows keeps the offset the previous list had — and lands the
            // user below every match it just found for them.
            scrollToTop()
        }
    }

    var searchMatchCount: Int {
        PreferenceRowFilter.apply(makeRows(), query: searchQuery)
            .filter { !$0.isSection }
            .count
    }

    init(pane: SettingsPane, rows: @escaping () -> [PreferenceRow]) {
        self.pane = pane
        self.makeRows = rows
        super.init(nibName: nil, bundle: nil)
        self.title = pane.title
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .tertiaryLabelColor

        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.contentView.drawsBackground = false
        scroll.documentView = stack
        stack.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            stack.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
        ])
        view = scroll
        rebuild()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let item = tabBarItem {
            item.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: pane.title)
        }
    }

    /// Every appearance rebuilds: the window is long-lived and the values
    /// behind these controls are not.
    override func viewWillAppear() {
        super.viewWillAppear()
        rebuild()
    }

    private func rebuild() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let rows = PreferenceRowFilter.apply(makeRows(), query: searchQuery)
        guard !rows.isEmpty else {
            stack.addArrangedSubview(emptyLabel)
            return
        }
        for row in rows { stack.addArrangedSubview(control(for: row)) }
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
        spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(spacer)
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 1).isActive = true
    }

    private func scrollToTop() {
        guard let scroll = view as? NSScrollView else { return }
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
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

        case .themePreview:
            let preview = ThemePreviewView()
            preview.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                preview.widthAnchor.constraint(equalToConstant: 520),
                preview.heightAnchor.constraint(equalToConstant: 112),
            ])
            return preview

        case .toggle(let title, let help, let get, let set):
            let button = NSButton(checkboxWithTitle: title, target: nil, action: nil)
            button.state = get() ? .on : .off
            let handler = ActionHandler { set(button.state == .on) }
            button.target = handler
            button.action = #selector(ActionHandler.run)
            objc_setAssociatedObject(button, &PreferencesPane.handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
            return labelled(button, help: help)

        case .stepper(let title, let help, let range, let step, let get, let set):
            // The formatter comes from the row's own step, so a fractional
            // setting can actually be typed: a bare NumberFormatter allows zero
            // fraction digits and quietly rejects "1.55" for line height.
            let formatter = PreferencesPane.numberFormatter(range: range, step: step)
            let field = NSTextField(string: formatter.string(from: NSNumber(value: get())) ?? "")
            field.formatter = formatter
            field.widthAnchor.constraint(equalToConstant: 70).isActive = true
            let stepper = NSStepper()
            stepper.minValue = range.lowerBound
            stepper.maxValue = range.upperBound
            stepper.increment = step
            stepper.doubleValue = get()
            let updateValue: (Double) -> Void = { value in
                let value = min(range.upperBound, max(range.lowerBound, value))
                stepper.doubleValue = value
                field.stringValue = formatter.string(from: NSNumber(value: value)) ?? ""
                set(value)
            }
            let stepperHandler = ActionHandler { updateValue(stepper.doubleValue) }
            let fieldHandler = ActionHandler {
                guard let value = Double(field.stringValue) else {
                    field.stringValue = formatter.string(from: NSNumber(value: stepper.doubleValue)) ?? ""
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

            var controls: [NSView] = [field, stepper]
            if let unit = Self.unit(for: title) {
                controls.append(NSTextField(labelWithString: unit))
            }
            let row = formRow(title: title, controls: controls)
            return labelled(row, help: help)

        case .choice(let title, let help, let options, let get, let set):
            let popup = NSPopUpButton()
            popup.autoenablesItems = false
            popup.addItems(withTitles: options)
            switch get() {
            case .index(let index):
                popup.selectItem(at: min(max(0, index), max(0, options.count - 1)))
            case .missing(let name):
                // Show what is stored, disabled, instead of silently selecting
                // something else: the setting and the popup must agree.
                popup.addItem(withTitle: "\(name) (not available)")
                popup.lastItem?.isEnabled = false
                popup.select(popup.lastItem)
            }
            let handler = ActionHandler { set(popup.indexOfSelectedItem) }
            popup.target = handler
            popup.action = #selector(ActionHandler.run)
            objc_setAssociatedObject(popup, &PreferencesPane.handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)

            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
            let row = formRow(title: title, controls: [popup])
            return labelled(row, help: help)

        case .text(let title, let help, let get, let set):
            let field = NSTextField(string: get())
            field.widthAnchor.constraint(equalToConstant: 280).isActive = true
            let handler = ActionHandler { set(field.stringValue) }
            field.target = handler
            field.action = #selector(ActionHandler.run)
            objc_setAssociatedObject(field, &PreferencesPane.handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)

            let row = formRow(title: title, controls: [field])
            return labelled(row, help: help)

        case .button(let title, let action):
            let button = NSButton(title: title, target: nil, action: nil)
            let handler = ActionHandler(action)
            button.target = handler
            button.action = #selector(ActionHandler.run)
            objc_setAssociatedObject(button, &PreferencesPane.handlerKey, handler, .OBJC_ASSOCIATION_RETAIN)
            return button
        }
    }

    private func formRow(title: String, controls: [NSView]) -> NSView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 150).isActive = true
        let row = NSStackView(views: [label] + controls)
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        return row
    }

    private static func unit(for title: String) -> String? {
        switch title {
        case "Size", "Text size adjustment": return "pt"
        case "Line height", "Math scale": return "×"
        case "Measure (characters)": return "characters"
        case "Large-file threshold", "Maximum size": return "MB"
        case "Keep versions for": return "days"
        default: return nil
        }
    }

    /// Decimal places implied by a step: 1 → none, 0.05 → two.
    static func numberFormatter(range: ClosedRange<Double>, step: Double) -> NumberFormatter {
        let digits = step > 0 ? max(0, Int(ceil(-log10(step)))) : 0
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.allowsFloats = digits > 0
        formatter.minimumFractionDigits = 0
        formatter.maximumFractionDigits = digits
        formatter.minimum = NSNumber(value: range.lowerBound)
        formatter.maximum = NSNumber(value: range.upperBound)
        return formatter
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
    /// One row-builder per pane, evaluated afresh every time a pane appears.
    @MainActor
    static func rows(for pane: SettingsPane) -> () -> [PreferenceRow] {
        switch pane {
        case .general: return general
        case .appearance: return appearance
        case .typography: return typography
        case .editor: return editor
        case .history: return history
        case .updates: return updates
        case .keys: return { [] }
        }
    }

    /// The shortcut a command answers to right now.  Settings copy must never
    /// hard-code a chord: every binding here is user-editable.
    @MainActor
    static func shortcut(for command: Command) -> String? {
        KeybindingStore.shared.primaryBinding(for: command)?.displayString
    }

    @MainActor
    static func general() -> [PreferenceRow] {
        // Offering an editor that isn't installed makes "Open in Editor" fail
        // with no explanation, so the list is what this Mac actually has.
        let editors = ExternalEditor.allCases.filter(\.isInstalled)
        return [
            .section("On open"),
            .toggle("Restore windows from the last session", help: nil,
                    get: { Preferences.shared.values.restoreSession },
                    set: { value in Preferences.shared.update { $0.restoreSession = value } }),

            .section("Working with agents"),
            .toggle("Watch files for external changes",
                    help: "Marks what changed in the document while you were reading it.",
                    get: { Preferences.shared.values.watchFiles },
                    set: { value in Preferences.shared.update { $0.watchFiles = value } }),
            .toggle("Resolve file paths in documents",
                    help: "Underlines paths that aren't there, so a file an agent claims to have written is easy to check.",
                    get: { Preferences.shared.values.resolvePathTokens },
                    set: { value in Preferences.shared.update { $0.resolvePathTokens = value } }),
            .choice("Open code files in",
                    help: "Only apps installed on this Mac are listed.",
                    options: editors.map(\.title),
                    get: {
                        let current = Preferences.shared.values.externalEditor
                        if let index = editors.firstIndex(of: current) { return .index(index) }
                        return .missing(current.title)
                    },
                    set: { index in
                        guard editors.indices.contains(index) else { return }
                        Preferences.shared.update { $0.externalEditor = editors[index] }
                    }),
            .text("Extra sibling folders",
                  help: "Folder names, separated by commas, scanned one level down from the document. Reopen a document for a change here to reach it.",
                  get: { Preferences.shared.values.siblingScanDirectories.joined(separator: ", ") },
                  set: { value in
                      Preferences.shared.update {
                          $0.siblingScanDirectories = value
                              .split(separator: ",")
                              .map { $0.trimmingCharacters(in: .whitespaces) }
                              .filter { !$0.isEmpty }
                      }
                  }),
        ] + systemIntegration()
    }

    /// The first-run setup panel's steps, kept reachable for good.
    ///
    /// The panel is shown once and answering "Not now" is meant to stick, so
    /// this is where someone goes when they change their mind, when Quick Look
    /// stops working after a macOS update, or when they moved the app and the
    /// registration went stale.  Rows are rebuilt every time the pane appears,
    /// so what they say is what is true right now.
    @MainActor
    static func systemIntegration() -> [PreferenceRow] {
        var rows: [PreferenceRow] = [.section("System integration")]

        if SystemIntegration.isDefaultMarkdownHandler {
            rows.append(.note("Markdown files open in Downright."))
        } else {
            rows.append(.note(defaultHandlerDescription()))
            rows.append(.button("Open Markdown Files with Downright") {
                Task { @MainActor in
                    let failure = await SystemIntegration.makeDefaultMarkdownHandler()
                    if SystemIntegration.isDefaultMarkdownHandler {
                        report("Markdown files now open in Downright.", detail: nil)
                    } else {
                        report(
                            "Couldn’t change the default app.",
                            detail: failure?.localizedDescription
                                ?? "Finder’s Get Info → Open With → Change All can set it directly."
                        )
                    }
                }
            })
        }

        if SystemIntegration.commandLineToolIsBundled {
            rows.append(.button(
                SystemIntegration.isCommandLineToolInstalled
                    ? "Reinstall the down Command Line Tool"
                    : "Install the down Command Line Tool"
            ) {
                do {
                    let result = try SystemIntegration.installCommandLineTool()
                    guard !result.linked.isEmpty else {
                        report(
                            "Nothing was installed.",
                            detail: "Something else already owns \(result.skipped.joined(separator: " and ")) in \(result.directory.path)."
                        )
                        return
                    }
                    report(
                        "Installed \(result.linked.joined(separator: " and ")) in \(result.directory.path).",
                        detail: result.isOnPath
                            ? nil
                            : "That folder isn’t on your PATH — add it to your shell profile to use the command."
                    )
                } catch {
                    report("Couldn’t install the command line tool.", detail: error.localizedDescription)
                }
            })
        }

        if SystemIntegration.quickLookExtensionsAreBundled {
            rows.append(.button("Re-register Quick Look Previews and Icons") {
                SystemIntegration.registerWithSystem(resetThumbnailCache: true) { enabled in
                    report(
                        enabled
                            ? "Quick Look previews and Finder icons are on."
                            : "Quick Look needs one switch from you.",
                        detail: enabled
                            ? "Press space on a Markdown file to try it."
                            : "System Settings → General → Login Items & Extensions → Quick Look, then tick Downright."
                    )
                }
            })
            rows.append(.button("Open Quick Look Settings") {
                SystemIntegration.openQuickLookSettings()
            })
        } else {
            // A SwiftPM dev build genuinely cannot carry an `.appex`; saying so
            // beats offering a button that can only ever fail.
            rows.append(.note("Quick Look previews are available in the installed release of Downright."))
        }

        rows.append(contentsOf: agentIntegration())

        return rows
    }

    /// Coding agents rewriting Markdown under the reader is the case this app
    /// exists for, so the hook that makes them hand the file over belongs beside
    /// the other system registrations.
    ///
    /// Like every row above it, this reads live state rather than a stored
    /// preference: the truth is in the agent's own settings file, which the user
    /// may edit by hand or replace entirely.
    @MainActor
    static func agentIntegration() -> [PreferenceRow] {
        // The hook invokes `down` by absolute path, so without the CLI there is
        // nothing to install and a button would only ever fail.
        guard AgentIntegration.executablePath != nil else {
            return [.note("Install the down command line tool above to let coding agents open Markdown here.")]
        }

        guard AgentIntegration.isInstalled else {
            return [
                .note("Let coding agents open Markdown in Downright as they write it."),
                .button("Open Agent Edits in Downright") {
                    do {
                        try AgentIntegration.install()
                        report(
                            "Agent edits now open in Downright.",
                            detail: "Added to \(AgentIntegration.settingsURL.path)."
                        )
                    } catch {
                        report("Couldn’t update the agent settings.", detail: error.localizedDescription)
                    }
                },
            ]
        }

        return [
            .note("Coding agents open Markdown in Downright as they write it."),
            .button("Stop Opening Agent Edits") {
                do {
                    try AgentIntegration.uninstall()
                    report("Agent edits no longer open in Downright.", detail: nil)
                } catch {
                    report("Couldn’t update the agent settings.", detail: error.localizedDescription)
                }
            },
        ]
    }

    /// Names the app that currently owns Markdown, so the row explains what it
    /// would be changing rather than only what it would be setting.
    @MainActor
    private static func defaultHandlerDescription() -> String {
        guard let type = SystemIntegration.claimedTypes.first,
              let handler = NSWorkspace.shared.urlForApplication(toOpen: type)
        else { return "No app is set to open Markdown files." }
        let name = FileManager.default.displayName(atPath: handler.path)
        return "Markdown files currently open in \(name)."
    }

    @MainActor
    private static func report(_ message: String, detail: String?) {
        let alert = NSAlert()
        alert.messageText = message
        if let detail { alert.informativeText = detail }
        alert.alertStyle = .informational
        alert.runModal()
    }

    @MainActor
    static func typography() -> [PreferenceRow] {
        [
            .section("Body"),
            .choice("Preset", help: "Reading is set in New York, Working in SF Pro Text.",
                    options: TypographyConfig.BodyPreset.allCases.map(\.title),
                    get: {
                        let presets = TypographyConfig.BodyPreset.allCases
                        let current = Preferences.shared.values.typography.preset
                        return .index(presets.firstIndex(of: current) ?? 0)
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
            .stepper("Text size adjustment", help: "A quick app-wide nudge, also on the View menu.",
                     range: -4...10, step: 1,
                     get: { Double(Preferences.shared.values.textSizeAdjustment) },
                     set: { value in Preferences.shared.update { $0.textSizeAdjustment = CGFloat(value) } }),
            .choice("Type scale", help: "One ratio sets every heading size.",
                    options: ["1.200", "1.250", "1.333"],
                    get: {
                        let ratio = Preferences.shared.values.typography.scaleRatio
                        return .index(ratio < 1.22 ? 0 : (ratio < 1.29 ? 1 : 2))
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
            .stepper("Measure (characters)",
                     help: "How much text fits on a line before it wraps. Around 68 to 72 reads best; full-width text is the most common thing Markdown viewers get wrong.",
                     range: 60...80, step: 1,
                     get: { Double(Preferences.shared.values.typography.measureCharacters) },
                     set: { value in Preferences.shared.update { $0.typography.measureCharacters = CGFloat(value) } }),

            .section("Code"),
            .choice("Monospace family", help: nil,
                    options: NSFontManager.shared.availableFontFamilies.sorted(),
                    get: {
                        let fonts = NSFontManager.shared.availableFontFamilies.sorted()
                        let current = Preferences.shared.values.typography.monoFamily
                        return fonts.firstIndex(of: current).map { .index($0) } ?? .missing(current)
                    },
                    set: { index in
                        let fonts = NSFontManager.shared.availableFontFamilies.sorted()
                        guard fonts.indices.contains(index) else { return }
                        Preferences.shared.update { $0.typography.monoFamily = fonts[index] }
                    }),
            .toggle("Ligatures", help: nil,
                    get: { Preferences.shared.values.typography.monoLigatures },
                    set: { value in Preferences.shared.update { $0.typography.monoLigatures = value } }),

            .section("Detail"),
            .toggle("Hanging punctuation and optical margins",
                    help: "Makes text look set rather than merely laid out.",
                    get: { Preferences.shared.values.typography.opticalMargins },
                    set: { value in Preferences.shared.update { $0.typography.opticalMargins = value } }),
            .stepper("Math scale", help: "Sizes formulas to sit evenly against the body text.",
                     range: 0.8...1.3, step: 0.05,
                     get: { Double(Preferences.shared.values.typography.mathScale) },
                     set: { value in Preferences.shared.update { $0.typography.mathScale = CGFloat(value) } }),
        ]
    }

    @MainActor
    static func appearance() -> [PreferenceRow] {
        // Both lists are read here, on every rebuild, and again inside the
        // setters — an imported or reloaded theme must not leave the popup
        // indices pointing at names that have moved.
        let light = ThemeStore.shared.themes.filter { $0.appearance != .dark }.map(\.name)
        let dark = ThemeStore.shared.themes.filter { $0.appearance != .light }.map(\.name)
        return [
            .section("Themes"),
            .choice("Light theme", help: "Used when macOS is in Light appearance.",
                    options: light,
                    get: {
                        let name = Preferences.shared.values.themeName
                        return light.firstIndex(of: name).map { .index($0) } ?? .missing(name)
                    },
                    set: { index in
                        guard light.indices.contains(index) else { return }
                        Preferences.shared.update { $0.themeName = light[index] }
                    }),
            .choice("Dark theme", help: "Used when macOS is in Dark appearance.",
                    options: dark,
                    get: {
                        let name = Preferences.shared.values.darkThemeName
                        return dark.firstIndex(of: name).map { .index($0) } ?? .missing(name)
                    },
                    set: { index in
                        guard dark.indices.contains(index) else { return }
                        Preferences.shared.update { $0.darkThemeName = dark[index] }
                    }),
            .toggle("Follow system appearance",
                    help: "Switch between the light and dark themes as macOS does. Turn this off to keep the light theme in both.",
                    get: { Preferences.shared.values.followsSystemAppearance },
                    set: { value in Preferences.shared.update { $0.followsSystemAppearance = value } }),
            .themePreview,
            .note("Themes live in the Downright folder in Application Support. Import Theme and Reload Themes are on the View menu."),
        ]
    }

    @MainActor
    static func editor() -> [PreferenceRow] {
        [
            .section("Saving"),
            .toggle("Autosave while editing",
                    help: "Writes changes to disk as you type. Turn this off when an agent or external tool is also writing the same file — the default is off for that reason.",
                    get: { Preferences.shared.values.autosaveEnabled },
                    set: { value in Preferences.shared.update { $0.autosaveEnabled = value } }),
            .section("Typing"),
            .toggle("Typewriter scrolling", help: nil,
                    get: { Preferences.shared.values.typewriterScrolling },
                    set: { value in Preferences.shared.update { $0.typewriterScrolling = value } }),
            .toggle("Use typographic substitutions",
                    help: "Convert straight quotes and dashes while typing. Off keeps Markdown source exact.",
                    get: { Preferences.shared.values.typographicSubstitution },
                    set: { value in Preferences.shared.update { $0.typographicSubstitution = value } }),
            .section("Display"),
            .toggle("Show spaces and tabs", help: "Draw whitespace markers in the visible part of the document.",
                    get: { Preferences.shared.values.showInvisibles },
                    set: { value in Preferences.shared.update { $0.showInvisibles = value } }),
            .toggle("Reflow wrapped paragraphs",
                    help: "Join source-wrapped prose visually without changing a byte of the file.",
                    get: { Preferences.shared.values.reflowHardWrappedParagraphs },
                    set: { value in Preferences.shared.update { $0.reflowHardWrappedParagraphs = value } }),
            .toggle("Reveal syntax at every cursor", help: "Show inline markers for extra insertion cursors too.",
                    get: { Preferences.shared.values.revealMarkersAtAllCursors },
                    set: { value in Preferences.shared.update { $0.revealMarkersAtAllCursors = value } }),
            .toggle("Focus mode on open", help: "Hide the surrounding chrome and panels for a single-column writing surface.",
                    get: { Preferences.shared.values.focusMode },
                    set: { value in Preferences.shared.update { $0.focusMode = value } }),
            .choice("Default mode", help: "How a document looks when you open it.",
                    options: RenderMode.userFacingModes.map(\.title),
                    get: {
                        let current = Preferences.shared.values.defaultMode
                        return .index(RenderMode.userFacingModes.firstIndex(of: current) ?? 0)
                    },
                    set: { index in
                        guard RenderMode.userFacingModes.indices.contains(index) else { return }
                        Preferences.shared.update { $0.defaultMode = RenderMode.userFacingModes[index] }
                    }),
            .section("Performance"),
            .stepper("Large-file threshold",
                     help: "Megabytes. Above this, Downright estimates the layout from line counts instead of laying out the whole file before showing you anything.",
                     range: 1...1024, step: 1,
                     get: { Double(Preferences.shared.values.largeFileThresholdMegabytes) },
                     set: { value in Preferences.shared.update { $0.largeFileThresholdMegabytes = Int(value) } }),
        ]
    }

    @MainActor
    static func updates() -> [PreferenceRow] {
        let coordinator = UpdateCoordinator.shared
        guard coordinator.isUpdateConfigurationPresent else {
            return [
                .note("This build carries no update configuration, so automatic updates are off. Install a release build to see update settings here."),
            ]
        }
        return [
            .section("Updates"),
            .note("Downright checks a signed update feed over HTTPS. A downloaded update installs when you quit, so an editing session is never interrupted."),
            .toggle("Automatically check for updates",
                    help: "Checks once a day. The menu command still works while this is off.",
                    get: { UpdateCoordinator.shared.automaticallyChecksForUpdates },
                    set: { value in UpdateCoordinator.shared.automaticallyChecksForUpdates = value }),
            .toggle("Automatically download and install updates",
                    help: "Downloads in the background and installs on the next normal quit. Turn it off to review each update first.",
                    get: { UpdateCoordinator.shared.automaticallyDownloadsUpdates },
                    set: { value in UpdateCoordinator.shared.automaticallyDownloadsUpdates = value }),
            .button("Check Now") { UpdateCoordinator.shared.checkForUpdates() },
            .section("Status"),
            .note(UpdateCoordinator.shared.statusLine()),
        ]
    }

    @MainActor
    static func history() -> [PreferenceRow] {
        let timeline = shortcut(for: .versionTimeline).map { " (\($0))" } ?? ""
        let used = ByteCountFormatter.string(
            fromByteCount: Int64(SnapshotStore.shared.totalBytes()),
            countStyle: .file
        )
        return [
            .section("Version history"),
            .note("""
            Downright keeps a copy of the document every time something else writes to it, \
            stored locally and deduplicated, so nothing is kept twice. That is where Version \
            Timeline\(timeline) gets the versions it shows you.
            """),
            .stepper("Keep versions for", help: "Days.", range: 1...365, step: 1,
                     get: { Double(Preferences.shared.values.historyMaximumDays) },
                     set: { value in Preferences.shared.update { $0.historyMaximumDays = Int(value) } }),
            .stepper("Maximum size", help: "Megabytes.", range: 50...5000, step: 50,
                     get: { Double(Preferences.shared.values.historyMaximumMegabytes) },
                     set: { value in Preferences.shared.update { $0.historyMaximumMegabytes = Int(value) } }),
            .note("Currently using \(used)."),
        ]
    }
}

// MARK: - Keybindings pane

@MainActor
final class KeybindingsPane: NSViewController, PreferenceSearchable {
    private let table = NSTableView()
    private let recordButton = NSButton(title: "Record Shortcut", target: nil, action: nil)
    private let resetRowButton = NSButton(title: "Reset Shortcut", target: nil, action: nil)
    private let allCommands: [Command] = Command.allCases.sorted {
        ($0.menu.rawValue, $0.title) < ($1.menu.rawValue, $1.title)
    }
    private var commands: [Command] = []
    private var recordingRow: Int?
    private var keyMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?

    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            cancelRecording()
            applyFilter()
        }
    }

    var searchMatchCount: Int { KeybindingsPane.filtered(allCommands, query: searchQuery).count }

    /// The pane names itself here rather than in `loadView()`.  Its view is not
    /// loaded until the tab is first selected, and by then everything that reads
    /// a controller's title — the tab item's label above all — has already read
    /// it and settled on the class name.
    init() {
        super.init(nibName: nil, bundle: nil)
        title = SettingsPane.keys.title
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Commands whose menu, name, or current shortcut matches every word typed.
    static func filtered(_ commands: [Command], query: String) -> [Command] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return commands }
        return commands.filter { command in
            let bindings = KeybindingStore.shared.bindings(for: command)
                .map(\.displayString).joined(separator: " ")
            let text = "\(command.menu.title) \(command.title) \(bindings)".lowercased()
            return words.allSatisfy(text.contains)
        }
    }

    override func loadView() {
        // A query typed before this pane was ever shown must survive the view
        // finally loading.
        commands = KeybindingsPane.filtered(allCommands, query: searchQuery)

        table.headerView = NSTableHeaderView()
        table.usesAlternatingRowBackgroundColors = true
        table.rowHeight = 22
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.doubleAction = #selector(beginRecordingSelectedRow)
        table.allowsEmptySelection = true

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

        let hint = NSTextField(labelWithString: "Select a command and press Record, or double-click its shortcut. ⌫ clears it, ⎋ stops recording.")
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .tertiaryLabelColor

        recordButton.target = self
        recordButton.action = #selector(toggleRecording)
        resetRowButton.target = self
        resetRowButton.action = #selector(resetSelected)
        let resetAll = NSButton(title: "Reset All…", target: self, action: #selector(resetAll))
        resetAll.hasDestructiveAction = true
        let footer = NSStackView(views: [NSView(), recordButton, resetRowButton, resetAll])
        footer.orientation = .horizontal
        footer.spacing = 8

        let stack = NSStackView(views: [scroll, hint, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 340),
            scroll.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: -86),
        ])
        view = stack
        refreshButtons()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        if let item = (parent as? NSTabViewController)?.tabViewItems.first(where: { $0.viewController === self }) {
            item.image = NSImage(systemSymbolName: SettingsPane.keys.symbol, accessibilityDescription: SettingsPane.keys.title)
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        table.reloadData()
        // A recorder that outlives the window would swallow the next keystroke
        // anywhere in the app, so it is torn down the moment focus leaves.
        if let window = view.window {
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelRecording() }
            }
        }
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        cancelRecording()
        resignKeyObserver.map(NotificationCenter.default.removeObserver)
        resignKeyObserver = nil
    }

    deinit {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        resignKeyObserver.map(NotificationCenter.default.removeObserver)
    }

    private func applyFilter() {
        commands = KeybindingsPane.filtered(allCommands, query: searchQuery)
        if isViewLoaded {
            table.reloadData()
            refreshButtons()
        }
    }

    // MARK: Recording

    @objc private func toggleRecording() {
        if recordingRow != nil {
            cancelRecording()
        } else {
            beginRecordingSelectedRow()
        }
    }

    @objc private func beginRecordingSelectedRow() {
        let clicked = table.clickedRow
        let row = clicked >= 0 ? clicked : table.selectedRow
        guard row >= 0, row < commands.count else { return }
        beginRecording(row: row)
    }

    private func beginRecording(row: Int) {
        // Always tear the previous monitor down first.  Two live monitors both
        // write into whichever row was recorded last, and the older one can
        // never be removed.
        cancelRecording()
        recordingRow = row
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integersIn: 0..<3))
        refreshButtons()

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, let row = self.recordingRow, row < self.commands.count else { return event }
            let command = self.commands[row]
            defer { self.endRecording() }

            if event.keyCode == 53 { return nil }                      // ⎋ cancels
            if event.keyCode == 51 {                                   // ⌫ clears
                KeybindingStore.shared.setBinding(nil, for: command)
                return nil
            }
            guard let key = KeyBinding.key(for: event) else { return nil }
            let binding = KeyBinding(key, event.modifierFlags.intersection(.deviceIndependentFlagsMask))

            let conflicts = KeybindingStore.shared.conflicts(for: binding, excluding: command)
            if !conflicts.isEmpty {
                let alert = NSAlert()
                alert.messageText = "\(binding.displayString) is already used"
                alert.informativeText = "Assigned to \(conflicts.map(\.title).joined(separator: ", ")). Reassign it?"
                alert.addButton(withTitle: "Reassign")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return nil }
                for conflict in conflicts { KeybindingStore.shared.setBinding(nil, for: conflict) }
            }
            KeybindingStore.shared.setBinding(binding, for: command)
            return nil
        }
    }

    /// Stops listening without changing anything.  Safe to call when nothing is
    /// being recorded, which is what makes it usable from every exit path.
    private func cancelRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        guard recordingRow != nil else { return }
        recordingRow = nil
        if isViewLoaded {
            table.reloadData()
            refreshButtons()
        }
    }

    private func endRecording() {
        cancelRecording()
        if let menu = NSApp.mainMenu { MainMenu.refreshKeyEquivalents(in: menu) }
    }

    private func refreshButtons() {
        let hasSelection = table.selectedRow >= 0 && table.selectedRow < commands.count
        recordButton.title = recordingRow == nil ? "Record Shortcut" : "Cancel"
        recordButton.isEnabled = recordingRow != nil || hasSelection
        resetRowButton.isEnabled = hasSelection && recordingRow == nil
    }

    // MARK: Resetting

    @objc private func resetSelected() {
        let row = table.selectedRow
        guard row >= 0, row < commands.count else { return }
        // Restores the shipped chord for this command.  A command that ships
        // with several chords keeps only the first until `KeybindingStore`
        // learns how to drop a single override.
        KeybindingStore.shared.setBinding(
            KeybindingDefaults.table[commands[row]]?.first,
            for: commands[row]
        )
        table.reloadData()
        if let menu = NSApp.mainMenu { MainMenu.refreshKeyEquivalents(in: menu) }
    }

    @objc private func resetAll() {
        cancelRecording()
        let alert = NSAlert()
        alert.messageText = "Reset every keyboard shortcut?"
        alert.informativeText = "All of your custom shortcuts go back to the ones Downright ships with. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Reset All")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        KeybindingStore.shared.resetToDefaults()
        table.reloadData()
        if let menu = NSApp.mainMenu { MainMenu.refreshKeyEquivalents(in: menu) }
    }

    @objc private func toggleVim(_ sender: NSButton) {
        Preferences.shared.update { $0.vimKeys = sender.state == .on }
        table.reloadData()
    }
}

extension KeybindingsPane: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { commands.count }

    func tableViewSelectionDidChange(_ notification: Notification) {
        // Moving to another command abandons the recording rather than pointing
        // it somewhere the user is no longer looking.
        cancelRecording()
        refreshButtons()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < commands.count else { return nil }
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
