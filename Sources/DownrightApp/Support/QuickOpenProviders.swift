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

    init(_ raw: String) {
        self.raw = raw
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch value.lowercased() {
        case ">": filter = .commands; terms = ""
        case "#task", "#tasks": filter = .tasks; terms = ""
        default:
            if value.lowercased().hasPrefix("file:") {
                filter = .files; terms = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if value.lowercased().hasPrefix("asset:") {
                filter = .assets; terms = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else if value.lowercased().hasPrefix("link:") {
                filter = .links; terms = String(value.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            } else if value.hasPrefix("@") {
                filter = .symbols; terms = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if value.hasPrefix(">") {
                filter = .commands; terms = String(value.dropFirst()).trimmingCharacters(in: .whitespaces)
            } else if value.lowercased().hasPrefix("#task ") {
                filter = .tasks; terms = String(value.dropFirst(6)).trimmingCharacters(in: .whitespaces)
            } else {
                filter = .all; terms = value
            }
        }
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
    let subtitle: String
    let action: QuickOpenAction
    let score: Int

    init(
        id: String,
        kind: QuickOpenProviderKind,
        title: String,
        subtitle: String = "",
        action: QuickOpenAction,
        score: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.subtitle = subtitle
        self.action = action
        self.score = score
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
                                              subtitle: destination, action: .select(span.range)))
            case .image(let source, let alt):
                guard query.filter == .all || query.filter == .assets else { continue }
                output.append(QuickOpenResult(id: "asset:\(span.range.location):\(index)", kind: .asset,
                                              title: alt.isEmpty ? source : alt, subtitle: source, action: .select(span.range)))
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
                                subtitle: $0.path, action: .open($0))
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
                            action: .open($0))
        }
    }
}
