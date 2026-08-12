import CoreServices
import Foundation

/// A directory watcher for `down watch` — the fallback path for agents that have
/// no hook system at all.
///
/// This deliberately mirrors the app's own `FileWatcher` in the one decision that
/// matters: **watch the parent directory, never the file**.  Every agent CLI
/// writes atomically — temp file, then `rename()` over the target — which unlinks
/// the original inode and silently kills any watch held against it.  A vnode
/// watch on the file would work perfectly in testing and then stop firing the
/// moment a real agent touched it.
///
/// Coalescing is not an optimisation here either.  A single agent edit routinely
/// produces several FSEvents (write, rename, attribute change), and one `open`
/// process per event would spawn a handful of launches for one logical change.
public final class AgentWatcher {
    /// How long to wait for a burst of events to settle before reporting.
    /// 300ms is comfortably longer than the write→rename gap of an atomic save
    /// and comfortably shorter than a human noticing a delay.
    public static let defaultDebounce: TimeInterval = 0.3

    private let roots: [URL]
    private let debounce: TimeInterval
    private let handler: ([URL]) -> Void
    private let queue = DispatchQueue(label: "com.ezzy.downright.agentwatcher", qos: .utility)
    private let queueKey = DispatchSpecificKey<Void>()

    private var stream: FSEventStreamRef?
    private final class StreamContext {
        weak var watcher: AgentWatcher?
    }
    private var streamContext: StreamContext?
    /// Resolved once at `start()`.  Recomputing it per event would stat the
    /// file system on every write in a busy directory to answer a question whose
    /// answer cannot change while the stream is running.
    private var watchPlan = WatchPlan(directories: [], allowedFiles: [])
    /// Paths accumulated since the last flush, in first-seen order.
    private var pending: [String] = []
    private var pendingSeen = Set<String>()
    private var flush: DispatchWorkItem?
    /// Content signature of every path already reported, so a metadata-only
    /// event cannot report the same unchanged bytes twice.  Bounded below.
    private var reported: [String: Signature] = [:]

    /// Enough of a file to tell "the agent rewrote this" from "something touched
    /// its metadata".  Deliberately *not* a hash: this runs on every event in a
    /// directory that may be churning, and reading file contents to decide
    /// whether to read file contents is the wrong trade.
    struct Signature: Equatable {
        var modified: Date
        var size: Int

        init?(path: String) {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
                  let modified = attributes[.modificationDate] as? Date,
                  let size = attributes[.size] as? Int
            else { return nil }
            self.modified = modified
            self.size = size
        }
    }

    /// Ceiling on the signature table for a watch left running over a large
    /// tree.  Clearing it is safe: a forgotten path is reported once more, which
    /// is a duplicate open at worst, never a missed change.
    private static let signatureLimit = 4096

    /// - Parameters:
    ///   - roots: files or directories to watch.  A file root is watched through
    ///     its parent directory and filtered back down to that one path.
    ///   - debounce: quiet period before a burst is reported.
    ///   - handler: called on the watcher's queue with the coalesced Markdown
    ///     files that changed.  Never called with an empty array.
    public init(
        roots: [URL],
        debounce: TimeInterval = AgentWatcher.defaultDebounce,
        handler: @escaping ([URL]) -> Void
    ) {
        self.roots = roots.map { $0.standardizedFileURL }
        self.debounce = debounce
        self.handler = handler
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { stop() }

    /// The directories FSEvents is asked to watch, and the file filter derived
    /// from the roots.  Split out from `start()` because it is the part worth
    /// reasoning about: a root that is a file contributes its parent directory
    /// to the watch set and its own path to the allow-list, while a root that is
    /// a directory contributes itself and allows everything beneath it.
    struct WatchPlan {
        var directories: [String]
        /// Exact file paths to allow.  Empty means "allow anything under the
        /// watched directories".
        var allowedFiles: Set<String>
    }

    static func plan(for roots: [URL]) -> WatchPlan {
        var directories: [String] = []
        var allowedFiles = Set<String>()
        var sawDirectory = false
        for root in roots {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory)
            if exists, isDirectory.boolValue {
                sawDirectory = true
                directories.append(root.path)
            } else {
                // A file that does not exist yet is still a legitimate target —
                // agents create files as well as rewrite them — so this does not
                // require existence, only that the parent directory is real.
                directories.append(root.deletingLastPathComponent().path)
                allowedFiles.insert(root.path)
            }
        }
        var seen = Set<String>()
        directories = directories.filter { seen.insert($0).inserted }
        // A directory root subsumes any file root under it; mixing the two would
        // otherwise let the allow-list suppress everything the directory wanted.
        return WatchPlan(directories: directories, allowedFiles: sawDirectory ? [] : allowedFiles)
    }

    /// True when an event path should be reported, given a plan.
    static func accepts(_ path: String, plan: WatchPlan) -> Bool {
        guard MarkdownCLI.isMarkdownPath(path) else { return false }
        guard !plan.allowedFiles.isEmpty else { return true }
        return plan.allowedFiles.contains(path)
    }

    @discardableResult
    public func start() -> Bool {
        stop()
        return onQueue { startOnQueue() }
    }

    private func startOnQueue() -> Bool {
        let plan = Self.plan(for: roots)
        guard !plan.directories.isEmpty else { return false }
        watchPlan = plan

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
        // Without `kFSEventStreamCreateFlagUseCFTypes` the callback receives a
        // plain `char **`.  That is deliberate: the CFTypes form hands back a
        // `CFArrayRef`, and reading one as a C array does not fail loudly — it
        // decodes garbage that quietly fails the Markdown filter, so the watcher
        // runs forever and simply never reports anything.
        let callback: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let box = Unmanaged<StreamContext>.fromOpaque(info).takeUnretainedValue()
            guard let watcher = box.watcher else { return }
            let raw = paths.assumingMemoryBound(to: UnsafePointer<CChar>?.self)
            var changed: [String] = []
            for index in 0..<count {
                guard let entry = raw[index] else { continue }
                changed.append(String(cString: entry))
            }
            guard !changed.isEmpty else { return }
            watcher.absorb(changed)
        }

        // `FileEvents` is what makes the callback report individual paths rather
        // than the directory; without it every event would arrive as the folder
        // and the filter below could not tell Markdown from build output.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            plan.directories as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            debounce / 2,
            flags
        ) else { return false }

        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        return FSEventStreamStart(stream)
    }

    public func stop() {
        onQueue { stopOnQueue() }
    }

    private func stopOnQueue() {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
        streamContext?.watcher = nil
        streamContext = nil
        flush?.cancel()
        flush = nil
        pending.removeAll(keepingCapacity: false)
        pendingSeen.removeAll(keepingCapacity: false)
    }

    private func onQueue<T>(_ body: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return body() }
        return queue.sync(execute: body)
    }

    private func absorb(_ paths: [String]) {
        queue.async { [weak self] in
            guard let self else { return }
            for path in paths where Self.accepts(path, plan: self.watchPlan) {
                let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
                if self.pendingSeen.insert(standardized).inserted {
                    self.pending.append(standardized)
                }
            }
            guard !self.pending.isEmpty else { return }
            self.scheduleFlush()
        }
    }

    private func scheduleFlush() {
        flush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pending
            self.pending.removeAll(keepingCapacity: true)
            self.pendingSeen.removeAll(keepingCapacity: true)
            guard !batch.isEmpty else { return }
            // Signatures are taken at flush time, not at event time.  A file
            // written and then deleted inside one debounce window has no
            // signature and drops out here, so the app is never launched for a
            // path that is already gone.
            //
            // This is also what breaks the feedback loop that makes a naive
            // version of this watcher unusable: opening a document updates the
            // file's metadata, macOS reports that as another event on the same
            // path, and the watcher opens it again — forever.  A metadata touch
            // leaves modification date and size alone, so it stops here.
            if self.reported.count > Self.signatureLimit { self.reported.removeAll(keepingCapacity: true) }
            var urls: [URL] = []
            for path in batch {
                guard let signature = Signature(path: path) else { continue }
                guard self.reported[path] != signature else { continue }
                self.reported[path] = signature
                urls.append(URL(fileURLWithPath: path))
            }
            guard !urls.isEmpty else { return }
            self.handler(urls)
        }
        flush = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
