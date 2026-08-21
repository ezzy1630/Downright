import AppKit
import MarkdownRender

/// Decisions for the ⇧ two-finger Back/Forward swipe, kept pure so the feel
/// can be tuned and tested without a trackpad under it.
///
/// Jump history has been reachable only from the keyboard and the View menu,
/// which is odd for a thing whose whole job is "put me back where I was" — the
/// most reflexive request a reader ever makes.  `JumpHistory` was written with
/// a gesture in mind: it deliberately refuses to record ordinary scrolling so
/// that a swipe through the stack stays useful rather than filling with noise.
/// This is that swipe, six months late.
///
/// Bare two fingers sideways already switch Document↔Source, so this needs a
/// modifier, and ⇧ is the one that is free.  Shift-scroll is conventionally
/// horizontal scrolling on macOS — but the document surface has no horizontal
/// axis to scroll (the scroll view's horizontal scroller is off and the text
/// is measured to the pane), so nothing is being taken from anybody.  The
/// direction follows Safari exactly: push the page right, uncovering what sits
/// to its left, and you go back.
enum HistorySwipePolicy {
    enum Direction: Equatable {
        case back
        case forward
    }

    /// Held for the whole of the deciding part of the gesture.  Tested for
    /// equality, so ⇧⌘ is not this gesture and never half-starts it.
    static let modifiers: NSEvent.ModifierFlags = [.shift]

    static func isSpelledCorrectly(_ held: NSEvent.ModifierFlags) -> Bool {
        held == modifiers
    }

    /// Horizontal travel that claims the gesture away from vertical scrolling.
    /// A shade longer than the presentation swipe's: ⇧ is often held for a
    /// reason that has nothing to do with this — extending a selection with
    /// the trackpad, for one — and going somewhere else in the document is a
    /// bigger surprise than changing presentation.
    static let intentThreshold: CGFloat = 14
    /// How far the horizontal component must beat the vertical one, for the
    /// same reason and a little more strictly.
    static let axisDominance: CGFloat = 1.5
    /// Share of the pane that commits on release, bounded at both ends: a
    /// narrow split pane must not travel on a twitch, and a full-width window
    /// must not demand a swipe longer than the trackpad.  Shorter than the
    /// presentation swipe's, because a Back that was not wanted costs one
    /// Forward to undo and the reader's place is never lost.
    static let commitFraction: CGFloat = 0.2
    static let minimumCommitDistance: CGFloat = 56
    static let maximumCommitDistance: CGFloat = 120
    /// Points per second that commits a short swipe — the flick.
    static let flickVelocity: CGFloat = 260
    /// How far the page travels under the fingers.  A touch further than the
    /// presentation swipe's, because there is no rail here reporting how far
    /// along the gesture is: the page's own travel is the only answer the
    /// reader gets to "is this enough yet?".
    static let maximumGive: CGFloat = 30

    typealias Claim = DocumentSwipePhysics.Claim

    static func claim(horizontal: CGFloat, vertical: CGFloat) -> Claim {
        DocumentSwipePhysics.claim(
            horizontal: horizontal,
            vertical: vertical,
            intentThreshold: intentThreshold,
            axisDominance: axisDominance
        )
    }

    /// Where a swipe of this translation is heading.
    ///
    /// `translation` is accumulated `scrollingDeltaX`, which AppKit has
    /// already flipped for the trackpad's scroll-direction preference, so this
    /// never reads the setting itself.  Positive pushes the page right and
    /// uncovers what sits to its left, which is where you have already been.
    static func direction(translation: CGFloat) -> Direction? {
        if translation > 0 { return .back }
        if translation < 0 { return .forward }
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

/// Drives the ⇧ two-finger Back/Forward swipe across every pane in a window.
///
/// The window owns jump history; this owns the gesture.  What it needs from
/// the window arrives as `Host` rather than a back-reference, so the state
/// machine can be exercised without a document behind it.
///
/// Like its sibling it renders nothing during the gesture: the destination is
/// a scroll position, and scrolling there speculatively so it could be dragged
/// in would move the reader somewhere they have not asked to go yet.  The page
/// gives against the fingers, and the trip happens on release.
@MainActor
final class HistorySwipeCoordinator: ScrollGestureHandler {
    struct Host {
        var panes: () -> [MarkdownContainerView]
        var styleSheet: () -> StyleSheet
        /// Whether jump history has anywhere to go that way.  Asked before the
        /// gesture is claimed, so a swipe into an empty stack never catches:
        /// a page that gives and then does nothing reads as a bug, and Back at
        /// the start of a session is the commonest way to find one.
        var canMove: (HistorySwipePolicy.Direction) -> Bool
        /// Take the step.  Called once, on release, and never speculatively.
        var move: (HistorySwipePolicy.Direction) -> Void
        /// The detent when the swipe passes the point where releasing would
        /// commit — the same `.alignment` tap the presentation rail uses when
        /// its indicator reaches the far segment, and the only "far enough
        /// now" this gesture has.
        var performHapticFeedback: () -> Void = {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
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
    private var direction: HistorySwipePolicy.Direction = .back
    private var passedCommitPoint = false
    private var swallowsMomentum = false
    private let gives = PaneGiveTrack()

    init(host: Host) {
        self.host = host
    }

    var isTracking: Bool { state == .swiping }
    var isSettling: Bool { state == .settling }
    var isClaimingGesture: Bool { isTracking || isSettling }
    /// Visible for tests: which way a claimed swipe is heading.
    var trackedDirectionForTesting: HistorySwipePolicy.Direction? {
        isTracking ? direction : nil
    }

    /// The single entry point from the chain.  Returns `true` when the swipe
    /// has taken the event, in which case the scroll view must not see it.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        // Trackpads only.  A wheel's ⇧-scroll is a single unphased notch with
        // no travel to measure and no release to commit on, so there is no
        // interactive gesture to build out of it — Back and Forward stay on
        // ⌘⌃[ and ⌘⌃] for a mouse.
        guard event.hasPreciseScrollingDeltas else { return false }

        // Momentum arrives after the fingers are up.  There is nothing left to
        // track, and it must never buy a second trip — but it is swallowed
        // rather than handed back, because the coast belongs to a gesture that
        // has already been answered.  Letting it through would scroll the
        // document underneath the trip it just committed, or lurch the page
        // the reader is watching spring home.
        guard event.momentumPhase.isEmpty else {
            let swallow = swallowsMomentum || state == .settling
            if !event.momentumPhase.intersection([.ended, .cancelled]).isEmpty {
                swallowsMomentum = false
            }
            return swallow
        }

        // Fingers back down ends the last gesture's coast, whatever this new
        // one turns out to be spelled with — otherwise a swipe's leftover
        // claim on momentum would eat the tail of somebody else's scroll.
        if event.phase == .began { swallowsMomentum = false }

        // ⇧ has to be held while the gesture is being decided.  Once it has
        // caught, letting go of ⇧ must not drop it: the page is travelling and
        // something has to finish it.
        if !isClaimingGesture,
           !HistorySwipePolicy.isSpelledCorrectly(ScrollGestureModifiers.held(in: event)) {
            // A gesture that started with ⇧ and lost it is over, not paused.
            if state == .undecided { state = .scrolling }
            return false
        }

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
        gives.release()
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
        passedCommitPoint = false
        swallowsMomentum = false
        lastTimestamp = timestamp
    }

    private func track(_ event: NSEvent) -> Bool {
        switch state {
        case .idle, .scrolling, .settling:
            return false
        case .undecided:
            horizontalTravel += event.scrollingDeltaX
            verticalTravel += event.scrollingDeltaY
            switch HistorySwipePolicy.claim(
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
        guard let heading = HistorySwipePolicy.direction(translation: translation) else {
            return false
        }
        // Nothing that way: hand the gesture back rather than promise a trip
        // that cannot happen.
        guard host.canMove(heading) else { return false }
        let widest = host.panes().map(\.bounds.width).max() ?? 0
        guard widest > 1 else { return false }

        direction = heading
        paneWidth = widest
        state = .swiping
        // From here the coast after the fingers lift belongs to this gesture,
        // whichever way it ends.
        swallowsMomentum = true
        if !host.styleSheet().reduceMotion {
            gives.engage(host.panes())
        }
        return true
    }

    private func applyTranslation() {
        gives.place(HistorySwipePolicy.give(translation))
        // The detent, once per crossing.  Coming back under it re-arms, so a
        // reader hovering at the threshold feels the line rather than a burst.
        let past = abs(translation) >= HistorySwipePolicy.commitDistance(paneWidth: paneWidth)
        if past != passedCommitPoint {
            passedCommitPoint = past
            if past { host.performHapticFeedback() }
        }
    }

    private func endGesture(cancelled: Bool) -> Bool {
        guard state == .swiping else {
            if state != .settling { state = .idle }
            return false
        }
        let commit = !cancelled
            && HistorySwipePolicy.shouldCommit(
                translation: translation,
                velocity: velocity,
                paneWidth: paneWidth
            )
            // Re-asked at the last moment: the stack cannot change during a
            // gesture today, but a trip that silently does nothing is a worse
            // failure than one that never starts.
            && host.canMove(direction)

        if commit {
            // Put the page back before the trip: the destination scroll
            // animates from the pane's resting frame and must not start from
            // a translated layer.
            gives.release()
            state = .idle
            host.move(direction)
            return true
        }

        // Nothing was moved, so nothing has to be undone — an abandoned swipe
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
        gives.release()
    }
}
