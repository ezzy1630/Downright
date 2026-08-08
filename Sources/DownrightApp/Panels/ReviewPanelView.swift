import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol ReviewPanelViewDelegate: AnyObject {
    func reviewPanel(_ panel: ReviewPanelView, didSelect review: ReviewItem)
    func reviewPanel(_ panel: ReviewPanelView, didApply review: ReviewItem)
    func reviewPanel(_ panel: ReviewPanelView, didReject review: ReviewItem)
    func reviewPanel(_ panel: ReviewPanelView, didResolve review: ReviewItem)
}

@MainActor
final class ReviewPanelView: NSView, PanelSurface {
    weak var delegate: ReviewPanelViewDelegate?

    var styleSheet: StyleSheet {
        didSet { backdrop.styleSheet = styleSheet; applyStyle() }
    }

    var reviews: [ReviewItem] = [] { didSet { reload() } }

    var sourceText: String = "" {
        didSet {
            guard sourceText != oldValue else { return }
            // The document changed, so every anchor has to be resolved again —
            // but only once each, not once per row per reload.
            resolutions.removeAll(keepingCapacity: true)
            reload()
        }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: Command.reviewPanel.panelTitle)
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyState = PanelEmptyStateView()
    private let table = PanelList.makeTableView(identifier: "reviews")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private let buttonRow = NSStackView()
    private weak var applyButton: NSButton?
    private weak var rejectButton: NSButton?
    private weak var resolveButton: NSButton?
    private var actions: [ButtonAction] = []
    /// Anchor resolution memoised per document revision.  Resolving every
    /// anchor over the whole document per row per reload made the panel cost
    /// O(reviews × document) on the main thread for every keystroke.
    private var resolutions: [ReviewAnchor: ReviewAnchorStatus] = [:]
    /// What the last action did.  Rows disappearing is not feedback.
    private var actionStatus: String?
    private var isActing = false

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)
        installBackdrop(backdrop)
        buildHeader()
        buildTable()
        applyStyle()
        reload()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Reviews")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildHeader() {
        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        statusLabel.font = PanelFont.secondary
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        let applyAction = ButtonAction { [weak self] in self?.applySelected() }
        let resolveAction = ButtonAction { [weak self] in self?.resolveSelected() }
        let rejectAction = ButtonAction { [weak self] in self?.rejectSelected() }
        let apply = PanelButton.text("Apply", action: applyAction)
        let reject = PanelButton.text("Reject", action: rejectAction)
        let resolve = PanelButton.text("Resolve", action: resolveAction)
        actions = [applyAction, rejectAction, resolveAction]
        for button in [apply, reject, resolve] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 6
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        buttonRow.addArrangedSubview(apply)
        buttonRow.addArrangedSubview(reject)
        buttonRow.addArrangedSubview(resolve)
        addSubview(buttonRow)
        applyButton = apply
        rejectButton = reject
        resolveButton = resolve

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            buttonRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            buttonRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PanelMetrics.inset),
            buttonRow.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
        ])
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = PanelMetrics.wideRowHeight
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Review items")
        addSubview(scroll)
        emptyState.install(in: self, over: scroll)
        // Anchored under the buttons rather than 70pt below the title: a magic
        // constant stops being right the moment a button grows.
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func reload() {
        if !isActing { actionStatus = nil }
        table.reloadData()
        let open = reviews.filter { $0.state == .open }.count
        if let actionStatus {
            statusLabel.stringValue = actionStatus
        } else {
            statusLabel.stringValue = open == 0 ? "No open reviews" : "\(open) open"
        }
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
        updateEmptyState()
        updateActionState()
    }

    private func updateEmptyState() {
        guard reviews.isEmpty else {
            emptyState.isHidden = true
            scroll.isHidden = false
            return
        }
        emptyState.configure(
            symbol: "bubble.left.and.bubble.right",
            title: "No reviews",
            subtitle: "Comments and suggestions left beside\nthis document will appear here.",
            styleSheet: styleSheet
        )
        emptyState.isHidden = false
        scroll.isHidden = true
    }

    private func updateActionState() {
        let review = selectedReview()
        let isSuggestion = review?.kind == .suggestion
        applyButton?.isEnabled = isSuggestion
        rejectButton?.isEnabled = isSuggestion
        resolveButton?.isEnabled = review != nil
    }

    private func selectedReview() -> ReviewItem? {
        guard reviews.indices.contains(table.selectedRow) else { return nil }
        return reviews[table.selectedRow]
    }

    private func activateSelection() {
        guard let review = selectedReview() else { return }
        delegate?.reviewPanel(self, didSelect: review)
    }

    private func applySelected() {
        guard let review = selectedReview(), review.kind == .suggestion else { return }
        act("Applied “\(review.title)”.") { self.delegate?.reviewPanel(self, didApply: review) }
    }

    private func resolveSelected() {
        guard let review = selectedReview() else { return }
        act("Resolved “\(review.title)”.") { self.delegate?.reviewPanel(self, didResolve: review) }
    }

    private func rejectSelected() {
        guard let review = selectedReview(), review.kind == .suggestion else { return }
        act("Rejected “\(review.title)”.") { self.delegate?.reviewPanel(self, didReject: review) }
    }

    /// Reports the outcome in the status label and keeps it there through the
    /// reload the action itself causes.
    private func act(_ message: String, _ body: () -> Void) {
        actionStatus = message
        isActing = true
        body()
        isActing = false
        statusLabel.stringValue = message
        statusLabel.setAccessibilityLabel(message)
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        statusLabel.textColor = styleSheet.textFaint
        table.reloadData()
        updateEmptyState()
    }

    @objc private func rowClicked(_ sender: NSTableView) { activateSelection() }
}

@MainActor
extension ReviewPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { reviews.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard reviews.indices.contains(row) else { return nil }
        let review = reviews[row]
        let identifier = NSUserInterfaceItemIdentifier("reviewRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? ReviewRowView
            ?? ReviewRowView(identifier: identifier)
        cell.configure(review, status: status(for: review.anchor), styleSheet: styleSheet)
        return cell
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PanelList.selectionRow(in: tableView, owner: self, styleSheet: styleSheet)
    }

    /// One resolution per anchor per document revision.
    private func status(for anchor: ReviewAnchor) -> ReviewAnchorStatus {
        if let cached = resolutions[anchor] { return cached }
        let status = ReviewAnchorResolver.resolve(anchor, in: sourceText).status
        resolutions[anchor] = status
        return status
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateActionState()
        guard let review = selectedReview() else { return }
        delegate?.reviewPanel(self, didSelect: review)
    }
}

private final class ReviewRowView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        titleLabel.font = PanelFont.rowEmphasised
        bodyLabel.font = PanelFont.secondary
        statusLabel.font = PanelFont.secondary
        statusLabel.alignment = .right
        for label in [titleLabel, bodyLabel, statusLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
        }
        bodyLabel.lineBreakMode = .byTruncatingTail
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: statusLabel.leadingAnchor, constant: -6),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            bodyLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -7),
        ])
        setAccessibilityRole(.staticText)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(_ review: ReviewItem, status: ReviewAnchorStatus, styleSheet: StyleSheet) {
        titleLabel.stringValue = review.title
        titleLabel.textColor = styleSheet.text
        bodyLabel.stringValue = review.kind == .suggestion
            ? "Replace \(quoted(review.anchor.selectedText)) with \(quoted(review.replacement ?? ""))"
            : review.body
        bodyLabel.textColor = styleSheet.textSecondary
        let state = review.state == .open ? status.rawValue.capitalized : review.state.rawValue.capitalized
        statusLabel.stringValue = state
        statusLabel.textColor = styleSheet.textFaint
        toolTip = review.body
        setAccessibilityLabel("\(review.title): \(review.body)")
        setAccessibilityValue(state)
    }

    private func quoted(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: "\n", with: " ↵ ")
        return "“\(compact)”"
    }
}
