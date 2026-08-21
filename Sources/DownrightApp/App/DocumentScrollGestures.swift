import AppKit
import MarkdownRender

/// The plumbing every scroll-driven gesture over the document surface shares.
///
/// `MarkdownTextView` offers the host every scroll event before the scroll
/// view sees it, and the host now has more than one answer: a modifier turns
/// the wheel into a zoom, ⇧ and two fingers move through jump history, and two
/// bare fingers switch Document↔Source.  They cannot all be asked at once —
/// two gestures claiming the same event is a page that scrolls *and* zooms —
/// so they are asked in order and the first to claim wins.
///
/// What lives here is only what is genuinely common: the ordering rule, the
/// arithmetic of a sideways swipe, and the page's give.  Every threshold stays
/// with the gesture it describes, because the numbers *are* the feel and two
/// gestures that happen to share a formula do not share a feel.

// MARK: - Modifiers

/// The modifiers that can change what a scroll over the document means.
///
/// Caps Lock, fn and the numeric-pad flag ride along on perfectly ordinary
/// events and must never decide a gesture, so every handler tests the four
/// that matter and only those — and tests them for equality, not membership,
/// or ⇧⌘-scroll would fire two gestures that disagree about the page.
enum ScrollGestureModifiers {
    static let considered: NSEvent.ModifierFlags = [.command, .option, .control, .shift]

    static func held(in event: NSEvent) -> NSEvent.ModifierFlags {
        event.modifierFlags.intersection(considered)
    }
}

// MARK: - Chain

/// One gesture the document surface can hand a scroll event to.
@MainActor
protocol ScrollGestureHandler: AnyObject {
    /// Offer the event.  Returning `true` consumes it and the scroll view
    /// never sees it; a handler that is still deciding must return `false` so
    /// ordinary scrolling never waits on the decision.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool

    /// `true` while this handler is physically in the middle of a gesture it
    /// has already taken.  A handler that says so is routed the rest of the
    /// gesture on its own: the alternative is a modifier pressed mid-swipe
    /// handing the events to somebody else and leaving a translated pane
    /// nobody owns.
    var isClaimingGesture: Bool { get }
}

extension ScrollGestureHandler {
    var isClaimingGesture: Bool { false }
}

/// The document surface's gestures, in the order they get to claim an event.
///
/// Order is a real decision, not a list.  The modifier zooms decide on a
/// single event, so they can be asked first and answer immediately.  The two
/// swipes need travel before they can tell themselves apart from a scroll, and
/// while they are deciding they hand the event back — which is exactly why the
/// one that needs ⇧ has to be asked before the one that needs nothing, and why
/// the bare swipe stands down whenever a modifier is held.
@MainActor
final class ScrollGestureChain {
    private let handlers: [any ScrollGestureHandler]

    init(_ handlers: [any ScrollGestureHandler]) {
        self.handlers = handlers
    }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        // A gesture that has already caught keeps every remaining event of it,
        // including the ones it will decline.  Polling from the top here would
        // let a late modifier steal a swipe that is already on screen.
        if let owner = handlers.first(where: { $0.isClaimingGesture }) {
            return owner.handle(event)
        }
        for handler in handlers {
            if handler.handle(event) { return true }
        }
        return false
    }
}

// MARK: - Swipe physics

/// The arithmetic behind a sideways swipe over the document surface.
///
/// Stateless and parameterised: each gesture states its own numbers and gets
/// the same physics, so the Document↔Source swipe and the Back/Forward swipe
/// resolve an axis, a commit and a give the same way while feeling like the
/// different things they are.
enum DocumentSwipePhysics {
    enum Claim: Equatable {
        /// Still ambiguous. The event belongs to the scroll view for now, so
        /// vertical scrolling never waits on this decision.
        case undecided
        /// A sideways gesture: the document surface stops scrolling.
        case swipe
        /// Ordinary scrolling. Stop testing for the rest of the gesture.
        case scroll
    }

    static func claim(
        horizontal: CGFloat,
        vertical: CGFloat,
        intentThreshold: CGFloat,
        axisDominance: CGFloat
    ) -> Claim {
        let across = abs(horizontal)
        let along = abs(vertical)
        if across >= intentThreshold, across >= along * axisDominance { return .swipe }
        if along >= intentThreshold { return .scroll }
        return .undecided
    }

    /// A share of the pane, bounded at both ends: a narrow split pane must not
    /// commit on a twitch, and a full-width window must not demand a swipe
    /// longer than the trackpad.
    static func commitDistance(
        paneWidth: CGFloat,
        fraction: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        min(max(paneWidth * fraction, minimum), maximum)
    }

    static func shouldCommit(
        translation: CGFloat,
        velocity: CGFloat,
        distance: CGFloat,
        flickVelocity: CGFloat
    ) -> Bool {
        guard translation != 0 else { return false }
        if abs(translation) >= distance { return true }
        // A flick commits even when short — but a reversal at the end of the
        // gesture means "put it back", however fast the hand was moving.
        return abs(velocity) >= flickVelocity && (velocity < 0) == (translation < 0)
    }

    /// The page's give: asymptotic, so it always answers the fingers and never
    /// arrives anywhere.  A linear give would need a clamp, and a clamp is a
    /// dead stop the hand can feel.
    static func give(_ translation: CGFloat, limit: CGFloat) -> CGFloat {
        guard limit > 0 else { return 0 }
        let sign: CGFloat = translation < 0 ? -1 : 1
        let distance = abs(translation)
        return sign * limit * (1 - 1 / (distance / (limit * 0.9) + 1))
    }

    /// Smoothed instantaneous velocity, in points per second.
    ///
    /// One 8 ms frame is far too short a window to tell a flick from a jitter
    /// at the end of a slow drag, so each sample only moves the estimate part
    /// of the way.
    static func velocity(
        current: CGFloat,
        delta: CGFloat,
        elapsed: TimeInterval
    ) -> CGFloat {
        guard elapsed > 0.0005 else { return current }
        let instantaneous = delta / CGFloat(elapsed)
        return current == 0 ? instantaneous : current * 0.6 + instantaneous * 0.4
    }
}

// MARK: - Give

/// One pane's give: the live text surface translated against the fingers.
///
/// A layer transform, not a frame change and not a snapshot — nothing is
/// re-rendered, nothing is laid out, and the compositor does the whole job.
/// The gutter and footnote rail stay put, the way a scroller does: they
/// annotate the page rather than travel with it.
@MainActor
final class PaneGive {
    private(set) weak var pane: MarkdownContainerView?
    private let wasMasking: Bool

    init?(pane: MarkdownContainerView) {
        guard pane.bounds.width > 1 else { return nil }
        // Asked for rather than assumed. The document window is layer-backed
        // in practice, but a give that silently does nothing when it is not
        // is worse than a one-off backing store on the first swipe.
        pane.wantsLayer = true
        pane.scrollView.wantsLayer = true
        guard let paneLayer = pane.layer, pane.scrollView.layer != nil else { return nil }
        self.pane = pane
        // The page has to be clipped to its own frame while it travels, or the
        // give paints over whatever sits beside it.
        wasMasking = paneLayer.masksToBounds
        paneLayer.masksToBounds = true
    }

    func place(_ offset: CGFloat) {
        guard let layer = pane?.scrollView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(offset, 0, 0)
        CATransaction.commit()
    }

    func release() {
        guard let pane else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pane.scrollView.layer?.transform = CATransform3DIdentity
        pane.layer?.masksToBounds = wasMasking
        CATransaction.commit()
    }
}

/// Every pane's give at once, plus the spring that puts them back.
///
/// A sideways gesture over a split window moves both panes together — the mode
/// and the reading position are the window's, not one pane's — and an
/// abandoned gesture owes the reader a return, not a snap.  Both swipes want
/// exactly this, so neither of them owns it.
@MainActor
final class PaneGiveTrack {
    private var surfaces: [PaneGive] = []
    private var driver: Motion.SpringDriver?
    /// Critically damped: the page returning past its own resting place would
    /// read as a bounce nothing caused.
    private var offset = Motion.SpringScalar(
        value: 0,
        perceptualDuration: Motion.springQuick
    )
    private var landing: (() -> Void)?
    private var pendingLanding = false

    deinit { driver?.park() }

    /// `true` from `settle(completion:)` until the panes are back at rest.
    private(set) var isSettling = false
    var isEngaged: Bool { !surfaces.isEmpty }

    /// Take hold of the panes.  Nothing is rendered and nothing is laid out;
    /// the cost is one backing store per pane, once.
    func engage(_ panes: [MarkdownContainerView]) {
        release()
        surfaces = panes.compactMap(PaneGive.init(pane:))
        offset.snap(to: 0)
    }

    func place(_ value: CGFloat) {
        offset.snap(to: value)
        for surface in surfaces { surface.place(value) }
    }

    /// Spring the panes home and call `completion` when they arrive.  With no
    /// give in flight there is nothing to wait for, so `completion` runs now.
    func settle(completion: @escaping () -> Void) {
        guard !surfaces.isEmpty else {
            completion()
            return
        }
        isSettling = true
        landing = completion
        offset.target(0)
        guard let anchor = surfaces.first?.pane, anchor.window != nil else {
            land()
            return
        }
        let driver = self.driver ?? Motion.SpringDriver(
            view: anchor,
            advance: { [weak self] dt in self?.tick(dt: dt) ?? false },
            apply: { [weak self] in self?.apply() }
        )
        self.driver = driver
        if !driver.arm() { land() }
    }

    /// Hand the panes back where they were with no spring at all.  A commit
    /// takes this path: the transition that follows draws from the pane's
    /// resting frame and must not start from a translated layer.
    func release() {
        isSettling = false
        pendingLanding = false
        landing = nil
        driver?.park()
        let finishing = surfaces
        surfaces = []
        for surface in finishing { surface.release() }
    }

    /// No display link to spring on — off-screen, or a window already gone.
    private func land() {
        offset.snap(to: 0)
        pendingLanding = false
        for surface in surfaces { surface.place(0) }
        finish()
    }

    private func tick(dt: CGFloat) -> Bool {
        let moving = offset.advance(dt: dt)
        if !moving { pendingLanding = true }
        return moving
    }

    private func apply() {
        for surface in surfaces { surface.place(offset.value) }
        if pendingLanding {
            pendingLanding = false
            finish()
        }
    }

    private func finish() {
        guard isSettling else { return }
        let completion = landing
        landing = nil
        isSettling = false
        completion?()
    }
}
