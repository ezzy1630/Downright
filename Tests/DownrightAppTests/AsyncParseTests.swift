import Foundation
import Testing
import MarkdownCore
@testable import DownrightApp

@Suite(.serialized)
struct AsyncParseTests {
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
    func latestRevisionWinsWithoutWaitingForOlderWorker() async {
        let gate = ParseGate()
        let committed = ParseSignal()
        let worker = MarkdownParseWorker { text, previous, revision in
            let parsed = MarkdownParser.parse(text)
            let result = MarkdownParseResult(
                revision: revision, text: text, document: parsed,
                dirty: ASTDiff.dirtySet(old: previous, new: parsed)
            )
            return await gate.hold(result)
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
        await gate.waitForRequestCount(2)

        await gate.releaseNext()
        await gate.releaseNext()
        await committed.wait()
        #expect(document.parsed.text == "three\n")
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
