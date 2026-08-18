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
@available(macOS 14.0, *)
final class ThumbnailProvider: QLThumbnailProvider {
    override func provideThumbnail(
        for request: QLFileThumbnailRequest,
        _ handler: @escaping (QLThumbnailReply?, Error?) -> Void
    ) {
        // Only the head of the file matters for a thumbnail, and reading 64KB
        // instead of a 4MB agent transcript is the difference between an icon
        // that appears and one that doesn't.
        guard let head = DocumentIO.readHead(contentsOf: request.fileURL, limit: 64 * 1024) else {
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

        // A page, not a square.  `maximumSize` is a bounding box, and handing it
        // back unchanged is what made these icons squares sitting among every
        // other app's portrait documents — the single thing that made a folder
        // of them look wrong before you had read a word.
        let size = ThumbnailProvider.pageSize(fitting: request.maximumSize)

        // This renderer uses AppKit text and paths, so request Quick Look's
        // AppKit current-context variant. The Core Graphics overload applies
        // the request's Retina scale before our NSGraphicsContext bridge;
        // bridging it again made Finder show only the bottom-left quarter.
        let reply = QLThumbnailReply(contextSize: size, currentContextDrawing: {
            ThumbnailProvider.draw(
                title: title, subtitle: subtitle,
                tasks: taskCount > 0 ? (doneCount, taskCount) : nil,
                size: size
            )
            return true
        })
        handler(reply, nil)
    }

    // MARK: - Geometry

    /// US Letter, near enough.  Every document icon on the system is this shape
    /// and an icon that isn't reads as a mistake long before it reads as a file.
    private static let pageAspect: CGFloat = 8.5 / 11.0

    static func pageSize(fitting maximum: CGSize) -> CGSize {
        guard maximum.width > 0, maximum.height > 0 else { return maximum }
        let tall = CGSize(width: maximum.height * pageAspect, height: maximum.height)
        guard tall.width > maximum.width else { return tall }
        return CGSize(width: maximum.width, height: maximum.width / pageAspect)
    }

    /// Below this the page is a few points wide per line of type and real text
    /// is a grey smudge, so the icon switches to ruled lines that at least read
    /// as a document.  Finder's list and column views live down here; icon view
    /// and Cover Flow live above it.
    private static let legibleTextHeight: CGFloat = 72

    // MARK: - Palette
    //
    // Fixed sRGB, never `labelColor` or `textBackgroundColor`.  A thumbnail is
    // drawn once by a background process with no appearance context and then
    // cached by the system for months; a dynamic colour resolves to whatever
    // that process happened to be and bakes it in, so a light icon can end up
    // permanently stuck in a dark Finder or the reverse.  Document icons are
    // artwork — Pages and TextEdit are white pages in both appearances too.

    private static func srgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    /// The warm paper of the app icon, not a clinical white.
    private static let paper = srgb(0.980, 0.973, 0.957)
    private static let pageEdge = srgb(0, 0, 0, 0.12)
    private static let spine = srgb(0.141, 0.251, 0.373)
    private static let titleInk = srgb(0.106, 0.153, 0.200)
    private static let bodyInk = srgb(0.431, 0.463, 0.506)
    private static let faintInk = srgb(0.604, 0.631, 0.667)
    private static let accent = srgb(0.290, 0.498, 0.757)

    // MARK: - Drawing

    private static func draw(
        title: String, subtitle: String, tasks: (done: Int, total: Int)?,
        size: CGSize
    ) {
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        let radius = size.width * 0.055
        let page = NSRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5)
        let outline = NSBezierPath(roundedRect: page, xRadius: radius, yRadius: radius)
        paper.setFill()
        outline.fill()

        // The spine is clipped to the page so it follows the rounded corners
        // instead of squaring them off, which the old full-height rect did.
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        spine.setFill()
        NSBezierPath(rect: NSRect(
            x: page.minX, y: page.minY,
            width: max(1.5, size.width * 0.035), height: page.height
        )).fill()
        NSGraphicsContext.restoreGraphicsState()

        pageEdge.setStroke()
        outline.lineWidth = 1
        outline.stroke()

        let leftInset = max(3, size.width * 0.035) + size.width * 0.085
        let rightInset = size.width * 0.085
        let content = NSRect(
            x: page.minX + leftInset,
            y: page.minY + size.height * 0.075,
            width: page.width - leftInset - rightInset,
            height: page.height - size.height * 0.15
        )

        guard size.height >= legibleTextHeight else {
            drawRuledLines(in: content, tasks: tasks, size: size)
            return
        }

        var cursor = content.maxY
        let titleSize = max(7, size.height * 0.098)
        // Each block advances the cursor by the height it actually used, so a
        // one-line title no longer leaves a three-line hole above the body.
        let titleHeight = drawText(
            title, font: .systemFont(ofSize: titleSize, weight: .semibold), color: titleInk,
            in: NSRect(x: content.minX, y: content.minY,
                       width: content.width, height: cursor - content.minY),
            topAt: cursor, lines: 3
        )
        cursor -= titleHeight

        let badgeReserve = tasks == nil ? 0 : size.height * 0.11
        if !subtitle.isEmpty {
            cursor -= size.height * 0.045
            let available = cursor - content.minY - badgeReserve
            let subtitleSize = max(6, size.height * 0.058)
            if available >= subtitleSize * 1.2 {
                _ = drawText(
                    subtitle, font: .systemFont(ofSize: subtitleSize), color: bodyInk,
                    in: NSRect(x: content.minX, y: content.minY + badgeReserve,
                               width: content.width, height: available),
                    topAt: cursor, lines: 4
                )
            }
        }

        // A plan's completion state is the single most useful thing an icon can
        // say about agent output (§8.5), and a bar says it before the eye has
        // resolved the digits.
        if let tasks { drawTaskBadge(tasks, in: content, size: size) }
    }

    /// Draws `text` with its top edge at `topAt` and returns the height used.
    @discardableResult
    private static func drawText(
        _ text: String, font: NSFont, color: NSColor,
        in bounds: NSRect, topAt: CGFloat, lines: Int
    ) -> CGFloat {
        guard bounds.height > 0 else { return 0 }
        // Word wrapping on the paragraph, truncation on the container.  A
        // paragraph style set to `.byTruncatingTail` never wraps at all — it
        // lays the whole string on one line and clips it — which is why these
        // icons only ever showed one line of title and one line of body no
        // matter how much page was left underneath.
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.maximumLineHeight = font.pointSize * 1.26
        paragraph.lineSpacing = 0

        let storage = NSTextStorage(string: text, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: paragraph,
        ])
        let container = NSTextContainer(size: NSSize(width: bounds.width, height: bounds.height))
        container.maximumNumberOfLines = lines
        container.lineBreakMode = .byTruncatingTail
        container.lineFragmentPadding = 0
        let layout = NSLayoutManager()
        layout.addTextContainer(container)
        storage.addLayoutManager(layout)

        let glyphs = layout.glyphRange(for: container)
        let used = layout.usedRect(for: container)

        // NSLayoutManager lays text out top-down — line 0 sits at the smallest
        // y of its own coordinate space — so drawing it straight into this
        // unflipped page puts the first line at the bottom and the paragraph
        // reads backwards.  One line hides the fault entirely, which is how it
        // survived; give the glyphs a flipped context of their own.
        let previous = NSGraphicsContext.current
        guard let cgContext = previous?.cgContext else { return used.height }
        cgContext.saveGState()
        cgContext.translateBy(x: 0, y: topAt)
        cgContext.scaleBy(x: 1, y: -1)
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cgContext, flipped: true)
        layout.drawGlyphs(forGlyphRange: glyphs, at: NSPoint(x: bounds.minX, y: 0))
        NSGraphicsContext.current = previous
        cgContext.restoreGState()

        return used.height
    }

    /// The small-size fallback: proportioned rules that read as a page of text.
    private static func drawRuledLines(in content: NSRect, tasks: (done: Int, total: Int)?, size: CGSize) {
        let rule = max(1, size.height * 0.055)
        let gap = rule * 0.85
        var y = content.maxY - rule

        spine.setFill()
        NSBezierPath(roundedRect: NSRect(x: content.minX, y: y, width: content.width * 0.82, height: rule),
                     xRadius: rule / 2, yRadius: rule / 2).fill()

        // Ragged widths so it reads as prose rather than a barcode.
        let widths: [CGFloat] = [0.95, 0.72, 0.88, 0.6]
        faintInk.setFill()
        for width in widths {
            y -= rule + gap
            guard y >= content.minY else { break }
            NSBezierPath(roundedRect: NSRect(x: content.minX, y: y, width: content.width * width, height: rule),
                         xRadius: rule / 2, yRadius: rule / 2).fill()
        }

        guard let tasks, tasks.total > 0 else { return }
        accent.setFill()
        let barHeight = max(1, size.height * 0.04)
        let fraction = CGFloat(tasks.done) / CGFloat(tasks.total)
        NSBezierPath(roundedRect: NSRect(x: content.minX, y: content.minY,
                                         width: content.width * fraction, height: barHeight),
                     xRadius: barHeight / 2, yRadius: barHeight / 2).fill()
    }

    private static func drawTaskBadge(_ tasks: (done: Int, total: Int), in content: NSRect, size: CGSize) {
        guard tasks.total > 0 else { return }
        let barHeight = max(1.5, size.height * 0.022)
        let barWidth = content.width * 0.5
        let bar = NSRect(x: content.minX, y: content.minY, width: barWidth, height: barHeight)

        faintInk.withAlphaComponent(0.35).setFill()
        NSBezierPath(roundedRect: bar, xRadius: barHeight / 2, yRadius: barHeight / 2).fill()

        let fraction = min(1, CGFloat(tasks.done) / CGFloat(tasks.total))
        accent.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: bar.minX, y: bar.minY, width: max(barHeight, barWidth * fraction), height: barHeight),
            xRadius: barHeight / 2, yRadius: barHeight / 2
        ).fill()

        let label = "\(tasks.done)/\(tasks.total)"
        let font = NSFont.systemFont(ofSize: max(5, size.height * 0.05), weight: .medium)
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: faintInk]
        let width = (label as NSString).size(withAttributes: attributes).width
        (label as NSString).draw(
            at: NSPoint(x: min(bar.maxX + size.width * 0.04, content.maxX - width),
                        y: bar.minY - font.pointSize * 0.36),
            withAttributes: attributes
        )
    }

    // MARK: - Reading

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
