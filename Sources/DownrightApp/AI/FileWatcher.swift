import Foundation
import CryptoKit

/// Watches a single file for external rewrites (§8.1).
///
/// The implementation gotcha the spec calls out is the whole reason this class
/// exists in this shape: **every agent CLI writes atomically** — write a temp
/// file, then `rename()` it over the target.  The original inode is unlinked,
/// so a vnode watch on the file silently stops firing and the app quietly stops
/// noticing changes.  So we watch the *parent directory* with FSEvents and
/// match on filename, and we re-stat the file after every event rather than
/// trusting any handle we held before it.
///
/// A slow mtime poll runs alongside as a safety net.  FSEvents is reliable on
/// local volumes but degrades on network and virtualised filesystems, and
/// people keep agent output in Dropbox folders whether or not we sync (§2).
final class FileWatcher {
    struct Snapshot: Equatable {
        var modified: Date
        var size: Int
        var inode: UInt64
        /// A content signature closes the gap where an editor rewrites a file
        /// in place without changing its size or filesystem timestamp.
        var contentDigest: Data?

        static let missing = Snapshot(
            modified: .distantPast,
            size: -1,
            inode: 0,
            contentDigest: nil
        )

        func withContentDigest(_ digest: Data) -> Snapshot {
            var copy = self
            copy.contentDigest = digest
            return copy
        }
    }

    enum Event {
        /// The file's bytes changed on disk.
        case changed
        /// The file went away — deleted, and not found again under a new name.
        case removed
        /// It came back after having been removed.
        case restored
        /// The file was renamed or moved within its directory.  The watcher has
        /// already re-attached; the URL is where it lives now.
        case renamed(to: URL)
    }

    private(set) var url: URL
    private let watchesDirectory: Bool
    private let handler: (Event) -> Void
    /// Extensions a directory watch reports.  A folder of agent output churns
    /// constantly — lockfiles, build artefacts, `.DS_Store` — and matching on
    /// the path prefix alone woke a full sibling rescan for every one of them.
    private let interestingExtensions: Set<String>
    private let queue = DispatchQueue(label: "com.ezzy.downright.filewatcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()

    private var stream: FSEventStreamRef?
    private var streamContext: StreamContext?
    private var pollTimer: DispatchSourceTimer?
    private var lastSnapshot: Snapshot
    private var coalesceWorkItem: DispatchWorkItem?
    /// A filesystem event is a strong signal that content should be checked
    /// immediately. Keep that request when a polling tick happens to
    /// coalesce with the event.
    private var forceContentDigestOnNextCheck = false
    /// Writes we made ourselves must not come back to us as external changes.
    ///
    /// Suppression is a *state*, not a clock: it opens with
    /// `suppressOwnWrite()` and closes at `acknowledgeOwnWrite(contents:)` or
    /// `cancelOwnWriteSuppression()`, however long the write takes — on a
    /// network volume an atomic save can easily outlive any fixed window, and
    /// a window that expires early delivers our own bytes back as a phantom
    /// external change. Two bounded clocks remain, neither load-bearing:
    /// a watchdog that fails open if an acknowledgement is somehow lost, and
    /// a short post-acknowledge grace that keeps late FSEvents from the same
    /// write from being reconciled as externals before the state pass sees
    /// them.
    private var ownWriteInFlight = false
    private var ownWriteWatchdogDeadline = Date.distantPast
    private var settleGraceUntil = Date.distantPast
    /// The last snapshot observed while an own-write suppression window was
    /// open.  This is deliberately separate from `lastSnapshot`: advancing the
    /// baseline before deciding whether a snapshot is ours is the race that
    /// used to swallow an external atomic replacement.
    private var suppressedSnapshots: [Snapshot] = []
    private var suppressionBaseline: Snapshot?
    private var expectedOwnSnapshot: Snapshot?
    private var ownWriteGeneration: UInt64 = 0
    /// Metadata is the cheap path for ordinary polls. Every few polls we
    /// still hash unchanged metadata so an in-place rewrite that preserves
    /// inode, size, and timestamps is detected even on filesystems whose
    /// event stream is unavailable. FSEvents and test probes force a hash.
    private var pollProbeCount: UInt64 = 0
    private let contentDigestPollStride: UInt64 = 4
    /// Bumped on every `stop()` so in-flight coalesced work becomes a no-op.
    private var generation: UInt64 = 0

    /// Weak box so FSEvents callbacks never touch a deallocated watcher after
    /// `stop()` — the stream may still deliver one last burst on its queue.
    private final class StreamContext {
        weak var watcher: FileWatcher?
    }

    /// Agents write a file two to five times in a few seconds — a plan, then a
    /// section, then a fix to that section.  120 ms was short enough that each
    /// of those arrived as its own event, and the reader watched the document
    /// rebuild five times.  300 ms holds a burst together without making a
    /// single deliberate write feel late.  The document layer adds a second,
    /// trailing quiet period on top of this; see
    /// `MarkdownDocument.handleExternalWrite`.
    private let coalesceInterval: TimeInterval = 0.30
    private let pollInterval: TimeInterval = 1.5

    init(
        url: URL,
        watchesDirectory: Bool = false,
        fileExtensions: Set<String>? = nil,
        handler: @escaping (Event) -> Void
    ) {
        self.url = url.resolvingSymlinksInPath()
        self.watchesDirectory = watchesDirectory
        self.interestingExtensions = fileExtensions
            ?? Set(DocumentTypes.fileExtensions.map { $0.lowercased() })
        self.handler = handler
        self.lastSnapshot = FileWatcher.snapshot(of: self.url)
        queue.setSpecific(key: queueKey, value: ())
        start()
    }

    deinit { stop() }

    // MARK: - Lifecycle

    private func start() {
        startStream()
        startPolling()
    }

    func stop() {
        onQueue { stopOnQueue() }
    }

    private func stopOnQueue() {
        generation &+= 1
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        streamContext?.watcher = nil
        streamContext = nil
        pollTimer?.cancel()
        pollTimer = nil
        coalesceWorkItem?.cancel()
        coalesceWorkItem = nil
        forceContentDigestOnNextCheck = false
    }

    /// Point the watcher at a different file (Save As, or following a rename).
    func retarget(to newURL: URL) {
        let resolved = newURL.resolvingSymlinksInPath()
        onQueue {
            guard resolved != url else { return }
            stopOnQueue()
            url = resolved
            lastSnapshot = FileWatcher.snapshot(of: resolved)
            pollProbeCount = 0
            start()
        }
    }

    /// Call immediately before writing the file ourselves.  Our own write would
    /// otherwise arrive back as an external change and re-mark the whole
    /// document — the toggle-a-checkbox case (§8.5) makes this obvious fast.
    ///
    /// Suppression stays open until the matching acknowledgement (or cancel),
    /// regardless of how long the write takes; `interval` only sizes the
    /// lost-acknowledgement watchdog.
    func suppressOwnWrite(for interval: TimeInterval = 0.6) {
        onQueue {
            ownWriteGeneration &+= 1
            suppressionBaseline = lastSnapshot
            expectedOwnSnapshot = nil
            suppressedSnapshots.removeAll(keepingCapacity: true)
            ownWriteInFlight = true
            settleGraceUntil = .distantPast
            // A save that never acknowledged must not mute the watcher
            // forever: fail open after a generous multiple of the caller's
            // expectation, floored well above any honest slow volume.
            ownWriteWatchdogDeadline = Date().addingTimeInterval(max(5.0, interval * 4))
        }
    }

    /// Call after writing so the baseline can reconcile the replacement.  When
    /// supplied, `contents` are the exact bytes Downright intended to write;
    /// retaining them is what distinguishes a racing external replacement from
    /// a successful own save even if no filesystem event arrived yet.
    func acknowledgeOwnWrite(contents: Data? = nil) {
        onQueue {
            let actual = FileWatcher.snapshot(of: url)
            // Passing the bytes written by the document layer lets us tell an
            // external replacement that won the race before this callback from
            // the bytes Downright intended to write.  Keep the no-argument API
            // for existing callers; its snapshot remains the best available
            // fallback when the caller cannot provide the payload.
            expectedOwnSnapshot = contents.map {
                actual.withContentDigest(FileWatcher.contentDigest(for: $0))
            } ?? actual

            if actual == expectedOwnSnapshot {
                lastSnapshot = actual
            } else if actual != lastSnapshot {
                // The file on disk is not the payload we just wrote.  Retain it
                // as an external observation for the reconciliation pass.
                recordSuppressedSnapshot(actual)
            }
            // The write has landed; the very next observation reconciles.
            ownWriteInFlight = false
            settleGraceUntil = Date().addingTimeInterval(0.25)
        }
    }

    /// A guarded save failed before committing our payload. End suppression
    /// immediately so the restored external generation is observed normally.
    func cancelOwnWriteSuppression() {
        onQueue {
            expectedOwnSnapshot = nil
            suppressedSnapshots.removeAll(keepingCapacity: true)
            ownWriteInFlight = false
            settleGraceUntil = .distantPast
            forceContentDigestOnNextCheck = true
            scheduleCheck(forceContentDigest: true)
        }
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    // MARK: - FSEvents

    private func startStream() {
        let directory = (watchesDirectory ? url : url.deletingLastPathComponent()).path
        let box = StreamContext()
        box.watcher = self
        streamContext = box
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<StreamContext>.fromOpaque(info).retain()
                return UnsafeRawPointer(info)
            },
            release: { info in
                guard let info else { return }
                Unmanaged<StreamContext>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let box = Unmanaged<StreamContext>.fromOpaque(info).takeUnretainedValue()
            guard let watcher = box.watcher else { return }
            // Without `kFSEventStreamCreateFlagUseCFTypes`, `eventPaths` is a
            // C array of UTF-8 path pointers. Bridging the raw pointer itself
            // as an NSArray is undefined behaviour and crashes in objc_msgSend.
            let pointers = eventPaths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var paths: [String] = []
            paths.reserveCapacity(count)
            for index in 0..<count {
                guard let path = pointers[index] else { continue }
                paths.append(String(cString: path))
            }
            watcher.handleStreamEvents(paths: paths)
        }

        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault, callback, &context,
            [directory] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.05, flags
        ) else { return }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func handleStreamEvents(paths: [String]) {
        if watchesDirectory {
            let root = url.path.hasSuffix("/") ? url.path : url.path + "/"
            let matches = paths.contains { path in
                guard path == url.path || path.hasPrefix(root) else { return false }
                return isInteresting(path)
            }
            guard matches else { return }
            scheduleDirectoryChange()
            return
        }

        // Match on filename, not on identity: after an atomic write the path
        // is the same file to the user and a different inode to the kernel.
        let target = url.standardizedFileURL.path
        let matches = paths.contains { path in
            URL(fileURLWithPath: path).standardizedFileURL.path == target
        }
        guard matches else { return }
        recordCurrentSnapshotIfSuppressed()
        scheduleCheck(forceContentDigest: true)
    }

    /// Whether a path under a watched directory is worth waking the owner for.
    ///
    /// Markdown files always are.  So is anything with no extension: a new
    /// `docs/` folder, or a `README` written without one.  Everything else —
    /// `.swift`, `.png`, `.tmp`, `.lock` — is noise to a sibling list, and
    /// `.DS_Store` and `.git` churn hardest of all.
    private func isInteresting(_ path: String) -> Bool {
        if path == url.path { return true }
        let name = (path as NSString).lastPathComponent
        if name == ".DS_Store" { return false }
        if path.contains("/.git/") || name == ".git" { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        return ext.isEmpty || interestingExtensions.contains(ext)
    }

    /// Delivers a coalesced `.changed` for directory watches.
    ///
    /// Contract: a directory watch reports *any* interesting churn under the
    /// root — it has no single file to attribute events to. While own-write
    /// suppression is open (the owner writing sidecars or review notes into
    /// the watched folder), deliveries are skipped so the app's own writes
    /// cannot wake an idempotent rescan; the next genuine change re-triggers
    /// one. Any future owner that treats these events as content-to-reload
    /// inherits this filter automatically and must not rely on receiving
    /// events for its own writes.
    private func scheduleDirectoryChange() {
        guard !isSuppressingOwnWrites() else { return }
        coalesceWorkItem?.cancel()
        let gen = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen else { return }
            DispatchQueue.main.async { [handler] in handler(.changed) }
        }
        coalesceWorkItem = item
        queue.asyncAfter(deadline: .now() + coalesceInterval, execute: item)
    }

    // MARK: - Polling safety net

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in self?.scheduleCheck() }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Change detection

    private func scheduleCheck(forceContentDigest: Bool = false) {
        if forceContentDigest {
            forceContentDigestOnNextCheck = true
        }
        coalesceWorkItem?.cancel()
        let gen = generation
        let writeGen = ownWriteGeneration
        let item = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == gen,
                  self.ownWriteGeneration == writeGen
            else { return }
            let shouldForceContentDigest = self.forceContentDigestOnNextCheck
            self.forceContentDigestOnNextCheck = false
            self.check(forceContentDigest: shouldForceContentDigest)
        }
        coalesceWorkItem = item
        queue.asyncAfter(deadline: .now() + coalesceInterval, execute: item)
    }

    /// Synchronous filesystem probe used by deterministic integration tests.
    /// Production notifications still arrive through FSEvents and the polling
    /// safety net; this hook only avoids making race tests depend on scheduler
    /// timing.
    func checkNowForTesting() {
        onQueue { check(forceContentDigest: true) }
    }

    /// A production-shaped metadata-only probe used by deterministic tests to
    /// exercise the bounded same-metadata fallback without waiting 1.5s per
    /// poll. Unlike `checkNowForTesting`, this does not force a content read.
    func pollNowForTesting() {
        onQueue { check(forceContentDigest: false) }
    }

    /// Forces the lost-acknowledgement watchdog to fire on the next check, so
    /// the fail-open path is deterministic instead of waiting out its floor.
    func tripSuppressionWatchdogForTesting() {
        onQueue { ownWriteWatchdogDeadline = .distantPast }
    }

    /// Drives directory-watch event matching directly, without depending on
    /// FSEvents delivery timing.
    func deliverDirectoryEventForTesting(paths: [String]) {
        onQueue { handleStreamEvents(paths: paths) }
    }

    /// Whether own-write suppression is currently absorbing observations.
    /// In-flight covers the whole save transaction; the settle grace only
    /// keeps late events from the just-landed write from racing the state
    /// reconciliation. Correctness never depends on the grace expiring.
    private func isSuppressingOwnWrites(now: Date = Date()) -> Bool {
        ownWriteInFlight || now < settleGraceUntil
    }

    private func check(forceContentDigest: Bool = false) {
        pollProbeCount &+= 1
        // Lost acknowledgement: fail open rather than stay deaf forever.
        if ownWriteInFlight, Date() >= ownWriteWatchdogDeadline {
            ownWriteInFlight = false
            forceContentDigestOnNextCheck = true
        }
        let metadata = FileWatcher.metadata(of: url) ?? .missing
        let metadataChanged = !FileWatcher.metadataMatches(metadata, lastSnapshot)
        let periodicContentProbe = pollProbeCount % contentDigestPollStride == 0
        guard forceContentDigest
                || metadataChanged
                || periodicContentProbe
                || !suppressedSnapshots.isEmpty
                || expectedOwnSnapshot != nil
        else {
            return
        }

        let now = FileWatcher.snapshot(of: url, includeContentDigest: true)

        if isSuppressingOwnWrites() {
            guard now != lastSnapshot else { return }
            if let expectedOwnSnapshot, now == expectedOwnSnapshot {
                // Consume our own replacement, but do not discard an external
                // snapshot observed earlier in the same generation.
                lastSnapshot = now
            } else {
                recordSuppressedSnapshot(now)
            }
            scheduleCheck()
            return
        }

        if !suppressedSnapshots.isEmpty || expectedOwnSnapshot != nil {
            reconcileSuppressedChange(final: now)
            return
        }

        guard now != lastSnapshot else { return }
        let previous = lastSnapshot
        lastSnapshot = now
        deliver(event(for: now, previous: previous))
    }

    /// Reconciles observations made while an own-write window was open.  The
    /// final snapshot is always committed, including when an external change
    /// preceded our own bytes; this prevents a later poll from re-reporting the
    /// suppressed own write.  Only the external snapshot is delivered.
    private func reconcileSuppressedChange(final: Snapshot) {
        let previous = suppressionBaseline ?? lastSnapshot
        let expected = expectedOwnSnapshot
        var candidates = suppressedSnapshots.filter {
            $0 != expected && $0 != previous
        }
        if final != previous, final != expected {
            candidates.append(final)
        }
        // Atomic replacement can expose a brief missing path between unlink
        // and rename.  Once the expected own bytes are present, that transient
        // is part of our save rather than an external removal event.
        if final == expected, !candidates.isEmpty,
           candidates.allSatisfy({ $0.size < 0 }) {
            candidates.removeAll(keepingCapacity: true)
        }
        let observedExternal = candidates.last

        suppressionBaseline = nil
        expectedOwnSnapshot = nil
        suppressedSnapshots.removeAll(keepingCapacity: true)
        ownWriteInFlight = false
        settleGraceUntil = .distantPast
        lastSnapshot = final

        if let observedExternal {
            deliver(event(for: observedExternal, previous: previous))
        }
    }

    private func recordSuppressedSnapshot(_ snapshot: Snapshot) {
        guard snapshot != suppressionBaseline,
              !suppressedSnapshots.contains(snapshot)
        else { return }
        suppressedSnapshots.append(snapshot)
    }

    private func recordCurrentSnapshotIfSuppressed() {
        guard isSuppressingOwnWrites() else { return }
        let snapshot = FileWatcher.snapshot(of: url)
        guard snapshot != lastSnapshot else { return }
        if let expectedOwnSnapshot, snapshot == expectedOwnSnapshot {
            lastSnapshot = snapshot
        } else {
            recordSuppressedSnapshot(snapshot)
        }
    }

    private func deliver(_ event: Event) {
        DispatchQueue.main.async { [handler] in handler(event) }
    }

    private func event(for now: Snapshot, previous: Snapshot) -> Event {

        // An atomic save deletes the original file before renaming the new one
        // in; if we act on the deletion we would close the document or report
        // it gone.  Check if a file with the same inode/size exists in the
        // directory before treating this as a true removal.  (This is also what
        // lets a file renamed in Finder keep its open window.)
        //
        // Sibling scan: if the path went away, scan the parent directory for a
        // file matching the *old* inode and size.  This catches external renames
        // (`mv doc.md archive.md`) that would otherwise leave the watcher
        // resolving and the app used to stop watching for good.  The inode is
        // still there under a new name, so look for it before declaring the
        // document gone.
        if now.size < 0, previous.inode != 0, previous.size >= 0,
           let relocated = FileWatcher.locate(previous, in: url.deletingLastPathComponent()) {
            retarget(to: relocated)
            let newURL = url
            return .renamed(to: newURL)
        }

        let event: Event
        if now.size < 0 {
            event = .removed
        } else if previous.size < 0 {
            event = .restored
        } else {
            event = .changed
        }

        return event
    }

    /// Finds the file that used to be at the watched path, shallowly, in one
    /// directory.
    ///
    /// Matched on the *whole* snapshot — inode, size, modification time, and
    /// content digest — not on the inode alone: a rename changes none of these,
    /// while an inode number freed by a genuine deletion can be handed straight
    /// back to an unrelated new file.
    ///
    /// Only ever runs when the watched file has just disappeared, so the cost
    /// is paid once per removal rather than once per event.  Capped because
    /// "agent output folder" and "ten thousand files" are not mutually
    /// exclusive.
    private static func locate(_ wanted: Snapshot, in directory: URL) -> URL? {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        for name in names.prefix(4096) {
            let candidate = directory.appendingPathComponent(name)
            guard let metadata = metadata(of: candidate),
                  metadata.modified == wanted.modified,
                  metadata.size == wanted.size,
                  metadata.inode == wanted.inode
            else { continue }
            // Only hash a candidate whose inode/metadata could actually be the
            // relocated file; a busy sibling directory should stay cheap.
            if wanted.contentDigest == nil || snapshot(of: candidate) == wanted {
                return candidate
            }
        }
        return nil
    }

    private static func snapshot(of url: URL, includeContentDigest: Bool = true) -> Snapshot {
        for _ in 0..<3 {
            guard let before = metadata(of: url) else { return .missing }
            guard includeContentDigest || before != .missing else { return .missing }
            guard includeContentDigest else { return before }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
                return before
            }
            guard let after = metadata(of: url) else { return .missing }
            guard before == after else { continue }
            return before.withContentDigest(contentDigest(for: data))
        }

        // A file that is being rewritten continuously is still represented by
        // its latest metadata.  The next FSEvents/poll pass will retry the
        // content signature once the writer settles.
        return metadata(of: url) ?? .missing
    }

    private static func metadataMatches(_ lhs: Snapshot, _ rhs: Snapshot) -> Bool {
        lhs.modified == rhs.modified
            && lhs.size == rhs.size
            && lhs.inode == rhs.inode
    }

    private static func metadata(of url: URL) -> Snapshot? {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return nil }
        let seconds = TimeInterval(st.st_mtimespec.tv_sec)
        let nanos = TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return Snapshot(
            modified: Date(timeIntervalSince1970: seconds + nanos),
            size: Int(st.st_size),
            inode: UInt64(st.st_ino),
            contentDigest: nil
        )
    }

    private static func contentDigest(for data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

}
