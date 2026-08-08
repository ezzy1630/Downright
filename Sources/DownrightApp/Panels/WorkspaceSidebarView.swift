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

    var entries: [WorkspaceIndexEntry] = [] {
        didSet { hasScanned = true; reload() }
    }

    var searchResults: [WorkspaceSearchResult] = [] {
        // Results arriving is what ends a search.  Until they do the panel must
        // not claim there are none (§11.4).
        didSet { isSearching = false; reload() }
    }

    var backlinks: [WorkspaceBacklink] = [] { didSet { reload() } }
    var selectedFileID: String? { didSet { reload() } }
    var selectedTab: WorkspaceSidebarTab = .files {
        didSet { guard selectedTab != oldValue else { return }; syncTab(); reload() }
    }

    /// Set while the host is scanning the folder for the first time.  A folder
    /// scan is work in progress, not an empty folder.
    var isScanning: Bool = false { didSet { reload() } }
    var errorMessage: String? { didSet { if errorMessage != oldValue { reload() } } }

    var preferredWidth: CGFloat { PanelMetrics.listWidth }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: Command.workspace.panelTitle)
    private let countLabel = NSTextField(labelWithString: "")
    private let tabControl: PanelSegmentedControl
    private let searchField = NSSearchField()
    private let spinner = ActivityIndicatorView()
    private let emptyState = PanelEmptyStateView()
    private let table = PanelList.makeTableView(identifier: "workspaceSidebar")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private var rows: [Row] = []
    /// True once the host has handed over a file list, so "no files" can be
    /// told apart from "not scanned yet".
    private var hasScanned = false
    private var isSearching = false

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
        tabControl = PanelSegmentedControl(
            items: WorkspaceSidebarTab.allCases.map(\.rawValue),
            styleSheet: styleSheet
        )
        super.init(frame: .zero)

        installBackdrop(backdrop)
        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)
        countLabel.font = PanelFont.secondary
        countLabel.alignment = .right
        countLabel.lineBreakMode = .byTruncatingTail
        countLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        // Sized from its labels and free to compress, so the tab strip cannot
        // out-measure a narrow inspector the way three 76pt segments did.
        tabControl.onChange = { [weak self] index in
            guard let tab = WorkspaceSidebarTab.allCases.element(at: index) else { return }
            self?.selectedTab = tab
        }
        tabControl.setAccessibilityLabel("Workspace sections")
        tabControl.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
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
        emptyState.install(in: self, over: scroll)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: PanelMetrics.headerTopPadding),
            spinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            spinner.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: spinner.trailingAnchor, constant: 6),
            tabControl.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            tabControl.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PanelMetrics.inset),
            tabControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            tabControl.heightAnchor.constraint(equalToConstant: PanelSegmentedControl.controlHeight),
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

    private func syncTab() {
        guard let index = WorkspaceSidebarTab.allCases.firstIndex(of: selectedTab) else { return }
        tabControl.setSelectedIndex(index)
        searchField.isHidden = selectedTab == .backlinks
    }

    /// True while the tab on screen is still waiting for its content.  Nothing
    /// may say "none" until this is false.
    private var isBusy: Bool {
        switch selectedTab {
        case .files: return errorMessage == nil && (isScanning || !hasScanned)
        case .search: return isSearching
        case .backlinks: return false
        }
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
            countLabel.stringValue = isBusy
                ? "Scanning…"
                : "\(entries.count) file\(entries.count == 1 ? "" : "s")"
        case .search:
            rows = searchResults.indices.map { .result($0) }
            countLabel.stringValue = isBusy
                ? "Searching…"
                : (searchResults.isEmpty
                    ? "No matches"
                    : "\(searchResults.count) match\(searchResults.count == 1 ? "" : "es")")
        case .backlinks:
            rows = backlinks.indices.map { .backlink($0) }
            countLabel.stringValue = backlinks.isEmpty
                ? "No backlinks"
                : "\(backlinks.count) backlink\(backlinks.count == 1 ? "" : "s")"
        }
        countLabel.setAccessibilityLabel(countLabel.stringValue)
        if isBusy { spinner.begin() } else { spinner.end() }
        table.reloadData()
        updateEmptyState()
        setAccessibilityValue(countLabel.stringValue)
    }

    private func updateEmptyState() {
        guard rows.isEmpty else {
            emptyState.isHidden = true
            scroll.isHidden = false
            return
        }
        let state: (symbol: String, title: String, subtitle: String)
        if let errorMessage {
            state = ("exclamationmark.triangle", "Workspace unavailable", errorMessage)
        } else { switch (selectedTab, isBusy) {
        case (.files, true):
            state = ("folder", "Scanning the folder", "Listing the Markdown files\nnext to this document.")
        case (.files, false):
            state = ("folder", "No Markdown files", "This workspace folder has no\nother Markdown documents.")
        case (.search, true):
            state = ("magnifyingglass", "Searching", "Looking through the workspace\nfiles for that text.")
        case (.search, false) where searchField.stringValue.isEmpty:
            state = ("magnifyingglass", "Search the workspace", "Type above to search every\nMarkdown file in this folder.")
        case (.search, false):
            state = ("magnifyingglass", "No matches", "Nothing in this workspace\ncontains “\(searchField.stringValue)”.")
        case (.backlinks, _):
            state = ("arrow.triangle.branch", "No backlinks", "No workspace file links to\nthis document yet.")
        } }
        emptyState.configure(symbol: state.symbol, title: state.title, subtitle: state.subtitle, styleSheet: styleSheet)
        emptyState.isHidden = false
        scroll.isHidden = true
    }

    @objc private func searchChanged(_ sender: Any?) {
        guard selectedTab == .search || !searchField.stringValue.isEmpty else { return }
        isSearching = !searchField.stringValue.isEmpty
        selectedTab = .search
        reload()
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
        tabControl.styleSheet = styleSheet
        table.reloadData()
        updateEmptyState()
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
        guard row < rows.count else { return PanelMetrics.detailRowHeight }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return PanelMetrics.detailRowHeight
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PanelList.selectionRow(in: tableView, owner: self, styleSheet: styleSheet)
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
            return makeRow(in: tableView, id: "workspaceFile", title: entry.relativePath, detail: headingSummary(entry), color: styleSheet.textSecondary)
        case .result(let index) where index < searchResults.count:
            let result = searchResults[index]
            return makeRow(in: tableView, id: "workspaceSearch", title: result.relativePath, detail: "Line \(result.line) · \(result.contextText)", color: styleSheet.textSecondary)
        case .backlink(let index) where index < backlinks.count:
            let backlink = backlinks[index]
            return makeRow(in: tableView, id: "workspaceBacklink", title: URL(fileURLWithPath: backlink.sourceFile).lastPathComponent, detail: backlink.destination, color: styleSheet.textSecondary)
        default: return nil
        }
    }

    private func headingSummary(_ entry: WorkspaceIndexEntry) -> String {
        if let heading = entry.headings.first { return heading.title }
        return "Markdown file"
    }

    /// Reuse rather than a fresh cell per `viewFor`: this table reloads on every
    /// keystroke in the search field.
    private func makeRow(
        in tableView: NSTableView, id: String, title: String, detail: String, color: NSColor
    ) -> NSView {
        let identifier = NSUserInterfaceItemIdentifier(id)
        let view = tableView.makeView(withIdentifier: identifier, owner: self) as? WorkspaceSidebarRowView
            ?? WorkspaceSidebarRowView(identifier: identifier)
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
