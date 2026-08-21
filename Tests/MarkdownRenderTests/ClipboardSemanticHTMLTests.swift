import AppKit
import Testing

@testable import MarkdownRender

@Suite("Clipboard semantic HTML")
struct ClipboardSemanticHTMLTests {
    @Test("exports common Markdown as semantic, escaped HTML")
    func commonMarkdown() {
        let html = ClipboardSemanticHTML.render(markdown: """
        # Read **this**

        - one
        - [two](https://example.com)

        | Name | Value |
        | --- | --- |
        | Ada | `1` |

        ```swift
        let x = 1 < 2
        ```
        """)
        #expect(html.contains("<h1>Read <strong>this</strong></h1>"))
        #expect(html.contains("<ul><li>one</li><li><a href=\"https://example.com\">two</a></li></ul>"))
        #expect(html.contains("<table><thead>"))
        #expect(html.contains("<th>Name</th>"))
        #expect(html.contains("<pre><code class=\"language-swift\">"))
        #expect(html.contains("&lt;"))
        #expect(!html.contains("<script"))
    }

    @Test("preserves nested mixed lists as semantic HTML")
    func nestedLists() {
        let html = ClipboardSemanticHTML.render(markdown: """
        - parent
          1. ordered child
          2. second child
             - deep bullet
        - sibling
        """)
        #expect(html.contains(
            "<ul><li>parent<ol><li>ordered child</li><li>second child<ul><li>deep bullet</li></ul></li></ol></li><li>sibling</li></ul>"
        ))
    }

    @Test("match style strips HTML formatting while Markdown mode preserves it")
    func pasteModes() {
        let payload = MarkdownPastePayload.html(
            "<p><strong>Bold</strong> <a href=\"https://example.com\">link</a></p>",
            fallback: ""
        )
        #expect(MarkdownSmartPaste.replacement(
            for: payload, selection: "", context: .markdown, mode: .matchStyle
        ) == "Bold link")
        #expect(MarkdownSmartPaste.replacement(
            for: payload, selection: "", context: .markdown, mode: .markdown
        ) == "**Bold** [link](https://example.com)")
    }

    @Test("RTF and WebArchive payloads use bounded textual fallbacks")
    func safeInboundPayloads() throws {
        let rtf = try NSAttributedString(
            string: "Rich text",
            attributes: [.font: NSFont.systemFont(ofSize: 12)]
        ).data(
            from: NSRange(location: 0, length: 9),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )
        let pasteboard = NSPasteboard(name: .init("DownrightClipboardTests.\(UUID())"))
        pasteboard.clearContents()
        pasteboard.setData(rtf, forType: .rtf)
        #expect(MarkdownSmartPaste.payload(from: pasteboard) == .text("Rich text"))
        guard case .html(let richHTML, let fallback) = MarkdownSmartPaste.payload(
            from: pasteboard,
            mode: .markdown
        ) else {
            Issue.record("RTF should retain semantic HTML when AppKit can convert it")
            return
        }
        #expect(richHTML.contains("Rich text"))
        #expect(fallback == "Rich text")

        let resource: [String: Any] = [
            "WebResourceData": Data("<p>Archive</p>".utf8),
            "WebResourceFrameName": "",
            "WebResourceMIMEType": "text/html",
            "WebResourceTextEncodingName": "utf-8",
            "WebResourceURL": "about:blank",
        ]
        let archive = try PropertyListSerialization.data(
            fromPropertyList: ["WebMainResource": resource], format: .binary, options: 0)
        let archiveBoard = NSPasteboard(name: .init("DownrightClipboardTests.\(UUID())"))
        archiveBoard.clearContents()
        archiveBoard.setData(archive, forType: .webArchive)
        #expect(MarkdownSmartPaste.payload(from: archiveBoard)
                == .html("<p>Archive</p>", fallback: ""))
    }
}
