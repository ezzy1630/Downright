import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol OutlinePanelDelegate: AnyObject {
    func outlinePanel(_ panel: OutlinePanelView, didSelectHeadingAt index: Int)
    /// Move the section at `index` — the heading *and everything beneath it* —
    /// so that it sits immediately before `targetIndex`.  `targetIndex ==
    /// headings.count` means "to the end of the document".
    func outlinePanel(_ panel: OutlinePanelView, didMoveHeadingAt index: Int, before targetIndex: Int)
    func outlinePanel(_ panel: OutlinePanelView, didToggleFoldAt index: Int)
    func outlinePanel(_ panel: OutlinePanelView, didChangeZoomLevel level: ZoomLevel)
}

extension NSPasteboard.PasteboardType {
    /// Local-only drag payload: the index of the heading being moved.
    static let downrightHeading = NSPasteboard.PasteboardType("com.ezzyrappeport.downright.heading")
}

/// The document contents panel (§7.1 drag-reorder).
///
/// The headline interaction is the drag: agent output is frequently in a poor
/// order, and dragging a heading here moves the heading and its entire subtree
/// in the source, which turns restructuring into a gesture instead of a
/// cut-and-paste.  A drop into a section's own subtree is refused outright
/// rather than silently no-op'd.
///
/// A flat `NSTableView` with indentation is used rather than `NSOutlineView`:
/// the panel needs a *document* fold control per row (a heading with no
/// sub-headings still has prose to fold), and two disclosure affordances on one
/// row — the outline's own triangle and the document's fold — is exactly the
/// kind of ambiguity that makes a panel feel unfinished.
final class OutlinePanelView: NSView, PanelSurface {
    weak var delegate: OutlinePanelDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    var headings: [HeadingNode] = [] { didSet { reload() } }
    var filterText: String = "" { didSet { guard filterText != oldValue else { return }; reload() } }
    /// Parallel to `headings`; may be short or empty, in which case the
    /// heading's own word count stands in.
    /// Kept for callers that already compute section metrics.  Navigation does
    /// not render read-time or density indicators; those belong to the reader.
    var sectionMetrics: [ReadingMetrics] = [] { didSet { reload() } }
    var foldedIndices: Set<Int> = [] { didSet { reload() } }

    var currentHeadingIndex: Int? {
        didSet {
            guard currentHeadingIndex != oldValue else { return }
            table.reloadData()
            revealCurrentHeading()
        }
    }

    var zoomLevel: ZoomLevel = .everything {
        didSet {
            guard zoomLevel != oldValue else { return }
        }
    }

    var preferredWidth: CGFloat { 320 }
    var hasVisibleContent: Bool { !visibleRows.isEmpty }
    var preferredHeight: CGFloat {
        guard hasVisibleContent else { return 0 }
        let rowCount = min(visibleRows.count, 12)
        return 40 + CGFloat(rowCount) * table.rowHeight
    }
    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Contents")
    private let filterStatusLabel = NSTextField(labelWithString: "")
    private let table = PanelList.makeTableView(identifier: "outline")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    /// Heading indices currently listed — a folded section hides its
    /// descendants here exactly as it hides them in the document.
    private var visibleRows: [Int] = []
    var visibleRowCountForTesting: Int { visibleRows.count }
    var filterMatchCountForTesting: Int { filterMatchCount }
    private var filterMatchCount = 0

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

        buildHeader()
        buildTable()
        applyStyle()

        setAccessibilityRole(.group)
        setAccessibilityLabel("Outline")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildHeader() {
        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        filterStatusLabel.font = PanelFont.secondary
        filterStatusLabel.alignment = .right
        filterStatusLabel.textColor = styleSheet.textFaint
        filterStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        filterStatusLabel.setAccessibilityRole(.staticText)
        addSubview(filterStatusLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            filterStatusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            filterStatusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            filterStatusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 30
        table.selectionHighlightStyle = .none
        table.registerForDraggedTypes([.downrightHeading])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        // The gap style is what actually shows the reader where the section
        // will land; a thin line between rows is too easy to miss on a dense
        // outline.
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel("Document headings")
        table.onActivate = { [weak self] in
            guard let self, let index = self.selectedHeadingIndex() else { return }
            self.revealFoldedAncestors(of: index)
            self.delegate?.outlinePanel(self, didSelectHeadingAt: index)
        }
        // ← / → fold and unfold the selected section, so the panel's two
        // actions are both reachable without the pointer (§11.4).
        table.onKeyDown = { [weak self] key in
            guard let self, let index = self.selectedHeadingIndex() else { return false }
            switch key {
            case "left" where !self.foldedIndices.contains(index),
                 "right" where self.foldedIndices.contains(index):
                self.delegate?.outlinePanel(self, didToggleFoldAt: index)
                return true
            default:
                return false
            }
        }

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Reload

    func reload() {
        rebuildVisibleRows()
        table.reloadData()
        invalidateIntrinsicContentSize()
        revealCurrentHeading()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        reload()
        displayIfNeeded()
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
    }

    private func rebuildVisibleRows() {
        visibleRows.removeAll(keepingCapacity: true)
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        guard !query.isEmpty else {
            filterMatchCount = 0
            var index = 0
            while index < headings.count {
                visibleRows.append(index)
                if foldedIndices.contains(index) {
                    index = sectionEnd(of: index)
                } else {
                    index += 1
                }
            }
            filterStatusLabel.stringValue = ""
            filterStatusLabel.setAccessibilityLabel("")
            return
        }

        let matches = headings.indices.compactMap { index -> (Int, Int)? in
            let title = headings[index].title.folding(
                options: [.caseInsensitive, .diacriticInsensitive], locale: .current
            )
            guard let match = FuzzyMatcher.match(needle: query, in: title) else { return nil }
            return (index, match.score)
        }
        .sorted { lhs, rhs in
            if lhs.1 != rhs.1 { return lhs.1 > rhs.1 }
            return lhs.0 < rhs.0
        }
        .map(\.0)
        filterMatchCount = matches.count

        // Search is an explicit request to look through the document. Keep
        // matching descendants visible even when their source section is
        // folded, and include their heading path so the result has context.
        var included = Set<Int>()
        for match in matches {
            included.insert(match)
            var level = headings[match].level
            var candidate = match - 1
            while candidate >= 0 {
                let candidateLevel = headings[candidate].level
                if candidateLevel < level {
                    included.insert(candidate)
                    level = candidateLevel
                }
                if level == 1 { break }
                candidate -= 1
            }
        }
        visibleRows = included.sorted()
        filterStatusLabel.stringValue = matches.isEmpty
            ? "No matches"
            : "\(matches.count) match\(matches.count == 1 ? "" : "es")"
        filterStatusLabel.setAccessibilityLabel(filterStatusLabel.stringValue)
    }

    private func selectedHeadingIndex() -> Int? {
        let row = table.selectedRow
        guard row >= 0, row < visibleRows.count else { return nil }
        return visibleRows[row]
    }

    /// Index one past the last descendant of `index`.
    private func sectionEnd(of index: Int) -> Int {
        guard index < headings.count else { return headings.count }
        let level = headings[index].level
        var end = index + 1
        while end < headings.count, headings[end].level > level { end += 1 }
        return end
    }

    private func revealCurrentHeading() {
        guard let current = currentHeadingIndex,
              let row = visibleRows.firstIndex(of: current) else { return }
        // Deliberately unanimated: this fires as the reader scrolls, and an
        // eased scroll chasing every heading boundary is motion sickness in a
        // sidebar — Reduce Motion or not.
        table.scrollRowToVisible(row)
    }

    private func revealFoldedAncestors(of index: Int) {
        var revealed = foldedIndices
        var level = headings[index].level
        var candidate = index - 1
        while candidate >= 0 {
            let candidateLevel = headings[candidate].level
            if candidateLevel < level {
                revealed.remove(candidate)
                level = candidateLevel
            }
            if level == 1 { break }
            candidate -= 1
        }
        guard revealed != foldedIndices else { return }
        for foldedIndex in foldedIndices.subtracting(revealed) {
            delegate?.outlinePanel(self, didToggleFoldAt: foldedIndex)
        }
        foldedIndices = revealed
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        filterStatusLabel.textColor = styleSheet.textFaint
        table.reloadData()
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        // Hairline under the header so the section label reads as chrome.
        styleSheet.rule.setFill()
        let y = scroll.frame.maxY
        NSRect(x: 0, y: y, width: bounds.width, height: PanelMetrics.hairline).fill()
    }
}

// MARK: - Table data

extension OutlinePanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { visibleRows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visibleRows.count else { return nil }
        let index = visibleRows[row]
        let identifier = NSUserInterfaceItemIdentifier("outlineRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? OutlineRowView
            ?? OutlineRowView(identifier: identifier)

        cell.onToggleFold = { [weak self] headingIndex in
            guard let self else { return }
            self.delegate?.outlinePanel(self, didToggleFoldAt: headingIndex)
        }
        cell.configure(
            heading: headings[index],
            index: index,
            styleSheet: styleSheet,
            isFolded: foldedIndices.contains(index),
            isCurrent: index == currentHeadingIndex,
            isSelected: tableView.selectedRow == row
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < visibleRows.count else { return }
        table.reloadData()
        let index = visibleRows[row]
        revealFoldedAncestors(of: index)
        delegate?.outlinePanel(self, didSelectHeadingAt: index)
    }

    // MARK: Drag and drop (§7.1)

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard row < visibleRows.count else { return nil }
        let item = NSPasteboardItem()
        item.setString(String(visibleRows[row]), forType: .downrightHeading)
        return item
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let source = draggedHeading(from: info) else { return [] }
        if dropOperation == .on {
            // Dropping *onto* a heading has no meaning here — every drop is an
            // insertion point.
            tableView.setDropRow(row, dropOperation: .above)
        }
        return isLegalMove(source: source, target: headingIndex(forDropRow: row)) ? .move : []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let source = draggedHeading(from: info) else { return false }
        let target = headingIndex(forDropRow: row)
        guard isLegalMove(source: source, target: target) else { return false }
        delegate?.outlinePanel(self, didMoveHeadingAt: source, before: target)
        return true
    }

    private func draggedHeading(from info: NSDraggingInfo) -> Int? {
        guard let raw = info.draggingPasteboard.string(forType: .downrightHeading),
              let index = Int(raw), headings.indices.contains(index) else { return nil }
        return index
    }

    private func headingIndex(forDropRow row: Int) -> Int {
        visibleRows.indices.contains(row) ? visibleRows[row] : headings.count
    }

    /// A section cannot be moved into itself, and moving it back where it
    /// already is is not a move.  Refusing both in `validateDrop` means the
    /// cursor says no before the drop rather than the document silently not
    /// changing after it.
    private func isLegalMove(source: Int, target: Int) -> Bool {
        guard headings.indices.contains(source) else { return false }
        if target == source { return false }
        return !(target > source && target <= sectionEnd(of: source))
    }
}

// MARK: - Row

/// One heading.  Fold and reorder affordances stay quiet until the row is
/// current or hovered, so Contents reads as a clean list at rest.
private final class OutlineRowView: NSView {
    var onToggleFold: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let foldButton = NSButton()
    private var foldAction: ButtonAction?
    private var titleLeading: NSLayoutConstraint!
    private var foldLeading: NSLayoutConstraint!

    private var styleSheet: StyleSheet?
    private var headingIndex = 0
    private var isCurrent = false
    private var isSelected = false
    private var isHovered = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        foldButton.isBordered = false
        foldButton.bezelStyle = .accessoryBarAction
        foldButton.imagePosition = .imageOnly
        foldButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(foldButton)

        titleLabel.font = PanelFont.row
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        foldLeading = foldButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset)
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: foldButton.trailingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            foldLeading,
            foldButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            foldButton.widthAnchor.constraint(equalToConstant: 14),
            titleLeading,
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PanelMetrics.inset),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(
        heading: HeadingNode,
        index: Int,
        styleSheet: StyleSheet,
        isFolded: Bool,
        isCurrent: Bool,
        isSelected: Bool
    ) {
        self.styleSheet = styleSheet
        self.headingIndex = index
        self.isCurrent = isCurrent
        self.isSelected = isSelected

        let indent = PanelMetrics.inset + CGFloat(min(heading.level, 6) - 1) * 11
        foldLeading.constant = indent

        titleLabel.stringValue = heading.title.isEmpty ? "Untitled" : heading.title
        titleLabel.textColor = styleSheet.headingColor(level: heading.level)
        titleLabel.font = isCurrent ? PanelFont.rowEmphasised : PanelFont.row

        let symbol = isFolded ? "chevron.right" : "chevron.down"
        let description = isFolded ? "Unfold section" : "Fold section"
        foldButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold))
        foldButton.contentTintColor = styleSheet.textFaint
        foldButton.setAccessibilityLabel(description)
        foldButton.toolTip = description

        let action = ButtonAction { [weak self] in
            guard let self else { return }
            self.onToggleFold?(self.headingIndex)
        }
        foldAction = action
        foldButton.target = action
        foldButton.action = #selector(ButtonAction.fire(_:))
        foldButton.isHidden = !(isCurrent || isSelected || isHovered)

        let state = isCurrent ? ", current section" : ""
        setAccessibilityLabel("\(heading.title), heading level \(heading.level)\(state)")
        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        foldButton.isHidden = false
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        foldButton.isHidden = !(isCurrent || isSelected)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let styleSheet else { return }

        if isCurrent {
            styleSheet.accent.setFill()
            NSRect(x: 0, y: 3, width: 3, height: bounds.height - 6).fill()
        }

        let alpha: CGFloat?
        if isSelected { alpha = 0.12 }
        else if isCurrent { alpha = 0.08 }
        else if isHovered { alpha = 0.05 }
        else { alpha = nil }
        guard let alpha else { return }
        styleSheet.text
            .panelAlpha(alpha, increaseContrast: styleSheet.increaseContrast)
            .setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 4, dy: 2),
            xRadius: PanelMetrics.cornerRadius,
            yRadius: PanelMetrics.cornerRadius
        ).fill()
    }
}
