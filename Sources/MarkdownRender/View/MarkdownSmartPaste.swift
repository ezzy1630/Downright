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

enum MarkdownPasteMode: Equatable {
    case smart
    case markdown
    case matchStyle
}

/// A clipboard payload independent of `NSPasteboard`, keeping flavour policy
/// pure and all source-coordinate mutation in `MarkdownTextView`.
enum MarkdownPastePayload: Equatable {
    case markdown(String)
    case url(String)
    case html(String, fallback: String)
    case richText(String)
    case file(String)
    case image
    case text(String)
}

enum MarkdownSmartPaste {
    /// Ordinary paste is conservative: lossless Downright Markdown wins, then
    /// the producer's visible plain text. Rich conversion belongs to the
    /// explicit Paste as Markdown command; Match Style also prefers visible
    /// text and strips formatting from rich-only payloads as a fallback.
    static func payload(
        from pasteboard: NSPasteboard,
        mode: MarkdownPasteMode = .smart
    ) -> MarkdownPastePayload? {
        let richTypes: [NSPasteboard.PasteboardType] = [
            .html, .rtf, .rtfd, .webArchive, .appleWebArchive,
        ]
        let orderedTypes: [NSPasteboard.PasteboardType]
        switch mode {
        case .smart:
            orderedTypes = [.downrightMarkdown, .string, .URL, .fileURL]
                + richTypes + [.tiff, .png]
        case .markdown:
            orderedTypes = [.downrightMarkdown] + richTypes
                + [.URL, .fileURL, .string, .tiff, .png]
        case .matchStyle:
            orderedTypes = [.string, .downrightMarkdown, .URL, .fileURL]
                + richTypes + [.tiff, .png]
        }
        for type in orderedTypes where pasteboard.types?.contains(type) == true {
            if type == .downrightMarkdown {
                if let markdown = pasteboard.string(forType: type) { return .markdown(markdown) }
            } else if type == .URL {
                if let url = pasteboard.string(forType: type), !url.isEmpty { return .url(url) }
            } else if type == .html {
                guard let html = pasteboard.string(forType: type) else { continue }
                return .html(html, fallback: pasteboard.string(forType: .string) ?? "")
            } else if type == .rtf || type == .rtfd {
                guard let data = pasteboard.data(forType: type),
                      data.count <= maximumRichPayloadBytes,
                      let attributed = try? NSAttributedString(
                        data: data,
                        options: [
                            .documentType: type == .rtf
                                ? NSAttributedString.DocumentType.rtf
                                : NSAttributedString.DocumentType.rtfd,
                        ],
                        documentAttributes: nil
                      ) else { continue }
                if let htmlData = try? attributed.data(
                    from: NSRange(location: 0, length: attributed.length),
                    documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
                ), let html = String(data: htmlData, encoding: .utf8) {
                    return .html(html, fallback: attributed.string)
                }
                return .richText(attributed.string)
            } else if type == .webArchive || type == .appleWebArchive {
                if let html = webArchiveHTML(from: pasteboard.data(forType: type)) {
                    return .html(html, fallback: pasteboard.string(forType: .string) ?? "")
                }
            } else if type == .fileURL {
                if let raw = pasteboard.string(forType: type),
                   let url = URL(string: raw), url.isFileURL {
                    return .file(url.path)
                }
            } else if type == .tiff || type == .png {
                // Embedding requires a document-owned file name. Keep the
                // operation explicit until the document layer can choose one.
                return .image
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
        replacement(for: payload, selection: selection, context: context, mode: .smart)
    }

    static func replacement(
        for payload: MarkdownPastePayload,
        selection: String,
        context: MarkdownPasteContext,
        mode: MarkdownPasteMode
    ) -> String {
        if mode == .matchStyle {
            return plainText(for: payload)
        }
        if mode == .smart && context != .markdown {
            // Existing Source/Code behavior intentionally leaves HTML visible
            // when the producer did not provide a text fallback; only the
            // explicit Match Style command strips it to words.
            if case .html(let html, let fallback) = payload {
                return fallback.isEmpty ? html : fallback
            }
            return plainText(for: payload)
        }

        switch payload {
        case .markdown(let markdown):
            return markdown
        case .url(let url):
            return SmartPaste.linkified(selection: selection, url: url) ?? url
        case .html(let html, let fallback):
            let markdown = SmartPaste.markdown(forHTML: html)
            return markdown.isEmpty ? fallback : markdown
        case .richText(let text):
            return text
        case .file(let path):
            return path
        case .image:
            return ""
        case .text(let text):
            return SmartPaste.markdownTable(forTabSeparated: text) ?? text
        }
    }

    private static func plainText(for payload: MarkdownPastePayload) -> String {
        switch payload {
        case .markdown(let markdown): return markdown
        case .url(let url): return url
        case .html(let html, let fallback):
            return fallback.isEmpty ? SmartPaste.plainText(forHTML: html) : fallback
        case .richText(let text): return text
        case .file(let path): return path
        case .image: return ""
        case .text(let text): return text
        }
    }

    private static func webArchiveHTML(from data: Data?) -> String? {
        guard let data, data.count <= maximumRichPayloadBytes,
              let plist = try? PropertyListSerialization.propertyList(
                from: data, options: [], format: nil
              ) as? [String: Any],
              let resource = plist["WebMainResource"] as? [String: Any],
              let htmlData = resource["WebResourceData"] as? Data else { return nil }
        return String(data: htmlData, encoding: .utf8)
            ?? String(data: htmlData, encoding: .utf16)
    }

    private static let maximumRichPayloadBytes = 8 * 1_024 * 1_024

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
        "com.ezzy.downright.markdown"
    )

    static let webArchive = NSPasteboard.PasteboardType("Apple Web Archive pasteboard type")
    static let appleWebArchive = NSPasteboard.PasteboardType("com.apple.webarchive")
}
