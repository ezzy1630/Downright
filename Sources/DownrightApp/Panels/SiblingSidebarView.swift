import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol SiblingSidebarDelegate: AnyObject {
    func siblingSidebar(_ sidebar: SiblingSidebarView, didSelect url: URL, inNewWindow: Bool)
}

/// Files section of the document navigator (§8.7).
///
/// "Agents don't write one file, they write six into the same folder."  Newest
/// first, because the file the agent just finished is the one you came for;
/// grouped by the subdirectory it was found in, so `docs/` and `plans/` stay
/// distinguishable from the folder you opened.
///
/// Hidden by default and summonable with `⌘0` (§11.4) — this is a context
/// strip, not a file browser, and nothing here indexes anything (§2).
final class SiblingSidebarView: NSView, PanelSurface {
    weak var delegate: SiblingSidebarDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    var siblings: [SiblingScanner.Sibling] = [] { didSet { reload() } }
    var filterText: String = "" { didSet { guard filterText != oldValue else { return }; reload() } }

    var preferredWidth: CGFloat { PanelMetrics.listWidth }
    var hasVisibleContent: Bool { !rows.isEmpty }
    var preferredHeight: CGFloat {
        guard hasVisibleContent else { return 0 }
        let rowCount = min(rows.count, 12)
        return 40 + CGFloat(rowCount) * PanelMetrics.listRowHeight
    }
    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Files")
    private let table = PanelList.makeTableView(identifier: "siblings")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    private enum Row {
        case group(String)
        /// Index into `ordered`.
        case sibling(Int)
    }

    private var rows: [Row] = []
    var visibleFileCountForTesting: Int { ordered.count }
    /// `siblings` regrouped and re-sorted for display.
    private var ordered: [SiblingScanner.Sibling] = []

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

        table.dataSource = self
        table.delegate = self
        table.rowHeight = PanelMetrics.listRowHeight
        // Selection is drawn once, by `PanelSelectionRowView`, for every panel.
        table.selectionHighlightStyle = .regular
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.openSelected(inNewWindow: false) }
        table.setAccessibilityLabel("Sibling markdown files")

        addSubview(scroll)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        applyStyle()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Nearby files")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Reload

    func reload() {
        rebuildRows()
        table.reloadData()
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: preferredHeight)
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds
    }

    /// Groups in first-appearance order (the scanner lists the document's own
    /// directory first), each group newest-first.
    private func rebuildRows() {
        rows.removeAll(keepingCapacity: true)
        ordered.removeAll(keepingCapacity: true)

        var groupOrder: [String?] = []
        var buckets: [String: [SiblingScanner.Sibling]] = [:]
        let ownDirectoryKey = ""

        for sibling in siblings {
            let key = sibling.group ?? ownDirectoryKey
            if buckets[key] == nil { groupOrder.append(sibling.group) }
            buckets[key, default: []].append(sibling)
        }

        for group in groupOrder {
            let key = group ?? ownDirectoryKey
            guard var items = buckets[key] else { continue }
            items.sort { $0.modified > $1.modified }
            let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            if !query.isEmpty {
                items = items.compactMap { sibling -> (SiblingScanner.Sibling, Int)? in
                    let haystack = "\(sibling.displayName) \(sibling.url.path)"
                        .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                    guard let match = FuzzyMatcher.match(needle: query, in: haystack) else { return nil }
                    return (sibling, match.score)
                }
                .sorted { $0.1 > $1.1 }
                .map(\.0)
            }
            guard !items.isEmpty else { continue }
            if groupOrder.count > 1 || group != nil {
                rows.append(.group(group ?? "This folder"))
            }
            for item in items {
                rows.append(.sibling(ordered.count))
                ordered.append(item)
            }
        }
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        table.reloadData()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    // MARK: - Activation

    /// `⌘`-click opens in a new window (§7.1) — the same modifier the document
    /// surface uses for a `.md` link, so the gesture transfers.
    @objc private func rowClicked(_ sender: Any?) {
        let inNewWindow = NSApp.currentEvent?.modifierFlags.contains(.command) ?? false
        openSelected(inNewWindow: inNewWindow)
    }

    private func openSelected(inNewWindow: Bool) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < rows.count, case .sibling(let index) = rows[row], index < ordered.count else { return }
        delegate?.siblingSidebar(self, didSelect: ordered[index].url, inNewWindow: inNewWindow)
    }
}

// MARK: - Table

extension SiblingSidebarView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return PanelMetrics.listRowHeight }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return PanelMetrics.listRowHeight
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
            let identifier = NSUserInterfaceItemIdentifier("siblingGroup")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PanelGroupRowView
                ?? PanelGroupRowView(identifier: identifier)
            cell.configure(text: title.uppercased(), color: styleSheet.textFaint)
            return cell

        case .sibling(let index):
            guard index < ordered.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("siblingRow")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? SiblingRowView
                ?? SiblingRowView(identifier: identifier)
            cell.configure(
                sibling: ordered[index],
                styleSheet: styleSheet,
                isSelected: tableView.selectedRow == row
            )
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.reloadData()
    }
}

// MARK: - Row

private final class SiblingRowView: NSView {
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var styleSheet: StyleSheet?
    private var hasUnseenChanges = false
    private var isCurrent = false
    private var isSelected = false
    private var isHovered = false

    private let dotDiameter: CGFloat = 6

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        iconView.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Markdown file")?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .regular))
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        nameLabel.font = PanelFont.row
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)

        timeLabel.font = PanelFont.secondary
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset + 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 6),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: timeLabel.leadingAnchor, constant: -6),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(sibling: SiblingScanner.Sibling, styleSheet: StyleSheet, isSelected: Bool) {
        self.styleSheet = styleSheet
        hasUnseenChanges = sibling.hasUnseenChanges
        isCurrent = sibling.isCurrent
        self.isSelected = isSelected

        nameLabel.stringValue = sibling.displayName
        nameLabel.font = sibling.isCurrent ? PanelFont.rowEmphasised : PanelFont.row
        nameLabel.textColor = sibling.isCurrent ? styleSheet.text : styleSheet.textSecondary
        iconView.contentTintColor = sibling.isCurrent ? styleSheet.accent : styleSheet.textFaint
        timeLabel.stringValue = RelativeTime.short(sibling.modified)
        timeLabel.textColor = styleSheet.textFaint

        var description = sibling.displayName
        if sibling.isCurrent { description += ", current document" }
        if sibling.hasUnseenChanges { description += ", changed since you last looked" }
        description += ", modified \(RelativeTime.long(sibling.modified))"
        setAccessibilityRole(.row)
        setAccessibilityLabel(description)
        toolTip = sibling.url.path

        needsDisplay = true
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    /// Selection is `PanelSelectionRowView`'s job now; the row draws only the
    /// current-document rule, the hover wash, and the unseen-change dot.
    override func draw(_ dirtyRect: NSRect) {
        guard let styleSheet else { return }

        let alpha: CGFloat?
        if isCurrent { alpha = 0.08 }
        else if isHovered && !isSelected { alpha = 0.05 }
        else { alpha = nil }
        if let alpha {
            styleSheet.text
                .panelAlpha(alpha, increaseContrast: styleSheet.increaseContrast)
                .setFill()
            NSBezierPath(
                roundedRect: bounds.insetBy(dx: 4, dy: 2),
                xRadius: PanelMetrics.cornerRadius,
                yRadius: PanelMetrics.cornerRadius
            ).fill()
        }

        if isCurrent {
            styleSheet.accent.setFill()
            NSRect(x: 0, y: 3, width: 3, height: bounds.height - 6).fill()
        }

        // The dot is the whole point of §8.7's "changed since you last looked",
        // so it uses the change colour rather than the accent — it means the
        // same thing here as a change bar means in the margin.
        guard hasUnseenChanges else { return }
        styleSheet.changeColor(.modified).setFill()
        let dot = NSRect(
            x: PanelMetrics.inset - 2,
            y: bounds.midY - dotDiameter / 2,
            width: dotDiameter, height: dotDiameter
        )
        NSBezierPath(ovalIn: dot).fill()
    }
}
