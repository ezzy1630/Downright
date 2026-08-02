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

    @Test func appleAdapterFailsClosedWithoutNetwork() async {
        let provider = AppleOnDeviceAIProvider()
        do {
            _ = try await provider.run(LocalAIRequest(task: .summarize, source: "Text"))
            Issue.record("Apple adapter must not claim a result without a local model")
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
        try await Task.sleep(for: .milliseconds(80))
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
