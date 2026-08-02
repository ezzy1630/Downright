import Foundation
import MarkdownCore
import MarkdownRender

/// A small, value-only snapshot of the style at the selected source offset.
/// The debugger never keeps AppKit objects or a text view.  The host resolves
/// fonts and attributes once, then injects these display-safe values.
struct VisualDebuggerStyleFacts: Sendable, Equatable {
    var fontFamily: String
    var pointSize: Double
    var foregroundColor: String
    var paragraphAlignment: String
    var lineHeight: Double
    var lineSpacing: Double
    var attributes: [String]

    init(
        fontFamily: String = "",
        pointSize: Double = 0,
        foregroundColor: String = "",
        paragraphAlignment: String = "",
        lineHeight: Double = 0,
        lineSpacing: Double = 0,
        attributes: [String] = []
    ) {
        self.fontFamily = fontFamily
        self.pointSize = pointSize
        self.foregroundColor = foregroundColor
        self.paragraphAlignment = paragraphAlignment
        self.lineHeight = lineHeight
        self.lineSpacing = lineSpacing
        self.attributes = attributes
    }
}

struct VisualDebuggerMapping: Sendable, Equatable {
    let sourceRange: NSRange
    let textKitRange: NSRange
    let sourceOffset: Int
    let textKitOffset: Int
    let isCanonical: Bool
    let hiddenSourceRanges: [NSRange]

    init(
        sourceRange: NSRange,
        textKitRange: NSRange = NSRange(location: 0, length: 0),
        sourceOffset: Int? = nil,
        textKitOffset: Int? = nil,
        isCanonical: Bool = true,
        hiddenSourceRanges: [NSRange] = []
    ) {
        self.sourceRange = sourceRange
        self.textKitRange = textKitRange
        self.sourceOffset = sourceOffset ?? sourceRange.location
        self.textKitOffset = textKitOffset ?? textKitRange.location
        self.isCanonical = isCanonical
        self.hiddenSourceRanges = hiddenSourceRanges
    }
}

struct VisualDebuggerInput: Sendable {
    let document: ParsedDocument
    let selection: NSRange
    let mode: RenderMode
    let style: VisualDebuggerStyleFacts
    let mapping: VisualDebuggerMapping
    let renderTargetReport: CompatibilityReport?
    let assets: [AssetDiagnostic]

    init(
        document: ParsedDocument,
        selection: NSRange,
        mode: RenderMode,
        style: VisualDebuggerStyleFacts = .init(),
        mapping: VisualDebuggerMapping? = nil,
        renderTargetReport: CompatibilityReport? = nil,
        assets: [AssetDiagnostic] = []
    ) {
        self.document = document
        self.selection = selection
        self.mode = mode
        self.style = style
        self.mapping = mapping ?? VisualDebuggerMapping(sourceRange: selection)
        self.renderTargetReport = renderTargetReport
        self.assets = assets
    }
}

struct VisualDebuggerBlockFact: Sendable, Equatable {
    let kind: String
    let range: NSRange
    let contentRange: NSRange
    let depth: Int
    let quoteDepth: Int
    let source: String
}

struct VisualDebuggerInlineFact: Sendable, Equatable {
    let kind: String
    let range: NSRange
    let contentRange: NSRange
    let source: String
}

struct VisualDebuggerModel: Sendable {
    let sourceSelection: NSRange
    let focusOffset: Int
    let line: Int
    let column: Int
    let sourceText: String
    let mode: RenderMode
    let block: VisualDebuggerBlockFact?
    let inline: VisualDebuggerInlineFact?
    let style: VisualDebuggerStyleFacts
    let mapping: VisualDebuggerMapping
    let renderTarget: RenderTargetProfile?
    let renderDiagnostics: [CompatibilityDiagnostic]
    let assetDiagnostics: [AssetDiagnostic]

    init(input: VisualDebuggerInput) {
        let length = input.document.length
        let source = NSRange(
            location: max(0, min(input.selection.location, length)),
            length: max(0, min(input.selection.length, length - max(0, min(input.selection.location, length))))
        )
        let offset = source.location
        let focusRange = source.length > 0 ? source : NSRange(location: offset, length: 0)
        self.sourceSelection = source
        self.focusOffset = offset
        self.line = input.document.line(at: offset)
        self.column = Self.column(at: offset, in: input.document)
        self.sourceText = input.document.substring(focusRange)
        self.mode = input.mode
        self.style = input.style
        self.mapping = input.mapping

        let focusedBlock = input.document.root.block(at: offset)
        self.block = focusedBlock.map { block in
            VisualDebuggerBlockFact(
                kind: Self.blockKind(block.content),
                range: block.range,
                contentRange: block.contentRange,
                depth: block.depth,
                quoteDepth: block.quoteDepth,
                source: input.document.substring(block.range)
            )
        }
        self.inline = focusedBlock.flatMap { block in
            guard let span = Self.inlineSpan(in: block.inlines, at: offset) else { return nil }
            return VisualDebuggerInlineFact(
                kind: Self.inlineKind(span.kind), range: span.range,
                contentRange: span.contentRange, source: input.document.substring(span.range)
            )
        }

        self.renderTarget = input.renderTargetReport?.profile
        self.renderDiagnostics = input.renderTargetReport?.diagnostics.filter {
            Self.intersects($0.range, source)
        } ?? []
        self.assetDiagnostics = input.assets.filter {
            Self.intersects($0.range, source) || Self.intersects($0.reference.imageRange, source)
        }
    }

    var summary: String {
        var lines = [
            "Downright Visual Debugger",
            "Source range: \(Self.rangeText(sourceSelection))",
            "Location: line \(line), column \(column), UTF-16 offset \(focusOffset)",
            "Mode: \(mode.title)",
            "TextKit range: \(Self.rangeText(mapping.textKitRange))",
            "TextKit offset: \(mapping.textKitOffset)",
            "Canonical source offset: \(mapping.isCanonical ? "yes" : "no")",
        ]
        if let block {
            lines += [
                "Block: \(block.kind)",
                "Block range: \(Self.rangeText(block.range))",
                "Block content range: \(Self.rangeText(block.contentRange))",
                "Block depth: \(block.depth), quote depth: \(block.quoteDepth)",
            ]
        } else {
            lines.append("Block: none")
        }
        if let inline {
            lines += [
                "Inline: \(inline.kind)",
                "Inline range: \(Self.rangeText(inline.range))",
                "Inline content range: \(Self.rangeText(inline.contentRange))",
            ]
        } else {
            lines.append("Inline: none")
        }
        let family = style.fontFamily.isEmpty ? "unknown" : style.fontFamily
        let pointSize = style.pointSize > 0 ? String(format: "%.1f pt", style.pointSize) : "unknown"
        let alignment = style.paragraphAlignment.isEmpty ? "unknown" : style.paragraphAlignment
        let lineHeight = style.lineHeight > 0 ? String(format: "%.1f pt", style.lineHeight) : "unknown"
        let lineSpacing = String(format: "%.1f pt", style.lineSpacing)
        lines += [
            "Font: \(family) \(pointSize)",
            "Paragraph: \(alignment), line height \(lineHeight), spacing \(lineSpacing)",
        ]
        if !style.attributes.isEmpty {
            lines.append("Visible attributes: \(style.attributes.joined(separator: ", "))")
        }
        if let renderTarget {
            lines.append("Render target: \(renderTarget.name)")
            if renderDiagnostics.isEmpty {
                lines.append("Render diagnostics: none at selection")
            } else {
                lines.append(contentsOf: renderDiagnostics.map { "Render diagnostic: \($0.title) [\($0.capability.rawValue)]" })
            }
        } else {
            lines.append("Render target: none")
        }
        if !assetDiagnostics.isEmpty {
            lines.append(contentsOf: assetDiagnostics.map { "Asset: \($0.message) [\($0.code.rawValue)]" })
        }
        if !mapping.hiddenSourceRanges.isEmpty {
            lines.append("Hidden source ranges: \(mapping.hiddenSourceRanges.map(Self.rangeText).joined(separator: ", "))")
        }
        return lines.joined(separator: "\n")
    }

    private static func rangeText(_ range: NSRange) -> String {
        "\(range.location)..<\(range.upperBound) (length \(range.length))"
    }

    private static func column(at offset: Int, in document: ParsedDocument) -> Int {
        let lineStart = document.lineStarts[max(0, min(document.lineStarts.count - 1, document.line(at: offset) - 1))]
        return max(1, offset - lineStart + 1)
    }

    private static func intersects(_ candidate: NSRange, _ selection: NSRange) -> Bool {
        if selection.length == 0 { return candidate.touches(offset: selection.location) }
        return candidate.intersection(selection) != nil
    }

    private static func inlineSpan(in spans: [InlineSpan], at offset: Int) -> InlineSpan? {
        for span in spans {
            if let child = inlineSpan(in: span.children, at: offset) {
                // Text leaves carry no useful syntax label.  Report their
                // nearest semantic parent instead (strong, link, image, ...).
                if case .text = child.kind {
                    if case .text = span.kind {
                        return child
                    }
                    return span
                }
                return child
            }
            if span.range.touches(offset: offset) { return span }
        }
        return nil
    }

    private static func blockKind(_ content: BlockContent) -> String {
        switch content {
        case .document: "document"
        case .heading(let level): "heading H\(level)"
        case .paragraph: "paragraph"
        case .blockQuote: "blockquote"
        case .callout(let kind, _): "callout \(kind.rawValue)"
        case .list(let ordered, _, _, let marker): "\(ordered ? "ordered" : "unordered") list (\(marker.rawValue))"
        case .listItem(let ordinal, let checkbox): "list item\(ordinal.map { " #\($0)" } ?? "")\(checkbox == nil ? "" : " task")"
        case .codeBlock(let language, let fenced, _): "\(fenced ? "fenced" : "indented") code\(language.map { " (\($0))" } ?? "")"
        case .mermaid: "mermaid"
        case .mathBlock: "display math"
        case .table: "table"
        case .thematicBreak: "thematic break"
        case .htmlBlock: "HTML block"
        case .frontMatter: "front matter"
        case .footnoteDefinition(let identifier): "footnote definition [\(identifier)]"
        }
    }

    private static func inlineKind(_ kind: InlineKind) -> String {
        switch kind {
        case .text: "text"
        case .emphasis: "emphasis"
        case .strong: "strong"
        case .strikethrough: "strikethrough"
        case .inlineCode: "inline code"
        case .link: "link"
        case .autolink: "autolink"
        case .wikilink: "wikilink"
        case .image: "image"
        case .inlineMath: "inline math"
        case .pathToken: "path token"
        case .footnoteReference: "footnote reference"
        case .softBreak: "soft break"
        case .lineBreak: "line break"
        case .inlineHTML: "inline HTML"
        }
    }
}
