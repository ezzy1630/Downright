import AppKit
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct ScrollZoomTests {

    // MARK: - Synthetic events

    private func scroll(
        deltaY: CGFloat = 0,
        deltaX: CGFloat = 0,
        phase: CGScrollPhase? = .changed,
        momentum: CGMomentumScrollPhase = CGMomentumScrollPhase.none,
        precise: Bool = true,
        modifiers: NSEvent.ModifierFlags = [],
        at seconds: TimeInterval = 0
    ) throws -> NSEvent {
        try SyntheticScroll.event(
            deltaX: deltaX, deltaY: deltaY, phase: phase, momentum: momentum,
            precise: precise, modifiers: modifiers, at: seconds
        )
    }

    /// A coordinator with everything it touches recorded rather than done.
    private final class Recorder {
        var textSteps: [Int] = []
        var detailSteps: [Int] = []
        var haptics = 0

        var host: ScrollZoomCoordinator.Host {
            ScrollZoomCoordinator.Host(
                stepTextSize: { [self] in textSteps.append($0) },
                stepDetail: { [self] in detailSteps.append($0) },
                performHapticFeedback: { [self] in haptics += 1 }
            )
        }
    }

    @Test
    func syntheticEventsCarryModifiersAndBothDeltaKinds() throws {
        let trackpad = try scroll(deltaY: -18, modifiers: .command, at: 1)
        #expect(trackpad.hasPreciseScrollingDeltas)
        #expect(trackpad.modifierFlags.contains(.command))
        #expect(!trackpad.modifierFlags.contains(.option))
        #expect(abs(trackpad.scrollingDeltaY - -18) < 0.001)

        // A wheel reports lines, and the coarse path only works if the event
        // really carries them.
        let wheel = try scroll(deltaY: 3, phase: nil, precise: false, modifiers: .option)
        #expect(!wheel.hasPreciseScrollingDeltas)
        #expect(wheel.modifierFlags.contains(.option))
        #expect(abs(wheel.scrollingDeltaY - 3) < 0.001)

        // Nothing held means nothing held, whatever the machine running the
        // test has its hands on.
        let bare = try scroll(deltaY: 4)
        #expect(ScrollGestureModifiers.held(in: bare).isEmpty)

        // Time is a real input here — the wheel's gesture boundary and every
        // flick are read out of it — so the synthesized clock has to survive
        // the round trip through `CGEvent`.
        let later = try scroll(deltaY: 4, at: 2)
        #expect(abs((later.timestamp - bare.timestamp) - 2) < 0.001)
    }

    // MARK: - Policy

    @Test
    func onlyExactlyCommandOrExactlyOptionIsAZoom() {
        #expect(ScrollZoomPolicy.intent(for: [.command]) == .textSize)
        #expect(ScrollZoomPolicy.intent(for: [.option]) == .structuralDetail)
        #expect(ScrollZoomPolicy.intent(for: []) == nil)
        // ⇧⌘ is jump history's business plus a stray finger; a zoom that
        // answered to any superset would fire underneath it.
        #expect(ScrollZoomPolicy.intent(for: [.command, .shift]) == nil)
        #expect(ScrollZoomPolicy.intent(for: [.option, .control]) == nil)
        #expect(ScrollZoomPolicy.intent(for: [.control]) == nil)
        #expect(ScrollZoomPolicy.intent(for: [.shift]) == nil)
    }

    @Test
    func capsLockAndFnRideAlongWithoutCancellingAZoom() throws {
        let event = try scroll(deltaY: -10, modifiers: [.command, .capsLock, .function])
        #expect(ScrollZoomPolicy.intent(for: ScrollGestureModifiers.held(in: event)) == .textSize)
    }

    @Test
    func aWheelsAccelerationIsThrownAwayAndATrackpadsPointsAreNot() {
        // Points are what the fingers actually travelled.
        #expect(ScrollZoomPolicy.contribution(deltaY: 37.5, precise: true) == 37.5)
        #expect(ScrollZoomPolicy.contribution(deltaY: -37.5, precise: true) == -37.5)
        // Lines arrive with macOS's acceleration curve baked in, and that
        // curve turns one flick of the wheel into the whole scale.
        #expect(ScrollZoomPolicy.contribution(deltaY: 12, precise: false) == 1)
        #expect(ScrollZoomPolicy.contribution(deltaY: -12, precise: false) == -1)
        #expect(ScrollZoomPolicy.contribution(deltaY: 1, precise: false) == 1)
        #expect(ScrollZoomPolicy.contribution(deltaY: 0, precise: false) == 0)
    }

    @Test
    func detailAsksForMoreTravelThanTextSize() {
        #expect(ScrollZoomPolicy.stepThreshold(.structuralDetail, precise: true)
            > ScrollZoomPolicy.stepThreshold(.textSize, precise: true))
        // A wheel's notch is the detent, for both scales.
        #expect(ScrollZoomPolicy.stepThreshold(.textSize, precise: false)
            == ScrollZoomPolicy.wheelStepLines)
        #expect(ScrollZoomPolicy.stepThreshold(.structuralDetail, precise: false)
            == ScrollZoomPolicy.wheelStepLines)
    }

    @Test
    func textSizeRampsAndStructuralDetailDoesNot() {
        #expect(ScrollZoomPolicy.allowsFurtherSteps(.textSize, spent: 0))
        #expect(ScrollZoomPolicy.allowsFurtherSteps(.textSize, spent: 9))
        #expect(ScrollZoomPolicy.allowsFurtherSteps(.structuralDetail, spent: 0))
        #expect(!ScrollZoomPolicy.allowsFurtherSteps(.structuralDetail, spent: 1))
        #expect(!ScrollZoomPolicy.allowsFurtherSteps(.structuralDetail, spent: -1))
    }

    @Test
    func stepsAreEarnedByTravelAndCappedByWhatTheGestureHasLeft() {
        let text = ScrollZoomPolicy.textSizeStepPoints
        #expect(ScrollZoomPolicy.steps(
            .textSize, accumulated: text - 0.01, spent: 0, precise: true) == 0)
        #expect(ScrollZoomPolicy.steps(
            .textSize, accumulated: text, spent: 0, precise: true) == 1)
        // A ramp is allowed to be a ramp.
        #expect(ScrollZoomPolicy.steps(
            .textSize, accumulated: text * 3.5, spent: 4, precise: true) == 3)
        #expect(ScrollZoomPolicy.steps(
            .textSize, accumulated: -text * 2, spent: 0, precise: true) == -2)

        let detail = ScrollZoomPolicy.detailStepPoints
        #expect(ScrollZoomPolicy.steps(
            .structuralDetail, accumulated: detail - 0.01, spent: 0, precise: true) == 0)
        #expect(ScrollZoomPolicy.steps(
            .structuralDetail, accumulated: detail, spent: 0, precise: true) == 1)
        // Five levels per flick is the failure this whole detent exists for:
        // one event that crosses the line five times still buys one step.
        #expect(ScrollZoomPolicy.steps(
            .structuralDetail, accumulated: detail * 5, spent: 0, precise: true) == 1)
        #expect(ScrollZoomPolicy.steps(
            .structuralDetail, accumulated: -detail * 5, spent: 0, precise: true) == -1)
        // …and once it is spent the gesture is over as far as detail goes.
        #expect(ScrollZoomPolicy.steps(
            .structuralDetail, accumulated: detail * 5, spent: 1, precise: true) == 0)
    }

    @Test
    func aWheelsGestureIsTheQuietAroundIt() {
        #expect(!ScrollZoomPolicy.startsNewWheelGesture(since: 0))
        // A spin: events a couple of frames apart.
        #expect(!ScrollZoomPolicy.startsNewWheelGesture(since: 0.03))
        #expect(!ScrollZoomPolicy.startsNewWheelGesture(
            since: ScrollZoomPolicy.wheelGestureGap - 0.001))
        // A notch, a look, another notch.
        #expect(ScrollZoomPolicy.startsNewWheelGesture(
            since: ScrollZoomPolicy.wheelGestureGap))
        #expect(ScrollZoomPolicy.startsNewWheelGesture(since: 5))
    }

    // MARK: - Coordinator: nothing held

    @Test
    func anUnmodifiedScrollIsNeverClaimedAndNeverZooms() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)

        #expect(!zoom.handle(try scroll(phase: .began, at: 0)))
        for step in 1...20 {
            #expect(!zoom.handle(try scroll(deltaY: -40, at: TimeInterval(step) * 0.008)))
        }
        #expect(!zoom.handle(try scroll(phase: .ended, at: 0.2)))
        #expect(recorder.textSteps.isEmpty)
        #expect(recorder.detailSteps.isEmpty)
    }

    // MARK: - Coordinator: ⌘ text size

    @Test
    func commandScrollBanksTravelAndReleasesWholeSteps() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)
        let step = ScrollZoomPolicy.textSizeStepPoints

        #expect(zoom.handle(try scroll(phase: .began, modifiers: .command, at: 0)))
        // Short of the threshold the event is still swallowed — the page must
        // not scroll while ⌘ is down — but nothing has been earned yet.
        #expect(zoom.handle(try scroll(deltaY: step / 2, modifiers: .command, at: 0.008)))
        #expect(recorder.textSteps.isEmpty)

        #expect(zoom.handle(try scroll(deltaY: step / 2, modifiers: .command, at: 0.016)))
        #expect(recorder.textSteps == [1])
        // Only the travel the step cost is spent; the remainder rolls on, so a
        // steady drag steps at a steady rate instead of stuttering.
        #expect(abs(zoom.accumulatedTravelForTesting) < 0.001)

        #expect(zoom.handle(try scroll(deltaY: step * 2, modifiers: .command, at: 0.024)))
        #expect(recorder.textSteps == [1, 2])
        #expect(recorder.detailSteps.isEmpty)
        // Sizing text is not a detent; it is a ramp, and a ramp does not tap.
        #expect(recorder.haptics == 0)
    }

    @Test
    func commandScrollTheOtherWayMakesTextSmaller() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)

        #expect(zoom.handle(try scroll(phase: .began, modifiers: .command, at: 0)))
        #expect(zoom.handle(try scroll(
            deltaY: -ScrollZoomPolicy.textSizeStepPoints, modifiers: .command, at: 0.008)))
        #expect(recorder.textSteps == [-1])
    }

    @Test
    func theMomentumTailIsSwallowedButNeverZooms() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)
        let step = ScrollZoomPolicy.textSizeStepPoints

        #expect(zoom.handle(try scroll(phase: .began, modifiers: .command, at: 0)))
        #expect(zoom.handle(try scroll(deltaY: step, modifiers: .command, at: 0.008)))
        #expect(zoom.handle(try scroll(phase: .ended, modifiers: .command, at: 0.016)))
        #expect(recorder.textSteps == [1])

        // The coast after the fingers lift. Handing it back would scroll the
        // page out from under a size the reader just settled on.
        for tick in 1...20 {
            let event = try scroll(
                deltaY: 200, phase: nil, momentum: .continuous,
                modifiers: .command, at: 0.016 + TimeInterval(tick) * 0.008
            )
            #expect(zoom.handle(event))
        }
        #expect(recorder.textSteps == [1])
    }

    @Test
    func lettingGoOfTheModifierHandsTheRestOfTheGestureBack() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)
        let step = ScrollZoomPolicy.textSizeStepPoints

        #expect(zoom.handle(try scroll(phase: .began, modifiers: .command, at: 0)))
        #expect(zoom.handle(try scroll(deltaY: step, modifiers: .command, at: 0.008)))
        #expect(recorder.textSteps == [1])
        // ⌘ up mid-gesture: the rest of it is an ordinary scroll again.
        #expect(!zoom.handle(try scroll(deltaY: step * 4, at: 0.016)))
        #expect(recorder.textSteps == [1])
    }

    // MARK: - Coordinator: ⌥ structural detail

    @Test
    func optionScrollSpendsExactlyOneLevelPerTrackpadGesture() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)

        #expect(zoom.handle(try scroll(phase: .began, modifiers: .option, at: 0)))
        // A hard flick: far more travel than one level's worth, all in one
        // gesture. Five relayouts of the whole document is the thing this is
        // here to prevent.
        for step in 1...20 {
            let event = try scroll(
                deltaY: -40, modifiers: .option, at: TimeInterval(step) * 0.008
            )
            #expect(zoom.handle(event))
        }
        #expect(recorder.detailSteps == [-1])
        #expect(recorder.haptics == 1)
        #expect(zoom.handle(try scroll(phase: .ended, modifiers: .option, at: 0.2)))

        // Fingers down again is a new gesture, and buys one more.
        #expect(zoom.handle(try scroll(phase: .began, modifiers: .option, at: 0.4)))
        for step in 1...20 {
            let event = try scroll(
                deltaY: -40, modifiers: .option, at: 0.4 + TimeInterval(step) * 0.008
            )
            #expect(zoom.handle(event))
        }
        #expect(recorder.detailSteps == [-1, -1])
        #expect(recorder.haptics == 2)
    }

    @Test
    func aShortOptionNudgeDoesNotMoveTheDetailLevel() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)

        #expect(zoom.handle(try scroll(phase: .began, modifiers: .option, at: 0)))
        #expect(zoom.handle(try scroll(
            deltaY: -(ScrollZoomPolicy.detailStepPoints - 1), modifiers: .option, at: 0.008)))
        #expect(zoom.handle(try scroll(phase: .ended, modifiers: .option, at: 0.016)))
        #expect(recorder.detailSteps.isEmpty)
        // …and the travel that did not earn anything is not banked toward the
        // next gesture, which would fire early for no visible reason.
        #expect(zoom.accumulatedTravelForTesting == 0)
        #expect(zoom.stepsFiredForTesting == 0)
    }

    @Test
    func optionScrollUpwardShowsMoreDetail() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)

        #expect(zoom.handle(try scroll(phase: .began, modifiers: .option, at: 0)))
        #expect(zoom.handle(try scroll(
            deltaY: ScrollZoomPolicy.detailStepPoints, modifiers: .option, at: 0.008)))
        #expect(recorder.detailSteps == [1])
    }

    // MARK: - Coordinator: the wheel

    @Test
    func oneWheelNotchIsOneTextSizeStepHoweverHardItIsSpun() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)

        // A gentle notch.
        #expect(zoom.handle(try scroll(
            deltaY: 1, phase: nil, precise: false, modifiers: .command, at: 1)))
        #expect(recorder.textSteps == [1])
        // An accelerated one: macOS reports twelve lines, the hand turned one
        // notch, and one notch is what it gets.
        #expect(zoom.handle(try scroll(
            deltaY: 12, phase: nil, precise: false, modifiers: .command, at: 1.03)))
        #expect(recorder.textSteps == [1, 1])
        // Text size is a ramp, so a spin keeps ramping.
        #expect(zoom.handle(try scroll(
            deltaY: 12, phase: nil, precise: false, modifiers: .command, at: 1.06)))
        #expect(recorder.textSteps == [1, 1, 1])
    }

    @Test
    func aSpinOfTheWheelIsOneStructuralLevelAndADeliberateNotchIsAnother() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)

        // A spin: notches a frame or two apart, accelerated hard.
        for tick in 0...9 {
            let event = try scroll(
                deltaY: -8, phase: nil, precise: false, modifiers: .option,
                at: 1 + TimeInterval(tick) * 0.03
            )
            #expect(zoom.handle(event))
        }
        #expect(recorder.detailSteps == [-1])

        // A pause, then a deliberate notch: the reader looked at the result
        // and asked for one more.
        #expect(zoom.handle(try scroll(
            deltaY: -1, phase: nil, precise: false, modifiers: .option,
            at: 1 + 9 * 0.03 + ScrollZoomPolicy.wheelGestureGap + 0.05
        )))
        #expect(recorder.detailSteps == [-1, -1])
        #expect(recorder.haptics == 2)
    }

    @Test
    func switchingModifierMidStreamStartsTheOtherScaleFromZero() throws {
        let recorder = Recorder()
        let zoom = ScrollZoomCoordinator(host: recorder.host)

        #expect(zoom.handle(try scroll(phase: .began, modifiers: .option, at: 0)))
        #expect(zoom.handle(try scroll(
            deltaY: -(ScrollZoomPolicy.detailStepPoints - 5), modifiers: .option, at: 0.008)))
        #expect(recorder.detailSteps.isEmpty)

        // ⌥ up, ⌘ down, same fingers still moving. The travel banked toward a
        // detail level must not fall through into a text-size step.
        #expect(zoom.handle(try scroll(deltaY: -5, modifiers: .command, at: 0.016)))
        #expect(recorder.textSteps.isEmpty)
        #expect(recorder.detailSteps.isEmpty)
        #expect(zoom.handle(try scroll(
            deltaY: -ScrollZoomPolicy.textSizeStepPoints, modifiers: .command, at: 0.024)))
        #expect(recorder.textSteps == [-1])
    }

    // MARK: - Wired into the window

    @Test
    func optionScrollMovesTheDocumentsDetailLevelThroughTheRealCommands() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        controller.window?.layoutIfNeeded()
        #expect(controller.containerTextView.zoomLevel == .everything)

        _ = controller.documentScrollGestures.handle(
            try scroll(phase: .began, modifiers: .option, at: 0))
        for step in 1...10 {
            let event = try scroll(
                deltaY: -30, modifiers: .option, at: TimeInterval(step) * 0.008
            )
            #expect(controller.documentScrollGestures.handle(event))
        }
        _ = controller.documentScrollGestures.handle(
            try scroll(phase: .ended, modifiers: .option, at: 0.1))

        // One level, not five — and through `.zoomOut`, so the gesture and the
        // ⌃⌥⌘- chord cannot drift apart about where the scale ends.
        #expect(controller.containerTextView.zoomLevel == .skeleton)
        #expect(controller.markdownDocument.state.zoomLevel == .skeleton)
    }

    @Test
    func commandScrollMovesTheReadingTextSize() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        controller.window?.layoutIfNeeded()

        // Text size is a preference, so put it back however this ends.
        let original = Preferences.shared.values.textSizeAdjustment
        defer { Preferences.shared.update { $0.textSizeAdjustment = original } }
        Preferences.shared.update { $0.textSizeAdjustment = 0 }

        _ = controller.documentScrollGestures.handle(
            try scroll(phase: .began, modifiers: .command, at: 0))
        #expect(controller.documentScrollGestures.handle(try scroll(
            deltaY: ScrollZoomPolicy.textSizeStepPoints * 2, modifiers: .command, at: 0.008)))
        _ = controller.documentScrollGestures.handle(
            try scroll(phase: .ended, modifiers: .command, at: 0.016))

        #expect(Preferences.shared.values.textSizeAdjustment == 2)
    }

    @Test
    func aModifiedSidewaysScrollNeverSwitchesPresentation() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 700), display: false)
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.layoutSubtreeIfNeeded()

        // Exactly the gesture that switches Document↔Source, with ⌘ held. The
        // zoom takes it, and the swipe has to stand down on its own account
        // rather than trust that it was asked second.
        _ = controller.documentScrollGestures.handle(
            try scroll(phase: .began, modifiers: .command, at: 0))
        for step in 1...12 {
            let event = try scroll(
                deltaX: -20, modifiers: .command, at: TimeInterval(step) * 0.008
            )
            #expect(controller.documentScrollGestures.handle(event))
        }
        _ = controller.documentScrollGestures.handle(
            try scroll(phase: .ended, modifiers: .command, at: 0.12))

        #expect(controller.presentationSegment == 0)
        #expect(!controller.presentationSwipe.isTracking)
    }
}
