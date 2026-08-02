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
        case .html(_, let fallback): return fallback
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
