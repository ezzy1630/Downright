import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol TableEditorDelegate: AnyObject {
    func tableEditor(_ editor: TableEditorView, didApply proposal: TableEditProposal)
    func tableEditor(_ editor: TableEditorView, didRequestSource range: NSRange)
}

/// A small, source-preserving table editor.
///
/// The view edits one cell or one structural operation at a time. The core
/// proposes the exact source replacement. The host owns the document mutation,
/// so every accepted operation has one undo step and no hidden re-serialise.
@MainActor
final class TableEditorView: NSView, PanelSurface, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: TableEditorDelegate?

    var preferredWidth: CGFloat { 520 }
    var styleSheet: StyleSheet { didSet { backdrop.styleSheet = styleSheet; applyStyle() } }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Table")
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let alignmentPopup = NSPopUpButton()
    private let sourceButton = NSButton(title: "Edit Source", target: nil, action: nil)

    private(set) var document: ParsedDocument
    private(set) var tableIndex: Int
    private var data: TableData?
    private var values: [[String]] = []
    private var alignments: [TableAlignment] = []
    private var tableRange = NSRange(location: 0, length: 0)
    private var selectedColumnValue = -1

    var rowCountForTesting: Int { values.count }
    var columnCountForTesting: Int { data?.columnCount ?? 0 }
    var sourceRangeForTesting: NSRange { tableRange }

    init(document: ParsedDocument, tableIndex: Int = 0, styleSheet: StyleSheet = .current) {
        self.document = document
        self.tableIndex = tableIndex
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)
        buildInterface()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Replace the parsed snapshot after the host accepts a proposal.
    func update(document: ParsedDocument) {
        self.document = document
        reload()
    }

    /// Select a cell without changing source. Useful for keyboard and tests.
    func select(row: Int, column: Int) {
        guard row >= 0, row < tableView.numberOfRows,
              column >= 0, column < tableView.numberOfColumns else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectedColumnValue = column
        tableView.scrollRowToVisible(row)
    }

    func apply(operation: TableEditOperation) {
        propose(operation)
    }

    func requestSourceForTesting() {
        requestSource(nil)
    }

    private func buildInterface() {
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        titleLabel.font = PanelFont.title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        statusLabel.font = PanelFont.secondary
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowHeight = 28
        tableView.allowsColumnReordering = false
        tableView.allowsEmptySelection = true
        tableView.setAccessibilityLabel("Editable markdown table")
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        configureAlignmentPopup()
        let controls = makeControls()
        addSubview(controls)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PanelMetrics.inset),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            controls.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -PanelMetrics.inset),
            controls.heightAnchor.constraint(equalToConstant: 30),
        ])

        sourceButton.bezelStyle = .rounded
        sourceButton.setAccessibilityLabel("Edit table source")
        sourceButton.target = self
        sourceButton.action = #selector(requestSource(_:))
        sourceButton.isHidden = true
        sourceButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sourceButton)
        NSLayoutConstraint.activate([
            sourceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            sourceButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Table editor")
        applyStyle()
    }

    private func configureAlignmentPopup() {
        alignmentPopup.removeAllItems()
        alignmentPopup.addItems(withTitles: ["Automatic", "Left", "Center", "Right"])
        alignmentPopup.target = self
        alignmentPopup.action = #selector(alignmentChanged(_:))
        alignmentPopup.setAccessibilityLabel("Column alignment")
        alignmentPopup.translatesAutoresizingMaskIntoConstraints = false
    }

    private func makeControls() -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 5
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        addButton("Add Row", symbol: "plus", selector: #selector(addRow(_:)), to: stack)
        addButton("Delete Row", symbol: "minus", selector: #selector(deleteRow(_:)), to: stack)
        addButton("Add Column", symbol: "rectangle.split.3x1", selector: #selector(addColumn(_:)), to: stack)
        addButton("Delete Column", symbol: "rectangle.split.2x1", selector: #selector(deleteColumn(_:)), to: stack)
        addButton("Move Row Up", symbol: "arrow.up", selector: #selector(moveRowUp(_:)), to: stack)
        addButton("Move Row Down", symbol: "arrow.down", selector: #selector(moveRowDown(_:)), to: stack)
        addButton("Move Column Left", symbol: "arrow.left", selector: #selector(moveColumnLeft(_:)), to: stack)
        addButton("Move Column Right", symbol: "arrow.right", selector: #selector(moveColumnRight(_:)), to: stack)
        stack.addArrangedSubview(alignmentPopup)
        return stack
    }

    private func addButton(_ title: String, symbol: String, selector: Selector, to stack: NSStackView) {
        let button = NSButton(title: title, target: self, action: selector)
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
        button.imagePosition = .imageOnly
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(button)
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.text
        statusLabel.textColor = styleSheet.textSecondary
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    // MARK: - Source model

    private func tableBlock() -> (MDBlock, TableData)? {
        var matches: [(MDBlock, TableData)] = []
        document.root.walk { block in
            if case let .table(data) = block.content { matches.append((block, data)) }
        }
        guard tableIndex >= 0, tableIndex < matches.count else { return nil }
        return matches[tableIndex]
    }

    func reload() {
        guard let (block, table) = tableBlock() else {
            data = nil
            values = []
            alignments = []
            tableRange = NSRange(location: 0, length: 0)
            titleLabel.stringValue = "Table"
            statusLabel.stringValue = "No table found"
            sourceButton.isHidden = true
            tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
            tableView.reloadData()
            return
        }
        data = table
        tableRange = block.range
        alignments = table.alignments
        values = table.rows.map { row in
            row.cells.map { document.substring($0.contentRange).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        titleLabel.stringValue = "Table \(tableIndex + 1)"
        statusLabel.stringValue = "\(table.columnCount) columns · \(max(0, table.rows.count - 1)) rows"
        sourceButton.isHidden = false
        rebuildColumns(count: table.columnCount)
        tableView.reloadData()
        updateAlignmentSelection()
    }

    private func rebuildColumns(count: Int) {
        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
        for index in 0..<count {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column-\(index)"))
            column.title = "\(index + 1)"
            column.minWidth = 90
            column.width = 130
            column.headerCell.alignment = .center
            tableView.addTableColumn(column)
        }
    }

    private var selectedRow: Int { tableView.selectedRow }
    private var selectedColumn: Int { selectedColumnValue }

    private func propose(_ operation: TableEditOperation) {
        let result = TableEditing.propose(document, tableIndex: tableIndex, operation: operation)
        guard let proposal = result.proposal else {
            statusLabel.stringValue = "Source edit is not available"
            return
        }
        delegate?.tableEditor(self, didApply: proposal)
    }

    // MARK: - Controls

    @objc private func addRow(_ sender: Any?) {
        guard let data else { return }
        let index = selectedRow >= 1 ? min(selectedRow + 1, data.rows.count) : data.rows.count
        propose(.insertRow(index: index, cells: Array(repeating: "", count: data.columnCount)))
    }

    @objc private func deleteRow(_ sender: Any?) {
        guard selectedRow > 0 else { statusLabel.stringValue = "Select a body row"; return }
        propose(.deleteRow(index: selectedRow))
    }

    @objc private func addColumn(_ sender: Any?) {
        guard let data else { return }
        let index = selectedColumn >= 0 ? selectedColumn + 1 : data.columnCount
        propose(.insertColumn(index: index, header: "", cells: []))
    }

    @objc private func deleteColumn(_ sender: Any?) {
        guard selectedColumn >= 0 else { statusLabel.stringValue = "Select a column"; return }
        propose(.deleteColumn(index: selectedColumn))
    }

    @objc private func moveRowUp(_ sender: Any?) {
        guard selectedRow > 1 else { return }
        propose(.moveRow(from: selectedRow, to: selectedRow - 1))
    }

    @objc private func moveRowDown(_ sender: Any?) {
        guard let data, selectedRow > 0, selectedRow + 1 < data.rows.count else { return }
        propose(.moveRow(from: selectedRow, to: selectedRow + 1))
    }

    @objc private func moveColumnLeft(_ sender: Any?) {
        guard selectedColumn > 0 else { return }
        propose(.moveColumn(from: selectedColumn, to: selectedColumn - 1))
    }

    @objc private func moveColumnRight(_ sender: Any?) {
        guard let data, selectedColumn >= 0, selectedColumn + 1 < data.columnCount else { return }
        propose(.moveColumn(from: selectedColumn, to: selectedColumn + 1))
    }

    @objc private func alignmentChanged(_ sender: NSPopUpButton) {
        guard let alignment = [TableAlignment.none, .left, .center, .right].element(at: sender.indexOfSelectedItem),
              selectedColumn >= 0 else { return }
        propose(.setAlignment(column: selectedColumn, alignment: alignment))
    }

    @objc private func requestSource(_ sender: Any?) {
        guard tableRange.length > 0 else { return }
        delegate?.tableEditor(self, didRequestSource: tableRange)
    }

    private func updateAlignmentSelection() {
        guard selectedColumn >= 0, selectedColumn < alignments.count else { return }
        alignmentPopup.selectItem(at: [TableAlignment.none, .left, .center, .right].firstIndex(of: alignments[selectedColumn]) ?? 0)
    }

    private func advance(from field: TableEditorCell, forward: Bool) {
        let row = field.tag / 10_000
        let column = field.tag % 10_000
        guard !values.isEmpty, let data else { return }
        let nextColumn = column + (forward ? 1 : -1)
        let nextRow: Int
        let targetColumn: Int
        if nextColumn >= data.columnCount {
            nextRow = min(values.count - 1, row + 1)
            targetColumn = 0
        } else if nextColumn < 0 {
            nextRow = max(0, row - 1)
            targetColumn = max(0, data.columnCount - 1)
        } else {
            nextRow = row
            targetColumn = nextColumn
        }
        select(row: nextRow, column: targetColumn)
        if let next = tableView.view(atColumn: targetColumn, row: nextRow, makeIfNecessary: true) {
            window?.makeFirstResponder(next)
        }
    }

    // MARK: - Table data

    func numberOfRows(in tableView: NSTableView) -> Int { values.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let tableColumn, let column = tableView.tableColumns.firstIndex(of: tableColumn),
              row < values.count, column < values[row].count else { return nil }
        let field = TableEditorCell(string: values[row][column])
        field.font = row == 0 ? PanelFont.rowEmphasised : PanelFont.row
        field.isBordered = false
        field.drawsBackground = false
        field.delegate = self
        field.tag = row * 10_000 + column
        field.onAdvance = { [weak self, weak field] forward in
            guard let self, let field else { return }
            self.advance(from: field, forward: forward)
        }
        field.setAccessibilityLabel("Table row \(row + 1), column \(column + 1)")
        field.setAccessibilityRole(.textField)
        return field
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateAlignmentSelection()
    }

    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn?, row: Int) {
        guard let tableColumn else { return }
        selectedColumnValue = tableView.tableColumns.firstIndex(of: tableColumn) ?? -1
        updateAlignmentSelection()
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = field.tag / 10_000
        let column = field.tag % 10_000
        guard row >= 0, column >= 0 else { return }
        propose(.setCell(row: row, column: column, text: field.stringValue))
    }
}

private final class TableEditorCell: NSTextField {
    var onAdvance: ((Bool) -> Void)?

    override func keyDown(with event: NSEvent) {
        let isTab = event.keyCode == 48
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        guard isTab || isReturn else {
            super.keyDown(with: event)
            return
        }
        onAdvance?(!event.modifierFlags.contains(.shift))
    }
}

private extension Array {
    func element(at index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}
