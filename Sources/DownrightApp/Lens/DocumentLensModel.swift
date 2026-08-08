import Foundation
import MarkdownCore

/// The seven views in Document Lens.  The order is the order shown in the
/// panel and is part of the keyboard contract.
enum DocumentLensTab: String, CaseIterable, Identifiable, Sendable {
    case structure
    case health
    case links
    case assets
    case tasks
    case changes
    case renderTarget

    var id: String { rawValue }

    var title: String {
        switch self {
        case .structure: "Structure"
        case .health: "Health"
        case .links: "Links"
        case .assets: "Assets"
        case .tasks: "Tasks"
        case .changes: "Changes"
        case .renderTarget: "Render Target"
        }
    }
}

enum DocumentLensItemKind: String, Sendable {
    case heading
    case block
    case health
    case link
    case image
    case task
    case change
    case compatibility
}

enum DocumentLensSeverity: String, Sendable {
    case info
    case warning
    case error
}

struct DocumentLensItem: Identifiable, Sendable {
    let id: String
    let title: String
    let detail: String
    let range: NSRange
    let kind: DocumentLensItemKind
    let severity: DocumentLensSeverity?
    let isResolved: Bool?

    init(
        id: String,
        title: String,
        detail: String = "",
        range: NSRange,
        kind: DocumentLensItemKind,
        severity: DocumentLensSeverity? = nil,
        isResolved: Bool? = nil
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.range = range
        self.kind = kind
        self.severity = severity
        self.isResolved = isResolved
    }
}

struct DocumentLensGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let items: [DocumentLensItem]

    var count: Int { items.count }
}

struct DocumentLensSection: Identifiable, Sendable {
    let tab: DocumentLensTab
    let groups: [DocumentLensGroup]

    var id: String { tab.id }
    var count: Int { groups.reduce(0) { $0 + $1.items.count } }
    var items: [DocumentLensItem] { groups.flatMap(\.items) }
}

/// A small, Sendable representation of a change mark.  The app keeps the
/// tracker private; this value is the dependency boundary for the pure Lens
/// builder and also makes tests deterministic.
struct DocumentLensChange: Sendable {
    let id: String
    let kind: ChangeKind
    let range: NSRange
    let wordRanges: [NSRange]

    init(id: String, kind: ChangeKind, range: NSRange, wordRanges: [NSRange] = []) {
        self.id = id
        self.kind = kind
        self.range = range
        self.wordRanges = wordRanges
    }
}

struct DocumentLensInput: Sendable {
    let document: ParsedDocument
    let health: [DocumentHealthDiagnostic]
    let assetReferences: [AssetReference]
    let assets: [AssetDiagnostic]
    let renderTarget: CompatibilityReport?
    let changes: [DocumentLensChange]

    init(
        document: ParsedDocument,
        health: [DocumentHealthDiagnostic] = [],
        assetReferences: [AssetReference] = [],
        assets: [AssetDiagnostic] = [],
        renderTarget: CompatibilityReport? = nil,
        changes: [DocumentLensChange] = []
    ) {
        self.document = document
        self.health = health
        self.assetReferences = assetReferences
        self.assets = assets
        self.renderTarget = renderTarget
        self.changes = changes
    }
}

/// Pure, injected data for the Document Lens panel.  It performs no file I/O,
/// no URL resolution, and no AppKit work.  All item ranges are UTF-16 ranges
/// into `DocumentLensInput.document.text`.
struct DocumentLensModel: Sendable {
    let sections: [DocumentLensSection]

    init(input: DocumentLensInput) {
        self.sections = [
            Self.structure(input.document),
            Self.health(input.health),
            Self.links(input.document),
            Self.assets(input.assetReferences, diagnostics: input.assets),
            Self.tasks(input.document),
            Self.changes(input.changes),
            Self.renderTarget(input.renderTarget),
        ]
    }

    func section(_ tab: DocumentLensTab) -> DocumentLensSection {
        sections.first { $0.tab == tab } ?? DocumentLensSection(tab: tab, groups: [])
    }

    private static func structure(_ document: ParsedDocument) -> DocumentLensSection {
        var items: [DocumentLensItem] = []
        var blockOrdinal = 0
        var representedRanges = Set<String>()
        for block in document.root.flattened() where block.contentRange.length > 0 {
            let rangeKey = "\(block.range.location):\(block.range.length)"
            guard representedRanges.insert(rangeKey).inserted else { continue }
            switch block.content {
            case .heading(let level):
                let title = document.substring(block.contentRange).trimmingCharacters(in: .whitespacesAndNewlines)
                items.append(DocumentLensItem(
                    id: "heading:\(block.range.location)", title: title.isEmpty ? "Untitled heading" : title,
                    detail: "H\(level)", range: block.range, kind: .heading
                ))
            case .document:
                continue
            default:
                let detail = blockLabel(block.content)
                items.append(DocumentLensItem(
                    id: "block:\(block.range.location):\(blockOrdinal)", title: detail,
                    detail: sourceLine(document, at: block.range.location), range: block.range, kind: .block
                ))
                blockOrdinal += 1
            }
        }
        return DocumentLensSection(tab: .structure, groups: [DocumentLensGroup(id: "structure", title: "Document", items: items)])
    }

    private static func health(_ diagnostics: [DocumentHealthDiagnostic]) -> DocumentLensSection {
        let groups = grouped(diagnostics, key: { $0.category.rawValue.capitalized }) { diagnostic in
            DocumentLensItem(
                id: "health:\(diagnostic.id):\(diagnostic.range.location)", title: diagnostic.message,
                detail: diagnostic.explanation, range: diagnostic.range, kind: .health,
                severity: severity(diagnostic.severity)
            )
        }
        return DocumentLensSection(
            tab: .health,
            groups: groups.isEmpty ? [DocumentLensGroup(id: "health", title: "No issues", items: [])] : groups
        )
    }

    private static func links(_ document: ParsedDocument) -> DocumentLensSection {
        var links: [DocumentLensItem] = []
        document.root.walk { block in
            for inline in block.inlines {
                inline.walk { span in
                    let item: DocumentLensItem?
                    switch span.kind {
                    case .link(let destination, let title):
                        item = DocumentLensItem(
                            id: "link:\(span.range.location)", title: destination,
                            detail: title ?? "Link", range: span.range, kind: .link
                        )
                    case .autolink(let destination):
                        item = DocumentLensItem(
                            id: "link:\(span.range.location)", title: destination,
                            detail: "Autolink", range: span.range, kind: .link
                        )
                    case .wikilink(let target, let label):
                        item = DocumentLensItem(
                            id: "link:\(span.range.location)", title: label ?? target,
                            detail: target, range: span.range, kind: .link
                        )
                    case .image(let source, let alt):
                        item = DocumentLensItem(
                            id: "image:\(span.range.location)", title: source,
                            detail: alt.isEmpty ? "No alt text" : alt, range: span.range, kind: .image
                        )
                    default:
                        item = nil
                    }
                    if let item { links.append(item) }
                }
            }
        }
        let linkItems = links.filter { $0.kind == .link }
        let imageItems = links.filter { $0.kind == .image }
        var groups: [DocumentLensGroup] = []
        if !linkItems.isEmpty { groups.append(DocumentLensGroup(id: "links", title: "Links", items: linkItems)) }
        if !imageItems.isEmpty { groups.append(DocumentLensGroup(id: "images", title: "Images", items: imageItems)) }
        if groups.isEmpty { groups = [DocumentLensGroup(id: "links", title: "Links", items: [])] }
        return DocumentLensSection(tab: .links, groups: groups)
    }

    private static func assets(_ references: [AssetReference], diagnostics: [AssetDiagnostic]) -> DocumentLensSection {
        var items = references.map { reference in
            let diagnostic = diagnostics.first { diagnostic in
                diagnostic.reference.imageRange == reference.imageRange ||
                    diagnostic.range.intersection(reference.imageRange) != nil
            }
            let detail = diagnostic.map { "\($0.message) · \(reference.altText.isEmpty ? "No alt text" : reference.altText)" }
                ?? (reference.altText.isEmpty ? "No alt text" : reference.altText)
            return DocumentLensItem(
                id: "asset:\(reference.imageRange.location)", title: reference.source,
                detail: detail, range: reference.imageRange, kind: .image,
                severity: diagnostic.map { assetSeverity($0.severity) }
            )
        }
        if references.isEmpty {
            items = diagnostics.map { diagnostic in
                DocumentLensItem(
                    id: diagnostic.id, title: diagnostic.message, detail: diagnostic.reference.source,
                    range: diagnostic.range, kind: .image, severity: assetSeverity(diagnostic.severity)
                )
            }
        }
        let groups = items.isEmpty ? [] : [DocumentLensGroup(id: "assets", title: "Images", items: items)]
        return DocumentLensSection(
            tab: .assets,
            groups: groups.isEmpty ? [DocumentLensGroup(id: "assets", title: "No asset issues", items: [])] : groups
        )
    }

    private static func tasks(_ document: ParsedDocument) -> DocumentLensSection {
        let items = document.tasks.enumerated().map { index, task in
            DocumentLensItem(
                id: "task:\(task.markRange.location):\(index)", title: task.text,
                detail: task.isChecked ? "Done" : "Open", range: task.contentRange,
                kind: .task, isResolved: task.isChecked
            )
        }
        return DocumentLensSection(tab: .tasks, groups: [DocumentLensGroup(id: "tasks", title: "Tasks", items: items)])
    }

    private static func changes(_ changes: [DocumentLensChange]) -> DocumentLensSection {
        let items = changes.map {
            DocumentLensItem(
                id: "change:\($0.id)", title: $0.kind.rawValue.capitalized,
                detail: $0.wordRanges.isEmpty ? "Changed source" : "Changed words",
                range: $0.range, kind: .change
            )
        }
        return DocumentLensSection(
            tab: .changes,
            groups: [DocumentLensGroup(id: "changes", title: items.isEmpty ? "No recent changes" : "Recent changes", items: items)]
        )
    }

    private static func renderTarget(_ report: CompatibilityReport?) -> DocumentLensSection {
        guard let report else {
            return DocumentLensSection(tab: .renderTarget, groups: [DocumentLensGroup(id: "target", title: "No target selected", items: [])])
        }
        let items = report.diagnostics.map {
            DocumentLensItem(
                id: "compatibility:\($0.id)", title: $0.title, detail: $0.explanation,
                range: $0.range, kind: .compatibility, severity: .warning
            )
        }
        return DocumentLensSection(tab: .renderTarget, groups: [DocumentLensGroup(id: "target", title: report.profile.name, items: items)])
    }

    private static func grouped<T>(
        _ values: [T], key: (T) -> String, item: (T) -> DocumentLensItem
    ) -> [DocumentLensGroup] {
        var order: [String] = []
        var buckets: [String: [DocumentLensItem]] = [:]
        for value in values {
            let name = key(value)
            if buckets[name] == nil { order.append(name) }
            buckets[name, default: []].append(item(value))
        }
        return order.map { DocumentLensGroup(id: $0, title: $0, items: buckets[$0] ?? []) }
    }

    private static func severity(_ severity: DocumentHealthSeverity) -> DocumentLensSeverity {
        switch severity {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }

    private static func assetSeverity(_ severity: AssetDiagnosticSeverity) -> DocumentLensSeverity {
        switch severity {
        case .info: .info
        case .warning: .warning
        case .error: .error
        }
    }

    private static func sourceLine(_ document: ParsedDocument, at offset: Int) -> String {
        "Line \(document.line(at: offset))"
    }

    private static func blockLabel(_ content: BlockContent) -> String {
        switch content {
        case .paragraph: "Paragraph"
        case .blockQuote: "Block quote"
        case .callout(let kind, _): "Callout · \(kind.rawValue.capitalized)"
        case .list: "List"
        case .listItem: "List item"
        case .codeBlock(let language, _, _): "Code\(language.map { " · \($0)" } ?? "")"
        case .mermaid: "Mermaid diagram"
        case .mathBlock: "Math block"
        case .table: "Table"
        case .thematicBreak: "Divider"
        case .htmlBlock: "HTML block"
        case .frontMatter: "Front matter"
        case .footnoteDefinition(let identifier): "Footnote · \(identifier)"
        case .document, .heading: "Block"
        }
    }
}
