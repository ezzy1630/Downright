import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol ChangeSummaryBarDelegate: AnyObject {
    func changeSummaryBar(_ bar: ChangeSummaryBarView, didRequestJump forward: Bool)
    /// A specific change was picked off the distribution ribbon.  Identified by
    /// mark rather than by index: the ribbon is sorted by position and the
    /// tracker's own array is not, so an index would silently address the wrong
    /// change the moment those two orders disagreed.
    func changeSummaryBar(_ bar: ChangeSummaryBarView, didSelectChangeWith id: UUID)
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
        /// order, for the distribution ribbon.
        var positions: [Position] = []

        struct Position: Equatable {
            var fraction: Double
            var kind: ChangeKind
            /// The mark this tick stands for, so a click can name a change
            /// rather than an ordinal.
            var id: UUID
        }

        var total: Int { added + rewritten + removed }

        /// Derives the summary from the tracker's own marks.
        ///
        /// `documentLength` is the current buffer length; a zero or negative
        /// length means there is nothing to place changes against, so the ribbon
        /// is simply omitted rather than being drawn from a division by zero.
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

        /// Spoken form.  VoiceOver gets the same facts as the ribbon, which is
        /// otherwise pure colour and position.
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

        setAccessibilityLabel("Document updated on disk")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Wide enough for the message it is carrying, never wider than a strip of
    /// chrome should be over a document.
    override var intrinsicContentSize: NSSize {
        NSSize(
            width: min(Self.maximumWidth, max(Self.minimumWidth, fittedWidth)),
            height: PanelMetrics.reviewBarHeight
        )
    }

    private static let minimumWidth: CGFloat = 260
    private static let maximumWidth: CGFloat = 520

    /// Configures the bar from the tracker's marks — the preferred entry point,
    /// and the only one that can draw the ribbon.
    ///
    /// A `message` overrides the derived headline, for the writes the summary
    /// cannot describe on its own: a rename, or a reload after the file was
    /// found damaged.  Those still get a ribbon; they just do not get told what
    /// their own event was.
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
        previousButton?.contentTintColor = styleSheet.textFaint
        nextButton?.contentTintColor = styleSheet.textFaint
        reviewedButton?.contentTintColor = styleSheet.textSecondary
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        drawDistributionRibbon(in: rect)
    }

    /// The bar's full width stands for the whole document; each tick is one
    /// change at its position in it.
    ///
    /// This is the cheapest honest answer to "where did it change" — the shape
    /// of the write is legible before any navigation happens, so a reader can
    /// tell "appended at the end" from "rewritten throughout" without walking a
    /// single change.  It stays deliberately mute: a 2pt strip along the bottom
    /// edge, inside the bar's own rounded shape, at an alpha that reads as
    /// texture until you look for it (§11.3).
    private func drawDistributionRibbon(in rect: NSRect) {
        guard !summary.positions.isEmpty, let track = trackRect() else { return }

        styleSheet.text.withAlphaComponent(styleSheet.increaseContrast ? 0.16 : 0.09).setFill()
        NSBezierPath(roundedRect: track, xRadius: 1, yRadius: 1).fill()

        for position in summary.positions {
            let hovered = position.id == hoveredChangeID
            // The hover target grows upward rather than in place: a tick that
            // only brightened would be ambiguous against the other ticks sharing
            // its colour, and one that grew in both directions would appear to
            // move.  The growth stops short of the label's descenders, so a
            // message with a "y" over a tick still clears it.
            let tick = tickRect(for: position, in: track)
            let drawn = hovered
                ? NSRect(x: tick.minX - 0.75, y: tick.minY, width: tick.width + 1.5, height: tick.height + 2)
                : tick
            styleSheet.changeColor(position.kind)
                .withAlphaComponent(hovered || styleSheet.increaseContrast ? 1 : 0.85)
                .setFill()
            NSBezierPath(roundedRect: drawn, xRadius: 1, yRadius: 1).fill()
        }
    }

    // MARK: - Ribbon geometry

    /// Keeps the ribbon clear of the 9pt corner radius at both ends.
    private static let ribbonInset: CGFloat = 12
    private static let tickWidth: CGFloat = 2.5
    /// The ribbon is 2pt tall, which is not a pointer target.  Clicks are taken
    /// from the bottom band of the bar instead, which is empty chrome — the
    /// label and the actions are centred well above it.
    private static let ribbonHitHeight: CGFloat = 11
    /// How far from a tick a click still counts as that tick.  Wide enough to
    /// hit a 2.5pt mark without aiming, narrow enough that clicking empty track
    /// stays a no-op rather than jumping somewhere arbitrary.
    private static let tickHitSlop: CGFloat = 7

    /// One definition of where the ribbon is, shared by drawing and hit-testing
    /// so the two cannot drift apart.
    private func trackRect() -> NSRect? {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let track = NSRect(
            x: rect.minX + Self.ribbonInset,
            y: rect.minY + 4,
            width: rect.width - Self.ribbonInset * 2,
            height: 2
        )
        return track.width > 0 ? track : nil
    }

    private func tickRect(for position: Summary.Position, in track: NSRect) -> NSRect {
        // Clamp so a change at either extreme stays inside the track instead of
        // bleeding past the rounded end and reading as a longer document.
        let span = max(0, track.width - Self.tickWidth)
        return NSRect(
            x: track.minX + span * CGFloat(position.fraction),
            y: track.minY,
            width: Self.tickWidth,
            height: track.height
        )
    }

    /// The band a click is taken from.
    private func ribbonHitRect() -> NSRect? {
        guard !summary.positions.isEmpty, let track = trackRect() else { return nil }
        return NSRect(
            x: track.minX - Self.tickHitSlop,
            y: bounds.minY,
            width: track.width + Self.tickHitSlop * 2,
            height: Self.ribbonHitHeight
        )
    }

    /// The change nearest a point, or nil when the point is not on the ribbon or
    /// lands on empty track.
    func change(at point: NSPoint) -> Summary.Position? {
        guard let hit = ribbonHitRect(), hit.contains(point), let track = trackRect() else { return nil }
        return summary.positions
            .map { ($0, abs(tickRect(for: $0, in: track).midX - point.x)) }
            .filter { $0.1 <= Self.tickHitSlop }
            .min { $0.1 < $1.1 }?
            .0
    }

    // MARK: - Ribbon interaction

    private var hoveredChangeID: UUID? {
        didSet {
            guard hoveredChangeID != oldValue else { return }
            needsDisplay = true
            window?.invalidateCursorRects(for: self)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea(
            &ribbonTracking,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect]
        )
    }

    private var ribbonTracking: NSTrackingArea?

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let hit = change(at: point)
        hoveredChangeID = hit?.id
        toolTip = hit.map { position in
            let ordinal = (summary.positions.firstIndex(of: position) ?? 0) + 1
            return "Go to \(Self.name(for: position.kind)) \(ordinal) of \(summary.positions.count)"
        }
    }

    override func mouseExited(with event: NSEvent) {
        hoveredChangeID = nil
        toolTip = nil
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = change(at: point) else {
            super.mouseDown(with: event)
            return
        }
        // Keep the walk counter in step, so picking a change off the ribbon and
        // then walking with the chevrons continues from where the click landed
        // rather than restarting.
        currentPosition = (summary.positions.firstIndex(of: hit) ?? 0) + 1
        updatePositionStatus()
        delegate?.changeSummaryBar(self, didSelectChangeWith: hit.id)
    }

    /// An interactive strip has to look interactive.  The cursor is the only
    /// affordance a 2pt ribbon has room for.
    override func resetCursorRects() {
        super.resetCursorRects()
        guard let hit = ribbonHitRect() else { return }
        addCursorRect(hit, cursor: .pointingHand)
    }

    private static func name(for kind: ChangeKind) -> String {
        switch kind {
        case .inserted: return "addition"
        case .modified: return "rewrite"
        case .deleted: return "removal"
        }
    }
}
