import AppKit
import Foundation
import MarkdownCore

/// The context in which a paste is applied.  Markdown syntax transforms are
/// useful in prose, but surprising inside a code or otherwise literal block.
enum MarkdownPasteContext: Equatable {
    case markdown
    case code
    case plain
}

/// Clipboard payload in the order in which AppKit presents useful flavours.
/// Keeping this value independent of `NSPasteboard` makes the policy pure and
/// keeps all source-coordinate mutation in `MarkdownTextView`.
enum MarkdownPastePayload: Equatable {
    case url(String)
    case html(String, fallback: String)
    case text(String)
}

enum MarkdownSmartPaste {
    /// Reads clipboard flavours in the same order as AppKit's paste action:
    /// an explicit URL wins over browser HTML, then plain text. The named
    /// pasteboard seam keeps tests and Quick Look callers off the global board.
    static func payload(from pasteboard: NSPasteboard) -> MarkdownPastePayload? {
        let orderedTypes: [NSPasteboard.PasteboardType] = [.downrightMarkdown, .URL, .html, .string]
        for type in orderedTypes where pasteboard.types?.contains(type) == true {
            if type == .downrightMarkdown {
                if let markdown = pasteboard.string(forType: type) { return .text(markdown) }
            } else if type == .URL {
                if let url = pasteboard.string(forType: type), !url.isEmpty { return .url(url) }
            } else if type == .html {
                guard let html = pasteboard.string(forType: type) else { continue }
                return .html(html, fallback: pasteboard.string(forType: .string) ?? "")
            } else if let text = pasteboard.string(forType: type) {
                return .text(text)
            }
        }
        return nil
    }

    static func replacement(
        for payload: MarkdownPastePayload,
        selection: String,
        context: MarkdownPasteContext
    ) -> String {
        guard context == .markdown else { return plainText(for: payload) }

        switch payload {
        case .url(let url):
            return SmartPaste.linkified(selection: selection, url: url) ?? url
        case .html(let html, let fallback):
            let markdown = SmartPaste.markdown(forHTML: html)
            return markdown.isEmpty ? fallback : markdown
        case .text(let text):
            return SmartPaste.markdownTable(forTabSeparated: text) ?? text
        }
    }

    private static func plainText(for payload: MarkdownPastePayload) -> String {
        switch payload {
        case .url(let url): return url
        case .html(let html, let fallback): return fallback.isEmpty ? html : fallback
        case .text(let text): return text
        }
    }

    /// A range is literal when it intersects a code block.  The block lookup
    /// is deliberately source-based, matching `MarkdownTextView`'s selection
    /// contract; a caret at a block boundary belongs to the following block.
    static func context(
        for range: NSRange,
        in document: ParsedDocument,
        mode: RenderMode = .live
    ) -> MarkdownPasteContext {
        guard mode != .source else { return .plain }
        var literalInlineRanges: [NSRange] = []
        for block in document.root.flattened() {
            for inline in block.inlines {
                inline.walk { span in
                    switch span.kind {
                    case .inlineCode, .inlineMath:
                        literalInlineRanges.append(span.range)
                    default:
                        break
                    }
                }
            }
        }
        let intersectsLiteralInline = literalInlineRanges.contains {
            range.length == 0
                ? $0.contains(offset: range.location)
                : $0.location < range.upperBound && range.location < $0.upperBound
        }
        if intersectsLiteralInline { return .plain }

        let blocks = document.root.flattened().filter {
            guard $0.range.length > 0 else { return false }
            if case .document = $0.content { return false }
            return true
        }
        let relevant: [MDBlock]
        if range.length == 0 {
            let containing = blocks.filter { $0.range.contains(offset: range.location) }
            relevant = [containing.min(by: { $0.range.length < $1.range.length })
                ?? blocks.filter { $0.range.location >= range.location }
                    .min(by: { $0.range.location < $1.range.location })]
                .compactMap { $0 }
        } else {
            relevant = blocks.filter {
                $0.range.location < range.upperBound && range.location < $0.range.upperBound
            }
        }
        var context: MarkdownPasteContext = .markdown
        for block in relevant {
            switch block.content {
            case .codeBlock:
                context = .code
                return context
            case .htmlBlock, .frontMatter, .mermaid, .mathBlock:
                context = .plain
            default:
                break
            }
        }
        return context
    }
}

public extension NSPasteboard.PasteboardType {
    /// Lossless Markdown companion to the standard visible-text clipboard.
    static let downrightMarkdown = NSPasteboard.PasteboardType(
        "com.ezzyrappeport.downright.markdown"
    )
}
