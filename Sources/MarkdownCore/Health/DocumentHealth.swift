import Foundation

/// Severity used by the document-health pass.  The pass never mutates a
/// document; a fix is only suggested when its edit is local and unambiguous.
public enum DocumentHealthSeverity: String, CaseIterable, Sendable {
    case info
    case warning
    case error
}

public enum DocumentHealthCategory: String, CaseIterable, Sendable {
    case structure
    case accessibility
    case references
    case links
    case media
    case syntax
    case prose
}

/// A deterministic finding.  `id` is a rule identifier, not a UUID generated
/// at runtime, so the same source produces the same findings on every pass.
public struct DocumentHealthDiagnostic: Sendable {
    public let id: String
    public let severity: DocumentHealthSeverity
    public let category: DocumentHealthCategory
    /// UTF-16 source range in the analyzed document.
    public let range: NSRange
    public let message: String
    public let explanation: String
    public let fix: TextEdit?

    public init(
        id: String,
        severity: DocumentHealthSeverity,
        category: DocumentHealthCategory,
        range: NSRange,
        message: String,
        explanation: String,
        fix: TextEdit? = nil
    ) {
        self.id = id
        self.severity = severity
        self.category = category
        self.range = range
        self.message = message
        self.explanation = explanation
        self.fix = fix
    }
}

public struct DocumentHealthOptions: Sendable {
    public var maxSectionWords: Int
    public var maxSentenceWords: Int
    public var maxParagraphWords: Int

    public init(
        maxSectionWords: Int = 500,
        maxSentenceWords: Int = 35,
        maxParagraphWords: Int = 120
    ) {
        self.maxSectionWords = max(1, maxSectionWords)
        self.maxSentenceWords = max(1, maxSentenceWords)
        self.maxParagraphWords = max(1, maxParagraphWords)
    }

    public static let `default` = DocumentHealthOptions()
}

/// Resolver injected by the app layer.  MarkdownCore deliberately performs
/// no file I/O.  Return `true` when the path is known to exist.
public struct DocumentHealthResolver: Sendable {
    public var exists: @Sendable (String) -> Bool

    public init(exists: @escaping @Sendable (String) -> Bool) {
        self.exists = exists
    }
}

public struct DocumentHealthReport: Sendable {
    public let diagnostics: [DocumentHealthDiagnostic]

    public init(diagnostics: [DocumentHealthDiagnostic]) {
        self.diagnostics = diagnostics
    }
}

public enum DocumentHealth {
    public static func analyze(
        _ text: String,
        options: DocumentHealthOptions = .default,
        resolver: DocumentHealthResolver? = nil
    ) -> [DocumentHealthDiagnostic] {
        analyze(MarkdownParser.parse(text), options: options, resolver: resolver)
    }

    public static func analyze(
        _ text: String,
        options: DocumentHealthOptions = .default,
        resolver: @escaping @Sendable (String) -> Bool
    ) -> [DocumentHealthDiagnostic] {
        analyze(text, options: options, resolver: DocumentHealthResolver(exists: resolver))
    }

    public static func analyze(
        _ document: ParsedDocument,
        options: DocumentHealthOptions = .default,
        resolver: DocumentHealthResolver? = nil
    ) -> [DocumentHealthDiagnostic] {
        HealthPass(document: document, options: options, resolver: resolver).run()
    }

    public static func analyze(
        _ document: ParsedDocument,
        options: DocumentHealthOptions = .default,
        resolver: @escaping @Sendable (String) -> Bool
    ) -> [DocumentHealthDiagnostic] {
        analyze(document, options: options, resolver: DocumentHealthResolver(exists: resolver))
    }

    public static func report(
        _ text: String,
        options: DocumentHealthOptions = .default,
        resolver: DocumentHealthResolver? = nil
    ) -> DocumentHealthReport {
        DocumentHealthReport(diagnostics: analyze(text, options: options, resolver: resolver))
    }
}

private struct HealthPass {
    let document: ParsedDocument
    let options: DocumentHealthOptions
    let resolver: DocumentHealthResolver?
    let source: NSString
    let ignored: IntervalIndex
    let inlineCode: IntervalIndex

    init(document: ParsedDocument, options: DocumentHealthOptions, resolver: DocumentHealthResolver?) {
        self.document = document
        self.options = options
        self.resolver = resolver
        self.source = document.text as NSString
        var ignored: [NSRange] = []
        var inlineCode: [NSRange] = []
        document.root.walk { block in
            switch block.content {
            case .frontMatter, .codeBlock, .mermaid, .mathBlock:
                ignored.append(block.range)
            default:
                break
            }
            for inline in block.inlines {
                inline.walk { span in
                    if case .inlineCode = span.kind { inlineCode.append(span.range) }
                }
            }
        }
        // Both sets are disjoint, so a binary-search index (rather than a
        // linear `contains`) keeps prose/reference passes sub-linear per
        // finding on large documents.
        self.ignored = IntervalIndex(ignored)
        self.inlineCode = IntervalIndex(inlineCode)
    }

    func run() -> [DocumentHealthDiagnostic] {
        var findings: [DocumentHealthDiagnostic] = []
        structure(&findings)
        references(&findings)
        linksAndImages(&findings)
        syntax(&findings)
        prose(&findings)
        return findings.sorted {
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            if $0.range.length != $1.range.length { return $0.range.length < $1.range.length }
            return $0.id < $1.id
        }
    }

    // MARK: Structure

    private func structure(_ out: inout [DocumentHealthDiagnostic]) {
        detectMalformedFrontMatter(&out)
        var previousLevel = 0
        var h1Seen = false
        var slugs: [String: Int] = [:]
        for heading in document.headings {
            if heading.level > previousLevel + 1, previousLevel > 0 {
                let target = previousLevel + 1
                let marker = markerRange(for: heading)
                let fix: TextEdit? = marker.map {
                    TextEdit(range: $0, replacement: String(repeating: "#", count: target) + " ", summary: "Lower heading level")
                }
                out.append(diagnostic(
                    id: "heading.skipped-level", severity: .warning, category: .structure,
                    range: heading.range, message: "Heading level skips from H\(previousLevel) to H\(heading.level)",
                    explanation: "Heading levels should increase one level at a time so the outline remains navigable.", fix: fix
                ))
            }
            if heading.level == 1 {
                if h1Seen {
                    out.append(diagnostic(
                        id: "heading.multiple-h1", severity: .warning, category: .structure,
                        range: heading.range, message: "Document has more than one H1 heading",
                        explanation: "Use one document title (H1), then use H2 and deeper headings for sections."
                    ))
                }
                h1Seen = true
            }
            if heading.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(diagnostic(
                    id: "heading.empty", severity: .warning, category: .accessibility,
                    range: heading.range, message: "Heading has no text",
                    explanation: "Empty headings create an unlabeled outline entry and an unusable anchor."
                ))
            }
            let slug = slugify(heading.title)
            if let count = slugs[slug] {
                out.append(diagnostic(
                    id: "heading.duplicate-anchor", severity: .warning, category: .structure,
                    range: heading.range, message: "Heading creates a duplicate anchor",
                    explanation: "Two headings with the same anchor make links and table-of-contents entries ambiguous."
                ))
                slugs[slug] = count + 1
            } else {
                slugs[slug] = 1
            }
            previousLevel = heading.level
            if heading.wordCount > options.maxSectionWords {
                out.append(diagnostic(
                    id: "section.long", severity: .info, category: .structure,
                    range: heading.sectionRange, message: "Section is unusually long",
                    explanation: "Large sections are harder to scan; consider splitting this section into focused subsections."
                ))
            }
        }

        guard let firstHeading = document.headings.first else { return }
        document.root.children
            .filter { $0.range.location < firstHeading.range.location && !isIgnored($0.range) && !isBlank($0.range) }
            .forEach { block in
                out.append(diagnostic(
                    id: "document.content-before-first-heading", severity: .info, category: .structure,
                    range: block.range, message: "Content appears before the first heading",
                    explanation: "Put introductory content under a heading, or keep only a short document preamble."
                ))
            }
    }

    /// A line that looks like a front-matter delimiter but is not the exact
    /// `---` opener — a stray character in front of it (`t---`), or an opener
    /// that never closes — leaves the YAML fields to render as ordinary prose.
    /// Report it explicitly instead of letting the leak style itself as body
    /// content (§5.1).
    private func detectMalformedFrontMatter(_ out: inout [DocumentHealthDiagnostic]) {
        guard document.frontMatter == nil else { return }
        let text = document.text as NSString
        guard text.length > 0 else { return }
        let firstLine = text.lineRange(for: NSRange(location: 0, length: 0))
        let first = text.substring(with: firstLine).trimmingCharacters(in: .whitespacesAndNewlines)

        // `t---`, `-x--`, … a stray character in front of an opener.  `----`
        // and longer dash runs are thematic breaks and are left alone.
        if first.count >= 4, first.hasPrefix("---") == false, first.dropFirst().hasPrefix("---") {
            out.append(diagnostic(
                id: "frontmatter.malformed-delimiter", severity: .warning, category: .structure,
                range: NSRange(location: firstLine.location, length: 4),
                message: "Front-matter opener has a stray character before `---`",
                explanation: "A valid YAML front-matter block opens with `---` on the very first line. "
                    + "`\(first)` is not a valid opener, so the metadata below renders as body prose "
                    + "instead of a metadata card."
            ))
            return
        }

        // `---` opener that never closes, when the lines between look like a
        // field list rather than a plain thematic break.
        if first == "---" {
            var sawField = false
            var cursor = firstLine.upperBound
            while cursor < text.length {
                let line = text.lineRange(for: NSRange(location: cursor, length: 0))
                let trimmed = text.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed == "---" { return }  // closed: valid front matter
                if !trimmed.isEmpty && trimmed.contains(":") { sawField = true }
                cursor = line.upperBound
            }
            if sawField {
                out.append(diagnostic(
                    id: "frontmatter.unclosed", severity: .warning, category: .structure,
                    range: firstLine, message: "Front-matter block is never closed",
                    explanation: "A YAML front-matter block needs a closing `---` line; without it the "
                        + "metadata below renders as ordinary prose."
                ))
            }
        }
    }

    // MARK: References

    private func references(_ out: inout [DocumentHealthDiagnostic]) {
        let definitions = referenceDefinitions()
        var uses: [String: [NSRange]] = [:]
        let pattern = #"(?<!\!)\[[^\]\n]+\]\[([^\]\n]*)\]"#
        for match in matches(pattern) where !isIgnored(match.range) {
            let value = source.substring(with: match.capture(1)).trimmingCharacters(in: .whitespacesAndNewlines)
            let label = value.isEmpty ? referenceLabelBefore(match.range) : value
            guard !label.isEmpty else { continue }
            let key = label.lowercased()
            uses[key, default: []].append(match.range)
            if definitions[key] == nil {
                out.append(diagnostic(
                    id: "reference.undefined", severity: .error, category: .references,
                    range: match.range, message: "Reference ‘\(label)’ is undefined",
                    explanation: "Add a matching [\(label)]: destination definition, or use an inline link."
                ))
            }
        }
        for (key, definition) in definitions where uses[key] == nil {
            out.append(diagnostic(
                id: "reference.unused", severity: .info, category: .references,
                range: definition.range, message: "Reference ‘\(definition.label)’ is unused",
                explanation: "Remove definitions that have no references to keep the document easy to maintain."
            ))
        }

        var footnotes: [String: NSRange] = [:]
        for line in lines() {
            guard !isIgnored(line.range), let match = firstMatch(#"^\s*\[\^([^\]\n]+)\]:"#, in: line.text) else { continue }
            let id = source.substring(with: NSRange(location: line.range.location + match.captureRange(1).location, length: match.captureRange(1).length)).lowercased()
            if footnotes[id] != nil {
                out.append(diagnostic(
                    id: "footnote.duplicate", severity: .error, category: .references,
                    range: line.range, message: "Footnote ‘\(id)’ is defined more than once",
                    explanation: "Footnote references resolve to one definition; keep a single definition for each identifier."
                ))
            } else {
                footnotes[id] = line.range
            }
        }
    }

    private struct Definition { let label: String; let range: NSRange }

    private func referenceDefinitions() -> [String: Definition] {
        var result: [String: Definition] = [:]
        for line in lines() where !isIgnored(line.range) {
            guard let match = firstMatch(#"^\s*\[([^\]^\n]+)\]:"#, in: line.text) else { continue }
            let labelRange = NSRange(location: line.range.location + match.captureRange(1).location, length: match.captureRange(1).length)
            let label = source.substring(with: labelRange)
            result[label.lowercased()] = Definition(label: label, range: line.range)
        }
        return result
    }

    // MARK: Links and media

    private func linksAndImages(_ out: inout [DocumentHealthDiagnostic]) {
        document.root.walk { block in
            for inline in block.inlines { inspect(inline, out: &out) }
        }
        for definition in referenceDefinitions().values {
            guard let match = firstMatch(#"^\s*\[[^\]]+\]:\s*(\S+)"#, in: source.substring(with: definition.range)) else { continue }
            inspectURL(source.substring(with: match.captureRange(1)), range: definition.range, isImage: false, out: &out)
        }
    }

    private func inspect(_ span: InlineSpan, out: inout [DocumentHealthDiagnostic]) {
        switch span.kind {
        case .image(let source, let alt):
            if alt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out.append(diagnostic(
                    id: "image.missing-alt", severity: .error, category: .accessibility,
                    range: span.range, message: "Image is missing alternative text",
                    explanation: "Describe the image's purpose so readers using assistive technology are not left without context."
                ))
            }
            inspectURL(source, range: span.range, isImage: true, out: &out)
        case .link(let destination, _), .autolink(let destination):
            inspectURL(destination, range: span.range, isImage: false, out: &out)
        default:
            break
        }
        for child in span.children { inspect(child, out: &out) }
    }

    private func inspectURL(_ value: String, range: NSRange, isImage: Bool, out: inout [DocumentHealthDiagnostic]) {
        let destination = value.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "<>\"'"))
        guard !destination.isEmpty else { return }
        if destination.hasPrefix("/") && !destination.hasPrefix("//") {
            out.append(diagnostic(
                id: isImage ? "asset.absolute-path" : "link.absolute-path",
                severity: .warning, category: isImage ? .media : .links, range: range,
                message: "Local path is absolute", explanation: "Use a project-relative path so the document works on another machine."
            ))
        }
        if let colon = destination.firstIndex(of: ":") {
            let scheme = String(destination[..<colon]).lowercased()
            if scheme.isEmpty || destination[ destination.index(after: colon)...].hasPrefix("//") {
                // `://` and empty schemes are malformed below.
            } else if ["http", "https"].contains(scheme) {
                out.append(diagnostic(
                    id: "url.malformed", severity: .error, category: .links, range: range,
                    message: "URL has a malformed scheme", explanation: "Use a valid absolute URL such as https://example.com or a relative path."
                ))
                return
            } else if !["http", "https", "mailto"].contains(scheme) {
                out.append(diagnostic(
                    id: "url.unsafe-scheme", severity: .error, category: .links,
                    range: range, message: "URL uses unsafe scheme ‘\(scheme):’",
                    explanation: "Only web and mail links are accepted by the health pass; unsafe schemes can execute code or expose local data."
                ))
                return
            }
        }
        if destination.contains("://") && !destination.hasPrefix("http://") && !destination.hasPrefix("https://") {
            out.append(diagnostic(
                id: "url.malformed", severity: .error, category: .links, range: range,
                message: "URL has a malformed scheme", explanation: "Use a valid absolute URL such as https://example.com or a relative path."
            ))
            return
        }
        guard isLocal(destination), let resolver else { return }
        let path = destination.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? destination
        guard !path.isEmpty, !resolver.exists(path) else { return }
        out.append(diagnostic(
            id: isImage ? "asset.missing" : "link.missing", severity: .warning,
            category: isImage ? .media : .links, range: range,
            message: isImage ? "Local image asset was not found" : "Local link target was not found",
            explanation: "Check the relative path or add the referenced file to the document's project."
        ))
    }

    // MARK: Syntax

    private func syntax(_ out: inout [DocumentHealthDiagnostic]) {
        var open: (char: Character, run: Int, range: NSRange)?
        for line in lines() {
            // Front matter is metadata, not a fence.  Code ranges are not
            // skipped here: an unclosed fence is itself the code range and
            // must remain observable to this source-level check.
            if let frontMatter = document.frontMatter, frontMatter.range.intersection(line.range) == line.range {
                continue
            }
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            guard line.text.leadingIndent.indentColumns < 4 else { continue }
            let run = trimmed.prefix { $0 == "`" || $0 == "~" }
            if run.count >= 3 {
                let char = run.first!
                if let current = open, char == current.char, run.count >= current.run {
                    open = nil
                } else if open == nil {
                    open = (char, run.count, line.range)
                }
            }
        }
        if let open {
            out.append(diagnostic(
                id: "fence.unclosed", severity: .error, category: .syntax, range: open.range,
                message: "Code fence is not closed", explanation: "Add a closing fence with the same marker character."
            ))
        }

        for block in document.root.flattened() {
            guard case .table(let table) = block.content else { continue }
            let expected = table.columnCount
            guard expected > 0 else { continue }
            for row in table.rows where row.cells.count != expected {
                out.append(diagnostic(
                    id: "table.invalid-row", severity: .warning, category: .syntax, range: row.range,
                    message: "Table row has a different number of cells", explanation: "Keep each table row aligned with the header's column count."
                ))
            }
        }
    }

    // MARK: Prose

    private func prose(_ out: inout [DocumentHealthDiagnostic]) {
        document.root.walk { block in
            guard case .paragraph = block.content, !isIgnored(block.range) else { return }
            let text = source.substring(with: block.range)
            let words = wordCount(text)
            if words > options.maxParagraphWords {
                out.append(diagnostic(
                    id: "paragraph.dense", severity: .info, category: .prose, range: block.range,
                    message: "Paragraph is dense (\(words) words)", explanation: "Break long paragraphs into smaller units so readers can scan the document."
                ))
            }
            for sentence in sentenceRanges(in: block.range)
                where !inlineCode.contains(range: sentence)
                && wordCount(source.substring(with: sentence)) > options.maxSentenceWords {
                out.append(diagnostic(
                    id: "sentence.long", severity: .info, category: .prose, range: sentence,
                    message: "Sentence is unusually long", explanation: "Shorter sentences are easier to understand and translate."
                ))
            }
            for match in matches(#"(?i)\b([a-z][a-z'’-]*)\s+\1\b"#, in: text) {
                let range = NSRange(location: block.range.location + match.range.location, length: match.range.length)
                guard !inlineCode.contains(offset: range.location) else { continue }
                out.append(diagnostic(
                    id: "prose.repeated-word", severity: .warning, category: .prose, range: range,
                    message: "Repeated adjacent word", explanation: "Remove the accidental duplicate unless the repetition is intentional."
                ))
            }
        }
    }

    // MARK: Source helpers

    private struct Line { let range: NSRange; let text: String }

    private func lines() -> [Line] {
        document.lineStarts.enumerated().map { index, start in
            let range = document.range(ofLine: index + 1)
            return Line(range: range, text: source.substring(with: range))
        }
    }

    private func isIgnored(_ range: NSRange) -> Bool { ignored.contains(range: range) }
    private func isBlank(_ range: NSRange) -> Bool { source.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private func isLocal(_ value: String) -> Bool {
        guard !value.hasPrefix("#"), !value.hasPrefix("//") else { return false }
        return !value.contains(":")
    }

    private func markerRange(for heading: HeadingNode) -> NSRange? {
        let prefix = source.substring(with: NSRange(location: heading.range.location, length: max(0, heading.contentRange.location - heading.range.location)))
        guard prefix.trimmingCharacters(in: .whitespaces).hasPrefix("#") else { return nil }
        return NSRange(location: heading.range.location, length: prefix.utf16.count)
    }

    private func slugify(_ title: String) -> String {
        var result = ""
        for character in title.lowercased() {
            if character.isLetter || character.isNumber { result.append(character) }
            else if character == " " || character == "-" || character == "_" { result.append("-") }
        }
        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private func wordCount(_ text: String) -> Int {
        text.split { !$0.isLetter && !$0.isNumber }.count
    }

    private func sentenceRanges(in range: NSRange) -> [NSRange] {
        let value = source.substring(with: range) as NSString
        // A static pattern here is effectively constant, but a crash on a
        // future edit would take the whole health pass down with it.
        guard let regex = try? NSRegularExpression(pattern: #"[^.!?]+(?:[.!?]+|$)"#) else { return [] }
        return regex.matches(in: value as String, range: NSRange(location: 0, length: value.length)).map {
            NSRange(location: range.location + $0.range.location, length: $0.range.length)
        }
    }

    private struct Match {
        let range: NSRange
        let captures: [NSRange]
        /// Capture indexes follow NSRegularExpression's 1-based convention.
        func capture(_ index: Int) -> NSRange {
            guard index > 0, index <= captures.count else { return NSRange(location: NSNotFound, length: 0) }
            return captures[index - 1]
        }
        func captureRange(_ index: Int) -> NSRange { capture(index) }
    }

    private func matches(_ pattern: String, in value: String? = nil) -> [Match] {
        let string = value ?? (source as String)
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: string, range: NSRange(location: 0, length: (string as NSString).length)).map { result in
            let captures = (1..<result.numberOfRanges).map { result.range(at: $0) }
            return Match(range: result.range, captures: captures)
        }
    }

    private func firstMatch(_ pattern: String, in value: String) -> Match? { matches(pattern, in: value).first }

    private func referenceLabelBefore(_ range: NSRange) -> String {
        let value = source.substring(with: range)
        guard let match = firstMatch(#"^\[([^\]]+)\]\[\]$"#, in: value) else { return "" }
        return (value as NSString).substring(with: match.capture(1))
    }

    private func diagnostic(
        id: String, severity: DocumentHealthSeverity, category: DocumentHealthCategory,
        range: NSRange, message: String, explanation: String, fix: TextEdit? = nil
    ) -> DocumentHealthDiagnostic {
        DocumentHealthDiagnostic(id: id, severity: severity, category: category, range: range, message: message, explanation: explanation, fix: fix)
    }
}

/// A binary-search index over a set of disjoint non-empty ranges.
///
/// The health pass used to answer every "am I inside a code span / ignored
/// block?" query with a linear scan, which on a document with many code spans
/// and blocks turned a prose/reference pass into roughly O(fragments × ranges)
/// work — quadratic-ish on large documents.  Both queries the pass makes —
/// "does some stored range fully contain this range" and "does some stored
/// range contain this offset" — collapse to one floor lookup because stored
/// ranges are disjoint.
private struct IntervalIndex {
    let ranges: [NSRange]

    init(_ ranges: [NSRange]) {
        self.ranges = ranges
            .filter { $0.location >= 0 && $0.length > 0 }
            .sorted { $0.location < $1.location }
    }

    /// The stored range with the greatest start ≤ `offset`.
    private func floor(_ offset: Int) -> NSRange? {
        var low = 0, high = ranges.count
        while low < high {
            let mid = (low + high) / 2
            if ranges[mid].location <= offset { low = mid + 1 } else { high = mid }
        }
        guard low > 0 else { return nil }
        return ranges[low - 1]
    }

    func contains(offset: Int) -> Bool {
        guard let floor = floor(offset) else { return false }
        return floor.location <= offset && offset < floor.upperBound
    }

    /// True when a stored range fully covers `query` (start and end inside one
    /// range, which is the only way a disjoint set can contain a query that
    /// does not itself span a gap).
    func contains(range query: NSRange) -> Bool {
        guard query.length > 0, let floor = floor(query.location) else { return false }
        return floor.upperBound >= query.upperBound
    }
}
