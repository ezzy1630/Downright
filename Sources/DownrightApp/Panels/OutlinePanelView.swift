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
    static let downrightHeading = NSPasteboard.PasteboardType("com.unrulyagency.downright.heading")
}

/// The outline panel (§5.2 header slider, §7.1 drag-reorder, §9.6 read time).
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
    /// Parallel to `headings`; may be short or empty, in which case the
    /// heading's own word count stands in.
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
            syncZoomControl()
        }
    }

    var preferredWidth: CGFloat { PanelMetrics.listWidth }

    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Outline")
    private let zoomNameLabel = NSTextField(labelWithString: "")
    private let zoomSlider = NSSlider()
    private let table = PanelList.makeTableView(identifier: "outline")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    /// Heading indices currently listed — a folded section hides its
    /// descendants here exactly as it hides them in the document.
    private var visibleRows: [Int] = []
    private var largestSectionWords = 1

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
        syncZoomControl()

        setAccessibilityRole(.group)
        setAccessibilityLabel("Outline")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildHeader() {
        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        zoomNameLabel.font = PanelFont.secondary
        zoomNameLabel.alignment = .right
        zoomNameLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomNameLabel)

        // §5.2: "a slider in the outline panel header".  Tick-only values keep
        // it honest — there is no zoom level 2.5.
        zoomSlider.minValue = Double(ZoomLevel.h1.rawValue)
        zoomSlider.maxValue = Double(ZoomLevel.everything.rawValue)
        zoomSlider.numberOfTickMarks = ZoomLevel.allCases.count
        zoomSlider.allowsTickMarkValuesOnly = true
        zoomSlider.tickMarkPosition = .below
        zoomSlider.controlSize = .small
        zoomSlider.target = self
        zoomSlider.action = #selector(zoomSliderChanged(_:))
        zoomSlider.setAccessibilityLabel("Structural zoom level")
        zoomSlider.translatesAutoresizingMaskIntoConstraints = false
        addSubview(zoomSlider)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            zoomNameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            zoomNameLabel.firstBaselineAnchor.constraint(equalTo: titleLabel.firstBaselineAnchor),
            zoomNameLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            zoomSlider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            zoomSlider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            zoomSlider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
        ])
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        table.registerForDraggedTypes([.downrightHeading])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        // The gap style is what actually shows the reader where the section
        // will land; a thin line between rows is too easy to miss on a dense
        // outline.
        table.draggingDestinationFeedbackStyle = .gap
        table.setAccessibilityLabel("Document headings")
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
            scroll.topAnchor.constraint(equalTo: zoomSlider.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Reload

    func reload() {
        rebuildVisibleRows()
        largestSectionWords = max(1, (0..<headings.count).map { words(forHeading: $0) }.max() ?? 1)
        table.reloadData()
        revealCurrentHeading()
    }

    private func rebuildVisibleRows() {
        visibleRows.removeAll(keepingCapacity: true)
        var index = 0
        while index < headings.count {
            visibleRows.append(index)
            if foldedIndices.contains(index) {
                index = sectionEnd(of: index)
            } else {
                index += 1
            }
        }
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

    private func words(forHeading index: Int) -> Int {
        if index < sectionMetrics.count { return sectionMetrics[index].words }
        return index < headings.count ? headings[index].wordCount : 0
    }

    private func readMinutes(forHeading index: Int) -> Double {
        if index < sectionMetrics.count { return sectionMetrics[index].readMinutes }
        // 238 wpm, the same median silent-reading rate `ReadingMetrics` uses.
        return Double(words(forHeading: index)) / 238
    }

    private func revealCurrentHeading() {
        guard let current = currentHeadingIndex,
              let row = visibleRows.firstIndex(of: current) else { return }
        // Deliberately unanimated: this fires as the reader scrolls, and an
        // eased scroll chasing every heading boundary is motion sickness in a
        // sidebar — Reduce Motion or not.
        table.scrollRowToVisible(row)
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        zoomNameLabel.textColor = styleSheet.textFaint
        table.reloadData()
        needsDisplay = true
    }

    private func syncZoomControl() {
        zoomSlider.doubleValue = Double(zoomLevel.rawValue)
        zoomNameLabel.stringValue = zoomLevel.title
        zoomSlider.setAccessibilityValueDescription(zoomLevel.title)
    }

    @objc private func zoomSliderChanged(_ sender: NSSlider) {
        guard let level = ZoomLevel(rawValue: Int(sender.doubleValue.rounded())), level != zoomLevel else { return }
        zoomLevel = level
        delegate?.outlinePanel(self, didChangeZoomLevel: level)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override func draw(_ dirtyRect: NSRect) {
        // Hairline under the header so the slider reads as chrome, not content.
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
            readMinutes: readMinutes(forHeading: index),
            density: CGFloat(words(forHeading: index)) / CGFloat(largestSectionWords),
            isFolded: foldedIndices.contains(index),
            isCurrent: index == currentHeadingIndex
        )
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < visibleRows.count else { return }
        delegate?.outlinePanel(self, didSelectHeadingAt: visibleRows[row])
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
              let index = Int(raw), index < headings.count else { return nil }
        return index
    }

    private func headingIndex(forDropRow row: Int) -> Int {
        row < visibleRows.count ? visibleRows[row] : headings.count
    }

    /// A section cannot be moved into itself, and moving it back where it
    /// already is is not a move.  Refusing both in `validateDrop` means the
    /// cursor says no before the drop rather than the document silently not
    /// changing after it.
    private func isLegalMove(source: Int, target: Int) -> Bool {
        guard source < headings.count else { return false }
        if target == source { return false }
        return !(target > source && target <= sectionEnd(of: source))
    }
}

// MARK: - Row

/// One heading.  Draws its own density bar because §9.6's point is comparative
/// — "where the bulk of a document actually is, which is not usually where
/// you'd guess" — and a bar per row answers that in a glance where a column of
/// minute counts does not.
private final class OutlineRowView: NSView {
    var onToggleFold: ((Int) -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let foldButton = NSButton()
    private var foldAction: ButtonAction?
    private var titleLeading: NSLayoutConstraint!
    private var foldLeading: NSLayoutConstraint!

    private var styleSheet: StyleSheet?
    private var headingIndex = 0
    private var density: CGFloat = 0
    private var isCurrent = false

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

        timeLabel.font = PanelFont.secondary
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(timeLabel)

        foldLeading = foldButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset)
        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: foldButton.trailingAnchor, constant: 4)
        NSLayoutConstraint.activate([
            foldLeading,
            foldButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            foldButton.widthAnchor.constraint(equalToConstant: 14),
            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(
        heading: HeadingNode,
        index: Int,
        styleSheet: StyleSheet,
        readMinutes: Double,
        density: CGFloat,
        isFolded: Bool,
        isCurrent: Bool
    ) {
        self.styleSheet = styleSheet
        self.headingIndex = index
        self.density = min(1, max(0, density))
        self.isCurrent = isCurrent

        let indent = PanelMetrics.inset + CGFloat(min(heading.level, 6) - 1) * 11
        foldLeading.constant = indent

        titleLabel.stringValue = heading.title.isEmpty ? "Untitled" : heading.title
        titleLabel.textColor = styleSheet.headingColor(level: heading.level)
        titleLabel.font = isCurrent ? PanelFont.rowEmphasised : PanelFont.row

        timeLabel.stringValue = Self.readTimeText(readMinutes)
        timeLabel.textColor = styleSheet.textFaint

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

        setAccessibilityLabel("\(heading.title), heading level \(heading.level)")
        needsDisplay = true
    }

    private static func readTimeText(_ minutes: Double) -> String {
        // Under half a minute a section has no meaningful read time, and the
        // density bar already says "this one is small".
        guard minutes >= 0.5 else { return "" }
        return "\(Int(minutes.rounded())) min"
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let styleSheet else { return }

        if density > 0 {
            let width = max(2, density * bounds.width)
            styleSheet.accent
                .panelAlpha(0.08, increaseContrast: styleSheet.increaseContrast)
                .setFill()
            NSRect(x: 0, y: 1, width: width, height: bounds.height - 2).fill()
        }

        if isCurrent {
            styleSheet.accent.setFill()
            NSRect(x: 0, y: 2, width: 3, height: bounds.height - 4).fill()
        }
    }
}
