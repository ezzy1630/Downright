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

    var preferredWidth: CGFloat { 352 }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Document Lens")
    private let countLabel = NSTextField(labelWithString: "")
    private let tabControl = NSSegmentedControl()
    private let targetControl = NSPopUpButton()
    private let table = PanelList.makeTableView(identifier: "documentLens")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    private enum Row {
        case group(DocumentLensGroup)
        case item(DocumentLensItem)
    }
    private var rows: [Row] = []

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

        tabControl.segmentCount = DocumentLensTab.allCases.count
        for (index, tab) in DocumentLensTab.allCases.enumerated() {
            tabControl.setLabel(tab.title, forSegment: index)
            tabControl.setWidth(46, forSegment: index)
        }
        tabControl.segmentStyle = .texturedRounded
        tabControl.controlSize = .small
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
            targetControl.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 4),
            targetControl.widthAnchor.constraint(equalToConstant: 152),
        ])
        syncTabControl()
        syncTargetControl()
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 48
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Document Lens items")
        addSubview(scroll)
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
        table.reloadData()
        table.deselectAll(nil)
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
        tabControl.selectedSegment = index
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        countLabel.textColor = styleSheet.textFaint
        table.reloadData()
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0,
              sender.selectedSegment < DocumentLensTab.allCases.count else { return }
        selectedTab = DocumentLensTab.allCases[sender.selectedSegment]
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
        guard row < rows.count else { return 48 }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return 48
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
            cell.configure(item: item, styleSheet: styleSheet) { [weak self] in
                guard let self else { return }
                self.delegate?.documentLens(self, didSelect: item.range, item: item)
            }
            return cell
        }
    }
}

private final class DocumentLensRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private var onSelect: (() -> Void)?

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

    func configure(item: DocumentLensItem, styleSheet: StyleSheet, onSelect: @escaping () -> Void) {
        self.onSelect = onSelect
        titleLabel.stringValue = item.title
        detailLabel.stringValue = item.detail
        titleLabel.textColor = color(for: item.severity, styleSheet: styleSheet)
        detailLabel.textColor = styleSheet.textFaint
        let source = "Source offset \(max(0, item.range.location))"
        setAccessibilityLabel("\(item.title), \(item.detail), \(source)")
        setAccessibilityRole(.button)
    }

    private func color(for severity: DocumentLensSeverity?, styleSheet: StyleSheet) -> NSColor {
        switch severity {
        case .error: styleSheet.calloutColor(.danger)
        case .warning: styleSheet.calloutColor(.warning)
        case .info, .none: styleSheet.textSecondary
        }
    }

    override func mouseDown(with event: NSEvent) {
        onSelect?()
        super.mouseDown(with: event)
    }
}
