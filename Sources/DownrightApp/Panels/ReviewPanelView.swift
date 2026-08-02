import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol ReviewPanelViewDelegate: AnyObject {
    func reviewPanel(_ panel: ReviewPanelView, didSelect review: ReviewItem)
    func reviewPanel(_ panel: ReviewPanelView, didApply review: ReviewItem)
    func reviewPanel(_ panel: ReviewPanelView, didReject review: ReviewItem)
    func reviewPanel(_ panel: ReviewPanelView, didResolve review: ReviewItem)
    func reviewPanelDidRequestClose(_ panel: ReviewPanelView)
}

@MainActor
final class ReviewPanelView: NSView, PanelSurface {
    weak var delegate: ReviewPanelViewDelegate?

    var styleSheet: StyleSheet {
        didSet { backdrop.styleSheet = styleSheet; applyStyle() }
    }

    var reviews: [ReviewItem] = [] { didSet { reload() } }
    var sourceText: String = "" { didSet { reload() } }
    var preferredWidth: CGFloat { 360 }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Reviews")
    private let statusLabel = NSTextField(labelWithString: "")
    private let table = PanelList.makeTableView(identifier: "reviews")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private var actions: [ButtonAction] = []

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)
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
        apply.translatesAutoresizingMaskIntoConstraints = false
        reject.translatesAutoresizingMaskIntoConstraints = false
        resolve.translatesAutoresizingMaskIntoConstraints = false
        addSubview(apply)
        addSubview(reject)
        addSubview(resolve)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            apply.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            apply.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 7),
            reject.leadingAnchor.constraint(equalTo: apply.trailingAnchor, constant: 6),
            reject.centerYAnchor.constraint(equalTo: apply.centerYAnchor),
            resolve.leadingAnchor.constraint(equalTo: reject.trailingAnchor, constant: 6),
            resolve.centerYAnchor.constraint(equalTo: reject.centerYAnchor),
        ])
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 60
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Review items")
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 70),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    func reload() {
        table.reloadData()
        let open = reviews.filter { $0.state == .open }.count
        statusLabel.stringValue = open == 0 ? "No open reviews" : "\(open) open"
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
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
        delegate?.reviewPanel(self, didApply: review)
    }

    private func resolveSelected() {
        guard let review = selectedReview() else { return }
        delegate?.reviewPanel(self, didResolve: review)
    }

    private func rejectSelected() {
        guard let review = selectedReview(), review.kind == .suggestion else { return }
        delegate?.reviewPanel(self, didReject: review)
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        statusLabel.textColor = styleSheet.textFaint
        table.reloadData()
    }

    @objc private func rowClicked(_ sender: NSTableView) { activateSelection() }
}

@MainActor
extension ReviewPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { reviews.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let review = reviews[row]
        let cell = ReviewRowView()
        let resolution = ReviewAnchorResolver.resolve(review.anchor, in: sourceText)
        cell.configure(review, status: resolution.status)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let review = selectedReview() else { return }
        delegate?.reviewPanel(self, didSelect: review)
    }
}

private final class ReviewRowView: NSTableCellView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
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

    func configure(_ review: ReviewItem, status: ReviewAnchorStatus) {
        titleLabel.stringValue = review.title
        bodyLabel.stringValue = review.kind == .suggestion
            ? "Replace \(quoted(review.anchor.selectedText)) with \(quoted(review.replacement ?? ""))"
            : review.body
        let state = review.state == .open ? status.rawValue.capitalized : review.state.rawValue.capitalized
        statusLabel.stringValue = state
        setAccessibilityLabel("\(review.title): \(review.body)")
        setAccessibilityValue(state)
    }

    private func quoted(_ value: String) -> String {
        let compact = value.replacingOccurrences(of: "\n", with: " ↵ ")
        return "“\(compact)”"
    }
}
