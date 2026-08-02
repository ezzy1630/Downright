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
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return .available
            case .unavailable: return .systemUnavailable
            }
        }
        return .systemUnavailable
        #else
        return .frameworkUnavailable
        #endif
    }

    func run(_ request: LocalAIRequest) async throws -> LocalAIResult {
        let input = try Self.input(for: request)
        guard availability == .available else { throw LocalAIError.unavailable(availability) }
        try Task.checkCancellation()

        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(
                model: .default,
                instructions: "You edit Markdown text. Follow the task exactly. Return only the requested text. Do not add commentary or code fences. Preserve Markdown syntax when you rewrite text."
            )
            let response = try await session.respond(to: Self.prompt(task: request.task, input: input))
            try Task.checkCancellation()
            return Self.result(for: request, input: input, output: response.content)
        }
        #endif

        throw LocalAIError.unavailable(.frameworkUnavailable)
    }

    private static func input(for request: LocalAIRequest) throws -> String {
        let source = request.source as NSString
        let input: String
        if let range = request.selection {
            guard range.location >= 0, range.upperBound <= source.length else {
                throw LocalAIError.emptyInput
            }
            input = source.substring(with: range)
        } else {
            input = request.source
        }
        guard !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LocalAIError.emptyInput
        }
        return input
    }

    private static func prompt(task: LocalAITask, input: String) -> String {
        switch task {
        case .summarize:
            return "Summarize this Markdown in at most five short sentences:\n\n\(input)"
        case .suggestTitle:
            return "Write one clear title of at most ten words for this Markdown. Return the title only:\n\n\(input)"
        case .improveClarity:
            return "Rewrite this text for clarity and brevity. Preserve its meaning and Markdown structure. Return the complete replacement text only:\n\n\(input)"
        }
    }

    private static func result(for request: LocalAIRequest, input: String, output: String) -> LocalAIResult {
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard request.task == .improveClarity else {
            return LocalAIResult(task: request.task, text: text, preview: nil)
        }
        let range = request.selection ?? NSRange(location: 0, length: (request.source as NSString).length)
        return LocalAIResult(
            task: request.task,
            text: text,
            preview: LocalAIPreview(range: range, originalSource: input, proposedSource: text)
        )
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
