import Foundation
import Testing
import MarkdownCore
@testable import DownrightApp

@Suite(.serialized)
struct LocalAITests {
    @Test func deterministicProviderProducesTypedResults() async throws {
        let provider = DeterministicLocalAIProvider()
        let summary = try await provider.run(LocalAIRequest(task: .summarize, source: "First sentence. Second sentence."))
        #expect(summary.task == .summarize)
        #expect(summary.text == "First sentence")

        let source = "Make this clear in order to help."
        let range = (source as NSString).range(of: source)
        let clarity = try await provider.run(LocalAIRequest(task: .improveClarity, source: source, selection: range))
        #expect(clarity.preview?.proposedSource == "Make this clear to help.")
    }

    @Test func editValidatorRejectsStaleSourceAndBuildsExactEdit() {
        let preview = LocalAIPreview(
            range: NSRange(location: 0, length: 3),
            originalSource: "old",
            proposedSource: "new"
        )
        let edit = LocalAIEditValidator.edit(for: preview, in: "old text")
        #expect(edit?.range == preview.range)
        #expect(edit?.replacement == "new")
        #expect(LocalAIEditValidator.edit(for: preview, in: "new text") == nil)
    }

    @Test func appleAdapterAvailabilityFailsClosed() async {
        let provider = AppleOnDeviceAIProvider()
        guard provider.availability != .available else {
            #expect(provider.availability == .available)
            return
        }
        do {
            _ = try await provider.run(LocalAIRequest(task: .summarize, source: "Text"))
            Issue.record("Unavailable Apple adapter must fail closed")
        } catch let error as LocalAIError {
            guard case .unavailable = error else {
                Issue.record("expected unavailable local adapter")
                return
            }
        } catch {
            Issue.record("unexpected error type")
        }
    }

    @Test @MainActor func latestRequestWins() async throws {
        let provider = SlowLocalAIProvider()
        let controller = LocalAILatestWinsController(provider: provider)
        var values: [String] = []
        controller.submit(LocalAIRequest(task: .summarize, source: "first")) { result in
            if case .success(let value) = result { values.append(value.text) }
        }
        controller.submit(LocalAIRequest(task: .summarize, source: "second")) { result in
            if case .success(let value) = result { values.append(value.text) }
        }
        // Wait for the result rather than for a stopwatch.  A fixed 80ms sleep
        // against a 30ms provider passes alone and loses the race about half
        // the time inside the full parallel suite, which made this the one
        // test nobody could trust.  Polling asserts the same thing — that only
        // the newest request ever delivers — without betting on scheduler
        // latency; the deadline is generous because it only bounds a failure.
        let deadline = ContinuousClock.now + .seconds(5)
        while values.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        // A short grace period after the winner lands: if the superseded
        // request were also going to deliver, this is when it would.
        try await Task.sleep(for: .milliseconds(60))
        #expect(values == ["second"])
    }
}

private final class SlowLocalAIProvider: LocalAIProvider {
    let availability: LocalAIAvailability = .available

    func run(_ request: LocalAIRequest) async throws -> LocalAIResult {
        try await Task.sleep(for: .milliseconds(30))
        try Task.checkCancellation()
        return LocalAIResult(task: request.task, text: request.source, preview: nil)
    }
}
