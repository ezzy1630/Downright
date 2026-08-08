import Foundation

public enum CompatibilitySeverity: String, Codable, CaseIterable, Sendable {
    case warning
}

/// A source-local, deterministic explanation of one unsupported construct.
public struct CompatibilityDiagnostic: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let capability: MarkdownCapability
    public let range: NSRange
    public let severity: CompatibilitySeverity
    public let title: String
    public let explanation: String
    public let proposal: CompatibilityTransformProposal?

    public init(
        capability: MarkdownCapability,
        range: NSRange,
        severity: CompatibilitySeverity = .warning,
        title: String,
        explanation: String,
        proposal: CompatibilityTransformProposal? = nil
    ) {
        self.capability = capability
        self.range = range
        self.severity = severity
        self.title = title
        self.explanation = explanation
        self.proposal = proposal
        self.id = "\(capability.rawValue):\(range.location):\(range.length)"
    }
}

/// An optional byte-local edit. `reverseReplacement` makes the proposal
/// reversible without retaining document state or normalizing line endings.
public struct CompatibilityTransformProposal: Codable, Hashable, Sendable {
    public let range: NSRange
    public let replacement: String
    public let reverseReplacement: String
    public let summary: String

    public init(range: NSRange, replacement: String, reverseReplacement: String, summary: String) {
        self.range = range
        self.replacement = replacement
        self.reverseReplacement = reverseReplacement
        self.summary = summary
    }

    public func applying(to text: String) -> String? {
        guard range.location >= 0, range.upperBound <= (text as NSString).length else { return nil }
        let output = NSMutableString(string: text)
        output.replaceCharacters(in: range, with: replacement)
        return output as String
    }

    public func reversing(in transformedText: String) -> String? {
        let transformedRange = NSRange(location: range.location, length: (replacement as NSString).length)
        guard transformedRange.location >= 0, transformedRange.upperBound <= (transformedText as NSString).length else { return nil }
        guard (transformedText as NSString).substring(with: transformedRange) == replacement else { return nil }
        let output = NSMutableString(string: transformedText)
        output.replaceCharacters(in: transformedRange, with: reverseReplacement)
        return output as String
    }
}

/// The result of checking one parsed document against one renderer.
public struct CompatibilityReport: Codable, Hashable, Sendable {
    public let profile: RenderTargetProfile
    public let diagnostics: [CompatibilityDiagnostic]

    public init(profile: RenderTargetProfile, diagnostics: [CompatibilityDiagnostic]) {
        self.profile = profile
        self.diagnostics = diagnostics
    }

}

/// Side-by-side compatibility result. The source side is retained as a
/// profile rather than a rendered copy; rendering belongs to MarkdownRender.
public struct RenderTargetComparison: Codable, Hashable, Sendable {
    public let source: RenderTargetProfile
    public let target: RenderTargetProfile
    public let sourceCapabilities: MarkdownCapabilities
    public let targetCapabilities: MarkdownCapabilities
    public let onlyInSource: MarkdownCapabilities
    public let onlyInTarget: MarkdownCapabilities
    public let report: CompatibilityReport

    public init(source: RenderTargetProfile, target: RenderTargetProfile, report: CompatibilityReport) {
        self.source = source
        self.target = target
        self.sourceCapabilities = source.capabilities
        self.targetCapabilities = target.capabilities
        self.onlyInSource = source.capabilities.subtracting(target.capabilities)
        self.onlyInTarget = target.capabilities.subtracting(source.capabilities)
        self.report = report
    }
}

public enum MarkdownCompatibility {
    public static func diagnose(
        _ document: ParsedDocument,
        for profile: RenderTargetProfile
    ) -> CompatibilityReport {
        var findings: [(MarkdownCapability, NSRange, String, String, CompatibilityTransformProposal?)] = []

        func extensionProtectedRanges() -> [NSRange] {
            var ranges: [NSRange] = []
            document.root.walk { block in
                switch block.content {
                case .frontMatter, .codeBlock, .mermaid, .mathBlock, .htmlBlock:
                    ranges.append(block.range)
                default:
                    break
                }
                for inline in block.inlines {
                    inline.walk { span in
                        switch span.kind {
                        case .inlineCode, .link, .autolink, .image, .inlineHTML, .wikilink:
                            ranges.append(span.range)
                        default:
                            break
                        }
                    }
                }
            }
            return ranges
        }

        func add(
            _ capability: MarkdownCapability,
            _ range: NSRange,
            _ title: String,
            _ explanation: String,
            _ proposal: CompatibilityTransformProposal? = nil
        ) {
            guard range.location >= 0, range.length >= 0, range.upperBound <= document.length else { return }
            guard !findings.contains(where: { $0.0 == capability && $0.1 == range }) else { return }
            findings.append((capability, range, title, explanation, proposal))
        }

        func strikethroughRanges() -> [NSRange] {
            let protected = extensionProtectedRanges()
            let text = document.text as NSString
            var result: [NSRange] = []
            var cursor = 0
            while cursor + 3 < text.length {
                guard text.character(at: cursor) == 0x7E,
                      text.character(at: cursor + 1) == 0x7E,
                      (cursor == 0 || text.character(at: cursor - 1) != 0x7E),
                      text.character(at: cursor + 2) != 0x7E,
                      !protected.contains(where: { $0.contains(offset: cursor) })
                else { cursor += 1; continue }
                var close = cursor + 2
                while close + 1 < text.length {
                    if text.character(at: close) == 0x7E,
                       text.character(at: close + 1) == 0x7E,
                       (close + 2 == text.length || text.character(at: close + 2) != 0x7E),
                       !protected.contains(where: { $0.contains(offset: close) }) {
                        break
                    }
                    close += 1
                }
                guard close + 1 < text.length else { break }
                let body = text.substring(with: NSRange(location: cursor + 2, length: close - cursor - 2))
                if !body.isEmpty, !body.contains("\n"), !body.trimmingCharacters(in: .whitespaces).isEmpty {
                    result.append(NSRange(location: cursor, length: close + 2 - cursor))
                    cursor = close + 2
                } else {
                    cursor += 2
                }
            }
            return result
        }

        func inlineMathRanges() -> [NSRange] {
            let protected = extensionProtectedRanges()
            return MathScanner.matches(
                in: document.text as NSString,
                range: NSRange(location: 0, length: document.length)
            )
            .map(\.range)
            .filter { candidate in
                !protected.contains { $0.intersection(candidate) != nil }
            }
        }

        func inlineFeatures(_ span: InlineSpan) {
            switch span.kind {
            case .strikethrough:
                if !profile.capabilities.contains(.strikethrough) {
                    add(.strikethrough, span.range, "Strikethrough is not supported", "This renderer treats `~~text~~` as literal text.")
                }
            case .inlineMath:
                if !profile.capabilities.contains(.math) {
                    add(.math, span.range, "Inline math is not supported", "The `$…$` or escaped math expression will not be rendered as mathematics.")
                }
            case .wikilink(let target, let label):
                if !profile.capabilities.contains(.wikilinks) {
                    let shown = label ?? target
                    let destination = target.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                        ? target
                        : "<\(target)>"
                    let replacement = "[\(shown)](\(destination))"
                    let proposal = CompatibilityTransformProposal(
                        range: span.range, replacement: replacement,
                        reverseReplacement: (document.text as NSString).substring(with: span.range),
                        summary: "Convert wikilink to a standard Markdown link"
                    )
                    add(.wikilinks, span.range, "Wikilinks are not supported", "The `[[target]]` syntax will remain visible instead of becoming a link.", proposal)
                }
            case .footnoteReference:
                if !profile.capabilities.contains(.footnotes) {
                    add(.footnotes, span.range, "Footnotes are not supported", "Footnote references will not resolve in this renderer.")
                }
            case .inlineHTML:
                if !profile.capabilities.contains(.rawHTML) {
                    add(.rawHTML, span.range, "Raw HTML is not supported", "Inline HTML is shown as literal text or removed by the renderer.")
                }
            default: break
            }
            for child in span.children { inlineFeatures(child) }
        }

        document.root.walk { block in
            switch block.content {
            case .table:
                if !profile.capabilities.contains(.tables) {
                    add(.tables, block.range, "Tables are not supported", "The pipe table will not be laid out as a table.")
                }
            case .listItem(_, let checkbox) where checkbox != nil:
                if !profile.capabilities.contains(.taskLists), let checkbox {
                    add(.taskLists, checkbox.markRange, "Task lists are not supported", "The checkbox marker will be rendered as ordinary list text.")
                }
            case .mathBlock:
                if !profile.capabilities.contains(.math) {
                    add(.math, block.range, "Display math is not supported", "The display formula will not be rendered as mathematics.")
                }
            case .mermaid:
                if !profile.capabilities.contains(.mermaid) {
                    add(.mermaid, block.range, "Mermaid is not supported", "The fenced diagram will remain a code block or plain text.")
                }
            case .callout:
                if !profile.capabilities.contains(.calloutsAlerts), let marker = block.markerRange {
                    add(.calloutsAlerts, marker, "Callouts or alerts are not supported", "The callout marker will be treated as an ordinary blockquote.")
                }
            case .htmlBlock:
                if !profile.capabilities.contains(.rawHTML) {
                    add(.rawHTML, block.range, "Raw HTML is not supported", "The HTML block will not be interpreted by the renderer.")
                }
            case .frontMatter(let frontMatter):
                if !profile.capabilities.contains(.frontMatter) {
                    add(.frontMatter, frontMatter.range, "Front matter is not supported", "The metadata fence and fields are not interpreted by this renderer.")
                }
            default: break
            }
            if case .heading = block.content,
               !profile.capabilities.contains(.headingAttributes),
               let range = Self.headingAttributes(in: document, heading: block) {
                add(.headingAttributes, range, "Heading attributes are not supported", "The `{#id .class}` heading attribute will remain literal text.")
            }
            for inline in block.inlines { inlineFeatures(inline) }
        }

        if !profile.capabilities.contains(.strikethrough) {
            for range in strikethroughRanges() {
                add(.strikethrough, range, "Strikethrough is not supported", "This renderer treats `~~text~~` as literal text.")
            }
        }

        if !profile.capabilities.contains(.math) {
            for range in inlineMathRanges() {
                add(.math, range, "Inline math is not supported", "The math expression will not be rendered as mathematics.")
            }
        }

        if !profile.capabilities.contains(.footnotes) {
            for definition in document.footnotes.values {
                add(.footnotes, definition.range, "Footnotes are not supported", "Footnote definitions will not resolve in this renderer.")
            }
        }

        let diagnostics = findings
            .sorted { lhs, rhs in
                lhs.1.location == rhs.1.location
                    ? lhs.0.rawValue < rhs.0.rawValue
                    : lhs.1.location < rhs.1.location
            }
            .map { capability, range, title, explanation, proposal in
                CompatibilityDiagnostic(
                    capability: capability, range: range, title: title,
                    explanation: explanation, proposal: proposal
                )
            }
        return CompatibilityReport(profile: profile, diagnostics: diagnostics)
    }

    public static func compare(
        _ document: ParsedDocument,
        from source: RenderTargetProfile,
        to target: RenderTargetProfile
    ) -> RenderTargetComparison {
        RenderTargetComparison(source: source, target: target, report: diagnose(document, for: target))
    }

    private static func headingAttributes(in document: ParsedDocument, heading: MDBlock) -> NSRange? {
        let line = document.substring(heading.range)
        let ns = line as NSString
        var end = ns.length
        while end > 0 {
            let character = ns.character(at: end - 1)
            guard character == 0x20 || character == 0x09 else { break }
            end -= 1
        }
        guard end > 1, ns.character(at: end - 1) == 0x7D else { return nil }
        guard let start = (0..<end).reversed().first(where: { ns.character(at: $0) == 0x7B }) else { return nil }
        let body = ns.substring(with: NSRange(location: start + 1, length: end - start - 2))
        guard body.contains("#") || body.contains(".") || body.contains("=") else { return nil }
        return NSRange(location: heading.range.location + start, length: end - start)
    }
}

public extension MarkdownCapability {
    var displayName: String {
        switch self {
        case .tables: return "Tables"
        case .taskLists: return "Task lists"
        case .strikethrough: return "Strikethrough"
        case .footnotes: return "Footnotes"
        case .math: return "Math"
        case .mermaid: return "Mermaid"
        case .calloutsAlerts: return "Callouts/alerts"
        case .wikilinks: return "Wikilinks"
        case .frontMatter: return "Front matter"
        case .rawHTML: return "Raw HTML"
        case .headingAttributes: return "Heading attributes"
        }
    }
}
