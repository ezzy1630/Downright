import AppKit
import MarkdownCore
import MarkdownRender
import QuickLookThumbnailing

/// Real Finder icons for markdown files (§10).
///
/// Nobody does this, and on a folder full of agent output it is transformative:
/// twelve files called `plan.md`, `output.md`, and `summary.md` become twelve
/// distinguishable documents, because the icon shows the first heading.
///
/// Runs under the same memory ceiling as the preview extension, so it parses
/// with `ParseOptions.structureOnly` and never touches math, mermaid, or images.
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // Only the head of the file matters for a thumbnail, and reading 64KB
        // instead of a 4MB agent transcript is the difference between an icon
        // that appears and one that doesn't.
        guard let head = ThumbnailProvider.readHead(of: request.fileURL, limit: 64 * 1024) else {
            handler(nil, CocoaError(.fileReadCorruptFile))
            return
        }

        let document = MarkdownParser.parse(head, options: .structureOnly)
        let title = document.headings.first?.title
            ?? document.frontMatter?["title"]
            ?? request.fileURL.deletingPathExtension().lastPathComponent
        let subtitle = ThumbnailProvider.firstProseLine(in: document) ?? ""
        let taskCount = document.tasks.count
        let doneCount = document.tasks.filter(\.isChecked).count

        let reply = QLThumbnailReply(contextSize: request.maximumSize) { context in
            ThumbnailProvider.draw(
                title: title, subtitle: subtitle,
                tasks: taskCount > 0 ? (doneCount, taskCount) : nil,
                size: request.maximumSize, scale: request.scale, in: context
            )
            return true
        }
        handler(reply, nil)
    }

    // MARK: - Drawing

    private static func draw(
        title: String, subtitle: String, tasks: (done: Int, total: Int)?,
        size: CGSize, scale: CGFloat, in context: CGContext
    ) {
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext

        let page = NSRect(origin: .zero, size: size)
        NSColor.textBackgroundColor.setFill()
        NSBezierPath(roundedRect: page, xRadius: size.width * 0.06, yRadius: size.width * 0.06).fill()

        // A hairline down the left edge, echoing the app's code block treatment
        // (§11.3) so the icon reads as the same family as the app.
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: max(2, size.width * 0.018), height: size.height)).fill()

        let inset = size.width * 0.12
        var cursor = size.height - inset

        let titleSize = max(9, size.height * 0.11)
        let titleFont = NSFont.systemFont(ofSize: titleSize, weight: .semibold)
        let titleHeight = min(size.height * 0.42, titleSize * 3.4)
        cursor -= titleHeight
        draw(
            text: title, font: titleFont, color: .labelColor,
            in: NSRect(x: inset, y: cursor, width: size.width - inset * 1.4, height: titleHeight),
            lines: 3
        )

        if !subtitle.isEmpty {
            let bodySize = max(7, size.height * 0.062)
            let bodyHeight = min(size.height * 0.26, bodySize * 4.2)
            cursor -= bodyHeight + size.height * 0.04
            draw(
                text: subtitle, font: .systemFont(ofSize: bodySize), color: .secondaryLabelColor,
                in: NSRect(x: inset, y: cursor, width: size.width - inset * 1.4, height: bodyHeight),
                lines: 3
            )
        }

        // A plan document's completion state is the single most useful thing an
        // icon can tell you about agent output (§8.5).
        if let tasks {
            let badgeSize = max(8, size.height * 0.07)
            draw(
                text: "\(tasks.done)/\(tasks.total) done",
                font: .systemFont(ofSize: badgeSize, weight: .medium),
                color: .tertiaryLabelColor,
                in: NSRect(x: inset, y: inset * 0.6, width: size.width - inset * 1.4, height: badgeSize * 1.6),
                lines: 1
            )
        }

        NSGraphicsContext.restoreGraphicsState()
    }

    private static func draw(text: String, font: NSFont, color: NSColor, in rect: NSRect, lines: Int) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        paragraph.maximumLineHeight = font.pointSize * 1.28
        paragraph.lineSpacing = 0

        let storage = NSTextStorage(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let container = NSTextContainer(size: NSSize(width: rect.width, height: rect.height))
        container.maximumNumberOfLines = lines
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let glyphs = layout.glyphRange(for: container)
        let used = layout.usedRect(for: container)
        layout.drawGlyphs(
            forGlyphRange: glyphs,
            at: NSPoint(x: rect.minX, y: rect.maxY - used.height)
        )
    }

    // MARK: - Reading

    private static func readHead(of url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        // A truncated read can split a multi-byte scalar; trim and retry before
        // falling back to a lossy encoding.
        for drop in 1...3 where data.count > drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    private static func firstProseLine(in document: ParsedDocument) -> String? {
        for block in document.root.children {
            guard case .paragraph = block.content else { continue }
            let text = document.substring(block.contentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { return text }
        }
        return nil
    }
}
