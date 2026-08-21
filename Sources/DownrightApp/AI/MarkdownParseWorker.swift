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
    private var inFlight = false
    private var lastPublishedBusy = false
    /// Published on transitions of the busy state — a snapshot queued or a
    /// parse running.  Fired from the actor; the owner hops to the main actor.
    /// `nonisolated(unsafe)` because it is written exactly once by the owning
    /// document before any snapshot can be submitted, then only read here.
    nonisolated(unsafe) var onBusyChange: (@Sendable (Bool) -> Void)?

    init(worker: MarkdownParseWorker) {
        self.worker = worker
    }

    /// `true` while a snapshot is queued or a parse is in flight.
    private var isBusy: Bool { pending != nil || inFlight }

    private func publishBusy() {
        let busy = isBusy
        guard busy != lastPublishedBusy else { return }
        lastPublishedBusy = busy
        onBusyChange?(busy)
    }

    func submit(_ request: MarkdownParseRequest) {
        guard !isSuspended, !isShutdown else { return }
        if let pendingRevision = pending?.revision {
            guard pendingRevision < request.revision else { return }
        }
        pending = request
        publishBusy()
        wake?.resume()
        wake = nil
    }

    /// Runs a correctness-critical snapshot without waiting behind an obsolete
    /// non-cancellable cmark parse. Actor reentrancy permits the Sendable worker
    /// operation to overlap the stale request; the document revision gate still
    /// decides which result may commit.
    func runImmediately(_ request: MarkdownParseRequest) async -> MarkdownParseResult {
        await worker.run(
            text: request.text,
            previous: request.previous,
            revision: request.revision
        )
    }

    /// Drops a snapshot that has not started running.  A synchronous reparse
    /// has already produced a newer tree, so keeping this request would only
    /// spend parse time on a result that the document revision gate rejects.
    func discardPending() {
        pending = nil
        publishBusy()
    }

    func suspend() {
        isSuspended = true
        pending = nil
        publishBusy()
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
        inFlight = false
        publishBusy()
        wake?.resume()
        wake = nil
    }

    /// Waits for and runs the next snapshot.  The caller owns the long-lived
    /// loop. Returning `nil` means that the owning document shut down.
    func nextResult() async -> MarkdownParseResult? {
        while true {
            if let request = pending {
                pending = nil
                inFlight = true
                publishBusy()
                let result = await worker.run(
                    text: request.text,
                    previous: request.previous,
                    revision: request.revision
                )
                inFlight = false
                publishBusy()
                return result
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
        // An empty previous tree means first paint / open — never try to
        // reconcile block-by-block against nothing.
        let dirty = previous.length == 0
            ? DirtySet.wholesale
            : ASTDiff.dirtySet(old: previous, new: document)
        return MarkdownParseResult(
            revision: revision, text: text, document: document, dirty: dirty
        )
    }
}
