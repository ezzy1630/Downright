import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol DocumentLensViewDelegate: AnyObject {
    func documentLens(_ view: DocumentLensView, didSelect range: NSRange, item: DocumentLensItem)
    func documentLens(_ view: DocumentLensView, didSelectRenderTarget profile: RenderTargetProfile)
}

/// A compact source map for the current document.  The panel only owns view
/// state.  The host owns parsing, diagnostics, and selection.
@MainActor
final class DocumentLensView: NSView, PanelSurface {
    weak var delegate: DocumentLensViewDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    var model: DocumentLensModel = DocumentLensModel(input: .init(document: .empty)) {
        didSet { reload() }
    }

    /// The document text the model was built from.  Supplied so rows can name a
    /// line instead of a byte offset; without it a row simply omits the
    /// position rather than reporting a wrong one.
    var sourceText: String = "" {
        didSet {
            guard sourceText != oldValue else { return }
            lineIndex = sourceText.isEmpty ? nil : SourceLineIndex(text: sourceText)
            table.reloadData()
        }
    }

    var selectedTab: DocumentLensTab = .structure {
        didSet {
            guard selectedTab != oldValue else { return }
            syncTabControl()
            reload()
        }
    }

    var renderTargetProfile: RenderTargetProfile = .gitHub {
        didSet {
            guard renderTargetProfile != oldValue else { return }
            syncTargetControl()
        }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: Command.documentLens.panelTitle)
    private let countLabel = NSTextField(labelWithString: "")
    /// Seven sections cannot fit a segmented control at the inspector's minimum
    /// width — "Structure" and "Render Target" truncated in every tab.  A popup
    /// names the section in full and carries its count as well (§11.4).
    private let tabControl = NSPopUpButton()
    private let targetControl = NSPopUpButton()
    private let emptyState = PanelEmptyStateView()
    private let table = PanelList.makeTableView(identifier: "documentLens")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    private enum Row {
        case group(DocumentLensGroup)
        case item(DocumentLensItem)
    }
    private var rows: [Row] = []
    /// Selection survives a reload by identity, not by row number: the host
    /// reparses on every keystroke, and losing the selected finding (and its
    /// preview) mid-sentence is the panel forgetting what you were doing.
    private var selectedItemID: String?
    private var lineIndex: SourceLineIndex?

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        buildHeader()
        buildTable()
        applyStyle()
        reload()

        setAccessibilityRole(.group)
        setAccessibilityLabel("Document Lens")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildHeader() {
        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        countLabel.font = PanelFont.secondary
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        tabControl.addItems(withTitles: DocumentLensTab.allCases.map(\.title))
        tabControl.font = PanelFont.row
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.setAccessibilityLabel("Document Lens sections")
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabControl)

        targetControl.addItems(withTitles: RenderTargetProfile.builtIns.map(\.name))
        targetControl.target = self
        targetControl.action = #selector(targetChanged(_:))
        targetControl.font = PanelFont.secondary
        targetControl.setAccessibilityLabel("Render target")
        targetControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(targetControl)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            tabControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            tabControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            tabControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            targetControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            targetControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            targetControl.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 4),
        ])
        syncTabControl()
        syncTargetControl()
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = PanelMetrics.detailRowHeight
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Document Lens items")
        addSubview(scroll)
        emptyState.install(in: self, over: scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: targetControl.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func reload() {
        let section = model.section(selectedTab)
        rows = section.groups.flatMap { group in
            [.group(group)] + group.items.map(Row.item)
        }
        countLabel.stringValue = section.count == 0 ? "None" : "\(section.count)"
        countLabel.setAccessibilityLabel("\(section.count) items")
        for (index, tab) in DocumentLensTab.allCases.enumerated() {
            let count = model.section(tab).count
            tabControl.item(at: index)?.title = count == 0 ? tab.title : "\(tab.title)  ·  \(count)"
        }
        syncTabControl()
        table.reloadData()
        restoreSelection()
        updateEmptyState(section: section)
    }

    /// Reselect the same item, wherever the reparse moved it to.
    private func restoreSelection() {
        guard let selectedItemID,
              let row = rows.firstIndex(where: {
                  if case .item(let item) = $0 { return item.id == selectedItemID }
                  return false
              })
        else {
            table.deselectAll(nil)
            return
        }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func updateEmptyState(section: DocumentLensSection) {
        guard rows.isEmpty else {
            emptyState.isHidden = true
            scroll.isHidden = false
            return
        }
        emptyState.configure(
            symbol: Self.emptySymbol(for: selectedTab),
            title: Self.emptyTitle(for: selectedTab),
            subtitle: Self.emptySubtitle(for: selectedTab),
            styleSheet: styleSheet
        )
        emptyState.isHidden = false
        scroll.isHidden = true
    }

    private static func emptySymbol(for tab: DocumentLensTab) -> String {
        switch tab {
        case .structure: "list.bullet.indent"
        case .health: "checkmark.seal"
        case .links: "link"
        case .assets: "photo.on.rectangle"
        case .tasks: "checklist"
        case .changes: "checkmark.seal"
        case .renderTarget: "checkmark.seal"
        }
    }

    private static func emptyTitle(for tab: DocumentLensTab) -> String {
        switch tab {
        case .structure: "No structure yet"
        case .health: "No findings"
        case .links: "No links"
        case .assets: "No images"
        case .tasks: "No tasks"
        case .changes: "No changes"
        case .renderTarget: "Compatible"
        }
    }

    private static func emptySubtitle(for tab: DocumentLensTab) -> String {
        switch tab {
        case .structure: "Add a heading to give this\ndocument a shape."
        case .health: "Nothing in this document looks\nwrong from here."
        case .links: "This document links nowhere yet."
        case .assets: "This document has no image\nreferences."
        case .tasks: "Add `- [ ]` to start a worklist."
        case .changes: "Nothing has changed since\nyou last looked."
        case .renderTarget: "Everything here renders on\nthe selected target."
        }
    }

    /// Test and accessibility harness entry point.  Production keyboard
    /// activation uses the same `PanelTableView` path.
    func selectItemForTesting(at row: Int) {
        guard row >= 0, row < rows.count, case .item = rows[row] else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        activateSelection()
    }

    private func syncTabControl() {
        guard let index = DocumentLensTab.allCases.firstIndex(of: selectedTab) else { return }
        tabControl.selectItem(at: index)
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        countLabel.textColor = styleSheet.textFaint
        table.reloadData()
    }

    @objc private func tabChanged(_ sender: NSPopUpButton) {
        guard let tab = DocumentLensTab.allCases.element(at: sender.indexOfSelectedItem) else { return }
        selectedTab = tab
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0,
              sender.indexOfSelectedItem < RenderTargetProfile.builtIns.count else { return }
        let profile = RenderTargetProfile.builtIns[sender.indexOfSelectedItem]
        renderTargetProfile = profile
        delegate?.documentLens(self, didSelectRenderTarget: profile)
    }

    private func syncTargetControl() {
        guard let index = RenderTargetProfile.builtIns.firstIndex(of: renderTargetProfile) else { return }
        targetControl.selectItem(at: index)
    }

    @objc private func rowClicked(_ sender: Any?) { activateSelection() }

    private func activateSelection() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count, case .item(let item) = rows[row] else { return }
        selectedItemID = item.id
        delegate?.documentLens(self, didSelect: item.range, item: item)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

extension DocumentLensView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return PanelMetrics.detailRowHeight }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return PanelMetrics.detailRowHeight
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .group = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .group(let group):
            let id = NSUserInterfaceItemIdentifier("documentLensGroup")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? PanelGroupRowView
                ?? PanelGroupRowView(identifier: id)
            cell.configure(text: "\(group.title.uppercased())  ·  \(group.count)", color: styleSheet.textFaint)
            return cell
        case .item(let item):
            let id = NSUserInterfaceItemIdentifier("documentLensItem")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? DocumentLensRowView
                ?? DocumentLensRowView(identifier: id)
            cell.configure(item: item, lineCaption: lineIndex?.caption(for: item.range), styleSheet: styleSheet)
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PanelList.selectionRow(in: tableView, owner: self, styleSheet: styleSheet)
    }
}

private final class DocumentLensRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = PanelFont.rowEmphasised
        detailLabel.font = PanelFont.secondary
        for label in [titleLabel, detailLabel] {
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(item: DocumentLensItem, lineCaption: String?, styleSheet: StyleSheet) {
        titleLabel.stringValue = item.title
        detailLabel.stringValue = [lineCaption, item.detail.isEmpty ? nil : item.detail]
            .compactMap { $0 }
            .joined(separator: "  ·  ")
        titleLabel.textColor = color(for: item.severity, styleSheet: styleSheet)
        detailLabel.textColor = styleSheet.textFaint
        toolTip = item.detail.isEmpty ? item.title : "\(item.title)\n\(item.detail)"
        let position = lineCaption ?? "Source range \(item.range.location)–\(item.range.upperBound)"
        setAccessibilityLabel("\(item.title), \(item.detail), \(position)")
        setAccessibilityRole(.button)
    }

    private func color(for severity: DocumentLensSeverity?, styleSheet: StyleSheet) -> NSColor {
        switch severity {
        case .error: styleSheet.calloutColor(.danger)
        case .warning: styleSheet.calloutColor(.warning)
        case .info, .none: styleSheet.textSecondary
        }
    }
}
