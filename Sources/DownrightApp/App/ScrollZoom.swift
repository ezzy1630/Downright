import AppKit
import MarkdownRender

/// Decisions for the two modifier zooms on the wheel, kept pure so the detent
/// can be tuned and tested without a trackpad or a mouse under it.
///
/// The document surface already zooms two ways, and until now both were shut
/// to a mouse.  Pinch drives the reading text size; ⌃⌥⌘1…5 drives structural
/// detail, which is one of the best things the app does and is buried behind a
/// four-key chord nobody remembers.  A wheel with a modifier on it is the
/// obvious way in, and it costs nothing: this surface scrolls vertically and
/// nothing else, so a modified scroll over it is unclaimed.
///
/// The two scales want opposite treatment, which is the whole design here.
/// Text size is a fine ramp with fifteen stops and a cheap reflow — the reader
/// nudges it until the page looks right, exactly as they do with pinch.
/// Structural detail is five stops, each of which rewrites what the document
/// *is*, at the cost of a full relayout.  Five of those in one flick is both
/// useless and slow, so a gesture is allowed exactly one.
enum ScrollZoomPolicy {
    enum Intent: Equatable {
        /// ⌘ — the reading size of the text, the scale pinch already drives.
        case textSize
        /// ⌥ — the structural detail level, the scale ⌃⌥⌘1…5 drives.
        case structuralDetail
    }

    /// Exactly ⌘ or exactly ⌥.  ⇧⌘ belongs to jump history and ⌃⌥ belongs to
    /// nothing at all; a zoom that answered to any superset would fire
    /// underneath both of them.
    static func intent(for held: NSEvent.ModifierFlags) -> Intent? {
        if held == .command { return .textSize }
        if held == .option { return .structuralDetail }
        return nil
    }

    /// Points of trackpad travel per text-size step.  Roughly a knuckle's
    /// worth: `magnify(with:)` steps every 0.075 of pinch, which is about the
    /// same amount of hand movement, so the two zooms ramp at the same rate
    /// and switching devices does not change the feel.
    static let textSizeStepPoints: CGFloat = 26

    /// Points of trackpad travel before the single structural step a gesture
    /// is allowed.  Longer than a twitch and longer than the sideways slop in
    /// a fast vertical flick, so ⌥ held down while reading cannot rewrite the
    /// document by accident.
    static let detailStepPoints: CGFloat = 60

    /// A coarse wheel measures in lines, not points, and its notches are
    /// already detents the hand can feel — so one notch is one step, the way
    /// every browser has always spelled ⌘-wheel.
    static let wheelStepLines: CGFloat = 1

    /// …but macOS accelerates a fast spin into deltas of ten lines and more,
    /// which would turn one flick of the wheel into the whole scale.  Each
    /// event contributes at most one notch, so the number of steps can only
    /// ever be the number of notches the hand actually turned.
    static let maximumWheelLinesPerEvent: CGFloat = 1

    /// Structural steps a single gesture may fire.  One, firmly: the keyboard
    /// chords are still there for jumping straight to a level, and a reader
    /// who wants two levels can ask twice.
    static let detailStepsPerGesture = 1

    /// A wheel has no phases, so "one gesture" has to be inferred from the
    /// quiet between events.  A deliberate notch-and-look is a fifth of a
    /// second apart at least; a spin is thirty milliseconds.  This tells them
    /// apart without asking the reader to lift anything.
    static let wheelGestureGap: TimeInterval = 0.2

    /// Travel per step, in whatever unit the device reports.
    static func stepThreshold(_ intent: Intent, precise: Bool) -> CGFloat {
        guard precise else { return wheelStepLines }
        switch intent {
        case .textSize: return textSizeStepPoints
        case .structuralDetail: return detailStepPoints
        }
    }

    /// What one event adds to the gesture's travel.
    ///
    /// Precise deltas are already points and are taken as they come.  Coarse
    /// deltas are lines with macOS's acceleration curve baked in, and that
    /// curve is the enemy of a detent, so it is thrown away.
    static func contribution(deltaY: CGFloat, precise: Bool) -> CGFloat {
        guard !precise else { return deltaY }
        return min(max(deltaY, -maximumWheelLinesPerEvent), maximumWheelLinesPerEvent)
    }

    /// Whether a gesture that has already fired `spent` steps may fire more.
    static func allowsFurtherSteps(_ intent: Intent, spent: Int) -> Bool {
        switch intent {
        case .textSize: return true
        case .structuralDetail: return abs(spent) < detailStepsPerGesture
        }
    }

    /// The steps `accumulated` travel has earned, capped by what this gesture
    /// has left to spend.  Positive is toward more: bigger text, more detail.
    ///
    /// Sign follows `scrollingDeltaY` untouched, which AppKit has already
    /// flipped for the scroll-direction preference — so the direction that
    /// scrolls toward the top of the document is the direction that zooms in,
    /// whichever way the reader has their trackpad set up.
    static func steps(
        _ intent: Intent,
        accumulated: CGFloat,
        spent: Int,
        precise: Bool
    ) -> Int {
        let threshold = stepThreshold(intent, precise: precise)
        guard threshold > 0, allowsFurtherSteps(intent, spent: spent) else { return 0 }
        let earned = Int(accumulated / threshold)
        guard earned != 0 else { return 0 }
        switch intent {
        case .textSize:
            return earned
        case .structuralDetail:
            // One event can cross the threshold twice over; it still only
            // buys the one step the gesture is allowed.
            let remaining = detailStepsPerGesture - abs(spent)
            return max(-remaining, min(remaining, earned))
        }
    }

    /// Whether an event this far from the last one starts a fresh gesture.
    /// Only a coarse wheel has to ask — a trackpad says so in its phases.
    static func startsNewWheelGesture(since elapsed: TimeInterval) -> Bool {
        elapsed >= wheelGestureGap
    }
}

// MARK: - Coordinator

/// Turns ⌘-scroll and ⌥-scroll over the document surface into text-size and
/// structural-detail steps.
///
/// What it needs from the window arrives as `Host` rather than a
/// back-reference, so the detent can be exercised without a document behind
/// it.  It renders nothing and animates nothing itself: both scales are
/// existing commands with their own transitions, and this only decides *when*
/// to ask for one.
@MainActor
final class ScrollZoomCoordinator: ScrollGestureHandler {
    struct Host {
        /// Step the reading text size — the path pinch-to-zoom already takes,
        /// so a mouse lands on exactly the same fifteen stops.
        var stepTextSize: (Int) -> Void
        /// Step the structural detail level — the path `.zoomIn` / `.zoomOut`
        /// take, so the gesture and the chord cannot drift apart.
        var stepDetail: (Int) -> Void
        /// The detent under the fingers when a detail level lands.  Structural
        /// detail is the one scale where a step is a whole new document, and
        /// the same `.alignment` tap the presentation rail uses is what says
        /// so before the relayout is visible.
        var performHapticFeedback: () -> Void = {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    private let host: Host
    private var intent: ScrollZoomPolicy.Intent?
    private var accumulated: CGFloat = 0
    private var spent = 0
    private var lastTimestamp: TimeInterval = -.greatestFiniteMagnitude

    init(host: Host) {
        self.host = host
    }

    /// Visible for tests: the travel banked toward the next step.
    var accumulatedTravelForTesting: CGFloat { accumulated }
    /// Visible for tests: steps this gesture has already fired.
    var stepsFiredForTesting: Int { spent }

    /// The single entry point from the chain.  Returns `true` when a zoom has
    /// taken the event, in which case the scroll view must not see it.
    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        // No modifier, no claim, and not one branch of thinking about it: an
        // unmodified scroll is the overwhelmingly common case and must cost
        // nothing on its way past.
        guard let intent = ScrollZoomPolicy.intent(for: ScrollGestureModifiers.held(in: event))
        else {
            self.intent = nil
            return false
        }

        let precise = event.hasPreciseScrollingDeltas
        if intent != self.intent { beginGesture(intent, at: event.timestamp) }
        // A trackpad announces the gesture; a wheel is only ever inferred from
        // the quiet before it.
        if precise {
            if event.phase == .began { beginGesture(intent, at: event.timestamp) }
        } else if ScrollZoomPolicy.startsNewWheelGesture(since: event.timestamp - lastTimestamp) {
            beginGesture(intent, at: event.timestamp)
        }
        lastTimestamp = event.timestamp

        // The momentum tail is the trackpad coasting, not the reader zooming.
        // It is still swallowed: handing it back would scroll the page out
        // from under a size the reader just settled on.
        guard event.momentumPhase.isEmpty else { return true }

        if event.phase == .ended || event.phase == .cancelled {
            endGesture()
            return true
        }

        accumulated += ScrollZoomPolicy.contribution(
            deltaY: event.scrollingDeltaY, precise: precise
        )
        let steps = ScrollZoomPolicy.steps(
            intent, accumulated: accumulated, spent: spent, precise: precise
        )
        guard steps != 0 else { return true }
        accumulated -= CGFloat(steps) * ScrollZoomPolicy.stepThreshold(intent, precise: precise)
        spent += steps

        switch intent {
        case .textSize:
            host.stepTextSize(steps)
        case .structuralDetail:
            host.stepDetail(steps)
            host.performHapticFeedback()
        }
        return true
    }

    private func beginGesture(_ intent: ScrollZoomPolicy.Intent, at timestamp: TimeInterval) {
        self.intent = intent
        accumulated = 0
        spent = 0
        lastTimestamp = timestamp
    }

    /// The fingers are up.  Nothing is banked across gestures: travel that did
    /// not earn a step was the reader changing their mind, and carrying it
    /// forward would make the *next* gesture fire early for no visible reason.
    private func endGesture() {
        intent = nil
        accumulated = 0
        spent = 0
    }
}
