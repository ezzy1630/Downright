import Foundation

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

        static let missing = Snapshot(modified: .distantPast, size: -1, inode: 0)
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
    /// Writes we made ourselves must not come back to us as external changes.
    private var suppressUntil: Date = .distantPast
    private var suppressedSnapshot: Snapshot?
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
    }

    /// Point the watcher at a different file (Save As, or following a rename).
    func retarget(to newURL: URL) {
        let resolved = newURL.resolvingSymlinksInPath()
        onQueue {
            guard resolved != url else { return }
            stopOnQueue()
            url = resolved
            lastSnapshot = FileWatcher.snapshot(of: resolved)
            start()
        }
    }

    /// Call immediately before writing the file ourselves.  Our own write would
    /// otherwise arrive back as an external change and re-mark the whole
    /// document — the toggle-a-checkbox case (§8.5) makes this obvious fast.
    func suppressOwnWrite(for interval: TimeInterval = 0.6) {
        onQueue {
            suppressUntil = Date().addingTimeInterval(interval)
            suppressedSnapshot = nil
        }
    }

    /// Call after writing so the baseline matches what is now on disk.
    func acknowledgeOwnWrite() {
        onQueue {
            lastSnapshot = FileWatcher.snapshot(of: url)
            suppressUntil = Date().addingTimeInterval(0.25)
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
        scheduleCheck()
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

    private func scheduleDirectoryChange() {
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

    private func scheduleCheck() {
        coalesceWorkItem?.cancel()
        let gen = generation
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.generation == gen else { return }
            self.check()
        }
        coalesceWorkItem = item
        queue.asyncAfter(deadline: .now() + coalesceInterval, execute: item)
    }

    private func check() {
        let now = FileWatcher.snapshot(of: url)
        guard now != lastSnapshot else { return }

        let previous = lastSnapshot
        lastSnapshot = now

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
            DispatchQueue.main.async { [handler] in handler(.renamed(to: newURL)) }
            return
        }

        let event: Event
        if now.size < 0 {
            event = .removed
        } else if previous.size < 0 {
            event = .restored
        } else {
            event = .changed
        }

        if Date() < suppressUntil {
            // Still inside the suppression window for our own write.
            // Defer notification until the suppression window closes and
            // acknowledgeOwnWrite has had an opportunity to update lastSnapshot.
            scheduleCheck()
            return
        }

        // Absorb a snapshot we already surfaced while the suppression window was
        // open (FSEvents can retransmit), so the one external write is reported
        // once, not repeatedly for each delivery.
        if let suppressed = suppressedSnapshot, now == suppressed {
            suppressedSnapshot = nil
            return
        }
        suppressedSnapshot = nil

        DispatchQueue.main.async { [handler] in handler(event) }
    }

    /// Finds the file that used to be at the watched path, shallowly, in one
    /// directory.
    ///
    /// Matched on the *whole* snapshot — inode, size, and modification time —
    /// not on the inode alone: a rename changes none of the three, while an
    /// inode number freed by a genuine deletion can be handed straight back to
    /// an unrelated new file.
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
            if snapshot(of: candidate) == wanted { return candidate }
        }
        return nil
    }

    private static func snapshot(of url: URL) -> Snapshot {
        var st = stat()
        guard stat(url.path, &st) == 0 else { return .missing }
        let seconds = TimeInterval(st.st_mtimespec.tv_sec)
        let nanos = TimeInterval(st.st_mtimespec.tv_nsec) / 1_000_000_000
        return Snapshot(
            modified: Date(timeIntervalSince1970: seconds + nanos),
            size: Int(st.st_size),
            inode: UInt64(st.st_ino)
        )
    }
}
