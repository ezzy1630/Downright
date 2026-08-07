import Foundation
import MarkdownCore

enum QuickOpenProviderKind: String, CaseIterable {
    case command
    case heading
    case link
    case footnote
    case task
    case asset
    case recentFile
    case workspaceFile
    case symbol
}

enum QuickOpenFilter: Equatable {
    case all
    case commands
    case headings
    case tasks
    case assets
    case links
    case files
    case symbols
}

struct QuickOpenQuery: Equatable {
    let raw: String
    let filter: QuickOpenFilter
    let terms: String

    /// Prefixes, longest first, because `#task` must win over `#`.  One table
    /// rather than a chain of `hasPrefix` branches, so a filter cannot be
    /// declared and then left unreachable — which is exactly how `.headings`
    /// became dead code.
    private static let prefixes: [(marker: String, filter: QuickOpenFilter)] = [
        ("#tasks", .tasks),
        ("#task", .tasks),
        ("asset:", .assets),
        ("file:", .files),
        ("link:", .links),
        ("#", .headings),
        ("@", .symbols),
        (">", .commands),
    ]

    init(_ raw: String) {
        self.raw = raw
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = value.lowercased()
        for (marker, filter) in Self.prefixes where lowered.hasPrefix(marker) {
            self.filter = filter
            self.terms = String(value.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            return
        }
        filter = .all
        terms = value
    }
}

enum QuickOpenAction: Equatable {
    case command(Command)
    case select(NSRange)
    case open(URL)
    case openAt(URL, NSRange)
}

struct QuickOpenResult: Identifiable, Equatable {
    let id: String
    let kind: QuickOpenProviderKind
    let title: String
    /// Rendered chrome — "⌘⇧K  ·  Document", "Heading 2".  Displayed, never
    /// searched: matching against it made `doc` match most of the app.
    let subtitle: String
    /// Extra text the query may match: a file path, a link destination, a
    /// command's synonyms.  Searched, never displayed.
    let searchText: String
    let action: QuickOpenAction
    let score: Int

    init(
        id: String,
        kind: QuickOpenProviderKind,
        title: String,
        subtitle: String = "",
        searchText: String = "",
        action: QuickOpenAction,
        score: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.searchText = searchText
        self.action = action
        self.score = score
    }

    /// The same result with a rank attached.  Scoring lives in the palette
    /// model, so every provider's results are ranked by one function.
    func scored(_ score: Int) -> QuickOpenResult {
        QuickOpenResult(
            id: id, kind: kind, title: title, subtitle: subtitle, searchText: searchText,
            action: action, score: score
        )
    }
}

protocol QuickOpenProvider {
    var id: String { get }
    func results(for query: QuickOpenQuery) -> [QuickOpenResult]
}

struct CurrentDocumentQuickOpenProvider: QuickOpenProvider {
    let id = "current-document"
    let document: ParsedDocument

    func results(for query: QuickOpenQuery) -> [QuickOpenResult] {
        var output: [QuickOpenResult] = []
        let wantsHeadings = query.filter == .all || query.filter == .headings || query.filter == .symbols
        if wantsHeadings {
            output += document.headings.map {
                QuickOpenResult(id: "heading:\($0.range.location)", kind: .heading,
                                title: $0.title, subtitle: "Heading \($0.level)", action: .select($0.range))
            }
        }
        let wantsTasks = query.filter == .all || query.filter == .tasks
        if wantsTasks {
            output += document.tasks.map {
                QuickOpenResult(id: "task:\($0.markRange.location)", kind: .task,
                                title: $0.text, subtitle: $0.isChecked ? "Done" : "Task", action: .select($0.contentRange))
            }
        }
        let wantsFootnotes = query.filter == .all
        if wantsFootnotes {
            output += document.footnotes.keys.sorted().compactMap { identifier in
                guard let block = document.footnotes[identifier] else { return nil }
                return QuickOpenResult(id: "footnote:\(identifier)", kind: .footnote,
                                       title: "Footnote \(identifier)", subtitle: "Definition", action: .select(block.range))
            }
        }

        let spans = document.root.flattened().flatMap(\.inlines).flatMap(Self.flatten)
        for (index, span) in spans.enumerated() {
            switch span.kind {
            case .link(let destination, _), .autolink(let destination):
                guard query.filter == .all || query.filter == .links else { continue }
                let label = document.substring(span.contentRange)
                output.append(QuickOpenResult(id: "link:\(span.range.location):\(index)", kind: .link,
                                              title: label.isEmpty ? destination : label,
                                              subtitle: destination, searchText: destination,
                                              action: .select(span.range)))
            case .image(let source, let alt):
                guard query.filter == .all || query.filter == .assets else { continue }
                output.append(QuickOpenResult(id: "asset:\(span.range.location):\(index)", kind: .asset,
                                              title: alt.isEmpty ? source : alt, subtitle: source,
                                              searchText: source, action: .select(span.range)))
            case .footnoteReference(let identifier):
                guard query.filter == .all else { continue }
                output.append(QuickOpenResult(id: "footnote-ref:\(span.range.location):\(index)", kind: .footnote,
                                              title: "Footnote \(identifier)", subtitle: "Reference", action: .select(span.range)))
            default: continue
            }
        }
        return output
    }

    private static func flatten(_ span: InlineSpan) -> [InlineSpan] {
        [span] + span.children.flatMap(flatten)
    }
}

struct WorkspaceQuickOpenProvider: QuickOpenProvider {
    let id = "workspace"
    let files: [URL]
    let symbols: [QuickOpenResult]

    func results(for query: QuickOpenQuery) -> [QuickOpenResult] {
        var output: [QuickOpenResult] = []
        if query.filter == .all || query.filter == .files {
            output += files.map {
                QuickOpenResult(id: "file:\($0.path)", kind: .workspaceFile,
                                title: $0.deletingPathExtension().lastPathComponent,
                                subtitle: $0.path, searchText: $0.path, action: .open($0))
            }
        }
        if query.filter == .all || query.filter == .symbols { output += symbols }
        return output
    }
}

struct RecentFilesQuickOpenProvider: QuickOpenProvider {
    let id = "recent-files"
    let files: [URL]

    func results(for query: QuickOpenQuery) -> [QuickOpenResult] {
        guard query.filter == .all || query.filter == .files else { return [] }
        return files.map {
            QuickOpenResult(id: "recent:\($0.path)", kind: .recentFile,
                            title: $0.lastPathComponent, subtitle: $0.deletingLastPathComponent().path,
                            searchText: $0.path, action: .open($0))
        }
    }
}
