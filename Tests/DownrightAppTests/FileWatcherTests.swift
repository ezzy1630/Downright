import Foundation
import Testing
@testable import DownrightApp

@Suite("File watcher reconciliation", .serialized)
struct FileWatcherTests {
    @Test("an acknowledged atomic own write is silent")
    func ownWriteIsSuppressed() async throws {
        let fixture = try Fixture(contents: "before")
        defer { fixture.remove() }
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        let own = Data("own bytes".utf8)
        watcher.suppressOwnWrite(for: 0.05)
        try fixture.atomicReplace(own)
        watcher.acknowledgeOwnWrite(contents: own)
        try await settle()
        watcher.checkNowForTesting()
        try await settle()

        #expect(events.count == 0)
    }

    @Test("an external replacement racing an own write is delivered once")
    func externalReplacementInsideSuppressionIsNotSwallowed() async throws {
        let fixture = try Fixture(contents: "before")
        defer { fixture.remove() }
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        let own = Data("own bytes".utf8)
        let external = Data("external".utf8)
        watcher.suppressOwnWrite(for: 0.05)
        try fixture.atomicReplace(own)
        try fixture.atomicReplace(external)
        watcher.acknowledgeOwnWrite(contents: own)
        try await settle()
        watcher.checkNowForTesting()
        try await expectEventCount(events, 1)
        watcher.checkNowForTesting()
        try await settle()

        #expect(events.count == 1)
        #expect(events.isChanged(at: 0))
    }

    @Test("an external replacement observed before the own acknowledgement survives it")
    func externalReplacementBeforeAcknowledgeIsRetained() async throws {
        let fixture = try Fixture(contents: "before")
        defer { fixture.remove() }
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        let own = Data("own bytes".utf8)
        let external = Data("external".utf8)
        watcher.suppressOwnWrite(for: 0.2)
        try fixture.atomicReplace(external)
        watcher.checkNowForTesting()
        try fixture.atomicReplace(own)
        watcher.acknowledgeOwnWrite(contents: own)
        try await settle()
        watcher.checkNowForTesting()
        try await expectEventCount(events, 1)

        #expect(events.count == 1)
        #expect(events.isChanged(at: 0))
    }

    @Test("a settled burst reports once and repeated probes stay quiet")
    func burstIsExactlyOnce() async throws {
        let fixture = try Fixture(contents: "before")
        defer { fixture.remove() }
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        try fixture.atomicReplace(Data("first".utf8))
        try fixture.atomicReplace(Data("second".utf8))
        try fixture.atomicReplace(Data("settled".utf8))
        watcher.checkNowForTesting()
        try await expectEventCount(events, 1)
        watcher.checkNowForTesting()
        try await settle()

        #expect(events.count == 1)
        #expect(events.isChanged(at: 0))
    }

    @Test("same-size, same-metadata rewrites are detected by content")
    func sameMetadataRewriteIsDetected() async throws {
        let fixture = try Fixture(contents: "aaaa")
        defer { fixture.remove() }
        let originalDate = try FileManager.default
            .attributesOfItem(atPath: fixture.url.path)[.modificationDate] as! Date
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("bbbb".utf8))
        try handle.truncate(atOffset: 4)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: fixture.url.path
        )
        watcher.checkNowForTesting()
        try await expectEventCount(events, 1)

        #expect(events.count == 1)
        #expect(events.isChanged(at: 0))
    }

    @Test("same-metadata rewrites are bounded when the poll path is used")
    func sameMetadataRewriteIsDetectedByBoundedPolling() async throws {
        let fixture = try Fixture(contents: "aaaa")
        defer { fixture.remove() }
        let originalDate = try FileManager.default
            .attributesOfItem(atPath: fixture.url.path)[.modificationDate] as! Date
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        // Leave the initial metadata baseline untouched, then rewrite in
        // place while preserving size and mtime. The production poll path
        // hashes at a bounded cadence rather than every ordinary poll.
        watcher.pollNowForTesting()
        let handle = try FileHandle(forWritingTo: fixture.url)
        try handle.seek(toOffset: 0)
        try handle.write(contentsOf: Data("bbbb".utf8))
        try handle.truncate(atOffset: 4)
        try handle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: originalDate],
            ofItemAtPath: fixture.url.path
        )

        for _ in 0..<3 {
            watcher.pollNowForTesting()
        }
        watcher.pollNowForTesting()
        try await expectEventCount(events, 1)
        #expect(events.isChanged(at: 0))
    }

    @Test("rename, removal, and restoration retain their event semantics")
    func renameRemoveRestore() async throws {
        let fixture = try Fixture(contents: "document")
        defer { fixture.remove() }
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        let renamedURL = fixture.directory.appendingPathComponent("renamed.md")
        try FileManager.default.moveItem(at: fixture.url, to: renamedURL)
        watcher.checkNowForTesting()
        try await expectEventCount(events, 1)
        #expect(events.isRename(to: renamedURL, at: 0))

        try FileManager.default.removeItem(at: renamedURL)
        watcher.checkNowForTesting()
        try await expectEventCount(events, 2)
        #expect(events.isRemoved(at: 1))

        try Data("restored".utf8).write(to: renamedURL)
        watcher.checkNowForTesting()
        try await expectEventCount(events, 3)
        #expect(events.isRestored(at: 2))
    }

    /// Regression: an external atomic save observed inside its unlink→rename
    /// gap used to be delivered as `.removed` — the sibling scan looks for
    /// the *old* inode, which the replacement does not have. A tentative
    /// removal now waits out one bounded re-probe.
    @Test("an external atomic replacement observed mid-gap is a change, not a removal")
    func atomicReplacementObservedMidGapIsNotARemoval() async throws {
        let fixture = try Fixture(contents: "document")
        defer { fixture.remove() }
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        watcher.checkNowForTesting()

        // The unlink phase of an external atomic save: the watched path is
        // missing and the old inode is gone (a parked sibling would make
        // this an ordinary rename, which follows immediately).
        try FileManager.default.removeItem(at: fixture.url)
        watcher.checkNowForTesting()
        #expect(events.count == 0, "the transient gap must not be reported")

        // The rename phase lands new content at the path before the probe.
        try Data("rewritten".utf8).write(to: fixture.url)
        watcher.resolveRemovalProbeForTesting()

        try await expectEventCount(events, 1)
        #expect(events.isChanged(at: 0), "the replacement must arrive as a change")
    }

    @Test("a genuine removal is still delivered once the re-probe resolves")
    func trueRemovalIsStillDelivered() async throws {
        let fixture = try Fixture(contents: "document")
        defer { fixture.remove() }
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        watcher.checkNowForTesting()
        try FileManager.default.removeItem(at: fixture.url)
        watcher.checkNowForTesting()
        #expect(events.count == 0, "the probe has not resolved yet")
        watcher.resolveRemovalProbeForTesting()

        try await expectEventCount(events, 1)
        #expect(events.isRemoved(at: 0))
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 350_000_000)
    }

    /// A save on a slow volume can stay in flight far longer than any fixed
    /// suppression window. Suppression is a state now, so the observation
    /// made while the write is still unacknowledged — and the acknowledged
    /// bytes themselves — must both stay silent, and only genuine later
    /// external activity may deliver.
    @Test("a write still unacknowledged past the old clock window stays suppressed")
    func slowVolumeSaveIsNotAPhantomExternalChange() async throws {
        let fixture = try Fixture(contents: "before")
        defer { fixture.remove() }
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        let own = Data("own bytes written slowly".utf8)
        watcher.suppressOwnWrite(for: 0.05)
        try fixture.atomicReplace(own)

        // Outlive the caller's whole interval and the legacy 0.6 s window.
        try await Task.sleep(nanoseconds: 700_000_000)
        watcher.checkNowForTesting()
        try await settle()
        #expect(events.count == 0, "an in-flight own write must not arrive as an external change")

        watcher.acknowledgeOwnWrite(contents: own)
        watcher.checkNowForTesting()
        try await settle()
        #expect(events.count == 0, "the acknowledged bytes stay silent too")

        let external = Data("genuinely external".utf8)
        try fixture.atomicReplace(external)
        watcher.checkNowForTesting()
        try await expectEventCount(events, 1)
        #expect(events.count == 1)
        #expect(events.isChanged(at: 0))
    }

    /// If an acknowledgement is somehow lost, the watchdog fails open instead
    /// of leaving the watcher deaf forever.
    @Test("a lost acknowledgement trips the watchdog back to detection")
    func lostAcknowledgementFailsOpen() async throws {
        let fixture = try Fixture(contents: "before")
        defer { fixture.remove() }
        let events = EventCollector()
        let watcher = FileWatcher(url: fixture.url) { events.append($0) }
        defer { watcher.stop() }

        let own = Data("unacknowledged bytes".utf8)
        watcher.suppressOwnWrite(for: 5)
        try fixture.atomicReplace(own)
        watcher.tripSuppressionWatchdogForTesting()

        watcher.checkNowForTesting()
        try await expectEventCount(events, 1)
        #expect(events.isChanged(at: 0), "fail-open surfaces the unacknowledged write as change")

        // And the watcher keeps detecting afterwards.
        try fixture.atomicReplace(Data("later".utf8))
        watcher.checkNowForTesting()
        try await expectEventCount(events, 2)
    }

    /// Directory watches honor the same own-write suppression: the owner
    /// writing sidecars into the watched folder must not wake an idempotent
    /// rescan, and detection resumes once suppression ends.
    @Test("directory watch skips deliveries while own-write suppression is open")
    func directoryWatchRespectsOwnWriteSuppression() async throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-dirwatch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = directory.appendingPathComponent("sibling.md")
        try Data("first\n".utf8).write(to: sibling)

        let events = EventCollector()
        let watcher = FileWatcher(
            url: directory,
            watchesDirectory: true,
            fileExtensions: ["md"]
        ) { events.append($0) }
        defer { watcher.stop() }

        watcher.suppressOwnWrite(for: 5)
        try Data("second\n".utf8).write(to: sibling)
        watcher.deliverDirectoryEventForTesting(paths: [sibling.path])
        try await settle()
        #expect(events.count == 0, "our own write into the folder stays silent")

        watcher.cancelOwnWriteSuppression()
        watcher.deliverDirectoryEventForTesting(paths: [sibling.path])
        try await expectEventCount(events, 1)
        #expect(events.isChanged(at: 0))
    }

    private func expectEventCount(_ events: EventCollector, _ count: Int) async throws {
        for _ in 0..<100 {
            if events.count >= count { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        Issue.record("Timed out waiting for (count) file-watcher event(s); got (events.count)")
    }
}

private final class EventCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [FileWatcher.Event] = []

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return values.count
    }

    func append(_ event: FileWatcher.Event) {
        lock.lock(); defer { lock.unlock() }
        values.append(event)
    }

    func isChanged(at index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values.indices.contains(index) else { return false }
        if case .changed = values[index] { return true }
        return false
    }

    func isRemoved(at index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values.indices.contains(index) else { return false }
        if case .removed = values[index] { return true }
        return false
    }

    func isRestored(at index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values.indices.contains(index) else { return false }
        if case .restored = values[index] { return true }
        return false
    }

    func isRename(to url: URL, at index: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard values.indices.contains(index) else { return false }
        if case let .renamed(target) = values[index] {
            return target.standardizedFileURL == url.standardizedFileURL
        }
        return false
    }
}

private final class Fixture {
    let directory: URL
    let url: URL

    init(contents: String) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-filewatcher-(UUID().uuidString)")
        url = directory.appendingPathComponent("document.md")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
    }

    func atomicReplace(_ data: Data) throws {
        let temporary = directory.appendingPathComponent(".tmp-(UUID().uuidString)")
        try data.write(to: temporary)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temporary)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
