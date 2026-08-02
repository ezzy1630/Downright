import Foundation
import MarkdownCore

/// The revision attached to one immutable source snapshot.
///
/// A value type makes it difficult to accidentally compare a parse result from
/// one source edit with the revision of another edit.
struct MarkdownParseRevision: RawRepresentable, Comparable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static let zero = MarkdownParseRevision(rawValue: 0)

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func advanced() -> Self {
        Self(rawValue: rawValue &+ 1)
    }
}

struct MarkdownParseResult: Sendable {
    let revision: MarkdownParseRevision
    let text: String
    let document: ParsedDocument
    let dirty: DirtySet
}

/// One immutable source snapshot waiting for the parse lane.
struct MarkdownParseRequest: Sendable {
    let text: String
    let previous: ParsedDocument
    let revision: MarkdownParseRevision
}

/// Serial, latest-wins parse coordinator.
///
/// cmark does not provide a cancellation point for a parse already in flight.
/// A cancelled `Task` therefore cannot be used as a concurrency limit: a fast
/// typing burst would start one cmark parse per keystroke.  This actor keeps
/// one parse in flight and one pending snapshot.  A newer snapshot replaces
/// the pending snapshot before it starts.  Old results are still checked by
/// the document revision gate when they return.
actor MarkdownParseCoordinator {
    private let worker: MarkdownParseWorker
    private var pending: MarkdownParseRequest?
    private var wake: CheckedContinuation<Void, Never>?
    private var isSuspended = false
    private var isShutdown = false

    init(worker: MarkdownParseWorker) {
        self.worker = worker
    }

    func submit(_ request: MarkdownParseRequest) {
        guard !isSuspended, !isShutdown else { return }
        guard pending?.revision ?? .zero < request.revision else { return }
        pending = request
        wake?.resume()
        wake = nil
    }

    func suspend() {
        isSuspended = true
        pending = nil
        wake?.resume()
        wake = nil
    }

    func resume() {
        guard !isShutdown else { return }
        isSuspended = false
        wake?.resume()
        wake = nil
    }

    func shutdown() {
        isShutdown = true
        pending = nil
        wake?.resume()
        wake = nil
    }

    /// Waits for and runs the next snapshot.  The caller owns the long-lived
    /// loop. Returning `nil` means that the owning document shut down.
    func nextResult() async -> MarkdownParseResult? {
        while true {
            if let request = pending {
                pending = nil
                return await worker.run(
                    text: request.text,
                    previous: request.previous,
                    revision: request.revision
                )
            }
            if isShutdown { return nil }
            await withCheckedContinuation { continuation in
                wake = continuation
            }
        }
    }
}

/// Pure parse work.  The app runs the worker in a detached user-initiated task;
/// tests can inject a deterministic async closure without sleeping.
struct MarkdownParseWorker: Sendable {
    typealias Operation = @Sendable (
        _ text: String,
        _ previous: ParsedDocument,
        _ revision: MarkdownParseRevision
    ) async -> MarkdownParseResult

    let operation: Operation

    init(operation: Operation? = nil) {
        self.operation = operation ?? Self.defaultOperation
    }

    func run(
        text: String,
        previous: ParsedDocument,
        revision: MarkdownParseRevision
    ) async -> MarkdownParseResult {
        await operation(text, previous, revision)
    }

    private static let defaultOperation: Operation = { text, previous, revision in
        let document = MarkdownParser.parse(text)
        let dirty = ASTDiff.dirtySet(old: previous, new: document)
        return MarkdownParseResult(
            revision: revision, text: text, document: document, dirty: dirty
        )
    }
}
