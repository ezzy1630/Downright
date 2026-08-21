import AppKit
import MarkdownRender
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct PresentationSwipeTests {

    // MARK: - Synthetic trackpad events

    /// A continuous scroll event with real phases, so the coordinator is
    /// exercised through the same `NSEvent` decoding the trackpad drives.
    private func scroll(
        deltaX: CGFloat = 0,
        deltaY: CGFloat = 0,
        phase: CGScrollPhase? = .changed,
        momentum: CGMomentumScrollPhase = CGMomentumScrollPhase.none,
        precise: Bool = true,
        at seconds: TimeInterval = 0
    ) throws -> NSEvent {
        let event = try #require(CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ))
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(deltaY))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(deltaX))
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue)
        )
        event.timestamp = UInt64(max(0, seconds) * 1_000_000_000)
        return try #require(NSEvent(cgEvent: event))
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

    @Test
    func syntheticScrollEventsCarryTrackpadPhasesAndPreciseDeltas() throws {
        let event = try scroll(deltaX: -20, deltaY: 3, phase: .began, at: 1)
        #expect(event.hasPreciseScrollingDeltas)
        #expect(event.phase == .began)
        #expect(event.momentumPhase.isEmpty)
        #expect(abs(event.scrollingDeltaX - -20) < 0.001)
        #expect(abs(event.scrollingDeltaY - 3) < 0.001)

        let ended = try scroll(phase: .ended)
        #expect(ended.phase == .ended)

        let coasting = try scroll(deltaX: -8, phase: nil, momentum: .continuous)
        #expect(!coasting.momentumPhase.isEmpty)
    }

    // MARK: - Policy

    @Test
    func swipeIsClaimedOnlyWhenItIsDecidedlySideways() {
        // Nothing has happened yet: the scroll view keeps the event, so
        // vertical scrolling never waits on this decision.
        #expect(PresentationSwipePolicy.claim(horizontal: 4, vertical: 2) == .undecided)
        #expect(PresentationSwipePolicy.claim(horizontal: -11, vertical: 0) == .undecided)
        // Sideways and past the threshold.
        #expect(PresentationSwipePolicy.claim(horizontal: -12, vertical: 0) == .swipe)
        #expect(PresentationSwipePolicy.claim(horizontal: 30, vertical: 20) == .swipe)
        // A diagonal is a scroll: sideways travel that has not clearly beaten
        // the vertical is the far commoner intent, and once the page has moved
        // that far the gesture stops being re-litigated.
        #expect(PresentationSwipePolicy.claim(horizontal: 30, vertical: 25) == .scroll)
        #expect(PresentationSwipePolicy.claim(horizontal: 10, vertical: 40) == .scroll)
        #expect(PresentationSwipePolicy.claim(horizontal: 0, vertical: -12) == .scroll)
        // Below both thresholds nothing has been decided yet either way.
        #expect(PresentationSwipePolicy.claim(horizontal: 9, vertical: 8) == .undecided)
    }

    @Test
    func contentFollowsTheFingersOntoTheRail() {
        // Pushing the page left uncovers Source, which sits right on the rail.
        #expect(PresentationSwipePolicy.targetSegment(translation: -40) == 1)
        #expect(PresentationSwipePolicy.targetSegment(translation: 40) == 0)
        #expect(PresentationSwipePolicy.targetSegment(translation: 0) == nil)
    }

    @Test
    func commitDistanceStaysReachableAtEveryPaneWidth() {
        // A narrow split pane must not switch on a twitch…
        #expect(PresentationSwipePolicy.commitDistance(paneWidth: 120)
            == PresentationSwipePolicy.minimumCommitDistance)
        // …and a wide window must not ask for a swipe past the trackpad.
        #expect(PresentationSwipePolicy.commitDistance(paneWidth: 2400)
            == PresentationSwipePolicy.maximumCommitDistance)
        #expect(PresentationSwipePolicy.commitDistance(paneWidth: 400) == 100)
    }

    @Test
    func railFillsExactlyWhereReleasingWouldCommit() {
        let width: CGFloat = 900
        let distance = PresentationSwipePolicy.commitDistance(paneWidth: width)
        #expect(PresentationSwipePolicy.railProgress(translation: 0, paneWidth: width) == 0)
        #expect(abs(
            PresentationSwipePolicy.railProgress(translation: -distance / 2, paneWidth: width) - 0.5
        ) < 0.001)
        #expect(PresentationSwipePolicy.railProgress(translation: -distance, paneWidth: width) == 1)
        // Past the commit point the bar has nowhere further to go.
        #expect(PresentationSwipePolicy.railProgress(
            translation: -width, paneWidth: width) == 1)
    }

    @Test
    func railPositionRunsFromTheModeYouAreInTowardTheOneYouAreHeadingFor() {
        #expect(PresentationSwipePolicy.railPosition(progress: 0, origin: 0, target: 1) == 0)
        #expect(PresentationSwipePolicy.railPosition(progress: 0.5, origin: 0, target: 1) == 0.5)
        #expect(PresentationSwipePolicy.railPosition(progress: 1, origin: 0, target: 1) == 1)
        // Coming back the other way the bar travels toward Document.
        #expect(PresentationSwipePolicy.railPosition(progress: 0.25, origin: 1, target: 0) == 0.75)
        #expect(PresentationSwipePolicy.railPosition(progress: 4, origin: 1, target: 0) == 0)
    }

    @Test
    func aShortSwipeCommitsOnlyWhenItIsStillTravelling() {
        let width: CGFloat = 900
        let distance = PresentationSwipePolicy.commitDistance(paneWidth: width)

        #expect(PresentationSwipePolicy.shouldCommit(
            translation: -distance, velocity: 0, paneWidth: width))
        #expect(!PresentationSwipePolicy.shouldCommit(
            translation: -distance + 1, velocity: 0, paneWidth: width))
        // The flick: short, but leaving fast in the direction it was going.
        #expect(PresentationSwipePolicy.shouldCommit(
            translation: -20, velocity: -600, paneWidth: width))
        // Pulled back at the last moment. However fast the hand was moving,
        // reversing means "put it back".
        #expect(!PresentationSwipePolicy.shouldCommit(
            translation: -20, velocity: 600, paneWidth: width))
        #expect(!PresentationSwipePolicy.shouldCommit(
            translation: 0, velocity: -900, paneWidth: width))
    }

    @Test
    func thePageGivesAgainstTheFingersAndNeverArrives() {
        let limit = PresentationSwipePolicy.maximumGive
        #expect(PresentationSwipePolicy.give(0) == 0)
        // It answers immediately…
        #expect(PresentationSwipePolicy.give(-8) < -1)
        // …keeps its sign…
        #expect(PresentationSwipePolicy.give(40) > 0)
        #expect(PresentationSwipePolicy.give(-40) < 0)
        // …grows monotonically…
        #expect(abs(PresentationSwipePolicy.give(-40)) < abs(PresentationSwipePolicy.give(-140)))
        // …and asymptotes rather than hitting a wall the hand can feel.
        #expect(abs(PresentationSwipePolicy.give(-10_000)) < limit)
        #expect(abs(PresentationSwipePolicy.give(-10_000)) > limit * 0.99)
    }

    // MARK: - Rail

    @Test
    func railTracksTheSwipeAndLandsWithoutSwitchingTwice() {
        var changes: [Int] = []
        var haptics = 0
        let control = ToolbarPresentationControl(
            onChange: { changes.append($0) },
            performHapticFeedback: { haptics += 1 }
        )
        control.frame = NSRect(x: 0, y: 0, width: 184, height: 34)
        control.layoutSubtreeIfNeeded()
        let documentCenter = control.selectedSegmentCenterForTesting

        control.trackSwipe(position: 0.25)
        #expect(control.selectionIndicatorFrameForTesting.midX > documentCenter)
        #expect(control.selectedSegment == 0)
        #expect(haptics == 0)

        control.trackSwipe(position: 1)
        #expect(haptics == 1)
        // The document has already switched behind the transition; the rail
        // must not switch it a second time on the way past.
        #expect(changes.isEmpty)

        control.settleSwipe(at: 1)
        #expect(control.selectedSegment == 1)
        #expect(changes.isEmpty)
        #expect(abs(
            control.selectionIndicatorFrameForTesting.midX
                - control.selectedSegmentCenterForTesting
        ) < 0.01)
    }

    @Test
    func railReturnsToWhereItStartedWhenTheSwipeIsAbandoned() {
        let control = ToolbarPresentationControl(onChange: { _ in })
        control.frame = NSRect(x: 0, y: 0, width: 184, height: 34)
        control.layoutSubtreeIfNeeded()
        let documentCenter = control.selectedSegmentCenterForTesting

        control.trackSwipe(position: 0.8)
        #expect(control.selectionIndicatorFrameForTesting.midX > documentCenter)

        control.settleSwipe(at: 0)
        #expect(control.selectedSegment == 0)
        #expect(abs(control.selectionIndicatorFrameForTesting.midX - documentCenter) < 0.01)
    }

    // MARK: - Coordinator

    @Test
    func scrollingThePageIsNeverTakenForASwipe() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }

        #expect(!controller.presentationSwipe.handle(try scroll(phase: .began, at: 0)))
        for step in 1...12 {
            let event = try scroll(deltaX: -1, deltaY: -30, at: TimeInterval(step) * 0.008)
            #expect(!controller.presentationSwipe.handle(event))
        }
        #expect(!controller.presentationSwipe.handle(try scroll(phase: .ended, at: 0.2)))
        #expect(controller.presentationSegment == 0)
        #expect(!controller.presentationSwipe.isTracking)
    }

    @Test
    func aWheelWithoutPreciseDeltasIsLeftToTheScrollView() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }

        let event = try scroll(deltaX: -80, phase: .changed, precise: false)
        #expect(!controller.presentationSwipe.handle(event))
        #expect(controller.presentationSegment == 0)
    }

    @Test
    func swipingLeftClaimsTheGestureAndLandsOnSource() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let rail = try #require(controller.toolbarPresentationControl)

        #expect(!controller.presentationSwipe.handle(try scroll(phase: .began, at: 0)))
        // Still ambiguous, so the scroll view keeps this one.
        #expect(!controller.presentationSwipe.handle(try scroll(deltaX: -6, at: 0.008)))
        // Past the intent threshold: the swipe takes over.
        #expect(controller.presentationSwipe.handle(try scroll(deltaX: -10, at: 0.016)))
        #expect(controller.presentationSwipe.isTracking)
        #expect(rail.selectionIndicatorFrameForTesting.midX
            > rail.selectedSegmentCenterForTesting)

        for step in 3...12 {
            let event = try scroll(deltaX: -20, at: TimeInterval(step) * 0.008)
            #expect(controller.presentationSwipe.handle(event))
        }
        #expect(controller.presentationSwipe.handle(try scroll(phase: .ended, at: 0.12)))
        #expect(controller.presentationSegment == 1)
        #expect(rail.selectedSegment == 1)
        #expect(!controller.presentationSwipe.isTracking)
    }

    @Test
    func abandonedSwipeLeavesTheDocumentWhereItWas() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        let rail = try #require(controller.toolbarPresentationControl)

        _ = controller.presentationSwipe.handle(try scroll(phase: .began, at: 0))
        #expect(controller.presentationSwipe.handle(try scroll(deltaX: -16, at: 0.008)))
        // Barely moved and released slowly: not enough to commit.
        #expect(controller.presentationSwipe.handle(try scroll(deltaX: -4, at: 0.4)))
        #expect(controller.presentationSwipe.handle(try scroll(phase: .ended, at: 0.8)))

        #expect(controller.presentationSegment == 0)
        // The rail is back on Document. Where the indicator has physically
        // reached is the spring's business and is covered on a windowless
        // control above, which settles rather than flies.
        #expect(rail.selectedSegment == 0)
        #expect(!controller.presentationSwipe.isTracking)
    }

    @Test
    func swipingTowardTheModeYouAreAlreadyInIsNotClaimed() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }

        _ = controller.presentationSwipe.handle(try scroll(phase: .began, at: 0))
        // Document is already showing, and nothing sits to the left of it.
        #expect(!controller.presentationSwipe.handle(try scroll(deltaX: 40, at: 0.008)))
        #expect(!controller.presentationSwipe.isTracking)
        #expect(controller.presentationSegment == 0)
    }

    @Test
    func swipingBackFromSourceReturnsToTheDocument() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        controller.changePresentation(to: 1)
        #expect(controller.presentationSegment == 1)

        _ = controller.presentationSwipe.handle(try scroll(phase: .began, at: 0))
        for step in 1...10 {
            let event = try scroll(deltaX: 24, at: TimeInterval(step) * 0.008)
            #expect(controller.presentationSwipe.handle(event))
        }
        #expect(controller.presentationSwipe.handle(try scroll(phase: .ended, at: 0.1)))
        #expect(controller.presentationSegment == 0)
    }

    @Test
    func theGivePathRendersNothingUntilTheFingersLift() throws {
        // Priced out of the drag on purpose. This is the path a long document
        // takes, and its whole promise is that it builds nothing — so the test
        // must not depend on how long the fixture happens to be.
        PresentationSwitchBudget.resetCalibrationForTesting(millisecondsPerLine: 100)
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }

        let controller = sizedController(reduceMotion: false)
        defer {
            controller.presentationSwipe.cancelInFlight()
            controller.close()
        }
        let paneSubviews = controller.primaryContainer.subviews.count

        _ = controller.presentationSwipe.handle(try scroll(phase: .began, at: 0))
        #expect(controller.presentationSwipe.handle(try scroll(deltaX: -40, at: 0.008)))
        // The gesture asks for the backing store itself, so the layer only
        // exists once a swipe has actually caught.
        let scrollLayer = try #require(controller.primaryContainer.scrollView.layer)

        // Mid-gesture the document has not been rebuilt and no surface has
        // been added: the whole transition so far is one layer translation.
        #expect(controller.presentationSegment == 0)
        #expect(controller.primaryContainer.subviews.count == paneSubviews)
        #expect(scrollLayer.transform.m41 < 0)
        // …and it leans, rather than travelling: the give never promises the
        // page is really going anywhere.
        #expect(abs(scrollLayer.transform.m41) <= PresentationSwipePolicy.maximumGive)
        #expect(controller.primaryContainer.layer?.masksToBounds == true)

        controller.presentationSwipe.cancelInFlight()
        #expect(controller.presentationSegment == 0)
        #expect(scrollLayer.transform.m41 == 0)
    }

    @Test
    func theGivePutsThePageBackBeforeTheSwitchDraws() throws {
        PresentationSwitchBudget.resetCalibrationForTesting(millisecondsPerLine: 100)
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }
        let controller = sizedController(reduceMotion: false)
        defer { controller.close() }
        _ = controller.presentationSwipe.handle(try scroll(phase: .began, at: 0))
        for step in 1...10 {
            _ = controller.presentationSwipe.handle(
                try scroll(deltaX: -20, at: TimeInterval(step) * 0.008))
        }
        let scrollLayer = try #require(controller.primaryContainer.scrollView.layer)
        #expect(scrollLayer.transform.m41 < 0)
        #expect(controller.presentationSwipe.handle(try scroll(phase: .ended, at: 0.1)))

        // The mode change animates from the pane's resting frame, so the give
        // has to be surrendered before it runs, not after.
        #expect(scrollLayer.transform.m41 == 0)
        #expect(controller.presentationSegment == 1)
        #expect(!controller.presentationSwipe.isTracking)
        #expect(!controller.presentationSwipe.isSettling)
    }

    @Test
    func aSwipeInSplitViewCarriesBothPanes() throws {
        let controller = sizedController(reduceMotion: true)
        defer { controller.close() }
        controller.toggleSplitView()
        controller.window?.layoutIfNeeded()
        let split = try #require(controller.splitContainer)
        #expect(controller.documentPanes.count == 2)

        _ = controller.presentationSwipe.handle(try scroll(phase: .began, at: 0))
        for step in 1...10 {
            let event = try scroll(deltaX: -24, at: TimeInterval(step) * 0.008)
            #expect(controller.presentationSwipe.handle(event))
        }
        #expect(controller.presentationSwipe.handle(try scroll(phase: .ended, at: 0.1)))

        // The mode is the window's, not one pane's: both surfaces land in it.
        #expect(controller.primaryContainer.textView.sourceFocus != .none)
        #expect(split.textView.sourceFocus != .none)
    }

    @Test
    func aResizeMidSwipeGroundsItRatherThanFlyingStaleStills() throws {
        let controller = sizedController(reduceMotion: false)
        defer { controller.close() }

        _ = controller.presentationSwipe.handle(try scroll(phase: .began, at: 0))
        #expect(controller.presentationSwipe.handle(try scroll(deltaX: -40, at: 0.008)))
        #expect(controller.presentationSwipe.isTracking)

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        #expect(controller.presentationSegment == 0)
        #expect(controller.primaryContainer.scrollView.layer?.transform.m41 == 0)
        #expect(!controller.presentationSwipe.isTracking)
        #expect(!controller.presentationSwipe.isSettling)
    }
}
