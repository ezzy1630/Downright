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
        didSet { applyStyle() }
    }

    var hits: [SiblingSearch.Hit] = [] { didSet { reload() } }

    /// The query the results answer.  The host owns the search session; the
    /// panel echoes the text so an empty list can say *for what* nothing was
    /// found instead of showing a bare "No matches".
    var query: String = "" { didSet { updateStatus() } }

    /// How many sibling files the last pass scanned, so the empty state can
    /// also say *where* it looked.  0 means the host has not told us yet.
    var searchedFileCount: Int = 0 { didSet { updateStatus() } }

    var isSearching: Bool = false {
        didSet {
            guard isSearching != oldValue else { return }
            updateStatus()
        }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    // MARK: - Views

    // No backdrop of its own: this panel only ever lives inside the search
    // inspector, which already sits on the host's glass column.  A second
    // vibrancy view here muddied the column — and, worse, made the find bar
    // above it fail to render at all (an AppKit compositing conflict between
    // the two materials; the fix is the deletion, not a workaround).
    //
    // No title row either: the inspector header names the surface (§7.2), so
    // the panel leads with a quiet status caption and gets out of the way.
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyState = PanelEmptyStateView()
    private let spinner = ActivityIndicatorView()
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
        super.init(frame: .zero)

        statusLabel.font = PanelFont.secondary
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Search results")
        addSubview(scroll)
        // Lifted past the geometric centre: with the header row (and, in the
        // inspector, the find bar) pinning the eye to the top, exact centre
        // reads as sunk.
        emptyState.install(in: self, over: scroll, verticalBias: 0.9)

        NSLayoutConstraint.activate([
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            statusLabel.topAnchor.constraint(equalTo: topAnchor, constant: PanelMetrics.headerTopPadding),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: PanelMetrics.inset),
            spinner.trailingAnchor.constraint(equalTo: statusLabel.leadingAnchor, constant: -6),
            spinner.centerYAnchor.constraint(equalTo: statusLabel.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
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
            spinner.begin()
            statusLabel.stringValue = "Searching…"
        } else {
            spinner.end()
            let files = Set(hits.map(\.url.path)).count
            statusLabel.stringValue = hits.isEmpty
                ? "No matches"
                : "\(hits.count) in \(files) file\(files == 1 ? "" : "s")"
        }
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
        let hasResults = !rows.isEmpty
        table.isHidden = !hasResults
        emptyState.isHidden = hasResults
        emptyState.configure(
            symbol: isSearching ? "magnifyingglass" : "doc.text.magnifyingglass",
            title: emptyStateTitle,
            subtitle: emptyStateSubtitle,
            styleSheet: styleSheet
        )
        setAccessibilityValue(statusLabel.stringValue)
    }

    // MARK: - Empty-state copy

    /// Three quiet states: a pass in flight, a pass that found nothing (say
    /// for what, and where it looked), and nothing searched yet (say how to
    /// start).  A bare "No matches" under a query-less panel read as a bug,
    /// not as guidance.
    private var emptyStateTitle: String {
        if isSearching { return "Searching" }
        guard !query.isEmpty else { return "Type to search" }
        return "No matches for “\(Self.truncated(query))”"
    }

    private var emptyStateSubtitle: String {
        if isSearching {
            return searchedFileCount > 0
                ? "Searching \(searchedFileCount) nearby \(searchedFileCount == 1 ? "file" : "files")…"
                : "Searching nearby Markdown files…"
        }
        guard !query.isEmpty else {
            return "Matches in this document’s sibling files appear here as you type."
        }
        return searchedFileCount > 0
            ? "Nothing in \(searchedFileCount) nearby \(searchedFileCount == 1 ? "file" : "files") contains it."
            : "No matching files or lines."
    }

    /// A query of any length lands in one centred line.
    private static func truncated(_ query: String, limit: Int = 48) -> String {
        guard query.count > limit else { return query }
        return String(query.prefix(limit)) + "…"
    }

    private func applyStyle() {
        statusLabel.textColor = styleSheet.textFaint
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
    /// A wrapping label: `labelWithString` never sets `cell.wraps`, so the
    /// two-line allowance below used to truncate on line one.
    private let contextLabel = NSTextField(wrappingLabelWithString: "")

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
        // …and the ellipsis lands on the *last visible* line — without this
        // the second line just clips mid-word.
        contextLabel.cell?.truncatesLastVisibleLine = true
        contextLabel.cell?.usesSingleLineMode = false
        contextLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(contextLabel)

        NSLayoutConstraint.activate([
            lineLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            lineLabel.widthAnchor.constraint(equalToConstant: 30),
            // The number belongs to the context's first line whether the
            // context wraps or not, so the two share a baseline rather than
            // a top edge.
            lineLabel.firstBaselineAnchor.constraint(equalTo: contextLabel.firstBaselineAnchor),
            contextLabel.leadingAnchor.constraint(equalTo: lineLabel.trailingAnchor, constant: 6),
            contextLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            // Centred in the row: one-line hits used to pin to the top and
            // leave a shelf of dead space under the text, which made the list
            // read as unevenly spaced.
            contextLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            contextLabel.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
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

        // No paragraphStyle here: a truncation mode in the attributed string
        // defeats the cell's wrap-then-truncate and the row collapses to a
        // single clipped line.  The label's own `lineBreakMode` +
        // `maximumNumberOfLines` own that policy.
        let attributed = NSMutableAttributedString(string: raw, attributes: [
            .font: PanelFont.row,
            .foregroundColor: styleSheet.textSecondary,
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
