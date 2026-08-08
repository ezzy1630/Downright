import AppKit
import MarkdownRender

@MainActor
protocol CommandPaletteViewDelegate: AnyObject {
    func commandPalette(_ palette: CommandPaletteView, didChoose result: QuickOpenResult)
    func commandPaletteDidCancel(_ palette: CommandPaletteView)
}

/// A compact, keyboard-first command launcher.  It owns only search state;
/// command execution stays with the window's single `perform(_:)` owner.
@MainActor
final class CommandPaletteView: NSView, PanelSurface {
    weak var delegate: CommandPaletteViewDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    let preferredWidth: CGFloat = PanelMetrics.wideWidth

    private let backdrop: PanelBackdrop
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let hintLabel = NSTextField(labelWithString: "↑ ↓ Move   Return Open   Esc Close")
    /// The prefixes exist and nothing said so.  A filter you cannot discover
    /// is a filter nobody uses (§7.2).
    private let prefixLabel = NSTextField(
        labelWithString: "> commands   @ symbols   # headings   task: tasks   file:   link:   asset:"
    )
    private let emptyState = PanelEmptyStateView()
    private var model: CommandPaletteModel
    private let recentStore: CommandPaletteRecentStore
    private var keyMonitor: Any?

    convenience init() {
        self.init(styleSheet: .current, recentStore: UserDefaultsCommandPaletteRecentStore())
    }

    init(
        styleSheet: StyleSheet,
        recentStore: CommandPaletteRecentStore,
        model: CommandPaletteModel? = nil,
        providers: [any QuickOpenProvider] = []
    ) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(
            styleSheet: styleSheet,
            material: .hudWindow,
            blendingMode: .withinWindow
        )
        self.recentStore = recentStore
        self.model = model ?? CommandPaletteModel(recentCommands: recentStore.recentCommands(), providers: providers)
        super.init(frame: .zero)
        buildInterface()
        reloadResults()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            removeKeyMonitor()
        } else if keyMonitor == nil {
            installKeyMonitor()
            window?.makeFirstResponder(searchField)
        }
    }

    private func buildInterface() {
        wantsLayer = true
        layer?.cornerRadius = PanelMetrics.cornerRadius
        layer?.masksToBounds = true

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        searchField.placeholderString = "Search commands, headings, files"
        searchField.sendsSearchStringImmediately = true
        searchField.controlSize = .large
        searchField.font = PanelFont.system(16)
        searchField.isBezeled = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.setAccessibilityLabel("Search commands and document items")
        searchField.setAccessibilityHelp("Type a command, heading, task, link, asset, or file")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("command"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClick(_:))
        tableView.rowHeight = PanelMetrics.detailRowHeight
        tableView.intercellSpacing = NSSize(width: 0, height: 1)
        tableView.selectionHighlightStyle = .regular
        tableView.backgroundColor = .clear
        tableView.setAccessibilityLabel("Command results")
        tableView.setAccessibilityRole(.list)
        tableView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        hintLabel.font = PanelFont.secondary
        hintLabel.alignment = .right
        hintLabel.lineBreakMode = .byTruncatingTail
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        hintLabel.setAccessibilityLabel("Keyboard commands: move, open, close")
        addSubview(hintLabel)

        prefixLabel.font = PanelFont.system(10.5)
        prefixLabel.alignment = .left
        prefixLabel.lineBreakMode = .byTruncatingTail
        prefixLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        prefixLabel.translatesAutoresizingMaskIntoConstraints = false
        prefixLabel.setAccessibilityLabel(
            "Search prefixes: greater-than for commands, at for symbols, hash for headings, "
                + "hash task for tasks, file colon, link colon, asset colon"
        )
        addSubview(prefixLabel)
        emptyState.install(in: self, over: scrollView)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            searchField.heightAnchor.constraint(equalToConstant: 32),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: hintLabel.topAnchor, constant: -8),
            prefixLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            prefixLabel.centerYAnchor.constraint(equalTo: hintLabel.centerYAnchor),
            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: prefixLabel.trailingAnchor, constant: 12),
            hintLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            hintLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            hintLabel.heightAnchor.constraint(equalToConstant: 16),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Command palette")
        applyStyle()
    }

    private func applyStyle() {
        layer?.backgroundColor = styleSheet.background.cgColor
        searchField.backgroundColor = styleSheet.background
        searchField.textColor = styleSheet.text
        hintLabel.textColor = styleSheet.textFaint
        prefixLabel.textColor = styleSheet.textFaint
        tableView.reloadData()
        updateEmptyState()
    }

    private func reloadResults() {
        tableView.reloadData()
        let count = model.quickResults.count
        if count > 0 {
            tableView.selectRowIndexes(IndexSet(integer: model.selectedIndex), byExtendingSelection: false)
            tableView.scrollRowToVisible(model.selectedIndex)
        } else {
            tableView.deselectAll(nil)
        }
        let status = count == 1 ? "1 command" : "\(count) commands"
        tableView.setAccessibilityValue(status)
        updateEmptyState()
    }

    /// A typo produced a blank rectangle.  Say what happened and how to get
    /// out of it instead (§11.4).
    private func updateEmptyState() {
        guard model.quickResults.isEmpty else {
            emptyState.isHidden = true
            scrollView.isHidden = false
            return
        }
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        emptyState.configure(
            symbol: "magnifyingglass",
            title: query.isEmpty ? "Nothing to open yet" : "No matches for “\(query)”",
            subtitle: "Try a prefix: `>` for commands,\n`@` for symbols, `#` for headings.",
            styleSheet: styleSheet
        )
        emptyState.isHidden = false
        scrollView.isHidden = true
    }

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handleKey(event) ? nil : event
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    @discardableResult
    private func handleKey(_ event: NSEvent) -> Bool {
        switch event.keyCode {
        case 125: model.moveSelection(by: 1); reloadResults(); return true
        case 126: model.moveSelection(by: -1); reloadResults(); return true
        case 36, 76: chooseSelection(); return true
        case 53: delegate?.commandPaletteDidCancel(self); return true
        default: return false
        }
    }

    private func chooseSelection() {
        guard let result = model.selectedResult else { return }
        if case .command(let command) = result.action {
            model.record(command)
            recentStore.record(command)
        }
        delegate?.commandPalette(self, didChoose: result)
    }

    /// Esc closes the palette even if the local key monitor is not installed —
    /// the responder chain answers as well as the monitor does.
    override func cancelOperation(_ sender: Any?) {
        delegate?.commandPaletteDidCancel(self)
    }

    @objc private func doubleClick(_ sender: NSTableView) {
        guard sender.selectedRow >= 0 else { return }
        model.select(index: sender.selectedRow)
        chooseSelection()
    }
}

@MainActor
extension CommandPaletteView: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        model.updateQuery(searchField.stringValue)
        reloadResults()
    }
}

@MainActor
extension CommandPaletteView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { model.quickResults.count }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard model.quickResults.indices.contains(row) else { return nil }
        let result = model.quickResults[row]
        // Reuse: this table reloads on every keystroke.
        let identifier = NSUserInterfaceItemIdentifier("commandPaletteRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? CommandPaletteRowView
            ?? CommandPaletteRowView(identifier: identifier)
        cell.configure(result, styleSheet: styleSheet)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        model.select(index: tableView.selectedRow)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        model.quickResults.indices.contains(row)
    }

    func tableViewSelectionIsChanging(_ notification: Notification) {
        guard tableView.selectedRow >= 0 else { return }
        model.select(index: tableView.selectedRow)
    }

    func tableView(_ tableView: NSTableView, shouldTypeSelectFor event: NSEvent, withCurrentSearch search: String?) -> Bool {
        false
    }

}

private final class CommandPaletteRowView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let metadataLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = PanelFont.rowEmphasised
        metadataLabel.font = PanelFont.secondary
        // Long paths used to be cut off mid-glyph with no ellipsis.
        titleLabel.lineBreakMode = .byTruncatingTail
        metadataLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        metadataLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(metadataLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            metadataLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            metadataLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            metadataLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            metadataLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5),
        ])
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ result: QuickOpenResult, styleSheet: StyleSheet) {
        titleLabel.stringValue = result.title
        titleLabel.textColor = styleSheet.text
        metadataLabel.stringValue = result.subtitle.isEmpty ? result.kind.rawValue.capitalized : result.subtitle
        metadataLabel.textColor = styleSheet.textFaint
        toolTip = result.subtitle.isEmpty ? result.title : "\(result.title)\n\(result.subtitle)"
        setAccessibilityLabel(result.title)
        setAccessibilityValue(metadataLabel.stringValue)
    }
}
