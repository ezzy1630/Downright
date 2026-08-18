import Foundation
import Testing
import MarkdownCore
@testable import DownrightApp

@Suite(.serialized)
struct AsyncParseTests {
    @Test @MainActor
    func externalAbsorbPublishesWholesaleRender() {
        let document = MarkdownDocument()
        let initial = "# One\n\nA calm paragraph.\n"
        let incoming = "# One\n\nA rewritten paragraph with a different shape.\n"
        document.adopt(text: initial, displayURL: nil)

        var observedDirty: DirtySet?
        document.onReparse = { _, dirty in observedDirty = dirty }
        document.applyExternalText(
            incoming,
            hunks: TextDiff.hunks(old: initial, new: incoming)
        )

        #expect(document.text == incoming)
        #expect(observedDirty?.isWholesale == true)
    }

    @Test @MainActor
    func semanticEditConvergesBeforeReadingTree() {
        let document = MarkdownDocument()
        document.adopt(text: "# Heading\n", displayURL: nil)

        // The source edit leaves the old tree in place until the worker result
        // commits.  A semantic command must synchronously converge first.
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "- [ ] task\n",
            actionName: nil
        ))
        document.toggleTask(atMarkOffset: 2)

        #expect(document.text == "- [x] task\n")
        #expect(document.parsed.text == document.text)
    }

    @Test @MainActor
    func undoAndRedoLockViewportAndReparseBeforeReturning() {
        let document = MarkdownDocument()
        document.adopt(text: "one\n", displayURL: nil)
        #expect(document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "two lines\nsecond\n",
            actionName: "Expand"
        ))
        document.ensureParsedCurrent()

        var viewportLocks = 0
        var reparsesObservedAfterLock = 0
        var textSeenAtLock: [String] = []
        document.onWillApplyUndoRedo = {
            viewportLocks += 1
            textSeenAtLock.append(document.text)
        }
        document.onReparse = { _, _ in
            if viewportLocks > reparsesObservedAfterLock {
                reparsesObservedAfterLock += 1
            }
        }

        document.undoManager.undo()
        #expect(document.text == "one\n")
        #expect(document.parsed.text == document.text)

        document.undoManager.redo()
        #expect(document.text == "two lines\nsecond\n")
        #expect(document.parsed.text == document.text)
        #expect(viewportLocks == 2)
        #expect(reparsesObservedAfterLock == 2)
        #expect(textSeenAtLock == ["two lines\nsecond\n", "one\n"])
    }

    @Test @MainActor
    func groupedUndoLocksOnceForSeveralInverseEdits() {
        let document = MarkdownDocument()
        let source = "alpha\nbeta\n"
        document.adopt(text: source, displayURL: nil)
        let alpha = (source as NSString).range(of: "alpha")
        let beta = (source as NSString).range(of: "beta")
        document.apply([
            TextEdit(range: alpha, replacement: "ALPHA", summary: "Uppercase"),
            TextEdit(range: beta, replacement: "BETA", summary: "Uppercase"),
        ], actionName: "Uppercase")
        #expect(document.text == "ALPHA\nBETA\n")

        var viewportLocks = 0
        var editLocks = 0
        document.onWillApplyUndoRedo = { viewportLocks += 1 }
        document.onWillApplyEdits = { _ in editLocks += 1 }

        document.undoManager.undo()

        #expect(viewportLocks == 1)
        #expect(editLocks == 0)
        #expect(document.text == source)
        #expect(document.parsed.text == source)
    }

    @Test
    func injectedWorkerRunsPureParseAndDiff() async {
        let worker = MarkdownParseWorker { text, previous, revision in
            let document = MarkdownParser.parse(text)
            return MarkdownParseResult(
                revision: revision,
                text: text,
                document: document,
                dirty: ASTDiff.dirtySet(old: previous, new: document)
            )
        }
        let previous = MarkdownParser.parse("# One\n")
        let result = await worker.run(
            text: "# Two\n", previous: previous, revision: .zero.advanced()
        )

        #expect(result.document.text == "# Two\n")
        #expect(result.revision == .zero.advanced())
        #expect(!result.dirty.isEmpty)
    }

    @Test @MainActor
    func latestRevisionWinsWithOneInFlightWorker() async {
        let gate = ParseGate()
        let concurrency = WorkerConcurrencyCounter()
        let committed = ParseSignal()
        let worker = MarkdownParseWorker { text, previous, revision in
            concurrency.enter()
            let parsed = MarkdownParser.parse(text)
            let result = MarkdownParseResult(
                revision: revision, text: text, document: parsed,
                dirty: ASTDiff.dirtySet(old: previous, new: parsed)
            )
            let held = await gate.hold(result)
            concurrency.leave()
            return held
        }
        let document = MarkdownDocument(parseWorker: worker)
        document.adopt(text: "one\n", displayURL: nil)
        document.onReparse = { parsed, _ in
            if parsed.text == "three\n" { Task { await committed.signal() } }
        }
        document.replace(NSRange(location: 0, length: document.storage.length), with: "two\n", actionName: nil)
        document.flushScheduledReparse()
        await gate.waitForRequestCount(1)

        document.replace(NSRange(location: 0, length: document.storage.length), with: "three\n", actionName: nil)
        document.flushScheduledReparse()
        // The second snapshot waits in the coordinator's one-item pending
        // slot.  It must not start while the first cmark parse is held.
        for _ in 0..<4 { await Task.yield() }
        #expect(await gate.requestCount == 1)
        #expect(concurrency.maximum == 1)

        await gate.releaseNext()
        await gate.waitForRequestCount(2)
        await gate.releaseNext()
        await committed.wait()
        #expect(document.parsed.text == "three\n")
        #expect(concurrency.maximum == 1)
    }

    @Test @MainActor
    func burstKeepsOnlyLatestPendingSnapshot() async {
        let gate = ParseGate()
        let worker = MarkdownParseWorker { text, previous, revision in
            let parsed = MarkdownParser.parse(text)
            return await gate.hold(MarkdownParseResult(
                revision: revision, text: text, document: parsed,
                dirty: ASTDiff.dirtySet(old: previous, new: parsed)
            ))
        }
        let document = MarkdownDocument(parseWorker: worker)
        document.adopt(text: "zero\n", displayURL: nil)

        document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "one\n",
            actionName: nil
        )
        document.flushScheduledReparse()
        await gate.waitForRequestCount(1)

        for text in ["two\n", "three\n", "four\n"] {
            document.replace(
                NSRange(location: 0, length: document.storage.length),
                with: text,
                actionName: nil
            )
            document.flushScheduledReparse()
        }

        for _ in 0..<4 { await Task.yield() }
        #expect(await gate.requestCount == 1)
        await gate.releaseNext()
        await gate.waitForRequestCount(2)
        await gate.releaseNext()
        for _ in 0..<6 { await Task.yield() }
        #expect(document.parsed.text == "four\n")
    }

    @Test @MainActor
    func closeDropsQueuedParseBeforeWorkerStarts() async {
        let gate = ParseGate()
        let worker = MarkdownParseWorker { text, previous, revision in
            let parsed = MarkdownParser.parse(text)
            return await gate.hold(MarkdownParseResult(
                revision: revision, text: text, document: parsed,
                dirty: ASTDiff.dirtySet(old: previous, new: parsed)
            ))
        }
        let document = MarkdownDocument(parseWorker: worker)
        document.adopt(text: "one\n", displayURL: nil)
        document.replace(NSRange(location: 0, length: document.storage.length), with: "two\n", actionName: nil)
        document.close()
        document.flushScheduledReparse()
        await Task.yield()
        #expect(await gate.requestCount == 0)
    }

    @Test @MainActor
    func closeRejectsInFlightParseResult() async {
        let gate = ParseGate()
        let worker = MarkdownParseWorker { text, previous, revision in
            let parsed = MarkdownParser.parse(text)
            return await gate.hold(MarkdownParseResult(
                revision: revision, text: text, document: parsed,
                dirty: ASTDiff.dirtySet(old: previous, new: parsed)
            ))
        }
        let document = MarkdownDocument(parseWorker: worker)
        document.adopt(text: "one\n", displayURL: nil)
        document.replace(NSRange(location: 0, length: document.storage.length), with: "two\n", actionName: nil)
        document.flushScheduledReparse()
        await gate.waitForRequestCount(1)

        document.close()
        await gate.releaseNext()
        for _ in 0..<4 { await Task.yield() }
        #expect(document.parsed.text == "one\n")
    }

    @Test @MainActor
    func reopenAfterCloseAcceptsTheNewestSnapshot() async {
        let committed = ParseSignal()
        let document = MarkdownDocument()
        document.adopt(text: "one\n", displayURL: nil)
        document.close()
        document.adopt(text: "two\n", displayURL: nil)
        document.onReparse = { parsed, _ in
            if parsed.text == "three\n" { Task { await committed.signal() } }
        }

        document.replace(
            NSRange(location: 0, length: document.storage.length),
            with: "three\n",
            actionName: nil
        )
        document.flushScheduledReparse()
        await committed.wait()

        #expect(document.parsed.text == "three\n")
    }

    @Test @MainActor
    func sourceEditPathStaysUnderEightMillisecondsWithoutParsing() {
        let calls = WorkerCallCounter()
        let worker = MarkdownParseWorker { text, previous, revision in
            calls.increment()
            let parsed = MarkdownParser.parse(text)
            return MarkdownParseResult(
                revision: revision, text: text, document: parsed,
                dirty: ASTDiff.dirtySet(old: previous, new: parsed)
            )
        }
        let document = MarkdownDocument(parseWorker: worker)
        let corpus = String(repeating: "line of markdown\n", count: 5_000)
        document.adopt(text: corpus, displayURL: nil)

        var durations: [UInt64] = []
        durations.reserveCapacity(100)
        for _ in 0..<100 {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = document.replace(
                NSRange(location: 0, length: 0), with: "x", actionName: nil
            )
            durations.append(DispatchTime.now().uptimeNanoseconds - start)
        }
        durations.sort()
        let p95 = durations[94]
        print("[typing response] p95 \(Double(p95) / 1_000_000) ms (budget 8.0 ms)")
        #expect(p95 < 8_000_000)
        #expect(calls.value == 0)
    }
}

private actor ParseGate {
    private var requests = 0
    private var continuations: [(CheckedContinuation<MarkdownParseResult, Never>, MarkdownParseResult)] = []

    func hold(_ result: MarkdownParseResult) async -> MarkdownParseResult {
        requests += 1
        return await withCheckedContinuation { continuation in
            continuations.append((continuation, result))
        }
    }

    func waitForRequestCount(_ count: Int) async {
        while requests < count { await Task.yield() }
    }

    func releaseNext() {
        guard !continuations.isEmpty else { return }
        let (continuation, result) = continuations.removeFirst()
        continuation.resume(returning: result)
    }

    var requestCount: Int { requests }
}

private actor ParseSignal {
    private var signalled = false
    private var waiter: CheckedContinuation<Void, Never>?

    func signal() {
        signalled = true
        waiter?.resume()
        waiter = nil
    }

    func wait() async {
        if signalled { return }
        await withCheckedContinuation { waiter = $0 }
    }
}

private final class WorkerCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        defer { lock.unlock() }
        count += 1
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class WorkerConcurrencyCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var currentCount = 0
    private(set) var maximum = 0

    func enter() {
        lock.lock()
        currentCount += 1
        maximum = max(maximum, currentCount)
        lock.unlock()
    }

    func leave() {
        lock.lock()
        currentCount -= 1
        lock.unlock()
    }
}
