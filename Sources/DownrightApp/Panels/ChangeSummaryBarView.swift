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
    /// What a write did to the document, in the terms a reader deciding whether
    /// to look would use.
    ///
    /// A bare count answers "how many" and leaves the two questions that
    /// actually govern the decision unanswered: *what kind* of change, and
    /// *where*.  Ten insertions appended to the end is a different event from
    /// ten rewrites scattered through a document you had already read, and a
    /// count of ten describes both.
    struct Summary: Equatable {
        var added = 0
        var rewritten = 0
        var removed = 0
        /// Midpoint of each change as a fraction of the document, in document
        /// order — the shape of the write, which VoiceOver hears as the
        /// distribution sentence.
        var positions: [Position] = []

        struct Position: Equatable {
            var fraction: Double
            var kind: ChangeKind
            /// The mark this position was derived from.
            var id: UUID
        }

        var total: Int { added + rewritten + removed }

        /// Derives the summary from the tracker's own marks.
        ///
        /// `documentLength` is the current buffer length; a zero or negative
        /// length means there is nothing to place changes against, so positions
        /// are simply omitted rather than being derived from a division by zero.
        init(marks: [ChangeTracker.Mark], documentLength: Int) {
            for mark in marks {
                switch mark.kind {
                case .inserted: added += 1
                case .modified: rewritten += 1
                case .deleted: removed += 1
                }
            }
            guard documentLength > 0 else { return }
            positions = marks
                .map { mark in
                    let midpoint = Double(mark.range.location) + Double(mark.range.length) / 2
                    return Position(
                        fraction: min(1, max(0, midpoint / Double(documentLength))),
                        kind: mark.kind,
                        id: mark.id
                    )
                }
                .sorted { $0.fraction < $1.fraction }
        }

        /// A summary carrying only a count, for callers that have no marks in
        /// hand.  Reports as rewrites, the honest reading of "something changed
        /// and I cannot say what".
        init(changeCount: Int) {
            rewritten = max(0, changeCount)
        }

        /// The sentence the bar leads with.
        ///
        /// Written as a breakdown rather than a total because the breakdown is
        /// the information: "2 rewritten" and "2 added" ask for very different
        /// amounts of attention.
        var headline: String {
            let parts = [
                (added, "added"),
                (rewritten, "rewritten"),
                (removed, "removed"),
            ].filter { $0.0 > 0 }

            guard let first = parts.first else { return "Updated on disk" }
            guard parts.count > 1 else {
                return "\(first.0) \(first.0 == 1 ? "change" : "changes") \(first.1)"
            }
            return parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ")
        }

        /// Spoken form.  The same facts the marked-up document gives a sighted
        /// reader — what changed, and where — in words.
        var accessibilityDescription: String {
            guard total > 0 else { return "Document updated on disk. No unread changes." }
            var sentence = "Document updated on disk. \(headline)."
            if let spread = distributionDescription { sentence += " \(spread)." }
            return sentence
        }

        /// Where the changes fall, in words.  Only claimed when the marks
        /// actually cluster — a spurious "at the end" on evenly spread changes
        /// would be worse than saying nothing.
        var distributionDescription: String? {
            guard positions.count > 1 else { return nil }
            let fractions = positions.map(\.fraction)
            guard let low = fractions.first, let high = fractions.last else { return nil }
            guard high - low < 0.34 else { return "Spread through the document" }
            let middle = (low + high) / 2
            if middle < 0.34 { return "Clustered near the start" }
            if middle > 0.66 { return "Clustered near the end" }
            return "Clustered in the middle"
        }
    }

    weak var delegate: ChangeSummaryBarDelegate?
    private var summary = Summary(changeCount: 0)
    private var changeCount: Int { summary.total }
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
            button.widthAnchor.constraint(equalToConstant: 28).isActive = true
        }
        self.previousButton = previousButton
        self.nextButton = nextButton
        // The stack reads as two groups: the chevrons pair into one walk
        // control, and a wider gap sets the finishing action (reviewed, then
        // dismiss outside the stack) apart from it.
        setActionSpacing(0, after: previousButton)
        setActionSpacing(10, after: nextButton)
        updateNavigationState()

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

        // This is a transient notice, not a review toolbar.  Review remains
        // available from the Navigate menu and keyboard commands; keeping its
        // controls here made a brief disk-update cue read like permanent UI.
        hideButtons(in: self)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.cornerRadius = Self.cornerRadius

        setAccessibilityLabel("Document updated on disk")
        // The base's own `applyStyle` ran before these buttons existed, and a
        // host that never reassigns `styleSheet` would otherwise show every
        // glyph at full strength — the hierarchy above is part of setup, not
        // a theming afterthought.
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Wide enough for the message it is carrying, never wider than a strip of
    /// chrome should be over a document.
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: min(Self.maximumWidth, max(Self.minimumWidth, fittedWidth)),
            height: Self.toastHeight
        )
    }

    private static let minimumWidth: CGFloat = 190
    private static let maximumWidth: CGFloat = 330
    static let toastHeight: CGFloat = 38
    private static let cornerRadius: CGFloat = 19

    private func hideButtons(in view: NSView) {
        for subview in view.subviews {
            if let button = subview as? NSButton { button.isHidden = true }
            hideButtons(in: subview)
        }
    }

    /// Configures the bar from the tracker's marks — the preferred entry point,
    /// and the only one that can say where the changes fell.
    ///
    /// A `message` overrides the derived headline, for the writes the summary
    /// cannot describe on its own: a rename, or a reload after the file was
    /// found damaged.  Those still get positions; they just do not get told
    /// what their own event was.
    func configure(message: String? = nil, summary: Summary) {
        self.summary = summary
        self.message = message ?? summary.headline
        currentPosition = nil
        updatePositionStatus()
        updateNavigationState()
        invalidateIntrinsicContentSize()
        setAccessibilityLabel(
            message.map { "\($0). \(summary.accessibilityDescription)" }
                ?? summary.accessibilityDescription
        )
        needsDisplay = true
    }

    /// Count-only entry point, kept for callers with no marks to hand.
    func configure(message: String, changeCount: Int) {
        summary = Summary(changeCount: changeCount)
        self.message = message
        currentPosition = nil
        updatePositionStatus()
        updateNavigationState()
        invalidateIntrinsicContentSize()
        setAccessibilityLabel("\(message). \(changeCount) unread changes")
        needsDisplay = true
    }

    /// Walking is only offered when there is something to walk.  Enabled
    /// chevrons that silently do nothing are worse than no chevrons (§11.4).
    private func updateNavigationState() {
        let canWalk = changeCount > 0
        previousButton?.isEnabled = canWalk
        nextButton?.isEnabled = canWalk
        let help = canWalk ? "" : " (no unread changes)"
        previousButton?.toolTip = "Previous change\(help)"
        nextButton?.toolTip = "Next change\(help)"
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
        // The tint ladder follows the action hierarchy: the walk chevrons in
        // secondary, dismiss (in the base class) one step fainter, and the
        // confirm key wearing the bar's one strong colour — the stripe's own
        // green — so the way out reads as affirmation, not just another glyph.
        previousButton?.contentTintColor = styleSheet.textSecondary
        nextButton?.contentTintColor = styleSheet.textSecondary
        reviewedButton?.contentTintColor = styleSheet.changeColor(.inserted)
        layer?.cornerRadius = Self.cornerRadius
    }


    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        styleSheet.background.setFill()
        shape.fill()
        styleSheet.text.withAlphaComponent(styleSheet.increaseContrast ? 0.10 : 0.055).setFill()
        shape.fill()

        styleSheet.rule.withAlphaComponent(0.7).setStroke()
        shape.lineWidth = PanelMetrics.hairline
        shape.stroke()
    }
}
