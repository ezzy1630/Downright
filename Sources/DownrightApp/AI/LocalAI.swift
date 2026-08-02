import Foundation
import MarkdownCore

#if canImport(FoundationModels)
import FoundationModels
#endif

enum LocalAITask: String, CaseIterable, Sendable {
    case summarize
    case suggestTitle
    case improveClarity

    var title: String {
        switch self {
        case .summarize: return "Summarize"
        case .suggestTitle: return "Suggest Title"
        case .improveClarity: return "Improve Clarity"
        }
    }
}

enum LocalAIAvailability: Equatable, Sendable {
    case available
    case frameworkUnavailable
    case systemUnavailable
    case notConfigured
}

enum LocalAIError: Error, Equatable {
    case unavailable(LocalAIAvailability)
    case cancelled
    case emptyInput
}

struct LocalAIRequest: Sendable, Equatable {
    let task: LocalAITask
    let source: String
    let selection: NSRange?

    init(task: LocalAITask, source: String, selection: NSRange? = nil) {
        self.task = task
        self.source = source
        self.selection = selection
    }
}

struct LocalAIPreview: Sendable, Equatable {
    let range: NSRange
    let originalSource: String
    let proposedSource: String

    var isNoOp: Bool { originalSource == proposedSource }
}

struct LocalAIResult: Sendable, Equatable {
    let task: LocalAITask
    let text: String
    let preview: LocalAIPreview?
}

protocol LocalAIProvider: AnyObject {
    var availability: LocalAIAvailability { get }
    func run(_ request: LocalAIRequest) async throws -> LocalAIResult
}

/// Apple on-device adapter.  Foundation Models is optional at build time and
/// at run time.  The app never falls back to a network service.
final class AppleOnDeviceAIProvider: LocalAIProvider {
    var availability: LocalAIAvailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) { return .notConfigured }
        return .systemUnavailable
        #else
        return .frameworkUnavailable
        #endif
    }

    func run(_ request: LocalAIRequest) async throws -> LocalAIResult {
        guard !request.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIError.emptyInput
        }
        // Keep this adapter explicit until the host SDK exposes a stable model
        // contract.  This path is local-only and fails closed when unavailable.
        throw LocalAIError.unavailable(availability)
    }
}

/// Deterministic local provider used by tests and by previews when no Apple
/// model is installed.  It performs no I/O and is safe for sample documents.
final class DeterministicLocalAIProvider: LocalAIProvider {
    let availability: LocalAIAvailability = .available

    func run(_ request: LocalAIRequest) async throws -> LocalAIResult {
        try Task.checkCancellation()
        let source = request.selection.flatMap { range in
            guard range.location >= 0, range.upperBound <= (request.source as NSString).length else { return nil }
            return (request.source as NSString).substring(with: range)
        } ?? request.source
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw LocalAIError.emptyInput }
        switch request.task {
        case .summarize:
            let sentence = source.split(whereSeparator: { ".!?\n".contains($0) }).first.map(String.init) ?? source
            return LocalAIResult(task: request.task, text: sentence.trimmingCharacters(in: .whitespaces), preview: nil)
        case .suggestTitle:
            let title = source.split(whereSeparator: { $0 == " " || $0 == "\n" }).prefix(8).joined(separator: " ")
            return LocalAIResult(task: request.task, text: title.isEmpty ? "Untitled" : title.capitalized, preview: nil)
        case .improveClarity:
            let improved = source.replacingOccurrences(of: " in order to ", with: " to ")
            let range = request.selection ?? NSRange(location: 0, length: (request.source as NSString).length)
            return LocalAIResult(
                task: request.task,
                text: improved,
                preview: LocalAIPreview(range: range, originalSource: source, proposedSource: improved)
            )
        }
    }
}

enum LocalAIEditValidator {
    static func edit(for preview: LocalAIPreview, in currentSource: String) -> TextEdit? {
        let source = currentSource as NSString
        guard preview.range.location >= 0,
              preview.range.upperBound <= source.length,
              source.substring(with: preview.range) == preview.originalSource,
              !preview.isNoOp else { return nil }
        return TextEdit(range: preview.range, replacement: preview.proposedSource, summary: "Apply Local AI Suggestion")
    }
}

@MainActor
final class LocalAILatestWinsController {
    private let provider: LocalAIProvider
    private var task: Task<Void, Never>?
    private var generation = 0

    init(provider: LocalAIProvider) { self.provider = provider }

    var availability: LocalAIAvailability { provider.availability }

    func submit(
        _ request: LocalAIRequest,
        onResult: @escaping @MainActor (Result<LocalAIResult, Error>) -> Void
    ) {
        generation += 1
        let currentGeneration = generation
        task?.cancel()
        task = Task { [provider] in
            do {
                let result = try await provider.run(request)
                guard !Task.isCancelled, currentGeneration == self.generation else { return }
                onResult(.success(result))
            } catch {
                guard !Task.isCancelled, currentGeneration == self.generation else { return }
                onResult(.failure(error))
            }
        }
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
    }

}
