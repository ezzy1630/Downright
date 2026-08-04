import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol ChangeSummaryBarDelegate: AnyObject {
    func changeSummaryBar(_ bar: ChangeSummaryBarView, didRequestJump forward: Bool)
    func changeSummaryBarDidRequestMarkReviewed(_ bar: ChangeSummaryBarView)
    func changeSummaryBarDidRequestDismiss(_ bar: ChangeSummaryBarView)
}

/// The clean-buffer change summary (§8.1).
///
/// The document has already been updated in place underneath the reader — this
/// only reports what happened and offers to walk them, which is the pointer
/// equivalent of `[` and `]` (§7.2).  Same non-modal shape as the conflict bar:
/// it must be ignorable, because most of the time you will just carry on
/// reading and let the change marks fade.
final class ChangeSummaryBarView: MessageBarView {
    weak var delegate: ChangeSummaryBarDelegate?
    private var changeCount = 0
    private var currentPosition: Int?
    private weak var previousButton: NSButton?
    private weak var nextButton: NSButton?
    private weak var reviewedButton: NSButton?

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        super.init(styleSheet: styleSheet, stripeColor: styleSheet.changeColor(.inserted))
        useReviewBarLayout()

        message = "Updated on disk"
        let previousButton = addSymbolAction("chevron.up", label: "Previous change") { [weak self] in
            guard let self else { return }
            self.advancePosition(forward: false)
            self.delegate?.changeSummaryBar(self, didRequestJump: false)
        }
        let nextButton = addSymbolAction("chevron.down", label: "Next change") { [weak self] in
            guard let self else { return }
            self.advancePosition(forward: true)
            self.delegate?.changeSummaryBar(self, didRequestJump: true)
        }
        for button in [previousButton, nextButton] {
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
        }
        self.previousButton = previousButton
        self.nextButton = nextButton

        let reviewedButton = addSymbolAction(
            "checkmark",
            label: "Mark changes as reviewed"
        ) { [weak self] in
            guard let self else { return }
            self.delegate?.changeSummaryBarDidRequestMarkReviewed(self)
        }
        reviewedButton.isBordered = false
        reviewedButton.toolTip = "Clear unread change marks"
        self.reviewedButton = reviewedButton
        onDismiss = { [weak self] in
            guard let self else { return }
            self.delegate?.changeSummaryBarDidRequestDismiss(self)
        }

        setAccessibilityLabel("Document updated on disk")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 320, height: PanelMetrics.reviewBarHeight)
    }

    func configure(message: String, changeCount: Int) {
        self.message = message
        self.changeCount = max(0, changeCount)
        currentPosition = nil
        updatePositionStatus()
        setAccessibilityLabel("\(message). \(changeCount) unread changes")
    }

    var positionStatusForTesting: String {
        currentPosition.map { "\($0) of \(changeCount)" } ?? ""
    }

    private func advancePosition(forward: Bool) {
        guard changeCount > 0 else { return }
        switch (currentPosition, forward) {
        case (nil, true): currentPosition = 1
        case (nil, false): currentPosition = changeCount
        case (.some(let current), true): currentPosition = current == changeCount ? 1 : current + 1
        case (.some(let current), false): currentPosition = current == 1 ? changeCount : current - 1
        }
        updatePositionStatus()
    }

    private func updatePositionStatus() {
        setStatus(positionStatusForTesting)
    }

    override func applyStyle() {
        stripeColor = styleSheet.changeColor(.inserted)
        super.applyStyle()
        previousButton?.contentTintColor = styleSheet.textFaint
        nextButton?.contentTintColor = styleSheet.textFaint
        reviewedButton?.contentTintColor = styleSheet.textSecondary
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        styleSheet.background.withAlphaComponent(0.96).setFill()
        shape.fill()
        styleSheet.rule.withAlphaComponent(0.8).setStroke()
        shape.lineWidth = 1
        shape.stroke()

        stripeColor.setFill()
        NSBezierPath(ovalIn: NSRect(
            x: rect.minX + 8,
            y: rect.midY - 2,
            width: 4,
            height: 4
        )).fill()
    }
}
