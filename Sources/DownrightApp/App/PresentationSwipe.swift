import AppKit
import MarkdownRender

/// Decisions for the two-finger Document↔Source swipe, kept pure so the feel
/// can be tuned and tested without a trackpad under it.
///
/// The gesture is deliberately cheap.  Dragging the *next* presentation in
/// under the fingers was tried and measured: Source has to exist before it can
/// be dragged, and building it costs about 400 ms on a two-thousand-line
/// document — half a second of dead trackpad at the exact moment the swipe
/// catches, and the same again to undo if the swipe is then abandoned.  So
/// nothing is rendered during the gesture.  The rail's indicator is welded to
/// the fingers, the page gives against them, and the switch happens on release
/// for exactly what it costs from the toolbar and not a millisecond more.
enum PresentationSwipePolicy {
    /// Horizontal travel that claims the gesture away from vertical scrolling.
    /// Small enough that a deliberate swipe engages almost at once, large
    /// enough that the sideways component of a fast flick down the page does
    /// not read as one.
    static let intentThreshold: CGFloat = 12
    /// How far the horizontal component must beat the vertical one.  Diagonal
    /// drift while reading is a scroll; only a decidedly sideways gesture is
    /// a swipe.
    static let axisDominance: CGFloat = 1.4
    /// Share of the pane that commits on release, bounded at both ends: a
    /// narrow split pane must not switch on a twitch, and a full-width window
    /// must not demand a swipe longer than the trackpad.
    static let commitFraction: CGFloat = 0.25
    static let minimumCommitDistance: CGFloat = 64
    static let maximumCommitDistance: CGFloat = 140
    /// Points per second that commits a short swipe — the flick.
    static let flickVelocity: CGFloat = 260
    /// How far the page itself travels under the fingers.  Small on purpose:
    /// it is the physical evidence that the gesture has caught, not a preview
    /// of what is coming, and it costs one layer transform to draw.
    static let maximumGive: CGFloat = 28

    typealias Claim = DocumentSwipePhysics.Claim

    static func claim(horizontal: CGFloat, vertical: CGFloat) -> Claim {
        DocumentSwipePhysics.claim(
            horizontal: horizontal,
            vertical: vertical,
            intentThreshold: intentThreshold,
            axisDominance: axisDominance
        )
    }

    /// Which segment a swipe is heading for: `0` Document, `1` Source.
    ///
    /// The page follows the fingers, so pushing it left uncovers what sits to
    /// the right of the rail.  `translation` is accumulated `scrollingDeltaX`,
    /// which AppKit has already flipped for the trackpad's scroll-direction
    /// preference — the same reason a Spaces swipe reverses when natural
    /// scrolling is off, and the reason this never reads the setting itself.
    static func targetSegment(translation: CGFloat) -> Int? {
        if translation < 0 { return 1 }
        if translation > 0 { return 0 }
        return nil
    }

    static func commitDistance(paneWidth: CGFloat) -> CGFloat {
        DocumentSwipePhysics.commitDistance(
            paneWidth: paneWidth,
            fraction: commitFraction,
            minimum: minimumCommitDistance,
            maximum: maximumCommitDistance
        )
    }

    /// How far through the switch the rail's indicator should read, `0`…`1`.
    /// It reaches the far segment exactly where releasing would commit, so the
    /// bar is the answer to "is this far enough yet?".
    static func railProgress(translation: CGFloat, paneWidth: CGFloat) -> CGFloat {
        let distance = commitDistance(paneWidth: paneWidth)
        guard distance > 0 else { return 0 }
        return min(1, abs(translation) / distance)
    }

    /// That progress placed on the rail, which runs `0` Document to `1` Source.
    static func railPosition(progress: CGFloat, origin: Int, target: Int) -> CGFloat {
        let start = CGFloat(min(max(origin, 0), 1))
        let end = CGFloat(min(max(target, 0), 1))
        return start + (end - start) * min(max(progress, 0), 1)
    }

    static func shouldCommit(
        translation: CGFloat,
        velocity: CGFloat,
        paneWidth: CGFloat
    ) -> Bool {
        DocumentSwipePhysics.shouldCommit(
            translation: translation,
            velocity: velocity,
            distance: commitDistance(paneWidth: paneWidth),
            flickVelocity: flickVelocity
        )
    }

    static func give(_ translation: CGFloat) -> CGFloat {
        DocumentSwipePhysics.give(translation, limit: maximumGive)
    }
}

// MARK: - Coordinator

/// Drives the two-finger Document↔Source swipe across every pane in a window
/// and keeps the titlebar rail's indicator travelling with it.
///
/// The window owns the mode; this owns the gesture.  What it needs from the
/// window arrives as `Host` rather than a back-reference, so the state machine
/// can be exercised without a document behind it.
@MainActor
final class PresentationSwipeCoordinator: ScrollGestureHandler {
    struct Host {
        var panes: () -> [MarkdownContainerView]
        var styleSheet: () -> StyleSheet
        /// The presentation the document is actually in — `0` Document,
        /// `1` Source — not what the rail happens to be drawing mid-swipe.
        var selectedSegment: () -> Int
        /// Switch presentation, with the same transition the toolbar rail
        /// uses.  Called once, on release, and never speculatively.
        var commitSegment: (Int) -> Void
        /// Move the rail's indicator to `position` (`0` Document, `1` Source).
        var trackRail: (CGFloat) -> Void
        /// Land the rail on a segment.
        var settleRail: (Int) -> Void
        /// The open document's length, which decides whether the drag is
        /// affordable — see `PresentationSwitchBudget`.
        var documentLines: () -> Int
        /// Switch presentation with no transition of its own.  The drag makes
        /// the change behind a still at the top of the gesture, and puts it
        /// back the same way if the gesture is abandoned.
        var setSegment: (Int) -> Void
    }

    private enum State {
        case idle
        case undecided
        case scrolling
        case swiping
        case settling
    }

    private let host: Host
    private var state: State = .idle
    private var horizontalTravel: CGFloat = 0
    private var verticalTravel: CGFloat = 0
    private var translation: CGFloat = 0
    private var velocity: CGFloat = 0
    private var lastTimestamp: TimeInterval = 0
    private var paneWidth: CGFloat = 0
    private var originSegment = 0
    private var targetSegment = 0
    /// Two ways to answer the fingers, chosen per gesture by what the
    /// document can afford.  Under budget the real thing: the page you are
    /// leaving travels off while the one you are entering follows it in, both
    /// tracking 1:1.  Over budget the give: the page leans against your
    /// fingers and the switch happens on release.  Never both.
    private let drag = PaneDragTrack()
    private let gives = PaneGiveTrack()

    init(host: Host) {
        self.host = host
    }

    var isTracking: Bool { state == .swiping }
    var isSettling: Bool { state == .settling }
    var isClaimingGesture: Bool { isTracking || isSettling }

    /// The single entry point from the text surface.  Returns `true` when the
    /// swipe has taken the event, in which case the scroll view must not see
    /// it.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        // Trackpads only.  A wheel with a horizontal tilt has no phases to
        // build an interactive gesture out of, and stealing it would break
        // horizontal scrolling for anyone whose mouse has it.
        guard event.hasPreciseScrollingDeltas else { return false }

        // This is the gesture spelled with nothing held.  ⌘ and ⌥ zoom, ⇧
        // moves through jump history, and those are asked first — but a swipe
        // hands the event back for as long as it is still deciding, so this
        // one has to stand down on its own account rather than rely on the
        // order.  Once it *has* caught, a modifier pressed halfway through
        // changes nothing: the page is already travelling under the fingers
        // and something has to finish it.
        if !isClaimingGesture, !ScrollGestureModifiers.held(in: event).isEmpty {
            return false
        }

        // Momentum arrives after the fingers are up. There is nothing left to
        // track — but swallow it while the page settles, or a vertical tail
        // lurches the document the reader is watching return.
        guard event.momentumPhase.isEmpty else { return state == .settling }

        switch event.phase {
        case .began:
            beginGesture(at: event.timestamp)
            return false
        case .changed:
            return track(event)
        case .ended, .cancelled:
            return endGesture(cancelled: event.phase == .cancelled)
        default:
            return state == .swiping
        }
    }

    /// A resize reflows the page under the give, so the transform stops
    /// describing anything. Put the page back and let the gesture go.
    func cancelInFlight() {
        guard state == .swiping || state == .settling else { return }
        state = .idle
        // A drag switched the mode speculatively at the top of the gesture.
        // Grounding it is not a commit, so put the mode back before letting go
        // of the stills that are hiding the change.
        if drag.isEngaged, host.selectedSegment() != originSegment {
            host.setSegment(originSegment)
        }
        drag.release()
        gives.release()
        host.settleRail(host.selectedSegment())
    }

    // MARK: - Gesture

    private func beginGesture(at timestamp: TimeInterval) {
        // A new gesture during the settle abandons the tail rather than
        // fighting it: the reader has already started moving again.
        if state == .settling { finishSettle() }
        state = .undecided
        horizontalTravel = 0
        verticalTravel = 0
        translation = 0
        velocity = 0
        lastTimestamp = timestamp
    }

    private func track(_ event: NSEvent) -> Bool {
        switch state {
        case .idle, .scrolling, .settling:
            return false
        case .undecided:
            horizontalTravel += event.scrollingDeltaX
            verticalTravel += event.scrollingDeltaY
            switch PresentationSwipePolicy.claim(
                horizontal: horizontalTravel,
                vertical: verticalTravel
            ) {
            case .undecided:
                return false
            case .scroll:
                state = .scrolling
                return false
            case .swipe:
                // The travel already spent deciding is real movement the
                // reader made; start from there rather than dropping it.
                translation = horizontalTravel
                lastTimestamp = event.timestamp
                guard beginSwipe() else {
                    state = .scrolling
                    return false
                }
            }
        case .swiping:
            translation += event.scrollingDeltaX
            velocity = DocumentSwipePhysics.velocity(
                current: velocity,
                delta: event.scrollingDeltaX,
                elapsed: event.timestamp - lastTimestamp
            )
            lastTimestamp = event.timestamp
        }

        applyTranslation()
        return true
    }

    private func beginSwipe() -> Bool {
        guard let target = PresentationSwipePolicy.targetSegment(translation: translation)
        else { return false }
        originSegment = host.selectedSegment()
        // Nothing sits beyond the mode you are already in, so there is no
        // switch to promise. Hand the gesture back rather than invent a dead
        // end the reader has to swipe their way out of.
        guard target != originSegment else { return false }
        let widest = host.panes().map(\.bounds.width).max() ?? 0
        guard widest > 1 else { return false }

        targetSegment = target
        paneWidth = widest
        state = .swiping

        // Reduce Motion asked for no travelling surfaces at all. Honour the
        // gesture, skip the choreography: the switch happens on release the
        // way a click on the rail does.
        guard !host.styleSheet().reduceMotion else { return true }

        // The drag has to render what it is dragging in before a finger moves.
        // Ask the budget whether this document can afford that inside a few
        // frames; if it cannot, the give is not a consolation prize, it is the
        // right answer — it promises less and it always answers.
        if PresentationSwitchBudget.allowsDrag(lines: host.documentLines()),
           drag.engage(host.panes(), direction: translation < 0 ? -1 : 1) {
            // The stills are covering every pane now, so the rebuild happens
            // behind them rather than under the fingers.
            host.setSegment(target)
        } else {
            gives.engage(host.panes())
        }
        return true
    }

    private func applyTranslation() {
        if drag.isEngaged {
            // Welded to the fingers. The page is really going where you are
            // pushing it, so there is nothing to damp.
            drag.place(translation)
        } else {
            gives.place(PresentationSwipePolicy.give(translation))
        }
        host.trackRail(PresentationSwipePolicy.railPosition(
            progress: PresentationSwipePolicy.railProgress(
                translation: translation,
                paneWidth: paneWidth
            ),
            origin: originSegment,
            target: targetSegment
        ))
    }

    private func endGesture(cancelled: Bool) -> Bool {
        guard state == .swiping else {
            if state != .settling { state = .idle }
            return false
        }
        let commit = !cancelled && PresentationSwipePolicy.shouldCommit(
            translation: translation,
            velocity: velocity,
            paneWidth: paneWidth
        )
        host.settleRail(commit ? targetSegment : originSegment)

        if drag.isEngaged {
            // The mode was changed at the top of the gesture, so a commit has
            // nothing left to do but fly the outgoing page off. An abandoned
            // drag owes the reader the mode back — put it behind the still,
            // which is covering the pane again by the time this runs.
            state = .settling
            drag.settle(committed: commit, velocity: velocity) { [weak self] in
                guard let self else { return }
                if !commit, self.host.selectedSegment() != self.originSegment {
                    self.host.setSegment(self.originSegment)
                }
                self.drag.release()
                self.state = .idle
            }
            return true
        }

        if commit {
            // Put the page back before the switch: the mode change draws its
            // own transition from the pane's resting frame and must not start
            // from a translated layer.
            gives.release()
            state = .idle
            host.commitSegment(targetSegment)
            return true
        }

        // Nothing was built, so nothing has to be undone — an abandoned swipe
        // costs one spring back to rest.
        guard gives.isEngaged else {
            state = .idle
            return true
        }
        state = .settling
        gives.settle { [weak self] in self?.finishSettle() }
        return true
    }

    private func finishSettle() {
        guard state == .settling else { return }
        state = .idle
        drag.release()
        gives.release()
    }
}
