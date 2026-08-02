import Foundation
import MarkdownCore

private final class WorkspaceCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

private final class WorkspaceURLCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []

    func append(_ url: URL) {
        lock.withLock { urls.append(url) }
    }

    var values: [URL] { lock.withLock { urls } }

    var count: Int { lock.withLock { urls.count } }
}

private final class WorkspaceScanState: @unchecked Sendable {
    let lock = NSLock()
    var cursor = 0
    var skipped = 0
    var totalBytes: Int64 = 0
    var entries: [WorkspaceIndexEntry] = []
}

/// Files that can be indexed by the optional workspace surface.
public struct WorkspaceIndexPolicy: Sendable, Equatable {
    public var markdownExtensions: Set<String>
    public var ignoredDirectoryNames: Set<String>
    public var ignoresHiddenDirectories: Bool
    public var maximumFiles: Int
    public var maximumBytesPerFile: Int64
    public var maximumTotalBytes: Int64
    public var readConcurrency: Int

    public init(
        markdownExtensions: Set<String> = ["md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd"],
        ignoredDirectoryNames: Set<String> = [".git", ".build", "build", "vendor", "node_modules", "DerivedData", ".swiftpm", "Pods"],
        ignoresHiddenDirectories: Bool = true,
        maximumFiles: Int = 10_000,
        maximumBytesPerFile: Int64 = 10 * 1024 * 1024,
        maximumTotalBytes: Int64 = 100 * 1024 * 1024,
        readConcurrency: Int = 4
    ) {
        self.markdownExtensions = Set(markdownExtensions.map { $0.lowercased() })
        self.ignoredDirectoryNames = ignoredDirectoryNames
        self.ignoresHiddenDirectories = ignoresHiddenDirectories
        self.maximumFiles = max(1, maximumFiles)
        self.maximumBytesPerFile = max(1, maximumBytesPerFile)
        self.maximumTotalBytes = max(1, maximumTotalBytes)
        self.readConcurrency = min(16, max(1, readConcurrency))
    }

    public static let `default` = WorkspaceIndexPolicy()

    public func accepts(_ url: URL, isDirectory: Bool) -> Bool {
        if isDirectory {
            let name = url.lastPathComponent
            if ignoredDirectoryNames.contains(name) { return false }
            if ignoresHiddenDirectories && name.hasPrefix(".") { return false }
            return true
        }
        return markdownExtensions.contains(url.pathExtension.lowercased())
    }
}

public struct WorkspaceHeading: Sendable, Hashable {
    public let title: String
    public let range: NSRange
    public let level: Int

    public init(title: String, range: NSRange, level: Int) {
        self.title = title
        self.range = range
        self.level = level
    }
}

public struct WorkspaceFrontMatterField: Sendable, Hashable {
    public let key: String
    public let value: String
    public let range: NSRange

    public init(key: String, value: String, range: NSRange) {
        self.key = key
        self.value = value
        self.range = range
    }
}

public enum WorkspaceLinkKind: String, Sendable, Hashable {
    case markdown
    case wikilink
}

public struct WorkspaceLink: Sendable, Hashable {
    public let destination: String
    public let range: NSRange
    public let kind: WorkspaceLinkKind

    public init(destination: String, range: NSRange, kind: WorkspaceLinkKind) {
        self.destination = destination
        self.range = range
        self.kind = kind
    }
}

public struct WorkspaceIndexEntry: Identifiable, Sendable, Hashable {
    public let id: String
    public let url: URL
    public let relativePath: String
    public let text: String
    public let headings: [WorkspaceHeading]
    public let frontMatter: [WorkspaceFrontMatterField]
    public let links: [WorkspaceLink]
    public let byteCount: Int64

    public init(
        url: URL,
        relativePath: String,
        text: String,
        headings: [WorkspaceHeading],
        frontMatter: [WorkspaceFrontMatterField],
        links: [WorkspaceLink],
        byteCount: Int64
    ) {
        self.id = url.standardizedFileURL.path
        self.url = url
        self.relativePath = relativePath
        self.text = text
        self.headings = headings
        self.frontMatter = frontMatter
        self.links = links
        self.byteCount = byteCount
    }
}

public struct WorkspaceIndexSnapshot: Sendable, Equatable {
    public let rootURL: URL
    public let revision: Int
    public let entries: [WorkspaceIndexEntry]
    public let skippedFiles: Int

    public init(rootURL: URL, revision: Int, entries: [WorkspaceIndexEntry], skippedFiles: Int = 0) {
        self.rootURL = rootURL
        self.revision = revision
        self.entries = entries
        self.skippedFiles = skippedFiles
    }

    public static let empty = WorkspaceIndexSnapshot(rootURL: URL(fileURLWithPath: "/"), revision: 0, entries: [])
}

/// Optional, local-only workspace index.  The index has no database and no
/// network path.  New scans cancel the old scan, and a stale revision cannot
/// replace a newer snapshot.
@MainActor
final class WorkspaceIndex {
    typealias Enumerator = @Sendable (URL, WorkspaceIndexPolicy) -> [URL]
    typealias StreamingEnumerator = @Sendable (URL, WorkspaceIndexPolicy, @Sendable (URL) -> Bool) -> Void
    typealias Reader = @Sendable (URL) -> (text: String, byteCount: Int64)?

    var onUpdate: ((WorkspaceIndexSnapshot) -> Void)?
    private(set) var snapshot = WorkspaceIndexSnapshot.empty

    private let policy: WorkspaceIndexPolicy
    private let enumerator: StreamingEnumerator
    private let reader: Reader
    private var task: Task<Void, Never>?
    private var cancellationToken: WorkspaceCancellationToken?
    private var revision = 0

    convenience init(policy: WorkspaceIndexPolicy = .default) {
        self.init(policy: policy, streamingEnumerator: Self.defaultEnumerator, reader: Self.defaultReader)
    }

    convenience init(policy: WorkspaceIndexPolicy, enumerator: @escaping Enumerator, reader: @escaping Reader) {
        self.init(
            policy: policy,
            streamingEnumerator: { rootURL, policy, accept in
                for url in enumerator(rootURL, policy) {
                    if !accept(url) { break }
                }
            },
            reader: reader
        )
    }

    private init(policy: WorkspaceIndexPolicy, streamingEnumerator: @escaping StreamingEnumerator, reader: @escaping Reader) {
        self.policy = policy
        self.enumerator = streamingEnumerator
        self.reader = reader
    }

    deinit {
        cancellationToken?.cancel()
        task?.cancel()
    }

    func start(rootURL: URL) {
        revision += 1
        let currentRevision = revision
        cancellationToken?.cancel()
        task?.cancel()
        let cancellationToken = WorkspaceCancellationToken()
        self.cancellationToken = cancellationToken
        let policy = policy
        let enumerator = enumerator
        let reader = reader
        task = Task { [weak self] in
            let snapshot = await Task.detached(priority: .userInitiated) {
                Self.buildSnapshot(
                    rootURL: rootURL.standardizedFileURL,
                    revision: currentRevision,
                    policy: policy,
                    enumerator: enumerator,
                    reader: reader,
                    cancellationToken: cancellationToken
                )
            }.value
            guard !Task.isCancelled else { return }
            guard let self, self.revision == currentRevision else { return }
            self.snapshot = snapshot
            self.onUpdate?(snapshot)
        }
    }

    func cancel() {
        revision += 1
        cancellationToken?.cancel()
        cancellationToken = nil
        task?.cancel()
        task = nil
    }

    func reroot(to rootURL: URL) {
        let rootURL = rootURL.standardizedFileURL
        cancel()
        snapshot = WorkspaceIndexSnapshot(rootURL: rootURL, revision: revision, entries: [])
        onUpdate?(snapshot)
        start(rootURL: rootURL)
    }

    nonisolated private static func buildSnapshot(
        rootURL: URL,
        revision: Int,
        policy: WorkspaceIndexPolicy,
        enumerator: @escaping StreamingEnumerator,
        reader: @escaping Reader,
        cancellationToken: WorkspaceCancellationToken
    ) -> WorkspaceIndexSnapshot {
        let collector = WorkspaceURLCollector()
        let state = WorkspaceScanState()
        enumerator(rootURL, policy) { url in
            guard !cancellationToken.isCancelled else { return false }
            guard policy.accepts(url, isDirectory: false) else { return true }
            if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
               Int64(size) > policy.maximumBytesPerFile {
                state.lock.withLock { state.skipped += 1 }
                return true
            }
            collector.append(url)
            return collector.count < policy.maximumFiles
        }
        let urls = collector.values

        // A small worker pool gives predictable memory use without creating one
        // task per file.  The reader is injected, so tests never touch disk.
        DispatchQueue.concurrentPerform(iterations: min(policy.readConcurrency, max(1, urls.count))) { _ in
            while true {
                guard !cancellationToken.isCancelled else { return }
                state.lock.lock()
                guard state.cursor < urls.count else {
                    state.lock.unlock()
                    return
                }
                let url = urls[state.cursor]
                state.cursor += 1
                state.lock.unlock()

                if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                   Int64(size) > policy.maximumBytesPerFile {
                    state.lock.withLock { state.skipped += 1 }
                    continue
                }

                guard let result = reader(url),
                      result.byteCount >= 0,
                      result.byteCount <= policy.maximumBytesPerFile else {
                    state.lock.withLock { state.skipped += 1 }
                    continue
                }
                state.lock.lock()
                let fitsBudget = result.byteCount <= policy.maximumTotalBytes - state.totalBytes
                if fitsBudget {
                    state.totalBytes += result.byteCount
                } else {
                    state.skipped += 1
                }
                state.lock.unlock()
                guard fitsBudget else { continue }

                let document = MarkdownParser.parse(result.text)
                let entry = Self.entry(
                    url: url,
                    rootURL: rootURL,
                    text: result.text,
                    document: document,
                    byteCount: result.byteCount
                )
                guard !cancellationToken.isCancelled else { return }
                state.lock.withLock { state.entries.append(entry) }
            }
        }

        state.entries.sort { $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending }
        return WorkspaceIndexSnapshot(
            rootURL: rootURL,
            revision: revision,
            entries: state.entries,
            skippedFiles: state.skipped
        )
    }

    nonisolated private static func entry(
        url: URL,
        rootURL: URL,
        text: String,
        document: ParsedDocument,
        byteCount: Int64
    ) -> WorkspaceIndexEntry {
        let headings = document.headings.map {
            WorkspaceHeading(title: $0.title, range: $0.range, level: $0.level)
        }
        let fields = document.frontMatter?.fields.map {
            WorkspaceFrontMatterField(key: $0.key, value: $0.value, range: $0.keyRange.union($0.valueRange))
        } ?? []
        var links: [WorkspaceLink] = []
        document.root.walk { block in
            for inline in block.inlines {
                inline.walk { span in
                    switch span.kind {
                    case .link(let destination, _), .autolink(let destination):
                        links.append(WorkspaceLink(destination: destination, range: span.range, kind: .markdown))
                    case .wikilink(let target, _):
                        links.append(WorkspaceLink(destination: target, range: span.range, kind: .wikilink))
                    default:
                        break
                    }
                }
            }
        }
        let relative = url.standardizedFileURL.path.replacingOccurrences(
            of: rootURL.standardizedFileURL.path.hasSuffix("/")
                ? rootURL.standardizedFileURL.path : rootURL.standardizedFileURL.path + "/",
            with: ""
        )
        return WorkspaceIndexEntry(
            url: url, relativePath: relative, text: text, headings: headings,
            frontMatter: fields, links: links, byteCount: byteCount
        )
    }

    private static let defaultEnumerator: StreamingEnumerator = { root, policy, accept in
        guard let iterator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .fileSizeKey],
            options: []
        ) else { return }
        for case let url as URL in iterator {
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if !policy.accepts(url, isDirectory: true) { iterator.skipDescendants() }
                continue
            }
            if values?.isRegularFile == true, policy.accepts(url, isDirectory: false), !accept(url) {
                return
            }
        }
    }

    private static let defaultReader: Reader = { url in
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return (text, Int64(data.count))
    }
}
