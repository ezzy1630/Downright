import AppKit
import MarkdownRender
import Testing
@testable import DownrightApp

/// The two-finger swipe must cost nothing while it is happening.
///
/// This is a budget rather than a curiosity because the obvious design fails
/// it badly.  Dragging the Source presentation in under the fingers was built
/// and measured first: Source has to be rendered before it can be dragged, and
/// that rebuild is ~400 ms on a two-thousand-line document — a dead trackpad
/// at the moment the gesture catches, plus the same again to undo an abandoned
/// swipe.  The shipped gesture renders nothing at all; it translates one layer
/// and switches on release.  These numbers are what keeps it that way.
@Suite(.serialized)
@MainActor
struct PresentationSwipeBudgetTests {
    /// Generous against the measured cost — engagement and abandonment are
    /// hundredths of a millisecond in release, and a frame is 8 ms even at
    /// 120 Hz with room to spare.  A budget this loose still fails instantly
    /// if anything starts rendering inside the gesture again.
    private static let engagementBudget: Double = 8
    private static let trackingFrameBudget: Double = 1

    private func corpus(lines: Int) -> String {
        var out = "# Renderer handoff\n\n"
        for index in 0..<lines {
            switch index % 8 {
            case 0: out += "## Section \(index)\n\n"
            case 1: out += "Body text with `inline code`, **bold**, *italic* and a [link](https://example.com) in line \(index).\n\n"
            case 2: out += "- list item \(index) with trailing prose to make the line wrap at a realistic measure\n"
            case 3: out += "- [ ] task item \(index)\n\n"
            case 4: out += "```swift\nlet value\(index) = compute(\(index))\n```\n\n"
            case 5: out += "> quoted line \(index)\n\n"
            case 6: out += "| a | b |\n|---|---|\n| \(index) | \(index * 2) |\n\n"
            default: out += "Plain paragraph \(index).\n\n"
            }
        }
        return out
    }

    private func elapsed(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func scroll(_ deltaX: CGFloat, phase: CGScrollPhase, at seconds: Double) throws -> NSEvent {
        let raw = try #require(CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0
        ))
        raw.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        raw.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(deltaX))
        raw.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        raw.timestamp = UInt64(seconds * 1_000_000_000)
        return try #require(NSEvent(cgEvent: raw))
    }

    @Test
    func swipingAndAbandoningALargeDocumentRendersNothing() throws {
        let lines = 2_000
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("swipe-budget-\(ProcessInfo.processInfo.processIdentifier)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("corpus.md")
        try corpus(lines: lines).write(to: file, atomically: true, encoding: .utf8)

        let controller = DocumentWindowController()
        defer { controller.close() }
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1020, height: 728), display: false)
        try controller.open(file, mode: .live)
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.layoutSubtreeIfNeeded()
        controller.primaryContainer.textView.prepareForDisplay()

        let swipe = controller.presentationSwipe
        _ = swipe.handle(try scroll(0, phase: .began, at: 0))

        // Engagement: the frame the gesture is claimed on. This is where the
        // rejected design spent half a second.
        let engage = elapsed { _ = swipe.handle(try! self.scroll(-20, phase: .changed, at: 0.008)) }
        #expect(swipe.isTracking)

        let frames = 100
        let tracking = elapsed {
            for step in 2...(frames + 1) {
                _ = swipe.handle(try! self.scroll(-0.2, phase: .changed, at: Double(step) * 0.008))
            }
        }

        // Released short and slow: the reader thought better of it.
        let abandon = elapsed { _ = swipe.handle(try! self.scroll(0, phase: .ended, at: 4)) }
        swipe.cancelInFlight()

        #expect(engage < Self.engagementBudget,
                "engaging the swipe took \(engage) ms — something is rendering inside the gesture")
        #expect(tracking / Double(frames) < Self.trackingFrameBudget,
                "tracking cost \(tracking / Double(frames)) ms per frame")
        #expect(abandon < Self.engagementBudget,
                "abandoning the swipe took \(abandon) ms — an abandoned swipe must undo nothing")
        // The whole point: an abandoned swipe leaves the document exactly as
        // it found it, having built nothing to throw away.
        #expect(controller.presentationSegment == 0)
    }
}
