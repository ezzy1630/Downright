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
        await #expect(throws: LocalAIError.emptyInput) {
            try await provider.run(LocalAIRequest(task: .summarize, source: " "))
        }
        let availability = provider.availability
        if availability != .available {
            await #expect(throws: LocalAIError.unavailable(availability)) {
                try await provider.run(LocalAIRequest(task: .summarize, source: "Text"))
            }
        }
    }

    @Test @MainActor func latestRequestWins() async throws {
        let provider = GatedLocalAIProvider()
        defer { provider.releaseFirst.signal() }
        let controller = LocalAILatestWinsController(provider: provider)
        controller.submit(LocalAIRequest(task: .summarize, source: "first")) { _ in
            Issue.record("The superseded request delivered a result")
        }
        try #require(await provider.firstStarted.wait(), "The initial request never entered its provider")

        let completed = TestSignal()
        var latest: LocalAIResult?
        controller.submit(LocalAIRequest(task: .summarize, source: "second")) { result in
            latest = try? result.get()
            completed.signal()
        }
        try #require(await provider.firstCancelled.wait(), "Superseding the first request must cancel it")
        try #require(await completed.wait(), "The replacement request never completed")
        #expect(latest?.text == "second")

        provider.releaseFirst.signal()
        try #require(await provider.firstReturning.wait(), "The superseded provider never finished")
        await drainTestMainQueue()
    }
}

/// Gate delivery at the provider boundary while generating the result with the
/// real deterministic provider. A provider may finish even after cancellation.
private final class GatedLocalAIProvider: LocalAIProvider {
    private let provider = DeterministicLocalAIProvider()
    var availability: LocalAIAvailability { provider.availability }
    let firstStarted = TestSignal()
    let firstCancelled = TestSignal()
    let firstReturning = TestSignal()
    let releaseFirst = TestSignal()

    @MainActor
    func run(_ request: LocalAIRequest) async throws -> LocalAIResult {
        let result = try await provider.run(request)
        guard request.source == "first" else { return result }
        let release = Task.detached { [releaseFirst] in await releaseFirst.wait() }
        return try await withTaskCancellationHandler {
            firstStarted.signal()
            guard await release.value else { throw LocalAIError.cancelled }
            firstReturning.signal()
            return result
        } onCancel: { [firstCancelled] in
            firstCancelled.signal()
        }
    }
}
