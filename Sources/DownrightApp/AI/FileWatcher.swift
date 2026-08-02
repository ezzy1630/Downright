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
        /// The file went away — deleted, or renamed out from under us.
        case removed
        /// It came back after having been removed.
        case restored
    }

    private(set) var url: URL
    private let watchesDirectory: Bool
    private let handler: (Event) -> Void
    private let queue = DispatchQueue(label: "com.ezzyrappeport.downright.filewatcher", qos: .utility)

    private var stream: FSEventStreamRef?
    private var pollTimer: DispatchSourceTimer?
    private var lastSnapshot: Snapshot
    private var coalesceWorkItem: DispatchWorkItem?
    /// Writes we made ourselves must not come back to us as external changes.
    private var suppressUntil: Date = .distantPast
    private var suppressedSnapshot: Snapshot?

    /// Agents often write a file two or three times in quick succession.
    /// Coalescing avoids re-parsing and re-diffing a document three times for
    /// what the user experiences as one change.
    private let coalesceInterval: TimeInterval = 0.12
    private let pollInterval: TimeInterval = 1.5

    init(url: URL, watchesDirectory: Bool = false, handler: @escaping (Event) -> Void) {
        self.url = url.resolvingSymlinksInPath()
        self.watchesDirectory = watchesDirectory
        self.handler = handler
        self.lastSnapshot = FileWatcher.snapshot(of: self.url)
        start()
    }

    deinit { stop() }

    // MARK: - Lifecycle

    private func start() {
        startStream()
        startPolling()
    }

    func stop() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        pollTimer?.cancel()
        pollTimer = nil
        coalesceWorkItem?.cancel()
    }

    /// Point the watcher at a different file (Save As, or following a rename).
    func retarget(to newURL: URL) {
        let resolved = newURL.resolvingSymlinksInPath()
        guard resolved != url else { return }
        stop()
        url = resolved
        lastSnapshot = FileWatcher.snapshot(of: resolved)
        start()
    }

    /// Call immediately before writing the file ourselves.  Our own write would
    /// otherwise arrive back as an external change and re-mark the whole
    /// document — the toggle-a-checkbox case (§8.5) makes this obvious fast.
    func suppressOwnWrite(for interval: TimeInterval = 0.6) {
        queue.sync {
            suppressUntil = Date().addingTimeInterval(interval)
            suppressedSnapshot = nil
        }
    }

    /// Call after writing so the baseline matches what is now on disk.
    func acknowledgeOwnWrite() {
        queue.sync {
            lastSnapshot = FileWatcher.snapshot(of: url)
            suppressUntil = Date().addingTimeInterval(0.25)
        }
    }

    // MARK: - FSEvents

    private func startStream() {
        let directory = (watchesDirectory ? url : url.deletingLastPathComponent()).path
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, info, count, eventPaths, _, _ in
            guard let info else { return }
            let watcher = Unmanaged<FileWatcher>.fromOpaque(info).takeUnretainedValue()
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
            guard paths.contains(where: { $0 == url.path || $0.hasPrefix(root) }) else { return }
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

    private func scheduleDirectoryChange() {
        coalesceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [handler] in handler(.changed) }
        }
        coalesceWorkItem = item
        queue.asyncAfter(deadline: .now() + coalesceInterval, execute: item)
    }

    // MARK: - Polling safety net

    private func startPolling() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .milliseconds(400))
        timer.setEventHandler { [weak self] in self?.check() }
        timer.resume()
        pollTimer = timer
    }

    // MARK: - Change detection

    private func scheduleCheck() {
        coalesceWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.check() }
        coalesceWorkItem = item
        queue.asyncAfter(deadline: .now() + coalesceInterval, execute: item)
    }

    private func check() {
        let now = FileWatcher.snapshot(of: url)
        guard now != lastSnapshot else { return }

        let previous = lastSnapshot
        lastSnapshot = now

        if Date() < suppressUntil {
            // Our own write landing.  Absorb it, but keep the new baseline.
            suppressedSnapshot = now
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

        DispatchQueue.main.async { [handler] in handler(event) }
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
