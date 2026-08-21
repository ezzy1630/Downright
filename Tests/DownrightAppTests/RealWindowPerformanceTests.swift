import AppKit
import Foundation
import MarkdownRender
import Testing
@testable import DownrightApp

/// Acceptance coverage for the path a reader actually uses: an activated
/// `NSWindow`, a TextKit 2 document view, and a running display cycle.
///
/// The test target also runs on headless CI. In that environment AppKit cannot
/// deliver a real display frame, so the tests print a diagnostic and leave the
/// frame-specific assertions to the next window-capable run. The layout and
/// parser suites remain the non-window fallback for that machine.
@Suite("Real window performance", .serialized)
@MainActor
struct RealWindowPerformanceTests {
    private struct WindowFixture {
        let controller: DocumentWindowController
        let url: URL

        @MainActor
        func close() {
            controller.close()
            try? FileManager.default.removeItem(at: url)
        }
    }

    private struct FrameBudget {
        let refreshRate: Int
        let frameMilliseconds: Double

        var description: String {
            "\(refreshRate) Hz / frame \(String(format: "%.2f", frameMilliseconds)) ms / hitch \(String(format: "%.2f", hitchMilliseconds)) ms"
        }

        /// A real AppKit display cycle can span several compositor turns while
        /// TextKit materializes a large document. Five frames is a bounded,
        /// enforceable hitch budget while retaining the 60/120 Hz distinction.
        var hitchMilliseconds: Double {
            frameMilliseconds * 5
        }

        /// The prepared external snapshot commits source plus a rebuilt
        /// source/display coordinate map. It is off the immediate input frame,
        /// but still bounded so asynchronous work cannot become an unmeasured
        /// multi-second main-actor stall on large documents.
        var externalCommitMilliseconds: Double { 150 }
    }

    private enum WindowUnavailable: Error {
        case noDisplay
        case noWindowScreen
    }

    private func displayBudget(for window: NSWindow) throws -> FrameBudget {
        guard NSScreen.main != nil else { throw WindowUnavailable.noDisplay }
        guard let screen = window.screen ?? NSScreen.main else {
            throw WindowUnavailable.noWindowScreen
        }

        // Express the hitch ceiling in display frames, not an arbitrary wall
        // clock number. A ProMotion screen therefore gets the 120 Hz budget;
        // ordinary displays use the 60 Hz budget. Unknown display rates use
        // the conservative 60 Hz gate.
        let refreshRate = max(1, screen.maximumFramesPerSecond)
        let frameMilliseconds = refreshRate >= 100 ? 1_000 / 120.0 : 1_000 / 60.0
        return FrameBudget(refreshRate: refreshRate, frameMilliseconds: frameMilliseconds)
    }

    private func realWindowOrPrintSkip(requiresFiftyThousandLines: Bool = false) -> Bool {
        guard ProcessInfo.processInfo.environment["RUN_REAL_WINDOW_PERF"] == "1" else {
            print("REAL_WINDOW_PERF SKIP: set RUN_REAL_WINDOW_PERF=1 for rendered-window acceptance")
            return false
        }
        if requiresFiftyThousandLines,
           ProcessInfo.processInfo.environment["RUN_REAL_WINDOW_50K"] != "1" {
            print("REAL_WINDOW_PERF SKIP: set RUN_REAL_WINDOW_50K=1 for the exhaustive 50k-line case")
            return false
        }
        guard NSScreen.main != nil else {
            print("REAL_WINDOW_PERF SKIP: no NSScreen.main; display-cycle acceptance requires a window server")
            return false
        }
        return true
    }

    private func makeFixture(lines: Int) throws -> WindowFixture {
        let text = fixtureText(lines: lines)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "downright-real-window-\(lines)-\(UUID().uuidString).md"
            )
        try Data(text.utf8).write(to: url)

        let controller = DocumentWindowController()
        do {
            try controller.open(url, mode: .live)
            guard let window = controller.window else {
                throw WindowUnavailable.noWindowScreen
            }
            window.setFrame(
                NSRect(x: 80, y: 80, width: 1_020, height: 780),
                display: false
            )
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            pumpMainRunLoop(for: 0.20)
            _ = try displayBudget(for: window)
            return WindowFixture(controller: controller, url: url)
        } catch {
            controller.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(mode: .common, before: min(
                deadline, Date().addingTimeInterval(0.005)
            ))
        }
    }

    private func pumpMainRunLoop(
        until condition: () -> Bool,
        timeout: TimeInterval = 15
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .common, before: min(
                deadline, Date().addingTimeInterval(0.005)
            ))
        }
        return condition()
    }

    private func awaitCondition(
        timeout: TimeInterval = 15,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func forceFrame(_ window: NSWindow, _ textView: MarkdownTextView) {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        textView.layoutSubtreeIfNeeded()
        textView.prepareForDisplay()
        textView.displayIfNeeded()
        window.displayIfNeeded()
    }

    private func elapsedMilliseconds(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private func p95(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return .infinity }
        let sorted = samples.sorted()
        let index = min(sorted.count - 1, Int((Double(sorted.count - 1) * 0.95).rounded(.down)))
        return sorted[index]
    }

    private func assertFrameBudget(
        _ samples: [Double],
        label: String,
        budget: FrameBudget
    ) {
        let result = p95(samples)
        let maximum = samples.max() ?? .infinity
        print(
            "REAL_WINDOW_PERF \(label) p50="
                + String(format: "%.3f", samples.sorted()[samples.count / 2])
                + " ms p95=" + String(format: "%.3f", result)
                + " ms max=" + String(format: "%.3f", maximum)
                + " ms target=" + budget.description
        )
        #expect(
            result <= budget.hitchMilliseconds,
            "\(label) p95 \(String(format: "%.2f", result)) ms exceeded \(budget.description)"
        )
    }

    /// One corpus exercises the same blocks that make large agent-written
    /// README files expensive: images, display math, tables, Mermaid, tasks,
    /// links, and fenced code interleaved with ordinary paragraphs.
    private func fixtureText(lines target: Int) -> String {
        var lines: [String] = []
        lines.reserveCapacity(target)
        var section = 0
        while lines.count < target {
            section += 1
            lines.append("## Section \(section)")
            lines.append("")
            lines.append("A paragraph with **bold**, *emphasis*, a [link](https://example.com), and inline math $x^2 + y^2$.")
            lines.append("- [ ] pending task \(section)")
            lines.append("- [x] completed task \(section)")
            lines.append("- a nested-looking ordinary item")

            if section % 17 == 0 {
                lines.append("")
                lines.append("![local diagram](asset-\(section).png)")
                lines.append("")
                lines.append("$$")
                lines.append("x^2 / 3")
                lines.append("$$")
            }
            if section % 29 == 0 {
                lines.append("")
                lines.append("| column | value |")
                lines.append("| --- | ---: |")
                lines.append("| alpha | \(section) |")
                lines.append("| beta | \(section * 2) |")
            }
            if section % 43 == 0 {
                lines.append("")
                lines.append("```mermaid")
                lines.append("graph TD")
                lines.append("  A\(section) --> B\(section)")
                lines.append("```")
            }
            if section % 53 == 0 {
                lines.append("")
                lines.append("```swift")
                lines.append("let value\(section) = \(section)")
                lines.append("```")
            }
        }
        return lines.prefix(target).joined(separator: "\n") + "\n"
    }

    @Test("10k-line typing and scrolling stay within a bounded five-frame hitch")
    func tenThousandLineTypingAndScrolling() throws {
        guard realWindowOrPrintSkip() else { return }
        let fixture = try makeFixture(lines: 10_000)
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        let budget = try displayBudget(for: window)
        let textView = fixture.controller.primaryContainer.textView
        window.makeFirstResponder(textView)

        // Warm up TextKit's viewport and the local-edit path before measuring.
        textView.setSourceSelectedRanges([NSRange(
            location: fixture.controller.markdownDocument.storage.length / 2,
            length: 0
        )])
        forceFrame(window, textView)

        var typing: [Double] = []
        for _ in 0..<12 {
            let range = textView.sourceSelectedRange
            typing.append(elapsedMilliseconds {
                textView.insertText("x", replacementRange: range)
                forceFrame(window, textView)
            })
        }
        assertFrameBudget(typing, label: "10k typing→frame", budget: budget)

        var scrolling: [Double] = []
        let length = fixture.controller.markdownDocument.storage.length
        for fraction in stride(from: 0.08, through: 0.92, by: 0.08) {
            let offset = Int(Double(length) * fraction)
            scrolling.append(elapsedMilliseconds {
                textView.scroll(toOffset: offset, position: .top, animated: false)
                forceFrame(window, textView)
            })
        }
        assertFrameBudget(scrolling, label: "10k scrolling→frame", budget: budget)
        #expect(textView.topVisibleOffset > 0)
    }

    @Test("50k-line typing, scrolling, and split panes remain measurable")
    func fiftyThousandLineTypingScrollingAndSplitView() throws {
        guard realWindowOrPrintSkip(requiresFiftyThousandLines: true) else { return }
        let fixture = try makeFixture(lines: 50_000)
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        let budget = try displayBudget(for: window)
        let textView = fixture.controller.primaryContainer.textView
        window.makeFirstResponder(textView)
        textView.setSourceSelectedRanges([NSRange(
            location: fixture.controller.markdownDocument.storage.length / 2,
            length: 0
        )])
        forceFrame(window, textView)

        var typing: [Double] = []
        for _ in 0..<8 {
            let range = textView.sourceSelectedRange
            typing.append(elapsedMilliseconds {
                textView.insertText("y", replacementRange: range)
                forceFrame(window, textView)
            })
        }
        assertFrameBudget(typing, label: "50k typing→frame", budget: budget)

        var scrolling: [Double] = []
        let length = fixture.controller.markdownDocument.storage.length
        for fraction in stride(from: 0.10, through: 0.90, by: 0.10) {
            let offset = Int(Double(length) * fraction)
            scrolling.append(elapsedMilliseconds {
                textView.scroll(toOffset: offset, position: .top, animated: false)
                forceFrame(window, textView)
            })
        }
        assertFrameBudget(scrolling, label: "50k scrolling→frame", budget: budget)

        fixture.controller.toggleSplitView()
        guard let split = fixture.controller.splitContainer else {
            Issue.record("split view did not create its second real pane")
            return
        }
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(split.frame.width > 0)
        #expect(fixture.controller.primaryContainer.frame.width > 0)
        #expect(split.textView.textStorage === textView.textStorage)
        let splitScroll = elapsedMilliseconds {
            split.textView.scroll(toOffset: length / 3, position: .top, animated: false)
            forceFrame(window, split.textView)
        }
        print("REAL_WINDOW_PERF 50k split scroll→frame \(String(format: "%.3f", splitScroll)) ms target=\(budget.description)")
        #expect(splitScroll <= budget.hitchMilliseconds)
    }

    @Test("IME marked text and rich constructs use the same frame path")
    func imeCompositionAndRichBlocks() throws {
        guard realWindowOrPrintSkip() else { return }
        let fixture = try makeFixture(lines: 10_000)
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        let budget = try displayBudget(for: window)
        let textView = fixture.controller.primaryContainer.textView
        window.makeFirstResponder(textView)
        textView.setSourceSelectedRanges([NSRange(
            location: fixture.controller.markdownDocument.storage.length / 3,
            length: 0
        )])
        forceFrame(window, textView)

        let range = textView.sourceSelectedRange
        let marked = elapsedMilliseconds {
            textView.setMarkedText(
                "かな",
                selectedRange: NSRange(location: 2, length: 0),
                replacementRange: range
            )
            forceFrame(window, textView)
        }
        textView.unmarkText()
        forceFrame(window, textView)
        print("REAL_WINDOW_PERF IME marked-text→frame \(String(format: "%.3f", marked)) ms target=\(budget.description)")
        #expect(marked <= budget.hitchMilliseconds)
        #expect(fixture.controller.markdownDocument.text.contains("かな"))
    }

    @Test("external atomic rewrite delivers bounded scroll frames through convergence")
    func externalRewriteWhileScrolling() async throws {
        guard realWindowOrPrintSkip() else { return }
        let fixture = try makeFixture(lines: 10_000)
        defer { fixture.close() }
        let window = try #require(fixture.controller.window)
        let budget = try displayBudget(for: window)
        let textView = fixture.controller.primaryContainer.textView
        let length = fixture.controller.markdownDocument.storage.length
        let initialConverged = await awaitCondition(timeout: 30) {
            fixture.controller.markdownDocument.lastAsyncParseRevision
                == fixture.controller.markdownDocument.revision
        }
        #expect(initialConverged, "initial 10k parse did not converge before external-rewrite measurement")
        textView.scroll(toOffset: length / 2, position: .top, animated: false)
        forceFrame(window, textView)
        let before = textView.topVisibleOffset
        #expect(before > 0)

        // Write before entering the measured path. This keeps filesystem I/O
        // out of the UI number while still exercising the exact atomic replace
        // and document reconciliation used by the file watcher.
        let incoming = "# External heading\n\n" + fixture.controller.markdownDocument.text
        var commitMilliseconds: Double?
        let existingReparse = fixture.controller.markdownDocument.onReparse
        fixture.controller.markdownDocument.onReparse = { parsed, dirty in
            let started = DispatchTime.now().uptimeNanoseconds
            existingReparse?(parsed, dirty)
            if parsed.text == incoming {
                commitMilliseconds = Double(
                    DispatchTime.now().uptimeNanoseconds - started
                ) / 1_000_000
            }
        }
        try Data(incoming.utf8).write(to: fixture.url, options: .atomic)
        let rewrite = elapsedMilliseconds {
            fixture.controller.markdownDocument.handleExternalWrite()
            fixture.controller.markdownDocument.flushPendingExternalWrite()
            forceFrame(window, textView)
        }
        print("REAL_WINDOW_PERF external rewrite→frame \(String(format: "%.3f", rewrite)) ms target=\(budget.description)")
        #expect(rewrite <= budget.hitchMilliseconds)

        var scrollFrames: [Double] = []
        var sample = 0
        let deadline = ContinuousClock.now + .seconds(15)
        while fixture.controller.markdownDocument.parsed.text != incoming,
              ContinuousClock.now < deadline {
            let offset = min(
                fixture.controller.markdownDocument.storage.length - 1,
                length / 2 + (sample % 80) * 47
            )
            scrollFrames.append(elapsedMilliseconds {
                textView.scroll(toOffset: offset, position: .top, animated: false)
                forceFrame(window, textView)
            })
            sample += 1
            try await Task.sleep(for: .milliseconds(2))
        }
        let converged = fixture.controller.markdownDocument.parsed.text == incoming
        #expect(converged, "external rewrite did not converge in the 15-second acceptance window")
        #expect(!scrollFrames.isEmpty, "no scroll frames were sampled during external convergence")
        assertFrameBudget(scrollFrames, label: "external-convergence scrolling→frame", budget: budget)
        let commit = try #require(commitMilliseconds)
        print("REAL_WINDOW_PERF external commit→decorated frame \(String(format: "%.3f", commit)) ms target=\(budget.description)")
        #expect(
            commit <= budget.externalCommitMilliseconds,
            "external decorated commit exceeded the 150 ms bounded-main-actor ceiling"
        )
        #expect(textView.topVisibleOffset > 0)
        #expect(textView.topVisibleOffset < fixture.controller.markdownDocument.storage.length)
    }
}
