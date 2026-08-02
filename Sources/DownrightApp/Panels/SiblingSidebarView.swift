import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol SiblingSidebarDelegate: AnyObject {
    func siblingSidebar(_ sidebar: SiblingSidebarView, didSelect url: URL, inNewWindow: Bool)
}

/// Sibling sidebar (§8.7).
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

    var preferredWidth: CGFloat { PanelMetrics.listWidth }

    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Nearby")
    private let table = PanelList.makeTableView(identifier: "siblings")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    private enum Row {
        case group(String)
        /// Index into `ordered`.
        case sibling(Int)
    }

    private var rows: [Row] = []
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
        table.rowHeight = 30
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
        guard row < rows.count else { return 30 }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return 30
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
            cell.configure(sibling: ordered[index], styleSheet: styleSheet)
            return cell
        }
    }
}

// MARK: - Row

private final class SiblingRowView: NSView {
    private let nameLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private var styleSheet: StyleSheet?
    private var hasUnseenChanges = false
    private var isCurrent = false

    private let dotDiameter: CGFloat = 6

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        nameLabel.font = PanelFont.row
        nameLabel.lineBreakMode = .byTruncatingMiddle
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(nameLabel)

        timeLabel.font = PanelFont.secondary
        timeLabel.alignment = .right
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        timeLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(timeLabel)

        NSLayoutConstraint.activate([
            nameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset + 8),
            nameLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            timeLabel.leadingAnchor.constraint(greaterThanOrEqualTo: nameLabel.trailingAnchor, constant: 6),
            timeLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            timeLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(sibling: SiblingScanner.Sibling, styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        hasUnseenChanges = sibling.hasUnseenChanges
        isCurrent = sibling.isCurrent

        nameLabel.stringValue = sibling.displayName
        nameLabel.font = sibling.isCurrent ? PanelFont.rowEmphasised : PanelFont.row
        nameLabel.textColor = sibling.isCurrent ? styleSheet.text : styleSheet.textSecondary

        timeLabel.stringValue = RelativeTime.short(sibling.modified)
        timeLabel.textColor = styleSheet.textFaint

        var description = "\(sibling.displayName), modified \(RelativeTime.long(sibling.modified))"
        if sibling.isCurrent { description += ", current document" }
        if sibling.hasUnseenChanges { description += ", changed since you last looked" }
        setAccessibilityLabel(description)
        toolTip = sibling.url.path

        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let styleSheet else { return }

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
