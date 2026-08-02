import AppKit
import MarkdownCore
import MarkdownRender

protocol TidySheetDelegate: AnyObject {
    func tidySheet(_ sheet: TidySheetView, didApply edits: [TextEdit])
    func tidySheetDidCancel(_ sheet: TidySheetView)
}

/// Tidy Document's accept/reject sheet (§9.1).
///
/// "Shows a rendered diff before applying, with per-change accept/reject."
/// Grouping by `TidyRule` is what makes that practical: you almost always want
/// all of one rule and none of another — every renumbered list, but none of the
/// guessed fence languages — and a flat list of forty checkboxes would make
/// that a chore instead of two clicks.
final class TidySheetView: NSView {
    weak var delegate: TidySheetDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    /// Each edit with the before/after text to show.
    var proposals: [(edit: TextEdit, before: String, after: String)] = [] {
        didSet {
            accepted = Set(proposals.map(\.edit.id))
            reload()
        }
    }

    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Tidy Document")
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let table = PanelList.makeTableView(identifier: "tidy")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private let footer = NSStackView()
    private var applyButton: NSButton!
    private var actions: [ButtonAction] = []

    private enum Row {
        case group(TidyRule?)
        /// Index into `proposals`.
        case proposal(Int)
    }

    private var rows: [Row] = []
    private var accepted: Set<UUID> = []
    private var heightCache: [Int: CGFloat] = [:]
    private var cachedWidth: CGFloat = 0

    private let checkboxInset: CGFloat = 14
    private let textInset: CGFloat = 38

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet, material: .windowBackground)
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 460))

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        buildHeader()
        buildFooter()
        buildTable()
        applyStyle()

        setAccessibilityRole(.group)
        setAccessibilityLabel("Tidy Document changes")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize { NSSize(width: 620, height: 460) }

    private func buildHeader() {
        titleLabel.font = PanelFont.title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = PanelFont.secondary
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            subtitleLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    private func buildFooter() {
        let selectAll = ButtonAction { [weak self] in self?.setAll(accepted: true) }
        let selectNone = ButtonAction { [weak self] in self?.setAll(accepted: false) }
        let cancel = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.tidySheetDidCancel(self)
        }
        let apply = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.tidySheet(self, didApply: self.acceptedEdits())
        }
        actions.append(contentsOf: [selectAll, selectNone, cancel, apply])

        let cancelButton = PanelButton.text("Cancel", action: cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        applyButton = PanelButton.text("Apply", action: apply, isDefault: true)

        let spacer = NSView()
        spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        footer.orientation = .horizontal
        footer.spacing = 8
        footer.alignment = .centerY
        footer.distribution = .fill
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addArrangedSubview(PanelButton.text("Select All", action: selectAll))
        footer.addArrangedSubview(PanelButton.text("Select None", action: selectNone))
        footer.addArrangedSubview(spacer)
        footer.addArrangedSubview(cancelButton)
        footer.addArrangedSubview(applyButton)
        addSubview(footer)

        NSLayoutConstraint.activate([
            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
        ])
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Proposed changes")

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: subtitleLabel.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -10),
        ])
    }

    // MARK: - Reload

    func reload() {
        rebuildRows()
        heightCache.removeAll()
        table.reloadData()
        updateFooter()
    }

    /// Rules keep `TidyRule.allCases` order so the sheet reads the same way
    /// every time, with unruled edits last.
    private func rebuildRows() {
        rows.removeAll(keepingCapacity: true)
        var byRule: [TidyRule?: [Int]] = [:]
        for (index, proposal) in proposals.enumerated() {
            byRule[proposal.edit.rule, default: []].append(index)
        }
        for rule in TidyRule.allCases {
            guard let indices = byRule[rule], !indices.isEmpty else { continue }
            rows.append(.group(rule))
            rows.append(contentsOf: indices.map { Row.proposal($0) })
        }
        let unruled: TidyRule? = nil
        if let others = byRule[unruled], !others.isEmpty {
            rows.append(.group(nil))
            rows.append(contentsOf: others.map { Row.proposal($0) })
        }
    }

    private func acceptedEdits() -> [TextEdit] {
        proposals.filter { accepted.contains($0.edit.id) }.map(\.edit)
    }

    private func setAll(accepted value: Bool) {
        accepted = value ? Set(proposals.map(\.edit.id)) : []
        table.reloadData()
        updateFooter()
    }

    private func setAccepted(_ value: Bool, forGroup rule: TidyRule?) {
        for proposal in proposals where proposal.edit.rule == rule {
            if value { accepted.insert(proposal.edit.id) } else { accepted.remove(proposal.edit.id) }
        }
        table.reloadData()
        updateFooter()
    }

    private func toggle(_ index: Int) {
        guard index < proposals.count else { return }
        let id = proposals[index].edit.id
        if accepted.contains(id) { accepted.remove(id) } else { accepted.insert(id) }
        table.reloadData()
        updateFooter()
    }

    private func updateFooter() {
        let count = accepted.count
        applyButton.title = count == 1 ? "Apply 1 Change" : "Apply \(count) Changes"
        applyButton.isEnabled = count > 0
        subtitleLabel.stringValue = proposals.isEmpty
            ? "Nothing to tidy — this document is already clean."
            : "\(count) of \(proposals.count) selected"
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.text
        subtitleLabel.textColor = styleSheet.textSecondary
        heightCache.removeAll()
        table.reloadData()
    }

    override func layout() {
        super.layout()
        guard abs(scroll.bounds.width - cachedWidth) > 0.5 else { return }
        cachedWidth = scroll.bounds.width
        heightCache.removeAll()
        guard !rows.isEmpty else { return }
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<rows.count))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    // MARK: - Diff text

    /// Whitespace-only edits are half of what Tidy does, and "" → "" tells the
    /// reader nothing, so those get described rather than shown.
    static func displayText(_ text: String) -> String {
        if text.isEmpty { return "(nothing)" }
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let newlines = text.filter(\.isNewline).count
            if newlines > 0 { return "(\(newlines) blank line\(newlines == 1 ? "" : "s"))" }
            return "(\(text.count) space\(text.count == 1 ? "" : "s"))"
        }
        // Trailing whitespace is invisible and is exactly what one rule trims,
        // so make it visible where it occurs.
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                let trimmed = line.replacingOccurrences(of: "[ \t]+$", with: "", options: .regularExpression)
                return trimmed + String(repeating: "·", count: max(0, line.count - trimmed.count))
            }
            .joined(separator: "\n")
    }

    fileprivate func diffAttributes(for kind: ChangeKind) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        return [
            .font: styleSheet.monoFont(size: 11),
            .foregroundColor: styleSheet.changeColor(kind),
            .paragraphStyle: paragraph,
        ]
    }
}

// MARK: - Table

extension TidySheetView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool { false }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return PanelMetrics.rowHeight }
        switch rows[row] {
        case .group:
            return 26
        case .proposal(let index):
            if let cached = heightCache[index] { return cached }
            let width = max(200, (cachedWidth > 0 ? cachedWidth : bounds.width) - textInset - 16)
            let height = TidyProposalRowView.height(
                before: TidySheetView.displayText(proposals[index].before),
                after: TidySheetView.displayText(proposals[index].after),
                attributes: diffAttributes(for: .deleted),
                width: width
            )
            heightCache[index] = height
            return height
        }
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }

        switch rows[row] {
        case .group(let rule):
            let identifier = NSUserInterfaceItemIdentifier("tidyGroup")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TidyGroupRowView
                ?? TidyGroupRowView(identifier: identifier)
            let members = proposals.filter { $0.edit.rule == rule }
            let checkedCount = members.filter { accepted.contains($0.edit.id) }.count
            cell.onToggle = { [weak self] value in self?.setAccepted(value, forGroup: rule) }
            cell.configure(
                title: rule?.title ?? "Other changes",
                count: members.count,
                checkedCount: checkedCount,
                styleSheet: styleSheet
            )
            return cell

        case .proposal(let index):
            guard index < proposals.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("tidyProposal")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TidyProposalRowView
                ?? TidyProposalRowView(identifier: identifier)
            cell.onToggle = { [weak self] in self?.toggle(index) }
            cell.configure(
                summary: proposals[index].edit.summary,
                before: TidySheetView.displayText(proposals[index].before),
                after: TidySheetView.displayText(proposals[index].after),
                isAccepted: accepted.contains(proposals[index].edit.id),
                styleSheet: styleSheet,
                beforeAttributes: diffAttributes(for: .deleted),
                afterAttributes: diffAttributes(for: .inserted)
            )
            return cell
        }
    }
}

// MARK: - Group row

private final class TidyGroupRowView: NSView {
    var onToggle: ((Bool) -> Void)?

    private let checkbox = NSButton()
    private var action: ButtonAction?

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        checkbox.setButtonType(.switch)
        checkbox.allowsMixedState = true
        checkbox.font = PanelFont.group
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, count: Int, checkedCount: Int, styleSheet: StyleSheet) {
        checkbox.attributedTitle = NSAttributedString(string: "\(title)  (\(count))", attributes: [
            .font: PanelFont.group,
            .foregroundColor: styleSheet.textSecondary,
        ])
        checkbox.state = checkedCount == 0 ? .off : (checkedCount == count ? .on : .mixed)

        let next = checkedCount != count
        let action = ButtonAction { [weak self] in self?.onToggle?(next) }
        self.action = action
        checkbox.target = action
        checkbox.action = #selector(ButtonAction.fire(_:))
        checkbox.setAccessibilityLabel("\(title), \(checkedCount) of \(count) selected")
    }
}

// MARK: - Proposal row

private final class TidyProposalRowView: NSView {
    var onToggle: (() -> Void)?

    private let checkbox = NSButton()
    private var action: ButtonAction?
    private var summary = ""
    private var before = NSAttributedString()
    private var after = NSAttributedString()
    private var styleSheet: StyleSheet?

    private static let summaryHeight: CGFloat = 18
    private static let verticalPadding: CGFloat = 8
    private static let maximumDiffHeight: CGFloat = 48
    private static let textInset: CGFloat = 38

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 8),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    static func height(
        before: String,
        after: String,
        attributes: [NSAttributedString.Key: Any],
        width: CGFloat
    ) -> CGFloat {
        let measure = { (text: String) -> CGFloat in
            let bounds = NSAttributedString(string: text, attributes: attributes).boundingRect(
                with: NSSize(width: width, height: 200),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            return min(maximumDiffHeight, ceil(bounds.height))
        }
        return summaryHeight + measure(before) + measure(after) + verticalPadding * 2 + 4
    }

    func configure(
        summary: String,
        before: String,
        after: String,
        isAccepted: Bool,
        styleSheet: StyleSheet,
        beforeAttributes: [NSAttributedString.Key: Any],
        afterAttributes: [NSAttributedString.Key: Any]
    ) {
        self.summary = summary
        self.styleSheet = styleSheet
        self.before = NSAttributedString(string: before, attributes: beforeAttributes)
        self.after = NSAttributedString(string: after, attributes: afterAttributes)

        checkbox.state = isAccepted ? .on : .off
        let action = ButtonAction { [weak self] in self?.onToggle?() }
        self.action = action
        checkbox.target = action
        checkbox.action = #selector(ButtonAction.fire(_:))
        checkbox.setAccessibilityLabel(summary)

        setAccessibilityLabel("\(summary). Before: \(before). After: \(after)")
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let styleSheet else { return }
        let width = bounds.width - Self.textInset - 16
        guard width > 0 else { return }

        var y = Self.verticalPadding
        (summary as NSString).draw(
            at: NSPoint(x: Self.textInset, y: y),
            withAttributes: [.font: PanelFont.row, .foregroundColor: styleSheet.text]
        )
        y += Self.summaryHeight

        for text in [before, after] {
            let height = min(Self.maximumDiffHeight, ceil(text.boundingRect(
                with: NSSize(width: width, height: 200),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height))
            text.draw(
                with: NSRect(x: Self.textInset, y: y, width: width, height: height),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            y += height + 2
        }
    }
}
