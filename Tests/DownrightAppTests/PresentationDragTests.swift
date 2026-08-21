import AppKit
import MarkdownRender
import Testing
@testable import DownrightApp

/// The live Document↔Source drag, and the budget that decides whether the
/// reader gets it.
///
/// The budget is the load-bearing part. Dragging the next presentation in
/// requires rendering it first, and that rebuild scales with document length —
/// so a swipe that always dragged would stall for a fifth of a second on a
/// long file at the exact moment it caught. These tests pin the choice, not
/// just the mechanism.
@Suite(.serialized)
@MainActor
struct PresentationDragTests {
    private func corpus(lines: Int) -> String {
        var out = "# Drag corpus\n\n"
        for index in 0..<lines {
            out += index % 4 == 0 ? "## Section \(index)\n\n" : "Paragraph \(index) of prose.\n\n"
        }
        return out
    }

    /// A real controller over a document of a known length, since the budget's
    /// whole input is how long the document is.
    private func controller(lines: Int, reduceMotion: Bool = false) throws -> DocumentWindowController {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("drag-\(lines)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("corpus.md")
        try corpus(lines: lines).write(to: file, atomically: true, encoding: .utf8)

        let controller = DocumentWindowController()
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1020, height: 728), display: false)
        try controller.open(file, mode: .live)
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.layoutSubtreeIfNeeded()
        controller.activeStyleSheet = StyleSheet(
            theme: controller.activeStyleSheet.theme,
            appearance: controller.window?.effectiveAppearance ?? NSAppearance.currentDrawing(),
            reduceMotionOverride: reduceMotion
        )
        return controller
    }

    private func swipeLeft(
        _ controller: DocumentWindowController,
        steps: Int = 10,
        perStep: CGFloat = -24
    ) throws {
        let swipe = controller.presentationSwipe
        _ = swipe.handle(try SyntheticScroll.event(phase: .began, at: 0))
        for step in 1...steps {
            _ = swipe.handle(try SyntheticScroll.event(
                deltaX: perStep, at: TimeInterval(step) * 0.008))
        }
    }

    // MARK: - Budget

    @Test
    func budgetGrantsTheDragOnlyWhileTheSwitchFitsInsideAFewFrames() {
        PresentationSwitchBudget.resetCalibrationForTesting()
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }

        #expect(PresentationSwitchBudget.allowsDrag(lines: 100))
        #expect(PresentationSwitchBudget.allowsDrag(lines: 1_000))
        // Measured: past roughly twelve hundred lines of file, rendering
        // Source stops fitting inside the engagement budget.
        #expect(!PresentationSwitchBudget.allowsDrag(lines: 2_000))
        #expect(!PresentationSwitchBudget.allowsDrag(lines: 9_000))
        #expect(PresentationSwitchBudget.estimatedCost(lines: 0)
            == PresentationSwitchBudget.fixedCost)
    }

    @Test
    func budgetRecalibratesFromWhatTheSwitchActuallyCost() {
        PresentationSwitchBudget.resetCalibrationForTesting()
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }
        let before = PresentationSwitchBudget.millisecondsPerLine

        // A machine four times slower than the seeded constant.
        for _ in 0..<12 {
            PresentationSwitchBudget.record(cost: 0.272 * 1_000, lines: 1_000)
        }
        #expect(PresentationSwitchBudget.millisecondsPerLine > before * 2)
        // …and now refuses documents it would previously have accepted.
        #expect(!PresentationSwitchBudget.allowsDrag(lines: 1_000))

        // Nonsense never moves the estimate: a short document's cost is mostly
        // fixed overhead, so dividing it by the line count describes nothing.
        let calibrated = PresentationSwitchBudget.millisecondsPerLine
        PresentationSwitchBudget.record(cost: 9_999, lines: 10)
        PresentationSwitchBudget.record(cost: -5, lines: 5_000)
        PresentationSwitchBudget.record(cost: .infinity, lines: 5_000)
        #expect(PresentationSwitchBudget.millisecondsPerLine == calibrated)
    }

    // MARK: - Choosing

    @Test
    func aShortDocumentGetsTheRealDragAndSwitchesBehindIt() throws {
        PresentationSwitchBudget.resetCalibrationForTesting()
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }
        let controller = try controller(lines: 120)
        defer { controller.presentationSwipe.cancelInFlight(); controller.close() }

        try swipeLeft(controller)
        #expect(controller.presentationSwipe.isTracking)
        // The drag renders what it is pulling in, so by the time the fingers
        // have moved the live surface is already Source — hidden behind a
        // still of the page being left.
        #expect(controller.presentationSegment == 1)
        let scrollLayer = try #require(controller.primaryContainer.scrollView.layer)
        #expect(scrollLayer.transform.m41 != 0)
    }

    @Test
    func aLongDocumentGetsTheGiveAndIsNotRebuiltMidGesture() throws {
        PresentationSwitchBudget.resetCalibrationForTesting()
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }
        let controller = try controller(lines: 3_000)
        defer { controller.presentationSwipe.cancelInFlight(); controller.close() }

        try swipeLeft(controller)
        #expect(controller.presentationSwipe.isTracking)
        // Nothing was rendered: the give promises less precisely so that it can
        // always answer.
        #expect(controller.presentationSegment == 0)
    }

    @Test
    func reduceMotionTakesNeitherAndSwitchesOnRelease() throws {
        PresentationSwitchBudget.resetCalibrationForTesting()
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }
        let controller = try controller(lines: 120, reduceMotion: true)
        defer { controller.close() }

        try swipeLeft(controller)
        #expect(controller.presentationSegment == 0)
        _ = controller.presentationSwipe.handle(
            try SyntheticScroll.event(phase: .ended, at: 0.2))
        #expect(controller.presentationSegment == 1)
    }

    // MARK: - Finishing

    @Test
    func abandoningADragPutsTheModeBack() throws {
        PresentationSwitchBudget.resetCalibrationForTesting()
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }
        let controller = try controller(lines: 120)
        defer { controller.close() }

        // Far enough to engage, nowhere near far enough to commit.
        let swipe = controller.presentationSwipe
        _ = swipe.handle(try SyntheticScroll.event(phase: .began, at: 0))
        _ = swipe.handle(try SyntheticScroll.event(deltaX: -16, at: 0.008))
        #expect(controller.presentationSegment == 1)

        swipe.cancelInFlight()
        #expect(controller.presentationSegment == 0)
        #expect(controller.primaryContainer.scrollView.layer?.transform.m41 == 0)
        #expect(!swipe.isTracking)
    }

    @Test
    func aResizeMidDragGroundsItAndRestoresTheMode() throws {
        PresentationSwitchBudget.resetCalibrationForTesting()
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }
        let controller = try controller(lines: 120)
        defer { controller.close() }

        try swipeLeft(controller, steps: 2, perStep: -20)
        #expect(controller.presentationSegment == 1)

        controller.windowDidResize(Notification(name: NSWindow.didResizeNotification))
        #expect(controller.presentationSegment == 0)
        #expect(!controller.presentationSwipe.isTracking)
        #expect(!controller.presentationSwipe.isSettling)
    }

    @Test
    func swipingTowardTheModeYouAreInNeverEngagesEitherTrack() throws {
        PresentationSwitchBudget.resetCalibrationForTesting()
        defer { PresentationSwitchBudget.resetCalibrationForTesting() }
        let controller = try controller(lines: 120)
        defer { controller.close() }

        let swipe = controller.presentationSwipe
        _ = swipe.handle(try SyntheticScroll.event(phase: .began, at: 0))
        #expect(!swipe.handle(try SyntheticScroll.event(deltaX: 40, at: 0.008)))
        #expect(!swipe.isTracking)
        #expect(controller.presentationSegment == 0)
    }
}
