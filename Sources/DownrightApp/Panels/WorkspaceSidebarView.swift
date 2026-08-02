import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol WorkspaceSidebarViewDelegate: AnyObject {
    func workspaceSidebar(_ view: WorkspaceSidebarView, didSelect url: URL, range: NSRange?, inNewWindow: Bool)
    func workspaceSidebar(_ view: WorkspaceSidebarView, didSearch query: WorkspaceSearchQuery)
}

@MainActor
final class WorkspaceSidebarView: NSView, PanelSurface {
    weak var delegate: WorkspaceSidebarViewDelegate?

    var styleSheet: StyleSheet {
        didSet { backdrop.styleSheet = styleSheet; applyStyle() }
    }

    var entries: [WorkspaceIndexEntry] = [] { didSet { reload() } }
    var searchResults: [WorkspaceSearchResult] = [] { didSet { reload() } }
    var backlinks: [WorkspaceBacklink] = [] { didSet { reload() } }
    var selectedFileID: String? { didSet { reload() } }
    var selectedTab: WorkspaceSidebarTab = .files {
        didSet { guard selectedTab != oldValue else { return }; syncTab(); reload() }
    }
    var preferredWidth: CGFloat { 320 }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Workspace")
    private let countLabel = NSTextField(labelWithString: "")
    private let tabControl = NSSegmentedControl()
    private let searchField = NSSearchField()
    private let table = PanelList.makeTableView(identifier: "workspaceSidebar")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private var rows: [Row] = []

    enum WorkspaceSidebarTab: String, CaseIterable, Sendable {
        case files = "Files"
        case search = "Search"
        case backlinks = "Backlinks"
    }

    private enum Row {
        case group(String)
        case file(Int)
        case result(Int)
        case backlink(Int)
    }

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)
        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        countLabel.font = PanelFont.secondary
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        tabControl.segmentCount = WorkspaceSidebarTab.allCases.count
        for (index, tab) in WorkspaceSidebarTab.allCases.enumerated() {
            tabControl.setLabel(tab.rawValue, forSegment: index)
            tabControl.setWidth(76, forSegment: index)
        }
        tabControl.segmentStyle = .texturedRounded
        tabControl.controlSize = .small
        tabControl.target = self
        tabControl.action = #selector(tabChanged(_:))
        tabControl.setAccessibilityLabel("Workspace sections")
        tabControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(tabControl)

        searchField.placeholderString = "Search workspace"
        searchField.font = PanelFont.row
        searchField.delegate = self
        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.setAccessibilityLabel("Search workspace files")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Workspace results")
        addSubview(scroll)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            tabControl.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            tabControl.trailingAnchor.constraint(lessThanOrEqualTo: countLabel.trailingAnchor),
            tabControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            searchField.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            searchField.trailingAnchor.constraint(equalTo: countLabel.trailingAnchor),
            searchField.topAnchor.constraint(equalTo: tabControl.bottomAnchor, constant: 5),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Workspace")
        syncTab()
        applyStyle()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSearchTextForTesting(_ text: String) {
        searchField.stringValue = text
        searchChanged(searchField)
    }

    func selectRowForTesting(_ row: Int) {
        guard row >= 0, row < rows.count else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        activateSelection()
    }

    private func syncTab() {
        guard let index = WorkspaceSidebarTab.allCases.firstIndex(of: selectedTab) else { return }
        tabControl.selectedSegment = index
        searchField.isHidden = selectedTab == .backlinks
    }

    private func reload() {
        rows.removeAll(keepingCapacity: true)
        switch selectedTab {
        case .files:
            var groups: [String: [Int]] = [:]
            var order: [String] = []
            for index in entries.indices {
                let folder = URL(fileURLWithPath: entries[index].relativePath).deletingLastPathComponent().path
                if groups[folder] == nil { order.append(folder) }
                groups[folder, default: []].append(index)
            }
            for folder in order {
                if order.count > 1 { rows.append(.group(folder == "." ? "This folder" : folder)) }
                rows.append(contentsOf: groups[folder, default: []].map { .file($0) })
            }
            countLabel.stringValue = "\(entries.count) file\(entries.count == 1 ? "" : "s")"
        case .search:
            rows = searchResults.indices.map { .result($0) }
            countLabel.stringValue = searchResults.isEmpty
                ? "No matches"
                : "\(searchResults.count) match\(searchResults.count == 1 ? "" : "es")"
        case .backlinks:
            rows = backlinks.indices.map { .backlink($0) }
            countLabel.stringValue = backlinks.isEmpty
                ? "No backlinks"
                : "\(backlinks.count) backlink\(backlinks.count == 1 ? "" : "s")"
        }
        countLabel.setAccessibilityLabel(countLabel.stringValue)
        table.reloadData()
    }

    @objc private func tabChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0, sender.selectedSegment < WorkspaceSidebarTab.allCases.count else { return }
        selectedTab = WorkspaceSidebarTab.allCases[sender.selectedSegment]
    }

    @objc private func searchChanged(_ sender: Any?) {
        guard selectedTab == .search || !searchField.stringValue.isEmpty else { return }
        selectedTab = .search
        delegate?.workspaceSidebar(self, didSearch: WorkspaceSearchQuery(text: searchField.stringValue))
    }

    private func activateSelection() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count else { return }
        let inNewWindow = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        switch rows[row] {
        case .group: return
        case .file(let index) where index < entries.count:
            delegate?.workspaceSidebar(self, didSelect: entries[index].url, range: nil, inNewWindow: inNewWindow)
        case .result(let index) where index < searchResults.count:
            let result = searchResults[index]
            delegate?.workspaceSidebar(self, didSelect: result.url, range: result.range, inNewWindow: inNewWindow)
        case .backlink(let index) where index < backlinks.count:
            let backlink = backlinks[index]
            let url = URL(fileURLWithPath: backlink.sourceFile)
            delegate?.workspaceSidebar(self, didSelect: url, range: backlink.sourceRange, inNewWindow: inNewWindow)
        default: return
        }
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        countLabel.textColor = styleSheet.textFaint
        table.reloadData()
    }

    @objc private func rowClicked(_ sender: Any?) { activateSelection() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

extension WorkspaceSidebarView: NSSearchFieldDelegate {}

extension WorkspaceSidebarView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return 42 }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return 42
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
        case .group(let title):
            let id = NSUserInterfaceItemIdentifier("workspaceGroup")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? PanelGroupRowView ?? PanelGroupRowView(identifier: id)
            cell.configure(text: title.uppercased(), color: styleSheet.textFaint)
            return cell
        case .file(let index) where index < entries.count:
            let entry = entries[index]
            return makeRow(id: "workspaceFile", title: entry.relativePath, detail: headingSummary(entry), color: styleSheet.textSecondary)
        case .result(let index) where index < searchResults.count:
            let result = searchResults[index]
            return makeRow(id: "workspaceSearch", title: result.relativePath, detail: "Line \(result.line) · \(result.contextText)", color: styleSheet.textSecondary)
        case .backlink(let index) where index < backlinks.count:
            let backlink = backlinks[index]
            return makeRow(id: "workspaceBacklink", title: URL(fileURLWithPath: backlink.sourceFile).lastPathComponent, detail: backlink.destination, color: styleSheet.textSecondary)
        default: return nil
        }
    }

    private func headingSummary(_ entry: WorkspaceIndexEntry) -> String {
        if let heading = entry.headings.first { return heading.title }
        return "Markdown file"
    }

    private func makeRow(id: String, title: String, detail: String, color: NSColor) -> NSView {
        let view = WorkspaceSidebarRowView(identifier: NSUserInterfaceItemIdentifier(id))
        view.configure(title: title, detail: detail, color: color)
        return view
    }
}

private final class WorkspaceSidebarRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = PanelFont.row
        detailLabel.font = PanelFont.secondary
        for label in [titleLabel, detailLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
        ])
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, detail: String, color: NSColor) {
        titleLabel.stringValue = title
        detailLabel.stringValue = detail
        titleLabel.textColor = color
        detailLabel.textColor = color.withAlphaComponent(0.7)
        setAccessibilityLabel("\(title). \(detail)")
    }
}
