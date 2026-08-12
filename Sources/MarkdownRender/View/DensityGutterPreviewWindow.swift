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
        didSet {
            appearance = styleSheet.appearance
            content.appearance = styleSheet.appearance
            content.styleSheet = styleSheet
        }
    }

    var onPointerPresence: ((Bool) -> Void)?

    private let content: PreviewContentView
    static let preferredWidth: CGFloat = 320
    /// Narrowest card worth showing.  With the rail pinned to the window wall
    /// the margin between rail and prose is `(measure-centred) / 2` minus the
    /// rail lane, which at a ~1020pt window is only ~166pt — an 180pt floor
    /// meant the hover card *never appeared* at ordinary window widths.  140
    /// still fits a title plus two wrapped snippet lines (9pt padding, 12pt
    /// body) and only gives up when the margin is genuinely a sliver.
    static let minimumUsefulWidth: CGFloat = 140
    static let anchorGap: CGFloat = 8
    /// Quick Look windows are often only 600–800pt wide. When the reading
    /// measure consumes the entire margin, a compact overlay is preferable to
    /// silently removing the map's only orientation affordance. The editor
    /// leaves this off so prose is never covered during normal work.
    var allowsContentOverlap = false

    static func compactOverlayWidth(parentWidth: CGFloat) -> CGFloat {
        min(preferredWidth, max(minimumUsefulWidth, parentWidth * 0.42))
    }

    static func resolvedMaximumWidth(
        anchorX: CGFloat,
        maximumTrailingX: CGFloat?,
        minimumOriginX: CGFloat? = nil,
        opensInward: Bool
    ) -> CGFloat? {
        guard !opensInward, let maximumTrailingX else { return preferredWidth }
        let originX = max(anchorX + anchorGap, minimumOriginX ?? -.greatestFiniteMagnitude)
        let available = min(preferredWidth, maximumTrailingX - originX)
        return available >= minimumUsefulWidth ? available : nil
    }
    private let entranceDuration: TimeInterval = 0.10
    private let exitDuration: TimeInterval = 0.08
    private var presentationGeneration = 0

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.content = PreviewContentView(styleSheet: styleSheet)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: Self.preferredWidth, height: 40),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        appearance = styleSheet.appearance
        content.appearance = styleSheet.appearance
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
        maximumTrailingX: CGFloat? = nil,
        reduceMotion: Bool,
        interactive: Bool,
        allowContentOverlap: Bool = false
    ) {
        presentationGeneration &+= 1
        allowsContentOverlap = allowContentOverlap
        ignoresMouseEvents = !interactive
        let titleChanged = content.update(title: title, snippet: snippet, footer: footer)
        let alreadyPresented = isVisible && self.parent === parent
        // Pointer movement should not trigger a new text measurement on every
        // event. Keep the card geometry stable within a section; reflow only
        // when a new heading arrives, where the change carries meaning.
        let opensInward = anchor.x > parent.frame.midX
        let visibleFrame = (parent.screen ?? NSScreen.main)?.visibleFrame
        let resolvedWidth = Self.resolvedMaximumWidth(
            anchorX: anchor.x,
            maximumTrailingX: maximumTrailingX,
            minimumOriginX: visibleFrame.map { $0.minX + 4 },
            opensInward: opensInward
        )
        let usesCompactOverlay = resolvedWidth == nil && allowsContentOverlap
        let maximumWidth: CGFloat
        if let resolvedWidth {
            maximumWidth = resolvedWidth
        } else if usesCompactOverlay {
            maximumWidth = Self.compactOverlayWidth(parentWidth: parent.frame.width)
        } else {
            hide()
            return
        }
        let size = alreadyPresented && !titleChanged && frame.width <= maximumWidth
            ? frame.size
            : content.fittingSize(maxWidth: maximumWidth)

        var origin = NSPoint(
            x: opensInward
                ? anchor.x - size.width - Self.anchorGap
                : max(anchor.x + Self.anchorGap, visibleFrame.map { $0.minX + 4 } ?? anchor.x + Self.anchorGap),
            y: anchor.y - size.height / 2
        )
        if !opensInward, let maximumTrailingX {
            origin.x = min(origin.x, maximumTrailingX - size.width)
        }
        if let visible = visibleFrame {
            origin.x = min(max(visible.minX + 4, origin.x), visible.maxX - size.width - 4)
            origin.y = min(max(visible.minY + 4, origin.y), visible.maxY - size.height - 4)
        }
        // The screen clamp above must not trade one invariant for another. If
        // the card cannot fit both on-screen and before the text column, hide
        // it; covering prose is never an acceptable fallback.
        if !opensInward, let maximumTrailingX,
           !usesCompactOverlay,
           origin.x + size.width > maximumTrailingX + 0.5 {
            hide()
            return
        }
        let finalFrame = NSRect(origin: origin, size: size)

        if alreadyPresented {
            // Once visible, the preview tracks the pointer directly. An
            // easing animation here makes rapid line-to-line movement lag
            // behind the rail; entrance and exit carry the intentional motion.
            alphaValue = 1
            setFrame(finalFrame, display: true)
            if titleChanged {
                content.animateContentChange(reduceMotion: reduceMotion)
                content.staggerSnippetReveal(reduceMotion: reduceMotion)
            }
            content.needsDisplay = true
            return
        }

        // Rise ~4pt while fading in — card lifts toward the mark.
        let entranceFrame = finalFrame.offsetBy(
            dx: reduceMotion ? 0 : (opensInward ? 4 : -4),
            dy: reduceMotion ? 0 : -4
        )
        setFrame(entranceFrame, display: true)

        guard self.parent !== parent || !isVisible else {
            content.needsDisplay = true
            return
        }
        parent.addChildWindow(self, ordered: .above)
        alphaValue = reduceMotion ? 1 : 0
        orderFront(nil)
        content.prepareSnippetStagger(reduceMotion: reduceMotion)
        guard !reduceMotion else {
            content.revealSnippetImmediately()
            return
        }
        GutterChrome.animate(reduceMotion: false, duration: entranceDuration) { _ in
            self.animator().alphaValue = 1
            self.animator().setFrame(finalFrame, display: true)
        }
        content.staggerSnippetReveal(reduceMotion: false)
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
            content.revealSnippetImmediately()
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
            self.content.revealSnippetImmediately()
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
            cachedTitle = nil
            cachedSnippet = nil
            cachedFooter = nil
            needsDisplay = true
        }
    }

    private var title = ""
    private var snippet = ""
    private var footer = ""
    private var cachedTitle: NSAttributedString?
    private var cachedSnippet: NSAttributedString?
    private var cachedFooter: NSAttributedString?
    private let padding: CGFloat = 9
    /// Enough to recognise the section, not enough to read it here.
    private let snippetLimit = 220
    private var trackingArea: NSTrackingArea?
    private var snippetAlpha: CGFloat = 1
    private var snippetRevealWork: DispatchWorkItem?
    private var staggerGeneration = 0

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
        refreshTrackingArea(&trackingArea, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect])
    }

    override func mouseEntered(with event: NSEvent) { onPointerPresence?(true) }
    override func mouseExited(with event: NSEvent) { onPointerPresence?(false) }

    func update(title: String, snippet: String, footer: String) -> Bool {
        let titleChanged = title != self.title
        guard titleChanged || snippet != self.snippet || footer != self.footer else { return false }
        self.title = title
        self.snippet = snippet
        self.footer = footer
        cachedTitle = nil
        cachedSnippet = nil
        cachedFooter = nil
        needsDisplay = true
        return titleChanged
    }

    func animateContentChange(reduceMotion: Bool) {
        guard !reduceMotion, let layer else { return }
        let transition = CATransition()
        transition.type = .fade
        transition.duration = Motion.previewCrossfade
        transition.timingFunction = Motion.timing(.easeOut)
        layer.add(transition, forKey: "preview-content-change")
    }

    /// Title paints immediately; snippet waits a beat on entrance / section change.
    func prepareSnippetStagger(reduceMotion: Bool) {
        snippetRevealWork?.cancel()
        if reduceMotion || snippet.isEmpty {
            snippetAlpha = 1
        } else {
            snippetAlpha = 0
        }
        needsDisplay = true
    }

    func staggerSnippetReveal(reduceMotion: Bool) {
        snippetRevealWork?.cancel()
        staggerGeneration &+= 1
        let generation = staggerGeneration
        guard !reduceMotion, !snippet.isEmpty else {
            snippetAlpha = 1
            needsDisplay = true
            return
        }
        snippetAlpha = 0
        needsDisplay = true
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.staggerGeneration == generation else { return }
            self.animateSnippetAlpha(to: 1, generation: generation)
        }
        snippetRevealWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Motion.previewStagger, execute: work)
    }

    func revealSnippetImmediately() {
        snippetRevealWork?.cancel()
        snippetRevealWork = nil
        staggerGeneration &+= 1
        snippetAlpha = 1
        needsDisplay = true
    }

    private func animateSnippetAlpha(to target: CGFloat, generation: Int) {
        guard staggerGeneration == generation, abs(target - snippetAlpha) > 0.01 else { return }
        let fade = CATransition()
        fade.type = .fade
        fade.duration = Motion.quick
        fade.timingFunction = Motion.timing(.decelerate)
        layer?.add(fade, forKey: "snippet-reveal")
        snippetAlpha = target
        needsDisplay = true
    }

    func fittingSize(maxWidth: CGFloat) -> NSSize {
        let text = combinedAttributed(snippetAlpha: 1)
        let bounds = text.boundingRect(
            with: NSSize(width: maxWidth - padding * 2, height: 400),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return NSSize(width: maxWidth, height: min(140, ceil(bounds.height) + padding * 2))
    }

    private func titleAttributed() -> NSAttributedString {
        if let cachedTitle { return cachedTitle }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let value = NSAttributedString(string: title, attributes: [
            .font: GutterChrome.titleFont,
            .foregroundColor: styleSheet.text,
            .paragraphStyle: paragraph,
        ])
        cachedTitle = value
        return value
    }

    private func snippetAttributed() -> NSAttributedString {
        if let cachedSnippet { return cachedSnippet }
        var body = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > snippetLimit { body = String(body.prefix(snippetLimit)) + "…" }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let face = NSFont(descriptor: styleSheet.bodyFont().fontDescriptor, size: 12)
            ?? NSFont.systemFont(ofSize: 12)
        let value = NSAttributedString(string: body.isEmpty ? "" : "\n" + body, attributes: [
            .font: face,
            .foregroundColor: styleSheet.textSecondary,
            .paragraphStyle: paragraph,
        ])
        cachedSnippet = value
        return value
    }

    private func footerAttributed() -> NSAttributedString {
        if let cachedFooter { return cachedFooter }
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineSpacing = 2
        let value = NSAttributedString(
            string: footer.isEmpty ? "" : "\n" + footer,
            attributes: [
                .font: GutterChrome.bodyFont,
                .foregroundColor: styleSheet.textFaint,
                .paragraphStyle: paragraph,
            ]
        )
        cachedFooter = value
        return value
    }

    private func combinedAttributed(snippetAlpha: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: titleAttributed())
        if !snippet.isEmpty {
            let snippet = NSMutableAttributedString(attributedString: snippetAttributed())
            let color = styleSheet.textSecondary.withAlphaComponent(
                styleSheet.textSecondary.alphaComponent * snippetAlpha
            )
            snippet.addAttribute(
                .foregroundColor,
                value: color,
                range: NSRange(location: 0, length: snippet.length)
            )
            result.append(snippet)
        }
        if !footer.isEmpty {
            result.append(footerAttributed())
        }
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

        combinedAttributed(snippetAlpha: snippetAlpha).draw(
            with: bounds.insetBy(dx: padding, dy: padding),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        cachedTitle = nil
        cachedSnippet = nil
        cachedFooter = nil
        needsDisplay = true
    }
}
