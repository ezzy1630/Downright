import Foundation
import MarkdownCore
import MarkdownRender

/// Per-document reading state (§8.2, §9.3).
///
/// Long documents behave like books: you get your place back.  The position is
/// stored as a **heading anchor plus an offset into that section**, never as a
/// byte offset — an agent that inserts two paragraphs at the top of the file
/// would otherwise land you two paragraphs off every time.
struct ScrollAnchor: Codable, Equatable {
    /// Slug of the nearest heading at or above the viewport top.
    var headingSlug: String
    /// Index of that heading, as a tiebreak when slugs repeat.
    var headingIndex: Int
    /// Fraction of the way through that section, 0…1.
    var fractionThroughSection: Double

    static let top = ScrollAnchor(headingSlug: "", headingIndex: 0, fractionThroughSection: 0)
}

struct DocumentState: Codable, Equatable {
    var path: String
    /// Content hash at the moment the document was last closed.  If the bytes
    /// differ on reopen, §8.1 change marks are applied automatically (§8.2).
    var lastSeenHash: String
    var anchor: ScrollAnchor
    var mode: RenderMode
    var zoomLevel: ZoomLevel
    /// Heading slugs whose sections are folded.
    var foldedHeadings: Set<String>
    /// Source offsets of code blocks the user explicitly expanded or collapsed,
    /// overriding the auto-collapse rule (§5.1).
    var expandedCodeBlocks: Set<Int>
    var collapsedCodeBlocks: Set<Int>
    var lastOpened: Date
    var sidebarVisible: Bool
    var selectionLocation: Int
    var selectionLength: Int
    var splitViewEnabled: Bool

    init(path: String) {
        self.path = path
        self.lastSeenHash = ""
        self.anchor = .top
        self.mode = .live
        self.zoomLevel = .everything
        self.foldedHeadings = []
        self.expandedCodeBlocks = []
        self.collapsedCodeBlocks = []
        self.lastOpened = Date()
        self.sidebarVisible = false
        self.selectionLocation = 0
        self.selectionLength = 0
        self.splitViewEnabled = false
    }

    // Older state files won't have every key; decode leniently so a version
    // bump never costs the user their reading positions.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        path = try c.decodeIfPresent(String.self, forKey: .path) ?? ""
        lastSeenHash = try c.decodeIfPresent(String.self, forKey: .lastSeenHash) ?? ""
        anchor = try c.decodeIfPresent(ScrollAnchor.self, forKey: .anchor) ?? .top
        mode = (try c.decodeIfPresent(RenderMode.self, forKey: .mode) ?? .live).normalizedForEditing
        zoomLevel = try c.decodeIfPresent(ZoomLevel.self, forKey: .zoomLevel) ?? .everything
        foldedHeadings = try c.decodeIfPresent(Set<String>.self, forKey: .foldedHeadings) ?? []
        expandedCodeBlocks = try c.decodeIfPresent(Set<Int>.self, forKey: .expandedCodeBlocks) ?? []
        collapsedCodeBlocks = try c.decodeIfPresent(Set<Int>.self, forKey: .collapsedCodeBlocks) ?? []
        lastOpened = try c.decodeIfPresent(Date.self, forKey: .lastOpened) ?? Date()
        sidebarVisible = try c.decodeIfPresent(Bool.self, forKey: .sidebarVisible) ?? false
        selectionLocation = try c.decodeIfPresent(Int.self, forKey: .selectionLocation) ?? 0
        selectionLength = try c.decodeIfPresent(Int.self, forKey: .selectionLength) ?? 0
        splitViewEnabled = try c.decodeIfPresent(Bool.self, forKey: .splitViewEnabled) ?? false
    }
}

/// Entry in the recents list, kept with enough detail to draw a rendered
/// thumbnail without opening the file (§9.3).
struct RecentDocument: Codable, Equatable, Identifiable {
    var id: String { path }
    var path: String
    var displayName: String
    var firstHeading: String
    var lastOpened: Date
    var wordCount: Int
}

final class DocumentStateStore {
    static let shared = DocumentStateStore()

    private let fm = FileManager.default
    private var cache: [String: DocumentState] = [:]
    private let lock = NSLock()

    private init() { AppPaths.ensure(AppPaths.stateDirectory) }

    // MARK: - Per-document state

    func state(for url: URL) -> DocumentState {
        let key = SnapshotStore.documentKey(for: url)
        lock.lock()
        if let cached = cache[key] { lock.unlock(); return cached }
        lock.unlock()

        let fileURL = AppPaths.stateDirectory.appendingPathComponent(key + ".json")
        var state: DocumentState
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder.snapshotDecoder.decode(DocumentState.self, from: data) {
            state = decoded
        } else {
            state = DocumentState(path: url.path)
        }
        state.path = url.path

        lock.lock(); cache[key] = state; lock.unlock()
        return state
    }

    func save(_ state: DocumentState, for url: URL) {
        let key = SnapshotStore.documentKey(for: url)
        lock.lock(); cache[key] = state; lock.unlock()

        guard let data = try? JSONEncoder.snapshotEncoder.encode(state) else { return }
        let fileURL = AppPaths.stateDirectory.appendingPathComponent(key + ".json")
        try? data.write(to: fileURL, options: .atomic)
    }

    // MARK: - Recents

    private var recentsURL: URL { AppPaths.supportDirectory.appendingPathComponent("recents.json") }

    func recents(limit: Int = 30) -> [RecentDocument] {
        guard let data = try? Data(contentsOf: recentsURL),
              let list = try? JSONDecoder.snapshotDecoder.decode([RecentDocument].self, from: data)
        else { return [] }
        return Array(list.sorted { $0.lastOpened > $1.lastOpened }.prefix(limit))
    }

    func noteOpened(_ url: URL, document: ParsedDocument) {
        var list = recents(limit: 200).filter { $0.path != url.path }
        list.insert(
            RecentDocument(
                path: url.path,
                displayName: url.deletingPathExtension().lastPathComponent,
                firstHeading: document.headings.first?.title ?? "",
                lastOpened: Date(),
                wordCount: Metrics.metrics(for: document.text).words
            ),
            at: 0
        )
        list = Array(list.prefix(60))
        if let data = try? JSONEncoder.snapshotEncoder.encode(list) {
            try? data.write(to: recentsURL, options: .atomic)
        }
    }

    func clearRecents() {
        try? fm.removeItem(at: recentsURL)
    }
}

// MARK: - Anchoring

enum ScrollAnchoring {
    /// Builds an anchor for a source offset.  Used when the buffer is about to
    /// be replaced under the reader (§8.1) and when closing the document.
    static func anchor(for offset: Int, in document: ParsedDocument) -> ScrollAnchor {
        guard !document.headings.isEmpty else {
            let fraction = document.length > 0 ? Double(offset) / Double(document.length) : 0
            return ScrollAnchor(headingSlug: "", headingIndex: 0, fractionThroughSection: fraction)
        }

        var index = 0
        for (i, heading) in document.headings.enumerated() where heading.range.location <= offset {
            index = i
        }
        let heading = document.headings[index]
        let span = max(1, heading.sectionRange.length)
        let within = min(max(0, offset - heading.sectionRange.location), span)
        return ScrollAnchor(
            headingSlug: heading.slug,
            headingIndex: index,
            fractionThroughSection: Double(within) / Double(span)
        )
    }

    /// Resolves an anchor back to a source offset in a possibly-rewritten
    /// document.  Matching by slug first is what makes the position survive an
    /// agent inserting a whole new section above where you were reading.
    static func offset(for anchor: ScrollAnchor, in document: ParsedDocument) -> Int {
        guard !document.headings.isEmpty else {
            return Int(anchor.fractionThroughSection * Double(document.length))
        }
        guard !anchor.headingSlug.isEmpty else { return 0 }

        let candidates = document.headings.enumerated().filter { $0.element.slug == anchor.headingSlug }
        let heading: HeadingNode
        if let exact = candidates.first(where: { $0.offset == anchor.headingIndex })?.element {
            heading = exact
        } else if let nearest = candidates.min(by: {
            abs($0.offset - anchor.headingIndex) < abs($1.offset - anchor.headingIndex)
        })?.element {
            heading = nearest
        } else if anchor.headingIndex < document.headings.count {
            // The heading is gone entirely — fall back to positional.
            heading = document.headings[anchor.headingIndex]
        } else {
            heading = document.headings[document.headings.count - 1]
        }

        let offset = heading.sectionRange.location
            + Int(anchor.fractionThroughSection * Double(heading.sectionRange.length))
        return min(max(0, offset), document.length)
    }
}
