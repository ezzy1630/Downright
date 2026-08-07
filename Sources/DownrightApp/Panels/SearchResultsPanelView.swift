import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol SearchResultsDelegate: AnyObject {
    func searchResults(_ view: SearchResultsPanelView, didSelect hit: SiblingSearch.Hit)
}

/// Cross-file search results (§9.4, `⌘⇧F`).
///
/// Grouped by file, one context line per hit with the match emphasised.  Still
/// no index and no vault (§2): the host hands over hits from a shallow scan of
/// the sibling list, and this view's only job is to make them scannable.
final class SearchResultsPanelView: NSView, PanelSurface {
    weak var delegate: SearchResultsDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    var hits: [SiblingSearch.Hit] = [] { didSet { reload() } }

    var isSearching: Bool = false {
        didSet {
            guard isSearching != oldValue else { return }
            updateStatus()
        }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: Command.findInSiblings.panelTitle)
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let table = PanelList.makeTableView(identifier: "searchResults")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    private enum Row {
        case group(name: String, count: Int)
        /// Index into `hits`.
        case hit(Int)
    }

    private var rows: [Row] = []

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        statusLabel.font = PanelFont.secondary
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        emptyLabel.font = PanelFont.row
        emptyLabel.alignment = .center
        emptyLabel.textColor = styleSheet.textSecondary
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyLabel)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Search results")
        addSubview(scroll)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            spinner.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 6),
            spinner.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: spinner.trailingAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])

        applyStyle()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Search results")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Reload

    func reload() {
        rebuildRows()
        table.reloadData()
        updateStatus()
    }

    /// Hits arrive grouped by file already; this preserves that order rather
    /// than re-sorting, so the sibling list's newest-first ordering carries
    /// through to the results.
    private func rebuildRows() {
        rows.removeAll(keepingCapacity: true)
        var index = 0
        while index < hits.count {
            let path = hits[index].url.path
            var end = index
            while end < hits.count, hits[end].url.path == path { end += 1 }
            rows.append(.group(name: hits[index].displayName, count: end - index))
            rows.append(contentsOf: (index..<end).map { Row.hit($0) })
            index = end
        }
    }

    private func updateStatus() {
        if isSearching {
            spinner.startAnimation(nil)
            statusLabel.stringValue = "Searching…"
        } else {
            spinner.stopAnimation(nil)
            let files = Set(hits.map(\.url.path)).count
            statusLabel.stringValue = hits.isEmpty
                ? "No matches"
                : "\(hits.count) in \(files) file\(files == 1 ? "" : "s")"
        }
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
        let hasResults = !rows.isEmpty
        table.isHidden = !hasResults
        emptyLabel.isHidden = hasResults
        emptyLabel.stringValue = isSearching
            ? "Searching nearby Markdown files…"
            : "No matching files or lines."
        emptyLabel.setAccessibilityLabel(emptyLabel.stringValue)
        setAccessibilityValue(statusLabel.stringValue)
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        statusLabel.textColor = styleSheet.textFaint
        emptyLabel.textColor = styleSheet.textSecondary
        table.reloadData()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        activateSelection()
    }

    private func activateSelection() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count, case .hit(let index) = rows[row], index < hits.count else { return }
        delegate?.searchResults(self, didSelect: hits[index])
    }
}

// MARK: - Table

extension SearchResultsPanelView: NSTableViewDataSource, NSTableViewDelegate {
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
        case .group(let name, let count):
            let identifier = NSUserInterfaceItemIdentifier("resultsGroup")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PanelGroupRowView
                ?? PanelGroupRowView(identifier: identifier)
            cell.configure(text: "\(name.uppercased())  ·  \(count)", color: styleSheet.textFaint)
            return cell

        case .hit(let index):
            guard index < hits.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("resultsRow")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SearchHitRowView
                ?? SearchHitRowView(identifier: identifier)
            cell.configure(hit: hits[index], styleSheet: styleSheet)
            return cell
        }
    }
}

// MARK: - Row

private final class SearchHitRowView: NSView {
    private let lineLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        lineLabel.font = PanelFont.secondary
        lineLabel.alignment = .right
        lineLabel.translatesAutoresizingMaskIntoConstraints = false
        lineLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(lineLabel)

        contextLabel.font = PanelFont.row
        contextLabel.maximumNumberOfLines = 2
        contextLabel.lineBreakMode = .byTruncatingTail
        contextLabel.cell?.usesSingleLineMode = false
        contextLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contextLabel)

        NSLayoutConstraint.activate([
            lineLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            lineLabel.widthAnchor.constraint(equalToConstant: 30),
            lineLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            contextLabel.leadingAnchor.constraint(equalTo: lineLabel.trailingAnchor, constant: 6),
            contextLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            contextLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            contextLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -4),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(hit: SiblingSearch.Hit, styleSheet: StyleSheet) {
        lineLabel.stringValue = "\(hit.lineNumber)"
        lineLabel.textColor = styleSheet.textFaint

        // Collapse the context to one visual line before highlighting: a
        // paragraph's internal newlines are noise in a results list, and
        // collapsing them keeps the match offset arithmetic exact only if we
        // replace rather than remove, so each newline becomes one space.
        let raw = hit.contextText.replacingOccurrences(of: "\n", with: " ")
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail

        let attributed = NSMutableAttributedString(string: raw, attributes: [
            .font: PanelFont.row,
            .foregroundColor: styleSheet.textSecondary,
            .paragraphStyle: paragraph,
        ])

        let offset = hit.range.location - hit.contextRange.location
        let length = min(hit.range.length, max(0, attributed.length - offset))
        if offset >= 0, length > 0 {
            attributed.addAttributes([
                .foregroundColor: styleSheet.text,
                .backgroundColor: styleSheet.searchHit,
                .font: PanelFont.rowEmphasised,
            ], range: NSRange(location: offset, length: length))
        }
        contextLabel.attributedStringValue = attributed

        var label = "Line \(hit.lineNumber): \(raw)"
        label = "\(hit.displayName), \(label)"
        if let heading = hit.headingTitle { label += ", in \(heading)" }
        setAccessibilityRole(.row)
        setAccessibilityLabel(label)
        toolTip = hit.headingTitle
    }
}
