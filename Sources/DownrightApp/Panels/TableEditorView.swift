import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol TableEditorDelegate: AnyObject {
    func tableEditor(_ editor: TableEditorView, didApply proposal: TableEditProposal)
    func tableEditor(_ editor: TableEditorView, didRequestSource range: NSRange)
    /// The user is finished.  Every accepted operation was already written
    /// through `didApply`, so the host only has to take the sheet down.
    func tableEditorDidFinish(_ editor: TableEditorView)
    /// The user backed out.  `editor.appliedEditCount` is exactly how many undo
    /// steps this session wrote, so a host that wants a true revert can undo
    /// that many and nothing else.
    func tableEditorDidCancel(_ editor: TableEditorView)
}

/// Dismissal must work before any host adopts the two new callbacks: a sheet
/// with no exit is worse than a sheet whose host does not tidy up after it.
extension TableEditorDelegate {
    func tableEditorDidFinish(_ editor: TableEditorView) { editor.dismissHostingWindow() }
    func tableEditorDidCancel(_ editor: TableEditorView) { editor.dismissHostingWindow() }
}

/// A small, source-preserving table editor.
///
/// The view edits one cell or one structural operation at a time. The core
/// proposes the exact source replacement. The host owns the document mutation,
/// so every accepted operation has one undo step and no hidden re-serialise.
@MainActor
final class TableEditorView: NSView, PanelSurface, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
    weak var delegate: TableEditorDelegate?

    var preferredWidth: CGFloat { PanelMetrics.wideWidth }
    var styleSheet: StyleSheet { didSet { backdrop.styleSheet = styleSheet; applyStyle() } }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Table")
    private let statusLabel = NSTextField(labelWithString: "")
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let alignmentPopup = NSPopUpButton()
    private let sourceButton = NSButton(title: "Edit Source", target: nil, action: nil)
    private let doneButton = NSButton(title: "Done", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    /// Structural buttons, kept so selection can drive `isEnabled` rather than
    /// letting an invalid press write an explanation into the status label.
    private var columnButtons: [TableColumnOperation: NSButton] = [:]
    private var rowButtons: [TableRowOperation: NSButton] = [:]

    private(set) var document: ParsedDocument
    private(set) var tableIndex: Int
    private var data: TableData?
    private var values: [[String]] = []
    private var alignments: [TableAlignment] = []
    private var tableRange = NSRange(location: 0, length: 0)
    private var selectedColumnValue = -1
    /// Undo steps this session has written, so a cancelling host knows exactly
    /// how far to roll back.
    private(set) var appliedEditCount = 0

    /// Named so `isEnabled` is driven by a value, not by a button title.
    private enum TableColumnOperation: Hashable { case add, delete, moveLeft, moveRight }
    private enum TableRowOperation: Hashable { case add, delete, moveUp, moveDown }

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
        updateAlignmentSelection()
        updateOperationAvailability()
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
        tableView.rowHeight = PanelMetrics.listRowHeight
        tableView.allowsColumnReordering = false
        tableView.allowsEmptySelection = true
        tableView.target = self
        tableView.action = #selector(cellClicked(_:))
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

        sourceButton.bezelStyle = .rounded
        sourceButton.controlSize = .small
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

        // Done and Cancel are unconditional.  Every other control in this sheet
        // can be absent — there may be no table under the caret at all — so the
        // way out must not be one of the things that can disappear.
        let dismiss = makeDismissBar()
        addSubview(dismiss)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: sourceButton.leadingAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            scrollView.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: controls.topAnchor, constant: -8),
            controls.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            controls.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PanelMetrics.inset),
            controls.bottomAnchor.constraint(equalTo: dismiss.topAnchor, constant: -10),
            controls.heightAnchor.constraint(equalToConstant: 30),
            dismiss.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            dismiss.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: PanelMetrics.inset),
            dismiss.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -PanelMetrics.inset),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Table editor")
        applyStyle()
        updateOperationAvailability()
    }

    private func makeDismissBar() -> NSStackView {
        cancelButton.bezelStyle = .rounded
        cancelButton.target = self
        cancelButton.action = #selector(cancel(_:))
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.setAccessibilityLabel("Close the table editor")
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        doneButton.bezelStyle = .rounded
        doneButton.target = self
        doneButton.action = #selector(finish(_:))
        doneButton.keyEquivalent = "\r"
        doneButton.setAccessibilityLabel("Finish editing the table")
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [cancelButton, doneButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
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

        // Row and column glyphs differ by badge, not by tooltip: a plus-badged
        // rectangle and a minus-badged rectangle cannot be confused the way
        // `split.3x1` and `split.2x1` can.
        rowButtons[.add] = addButton("Add Row", symbol: "plus", selector: #selector(addRow(_:)), to: stack)
        rowButtons[.delete] = addButton("Delete Row", symbol: "minus", selector: #selector(deleteRow(_:)), to: stack)
        columnButtons[.add] = addButton("Add Column", symbol: "rectangle.badge.plus", selector: #selector(addColumn(_:)), to: stack)
        columnButtons[.delete] = addButton("Delete Column", symbol: "rectangle.badge.minus", selector: #selector(deleteColumn(_:)), to: stack)
        rowButtons[.moveUp] = addButton("Move Row Up", symbol: "arrow.up", selector: #selector(moveRowUp(_:)), to: stack)
        rowButtons[.moveDown] = addButton("Move Row Down", symbol: "arrow.down", selector: #selector(moveRowDown(_:)), to: stack)
        columnButtons[.moveLeft] = addButton("Move Column Left", symbol: "arrow.left", selector: #selector(moveColumnLeft(_:)), to: stack)
        columnButtons[.moveRight] = addButton("Move Column Right", symbol: "arrow.right", selector: #selector(moveColumnRight(_:)), to: stack)
        stack.addArrangedSubview(alignmentPopup)
        return stack
    }

    @discardableResult
    private func addButton(_ title: String, symbol: String, selector: Selector, to stack: NSStackView) -> NSButton {
        let button = NSButton(title: title, target: self, action: selector)
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: title) {
            button.image = image
            button.imagePosition = .imageOnly
        }
        button.toolTip = title
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(button)
        return button
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
            selectedColumnValue = -1
            tableRange = NSRange(location: 0, length: 0)
            titleLabel.stringValue = "Table"
            statusLabel.stringValue = "No table under the caret"
            sourceButton.isHidden = true
            tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
            tableView.reloadData()
            updateOperationAvailability()
            return
        }
        data = table
        tableRange = block.range
        alignments = table.alignments
        values = table.rows.map { row in
            row.cells.map { document.substring($0.contentRange).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        if selectedColumnValue >= table.columnCount { selectedColumnValue = table.columnCount - 1 }
        titleLabel.stringValue = "Table \(tableIndex + 1)"
        statusLabel.stringValue = "\(table.columnCount) columns · \(max(0, table.rows.count - 1)) rows"
        sourceButton.isHidden = false
        rebuildColumns(count: table.columnCount)
        tableView.reloadData()
        updateAlignmentSelection()
        updateOperationAvailability()
    }

    /// Columns are titled from the table's own header row.  A bare "1" gives a
    /// reader nothing to identify a column by, which is exactly what makes
    /// "select a column" feel like a guess.
    private func rebuildColumns(count: Int) {
        tableView.tableColumns.forEach { tableView.removeTableColumn($0) }
        let headers = values.first ?? []
        for index in 0..<count {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("column-\(index)"))
            let header = headers.element(at: index)?.trimmingCharacters(in: .whitespaces) ?? ""
            column.title = header.isEmpty ? "Column \(index + 1)" : header
            column.minWidth = 90
            column.width = 130
            column.headerCell.alignment = .center
            tableView.addTableColumn(column)
        }
    }

    private var selectedRow: Int { tableView.selectedRow }
    private var selectedColumn: Int { selectedColumnValue }

    /// Structural operations are enabled only where they mean something, so an
    /// invalid press cannot happen and no status line has to explain one.
    private func updateOperationAvailability() {
        let columns = data?.columnCount ?? 0
        let rows = data?.rows.count ?? 0
        let hasTable = data != nil
        let column = selectedColumn
        let row = selectedRow

        rowButtons[.add]?.isEnabled = hasTable
        rowButtons[.delete]?.isEnabled = row > 0
        rowButtons[.moveUp]?.isEnabled = row > 1
        rowButtons[.moveDown]?.isEnabled = row > 0 && row + 1 < rows
        columnButtons[.add]?.isEnabled = hasTable
        columnButtons[.delete]?.isEnabled = column >= 0 && columns > 1
        columnButtons[.moveLeft]?.isEnabled = column > 0
        columnButtons[.moveRight]?.isEnabled = column >= 0 && column + 1 < columns
        alignmentPopup.isEnabled = column >= 0
        sourceButton.isEnabled = tableRange.length > 0
    }

    private func propose(_ operation: TableEditOperation) {
        let result = TableEditing.propose(document, tableIndex: tableIndex, operation: operation)
        guard let proposal = result.proposal else {
            statusLabel.stringValue = "Source edit is not available"
            return
        }
        appliedEditCount += 1
        delegate?.tableEditor(self, didApply: proposal)
    }

    // MARK: - Controls

    @objc private func addRow(_ sender: Any?) {
        guard let data else { return }
        let index = selectedRow >= 1 ? min(selectedRow + 1, data.rows.count) : data.rows.count
        propose(.insertRow(index: index, cells: Array(repeating: "", count: data.columnCount)))
    }

    @objc private func deleteRow(_ sender: Any?) {
        guard selectedRow > 0 else { return }
        propose(.deleteRow(index: selectedRow))
    }

    @objc private func addColumn(_ sender: Any?) {
        guard let data else { return }
        let index = selectedColumn >= 0 ? selectedColumn + 1 : data.columnCount
        propose(.insertColumn(index: index, header: "", cells: []))
    }

    @objc private func deleteColumn(_ sender: Any?) {
        guard selectedColumn >= 0 else { return }
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

    // MARK: - Dismissal

    @objc private func finish(_ sender: Any?) {
        commitEditingCell()
        if let delegate { delegate.tableEditorDidFinish(self) } else { dismissHostingWindow() }
    }

    @objc private func cancel(_ sender: Any?) {
        window?.makeFirstResponder(nil)
        if let delegate { delegate.tableEditorDidCancel(self) } else { dismissHostingWindow() }
    }

    override func cancelOperation(_ sender: Any?) { cancel(sender) }

    /// The AppKit-correct way out of whatever window is hosting the editor,
    /// used when no host has claimed the dismissal callbacks.
    func dismissHostingWindow() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) } else { window.close() }
    }

    /// Ends the field editor so a half-typed cell is proposed before the sheet
    /// goes away rather than lost with it.
    private func commitEditingCell() {
        guard let window, window.firstResponder is NSText else { return }
        window.makeFirstResponder(tableView)
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
        updateOperationAvailability()
    }

    /// A header click selects a column.
    func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn?, row: Int) {
        guard let tableColumn else { return }
        select(column: tableView.tableColumns.firstIndex(of: tableColumn) ?? -1)
    }

    /// So does clicking a cell.  Requiring a header click was the whole reason
    /// the column operations looked broken: selecting a cell left the column at
    /// -1 and every column button silently refused.
    @objc private func cellClicked(_ sender: Any?) {
        guard tableView.clickedColumn >= 0 else { return }
        select(column: tableView.clickedColumn)
    }

    private func select(column: Int) {
        selectedColumnValue = column
        updateAlignmentSelection()
        updateOperationAvailability()
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        select(column: field.tag % 10_000)
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        let row = field.tag / 10_000
        let column = field.tag % 10_000
        guard row >= 0, column >= 0, row < values.count, column < values[row].count else { return }
        // Tabbing through a table must not write an undo step per cell: only a
        // value that actually changed is a change.
        guard values[row][column] != field.stringValue else { return }
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

