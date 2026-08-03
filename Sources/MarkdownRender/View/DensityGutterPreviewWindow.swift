import AppKit
import MarkdownCore

/// The gutter's hover/scrub tooltip (§8.6).
///
/// A borderless child window rather than an `NSPopover`: a popover animates,
/// takes focus, and draws an anchor arrow, all of which are wrong for something
/// that has to track a drag at 120fps.  It ignores mouse events entirely so it
/// stays non-interactive during scrubbing, but can accept pointer presence
/// during passive hover so the line-to-card path does not feel fragile.
final class DensityGutterPreviewWindow: NSWindow {
    var styleSheet: StyleSheet {
        didSet { content.styleSheet = styleSheet }
    }

    var onPointerPresence: ((Bool) -> Void)?

    private let content: PreviewContentView
    private let maximumWidth: CGFloat = 320
    private let entranceDuration: TimeInterval = 0.06
    private let exitDuration: TimeInterval = 0.08
    private var presentationGeneration = 0

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
        content.onPointerPresence = { [weak self] isInside in
            self?.onPointerPresence?(isInside)
        }
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
        reduceMotion: Bool,
        interactive: Bool
    ) {
        presentationGeneration &+= 1
        ignoresMouseEvents = !interactive
        let titleChanged = content.update(title: title, snippet: snippet, footer: footer)
        let alreadyPresented = isVisible && self.parent === parent
        // Pointer movement should not trigger a new text measurement on every
        // event. Keep the card geometry stable within a section; reflow only
        // when a new heading arrives, where the change carries meaning.
        let size = alreadyPresented && !titleChanged
            ? frame.size
            : content.fittingSize(maxWidth: maximumWidth)

        var origin = NSPoint(x: anchor.x + 8, y: anchor.y - size.height / 2)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(visible.minX + 4, origin.x), visible.maxX - size.width - 4)
            origin.y = min(max(visible.minY + 4, origin.y), visible.maxY - size.height - 4)
        }
        let finalFrame = NSRect(origin: origin, size: size)

        if alreadyPresented {
            // Once visible, the preview tracks the pointer directly. An
            // easing animation here makes rapid line-to-line movement lag
            // behind the rail; entrance and exit carry the intentional motion.
            alphaValue = 1
            setFrame(finalFrame, display: true)
            if titleChanged { content.animateContentChange(reduceMotion: reduceMotion) }
            content.needsDisplay = true
            return
        }

        let entranceFrame = finalFrame.offsetBy(dx: reduceMotion ? 0 : -4, dy: 0)
        setFrame(entranceFrame, display: true)

        guard self.parent !== parent || !isVisible else {
            content.needsDisplay = true
            return
        }
        parent.addChildWindow(self, ordered: .above)
        alphaValue = reduceMotion ? 1 : 0
        orderFront(nil)
        guard !reduceMotion else { return }
        GutterChrome.animate(reduceMotion: false, duration: entranceDuration) { _ in
            self.animator().alphaValue = 1
            self.animator().setFrame(finalFrame, display: true)
        }
    }

    func hide() {
        guard isVisible || parent != nil else { return }
        presentationGeneration &+= 1
        let generation = presentationGeneration

        guard !styleSheet.reduceMotion else {
            ignoresMouseEvents = true
            parent?.removeChildWindow(self)
            orderOut(nil)
            alphaValue = 1
            return
        }

        // Keep the child window attached during the short fade. A quick
        // re-entry can then reverse the transition without tearing down and
        // rebuilding the surface.
        GutterChrome.animate(reduceMotion: false, duration: exitDuration, { _ in
            self.animator().alphaValue = 0
        }, completion: { [weak self] in
            guard let self, self.presentationGeneration == generation else { return }
            self.ignoresMouseEvents = true
            self.parent?.removeChildWindow(self)
            self.orderOut(nil)
            self.alphaValue = 1
        })
    }

    func cancelHideAnimation() {
        guard isVisible else { return }
        presentationGeneration &+= 1
        alphaValue = 1
    }
}

// MARK: - Content

private final class PreviewContentView: NSView {
    var onPointerPresence: ((Bool) -> Void)?

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
    private var trackingArea: NSTrackingArea?

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

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerPresence?(true) }
    override func mouseExited(with event: NSEvent) { onPointerPresence?(false) }

    func update(title: String, snippet: String, footer: String) -> Bool {
        let titleChanged = title != self.title
        guard titleChanged || snippet != self.snippet || footer != self.footer else { return false }
        self.title = title
        self.snippet = snippet
        self.footer = footer
        cached = nil
        needsDisplay = true
        return titleChanged
    }

    func animateContentChange(reduceMotion: Bool) {
        guard !reduceMotion, let layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = 0.06
        transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(transition, forKey: "preview-content-change")
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
