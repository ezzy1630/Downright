import AppKit
import MarkdownCore

/// The gutter's hover/scrub tooltip (§8.6).
///
/// A borderless child window rather than an `NSPopover`: a popover animates,
/// takes focus, and draws an anchor arrow, all of which are wrong for something
/// that has to track a drag at 120fps.  It ignores mouse events entirely so it
/// can never interrupt the scrub that summoned it.
final class DensityGutterPreviewWindow: NSWindow {
    var styleSheet: StyleSheet {
        didSet { content.styleSheet = styleSheet }
    }

    private let content: PreviewContentView
    private let maximumWidth: CGFloat = 320

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.content = PreviewContentView(styleSheet: styleSheet)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: maximumWidth, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = content
    }

    /// `anchor` is the screen point at the gutter's trailing edge, level with
    /// the pointer. The hover form carries the heading and a short text
    /// glimpse; `footer` carries the §9.6 reading metrics.
    func show(
        title: String,
        snippet: String,
        footer: String,
        rightOf anchor: NSPoint,
        over parent: NSWindow,
        reduceMotion: Bool
    ) {
        content.update(title: title, snippet: snippet, footer: footer)
        let size = content.fittingSize(maxWidth: maximumWidth)

        var origin = NSPoint(x: anchor.x + 8, y: anchor.y - size.height / 2)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(visible.minX + 4, origin.x), visible.maxX - size.width - 4)
            origin.y = min(max(visible.minY + 4, origin.y), visible.maxY - size.height - 4)
        }
        let finalFrame = NSRect(origin: origin, size: size)
        let alreadyPresented = isVisible && self.parent === parent

        if alreadyPresented {
            // Hover moves should feel like one surface following the pointer,
            // not a sequence of cards blinking in and out.
            GutterChrome.animate(reduceMotion: reduceMotion, duration: 0.12) { _ in
                self.animator().setFrame(finalFrame, display: true)
            }
            content.needsDisplay = true
            return
        }

        setFrame(finalFrame, display: true)

        guard self.parent !== parent || !isVisible else {
            content.needsDisplay = true
            return
        }
        parent.addChildWindow(self, ordered: .above)
        alphaValue = reduceMotion ? 1 : 0
        orderFront(nil)
        guard !reduceMotion else { return }
        GutterChrome.animate(reduceMotion: false, duration: 0.10) { _ in
            self.animator().alphaValue = 1
        }
    }

    func hide() {
        guard isVisible else { return }
        parent?.removeChildWindow(self)
        orderOut(nil)
    }
}

// MARK: - Content

private final class PreviewContentView: NSView {
    var styleSheet: StyleSheet {
        didSet {
            layer?.backgroundColor = styleSheet.surface.withAlphaComponent(0.96).cgColor
            cached = nil
            needsDisplay = true
        }
    }

    private var title = ""
    private var snippet = ""
    private var footer = ""
    private var cached: NSAttributedString?
    private let padding: CGFloat = 9
    /// Enough to recognise the section, not enough to read it here.
    private let snippetLimit = 220

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.masksToBounds = true
        layer?.backgroundColor = styleSheet.surface.withAlphaComponent(0.96).cgColor
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document map preview")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }

    func update(title: String, snippet: String, footer: String) {
        guard title != self.title || snippet != self.snippet || footer != self.footer else { return }
        self.title = title
        self.snippet = snippet
        self.footer = footer
        cached = nil
        needsDisplay = true
    }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let text = attributed()
        let bounds = text.boundingRect(
            with: NSSize(width: maxWidth - padding * 2, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: maxWidth, height: min(140, ceil(bounds.height) + padding * 2))
    }

    private func attributed() -> NSAttributedString {
        if let cached { return cached }

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2

        let result = NSMutableAttributedString(string: title, attributes: [
            .font: GutterChrome.titleFont,
            .foregroundColor: styleSheet.text,
            .paragraphStyle: paragraph,
        ])

        if !snippet.isEmpty {
            var body = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.count > snippetLimit { body = String(body.prefix(snippetLimit)) + "…" }
            // The snippet is document text, so it borrows the theme's body face
            // at panel size rather than the system font (§11.1).
            let face = NSFont(descriptor: styleSheet.bodyFont().fontDescriptor, size: 12)
                ?? NSFont.systemFont(ofSize: 12)
            result.append(NSAttributedString(string: "\n" + body, attributes: [
                .font: face,
                .foregroundColor: styleSheet.textSecondary,
                .paragraphStyle: paragraph,
            ]))
        }

        if !footer.isEmpty {
            result.append(NSAttributedString(string: "\n" + footer, attributes: [
                .font: GutterChrome.bodyFont,
                .foregroundColor: styleSheet.textFaint,
                .paragraphStyle: paragraph,
            ]))
        }

        cached = result
        return result
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let card = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: card, xRadius: 14, yRadius: 14)
        styleSheet.surface.withAlphaComponent(0.96).setFill()
        path.fill()
        styleSheet.rule.setStroke()
        path.lineWidth = 1
        path.stroke()

        attributed().draw(
            with: bounds.insetBy(dx: padding, dy: padding),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cached = nil
        needsDisplay = true
    }
}
