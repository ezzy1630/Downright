import AppKit
import MarkdownRender
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct HistorySwipeTests {

    // MARK: - Fixtures

    private func scroll(
        deltaX: CGFloat = 0,
        deltaY: CGFloat = 0,
        phase: CGScrollPhase? = .changed,
        momentum: CGMomentumScrollPhase = CGMomentumScrollPhase.none,
        precise: Bool = true,
        modifiers: NSEvent.ModifierFlags = .shift,
        at seconds: TimeInterval = 0
    ) throws -> NSEvent {
        try SyntheticScroll.event(
            deltaX: deltaX, deltaY: deltaY, phase: phase, momentum: momentum,
            precise: precise, modifiers: modifiers, at: seconds
        )
    }

    private func sizedController(reduceMotion: Bool) -> DocumentWindowController {
        let controller = DocumentWindowController()
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.layoutSubtreeIfNeeded()
        // Always overridden, in both directions: a runner that inherits the
        // machine's Reduce Motion setting would otherwise silently run the
        // wrong state machine.
        controller.activeStyleSheet = StyleSheet(
            theme: controller.activeStyleSheet.theme,
            appearance: controller.window?.effectiveAppearance ?? NSAppearance.currentDrawing(),
            reduceMotionOverride: reduceMotion
        )
        return controller
    }

    /// A coordinator over real panes with the trip recorded rather than taken.
    private final class Recorder {
        var moves: [HistorySwipePolicy.Direction] = []
        var haptics = 0
        var canGoBack = true
        var canGoForward = true
    }

    private func swipe(
        over controller: DocumentWindowController,
        recording recorder: Recorder
    ) -> HistorySwipeCoordinator {
        HistorySwipeCoordinator(host: HistorySwipeCoordinator.Host(
            panes: { controller.documentPanes },
            styleSheet: { controller.activeStyleSheet },
            canMove: { direction in
                switch direction {
                case .back: return recorder.canGoBack
                case .forward: return recorder.canGoForward
                }
            },
            move: { recorder.moves.append($0) },
            performHapticFeedback: { recorder.haptics += 1 }
        ))
    }

    // MARK: - Policy

    @Test
    func onlyExactlyShiftSpellsThisGesture() {
        #expect(HistorySwipePolicy.isSpelledCorrectly([.shift]))
        // Nothing held is the Document↔Source swipe; ⇧⌘ is not a gesture at
        // all and must not half-start this one.
        #expect(!HistorySwipePolicy.isSpelledCorrectly([]))
        #expect(!HistorySwipePolicy.isSpelledCorrectly([.shift, .command]))
        #expect(!HistorySwipePolicy.isSpelledCorrectly([.command]))
        #expect(!HistorySwipePolicy.isSpelledCorrectly([.option]))
    }

    @Test
    func theSwipeIsClaimedOnlyWhenItIsDecidedlySideways() {
        #expect(HistorySwipePolicy.claim(horizontal: 6, vertical: 2) == .undecided)
        #expect(HistorySwipePolicy.claim(horizontal: 13, vertical: 0) == .undecided)
        #expect(HistorySwipePolicy.claim(horizontal: 14, vertical: 0) == .swipe)
        #expect(HistorySwipePolicy.claim(horizontal: -40, vertical: 10) == .swipe)
        // A diagonal is a scroll. This one is stricter than the presentation
        // swipe's, because ⇧ is held for plenty of reasons that are not this.
        #expect(HistorySwipePolicy.claim(horizontal: 30, vertical: 25) == .scroll)
        #expect(HistorySwipePolicy.claim(horizontal: 0, vertical: -20) == .scroll)
        #expect(HistorySwipePolicy.claim(horizontal: 8, vertical: 9) == .undecided)
    }

    @Test
    func theContentFollowsTheFingersAndBackIsWhatWasOnTheLeft() {
        // Safari's direction exactly: push the page right, uncovering what
        // sits to its left, and you go back.
        #expect(HistorySwipePolicy.direction(translation: 40) == .back)
        #expect(HistorySwipePolicy.direction(translation: -40) == .forward)
        #expect(HistorySwipePolicy.direction(translation: 0) == nil)
    }

    @Test
    func commitDistanceStaysReachableAtEveryPaneWidth() {
        #expect(HistorySwipePolicy.commitDistance(paneWidth: 120)
            == HistorySwipePolicy.minimumCommitDistance)
        #expect(HistorySwipePolicy.commitDistance(paneWidth: 2400)
            == HistorySwipePolicy.maximumCommitDistance)
        #expect(HistorySwipePolicy.commitDistance(paneWidth: 400) == 80)
        // A trip is cheaper to undo than a presentation switch, so it asks for
        // a little less travel.
        #expect(HistorySwipePolicy.commitDistance(paneWidth: 900)
            < PresentationSwipePolicy.commitDistance(paneWidth: 900))
    }

    @Test
    func aShortSwipeCommitsOnlyWhenItIsStillTravelling() {
        let width: CGFloat = 900
        let distance = HistorySwipePolicy.commitDistance(paneWidth: width)

        #expect(HistorySwipePolicy.shouldCommit(
            translation: distance, velocity: 0, paneWidth: width))
        #expect(!HistorySwipePolicy.shouldCommit(
            translation: distance - 1, velocity: 0, paneWidth: width))
        #expect(HistorySwipePolicy.shouldCommit(
            translation: 20, velocity: 600, paneWidth: width))
        // Pulled back at the last moment: however fast the hand was moving,
        // reversing means "put it back".
        #expect(!HistorySwipePolicy.shouldCommit(
            translation: 20, velocity: -600, paneWidth: width))
        #expect(!HistorySwipePolicy.shouldCommit(
            translation: 0, velocity: 900, paneWidth: width))
    }

    @Test
    func thePageGivesAgainstTheFingersAndNeverArrives() {
        let limit = HistorySwipePolicy.maximumGive
        #expect(HistorySwipePolicy.give(0) == 0)
        #expect(HistorySwipePolicy.give(8) > 1)
        #expect(HistorySwipePolicy.give(-40) < 0)
        #expect(abs(HistorySwipePolicy.give(40)) < abs(HistorySwipePolicy.give(140)))
        #expect(abs(HistorySwipePolicy.give(10_000)) < limit)
        #expect(abs(HistorySwipePolicy.give(10_000)) > limit * 0.99)
    }

    // MARK: - Coordinator

    @Test
    func swipingRightGoesBackAndSwipingLeftGoesForward() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)

        #expect(!gesture.handle(try scroll(phase: .began, at: 0)))
        // Still ambiguous, so the scroll view keeps this one.
        #expect(!gesture.handle(try scroll(deltaX: 8, at: 0.008)))
        // Past the intent threshold: the swipe takes over.
        #expect(gesture.handle(try scroll(deltaX: 10, at: 0.016)))
        #expect(gesture.isTracking)
        #expect(gesture.trackedDirectionForTesting == .back)

        for step in 3...12 {
            #expect(gesture.handle(try scroll(deltaX: 24, at: TimeInterval(step) * 0.008)))
        }
        #expect(gesture.handle(try scroll(phase: .ended, at: 0.12)))
        #expect(recorder.moves == [.back])
        #expect(!gesture.isTracking)

        _ = gesture.handle(try scroll(phase: .began, at: 1))
        for step in 1...12 {
            #expect(gesture.handle(try scroll(deltaX: -24, at: 1 + TimeInterval(step) * 0.008)))
        }
        #expect(gesture.handle(try scroll(phase: .ended, at: 1.12)))
        #expect(recorder.moves == [.back, .forward])
    }

    @Test
    func withoutShiftTheGestureIsNotEvenConsidered() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)

        #expect(!gesture.handle(try scroll(phase: .began, modifiers: [], at: 0)))
        for step in 1...12 {
            let event = try scroll(deltaX: 24, modifiers: [], at: TimeInterval(step) * 0.008)
            #expect(!gesture.handle(event))
        }
        #expect(!gesture.handle(try scroll(phase: .ended, modifiers: [], at: 0.12)))
        #expect(recorder.moves.isEmpty)
        #expect(!gesture.isTracking)
    }

    @Test
    func aSwipeIntoAnEmptyStackNeverCatches() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let recorder = Recorder()
        recorder.canGoBack = false
        let gesture = swipe(over: controller, recording: recorder)

        _ = gesture.handle(try scroll(phase: .began, at: 0))
        // A page that gives and then does nothing reads as a bug, so the
        // gesture is handed straight back and the surface just scrolls.
        for step in 1...12 {
            #expect(!gesture.handle(try scroll(deltaX: 24, at: TimeInterval(step) * 0.008)))
        }
        #expect(!gesture.handle(try scroll(phase: .ended, at: 0.12)))
        #expect(recorder.moves.isEmpty)
        #expect(!gesture.isTracking)

        // …and the other way is still open, so the reader is not locked out of
        // the direction that does have somewhere to go.
        _ = gesture.handle(try scroll(phase: .began, at: 1))
        for step in 1...12 {
            #expect(gesture.handle(try scroll(deltaX: -24, at: 1 + TimeInterval(step) * 0.008)))
        }
        #expect(gesture.handle(try scroll(phase: .ended, at: 1.12)))
        #expect(recorder.moves == [.forward])
    }

    @Test
    func readingWithShiftHeldIsStillJustReading() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)

        #expect(!gesture.handle(try scroll(phase: .began, at: 0)))
        for step in 1...12 {
            let event = try scroll(deltaX: -1, deltaY: -30, at: TimeInterval(step) * 0.008)
            #expect(!gesture.handle(event))
        }
        #expect(!gesture.handle(try scroll(phase: .ended, at: 0.12)))
        #expect(recorder.moves.isEmpty)
    }

    @Test
    func aWheelIsLeftAlone() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)

        // ⇧-wheel is a single unphased notch: no travel to measure and no
        // release to commit on. Back and Forward stay on the keyboard there.
        for tick in 0...10 {
            let event = try scroll(
                deltaX: -10, phase: nil, precise: false, at: TimeInterval(tick) * 0.03
            )
            #expect(!gesture.handle(event))
        }
        #expect(recorder.moves.isEmpty)
    }

    @Test
    func aFlickCommitsAndASlowNudgeDoesNot() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)

        // Short, fast, still going: the flick.
        _ = gesture.handle(try scroll(phase: .began, at: 0))
        #expect(gesture.handle(try scroll(deltaX: 16, at: 0.008)))
        #expect(gesture.handle(try scroll(deltaX: 20, at: 0.016)))
        #expect(gesture.handle(try scroll(phase: .ended, at: 0.02)))
        #expect(recorder.moves == [.back])

        // The same distance, released slowly: the reader thought better of it.
        _ = gesture.handle(try scroll(phase: .began, at: 1))
        #expect(gesture.handle(try scroll(deltaX: 16, at: 1.008)))
        #expect(gesture.handle(try scroll(deltaX: 4, at: 1.5)))
        #expect(gesture.handle(try scroll(phase: .ended, at: 2)))
        #expect(recorder.moves == [.back])
    }

    @Test
    func theCoastAfterAFlickIsSwallowedAndBuysNothing() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)

        _ = gesture.handle(try scroll(phase: .began, at: 0))
        #expect(gesture.handle(try scroll(deltaX: 16, at: 0.008)))
        #expect(gesture.handle(try scroll(deltaX: 20, at: 0.016)))
        #expect(gesture.handle(try scroll(phase: .ended, at: 0.02)))
        #expect(recorder.moves == [.back])

        // Hundreds of points of coast, all of it belonging to a gesture that
        // has already been answered. It must not travel again, and it must not
        // fall through and scroll the document under the trip either.
        for tick in 1...30 {
            let event = try scroll(
                deltaX: 60, phase: nil, momentum: .continuous,
                at: 0.02 + TimeInterval(tick) * 0.008
            )
            #expect(gesture.handle(event))
        }
        #expect(recorder.moves == [.back])
        let tail = try scroll(phase: nil, momentum: .end, at: 0.3)
        #expect(gesture.handle(tail))
        // With the coast over, the next scroll belongs to the scroll view.
        #expect(!gesture.handle(try scroll(
            deltaY: -20, phase: nil, momentum: .continuous, at: 0.31)))
        #expect(recorder.moves == [.back])
    }

    @Test
    func theCommitPointIsADetentTheHandCanFeelExactlyOncePerCrossing() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)
        let distance = HistorySwipePolicy.commitDistance(
            paneWidth: controller.primaryContainer.bounds.width
        )

        _ = gesture.handle(try scroll(phase: .began, at: 0))
        #expect(gesture.handle(try scroll(deltaX: 20, at: 0.008)))
        #expect(recorder.haptics == 0)
        #expect(gesture.handle(try scroll(deltaX: distance, at: 0.016)))
        #expect(recorder.haptics == 1)
        // Further out is still the same side of the line.
        #expect(gesture.handle(try scroll(deltaX: 200, at: 0.024)))
        #expect(recorder.haptics == 1)
        // Back under it re-arms, so hovering at the threshold feels like a
        // line rather than a burst.
        #expect(gesture.handle(try scroll(deltaX: -300, at: 0.032)))
        #expect(recorder.haptics == 1)
        #expect(gesture.handle(try scroll(deltaX: 300, at: 0.04)))
        #expect(recorder.haptics == 2)
    }

    // MARK: - The give

    @Test
    func thePageTravelsUnderTheFingersAndIsHandedBackBeforeTheTrip() throws {
        let controller = sizedController(reduceMotion: false)
        defer { controller.close() }
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)
        let paneSubviews = controller.primaryContainer.subviews.count

        _ = gesture.handle(try scroll(phase: .began, at: 0))
        #expect(gesture.handle(try scroll(deltaX: 40, at: 0.008)))
        let scrollLayer = try #require(controller.primaryContainer.scrollView.layer)
        #expect(scrollLayer.transform.m41 > 0)
        #expect(controller.primaryContainer.layer?.masksToBounds == true)
        // Nothing was rendered to get here: the whole gesture so far is one
        // layer translation, and the destination is not visited until release.
        #expect(controller.primaryContainer.subviews.count == paneSubviews)
        #expect(recorder.moves.isEmpty)

        for step in 2...10 {
            #expect(gesture.handle(try scroll(deltaX: 24, at: TimeInterval(step) * 0.008)))
        }
        #expect(gesture.handle(try scroll(phase: .ended, at: 0.1)))
        // The destination scroll animates from the pane's resting frame, so
        // the give is surrendered before the trip, not after.
        #expect(scrollLayer.transform.m41 == 0)
        #expect(recorder.moves == [.back])
        #expect(!gesture.isTracking)
        #expect(!gesture.isSettling)
    }

    @Test
    func reduceMotionTakesTheTripWithoutMovingThePage() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)

        _ = gesture.handle(try scroll(phase: .began, at: 0))
        #expect(gesture.handle(try scroll(deltaX: 40, at: 0.008)))
        #expect(gesture.isTracking)
        // No give was taken, so there is no transform and no spring to run —
        // and the gesture still does its job.
        #expect((controller.primaryContainer.scrollView.layer?.transform.m41 ?? 0) == 0)
        for step in 2...10 {
            #expect(gesture.handle(try scroll(deltaX: 24, at: TimeInterval(step) * 0.008)))
        }
        #expect(gesture.handle(try scroll(phase: .ended, at: 0.1)))
        #expect(recorder.moves == [.back])
        #expect(!gesture.isSettling)
    }

    @Test
    func aSwipeInSplitViewCarriesBothPanes() throws {
        let controller = sizedController(reduceMotion: false)
        defer {
            controller.historySwipe.cancelInFlight()
            controller.close()
        }
        controller.toggleSplitView()
        controller.window?.layoutIfNeeded()
        let split = try #require(controller.splitContainer)
        #expect(controller.documentPanes.count == 2)
        let recorder = Recorder()
        let gesture = swipe(over: controller, recording: recorder)

        _ = gesture.handle(try scroll(phase: .began, at: 0))
        #expect(gesture.handle(try scroll(deltaX: 40, at: 0.008)))
        // Where the reader is in the document is the window's, not one pane's,
        // so both surfaces travel.
        #expect((controller.primaryContainer.scrollView.layer?.transform.m41 ?? 0) > 0)
        #expect((split.scrollView.layer?.transform.m41 ?? 0) > 0)

        gesture.cancelInFlight()
        #expect(controller.primaryContainer.scrollView.layer?.transform.m41 == 0)
        #expect(split.scrollView.layer?.transform.m41 == 0)
    }

    @Test
    func aResizeMidSwipeGroundsItRatherThanHoldingAStaleTransform() throws {
        let controller = sizedController(reduceMotion: false)
        defer { controller.close() }
        controller.recordJump(to: 40, label: "Test")
        #expect(controller.jumpHistory.canGoBack)

        _ = controller.historySwipe.handle(try scroll(phase: .began, at: 0))
        #expect(controller.historySwipe.handle(try scroll(deltaX: 40, at: 0.008)))
        #expect(controller.historySwipe.isTracking)

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        #expect(controller.primaryContainer.scrollView.layer?.transform.m41 == 0)
        #expect(!controller.historySwipe.isTracking)
        #expect(!controller.historySwipe.isSettling)
        // Grounded, not committed: the reader never released.
        #expect(controller.jumpHistory.canGoBack)
    }

    // MARK: - Wired into the window

    @Test
    func shiftSwipingRightMovesBackThroughRealJumpHistory() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        controller.recordJump(to: 40, label: "Heading")
        #expect(controller.jumpHistory.canGoBack)
        #expect(!controller.jumpHistory.canGoForward)

        _ = controller.documentScrollGestures.handle(try scroll(phase: .began, at: 0))
        for step in 1...12 {
            let event = try scroll(deltaX: 24, at: TimeInterval(step) * 0.008)
            #expect(controller.documentScrollGestures.handle(event))
        }
        #expect(controller.documentScrollGestures.handle(try scroll(phase: .ended, at: 0.12)))

        #expect(!controller.jumpHistory.canGoBack)
        #expect(controller.jumpHistory.canGoForward)
        // The Document↔Source swipe shares this axis and must not have fired.
        #expect(controller.presentationSegment == 0)
    }

    @Test
    func shiftSwipingWithNoHistoryChangesNothingAtAll() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        #expect(!controller.jumpHistory.canGoBack)

        _ = controller.documentScrollGestures.handle(try scroll(phase: .began, at: 0))
        for step in 1...12 {
            let event = try scroll(deltaX: -24, at: TimeInterval(step) * 0.008)
            // Nowhere to go forward to either, so nothing claims it — and in
            // particular the bare swipe underneath must not, or ⇧ would switch
            // presentation whenever history was empty.
            #expect(!controller.documentScrollGestures.handle(event))
        }
        _ = controller.documentScrollGestures.handle(try scroll(phase: .ended, at: 0.12))

        #expect(controller.presentationSegment == 0)
        #expect(!controller.presentationSwipe.isTracking)
        #expect(!controller.historySwipe.isTracking)
    }
}
