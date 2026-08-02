import AppKit
import MarkdownCore
import MarkdownRender

/// Image lightbox (§7.1).
///
/// "Click an image → lightbox with zoom and pan; alt text renders as a
/// caption."  Scroll to zoom about the pointer, drag to pan, `⎋` or a click on
/// the backdrop to leave.
///
/// This is the one surface that does **not** take its colours from the theme.
/// A lightbox works by removing everything around the image — a themed scrim
/// would tint the picture you came to look at, which is the opposite of the
/// point.  Chrome is themed; a viewing surround is not.
final class LightboxWindow: NSWindow {
    private var lightboxView: LightboxContentView? { contentView as? LightboxContentView }

    convenience init(image: NSImage, caption: String?) {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.fullScreenAuxiliary, .transient]

        let view = LightboxContentView(image: image, caption: caption)
        view.onDismiss = { [weak self] in self?.dismiss() }
        contentView = view
    }

    override var canBecomeKey: Bool { true }

    func present(over window: NSWindow) {
        let frame = window.screen?.visibleFrame ?? window.frame
        setFrame(frame, display: true)
        lightboxView?.resetZoom()

        window.addChildWindow(self, ordered: .above)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        alphaValue = reduceMotion ? 1 : 0
        makeKeyAndOrderFront(nil)
        makeFirstResponder(contentView)
        guard !reduceMotion else { return }
        PanelAnimation.run(reduceMotion: false, duration: 0.15) { _ in
            animator().alphaValue = 1
        }
    }

    func dismiss() {
        let finish = { [weak self] in
            guard let self else { return }
            self.parent?.removeChildWindow(self)
            self.orderOut(nil)
            self.alphaValue = 1
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }
        PanelAnimation.run(reduceMotion: false, duration: 0.12, { _ in
            animator().alphaValue = 0
        }, completion: finish)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }
}

// MARK: - Content

private final class LightboxContentView: NSView {
    var onDismiss: (() -> Void)?

    private let image: NSImage
    private let caption: String?
    private var scale: CGFloat = 1
    private var offset = CGSize.zero
    private var didDrag = false

    private let captionInset: CGFloat = 24
    private let minimumScale: CGFloat = 0.05
    private let maximumScale: CGFloat = 16

    init(image: NSImage, caption: String?) {
        self.image = image
        self.caption = caption?.isEmpty == true ? nil : caption
        super.init(frame: .zero)
        setAccessibilityRole(.image)
        setAccessibilityLabel(self.caption ?? "Image")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }

    // MARK: Geometry

    /// Scale at which the image just fits, never enlarging a small image —
    /// blowing a 64pt icon up to fill a 27" display helps nobody.
    private var fitScale: CGFloat {
        let size = image.size
        guard size.width > 0, size.height > 0 else { return 1 }
        let available = bounds.insetBy(dx: 40, dy: 60)
        return min(1, min(available.width / size.width, available.height / size.height))
    }

    func resetZoom() {
        scale = fitScale
        offset = .zero
        needsDisplay = true
    }

    private var imageRect: NSRect {
        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        return NSRect(
            x: bounds.midX - size.width / 2 + offset.width,
            y: bounds.midY - size.height / 2 + offset.height,
            width: size.width, height: size.height
        )
    }

    /// Zooms about `anchor` so the pixel under the pointer stays under it.
    private func zoom(by factor: CGFloat, about anchor: NSPoint) {
        let old = imageRect
        let newScale = min(maximumScale, max(minimumScale, scale * factor))
        guard newScale != scale, old.width > 0, old.height > 0 else { return }

        let unitX = (anchor.x - old.minX) / old.width
        let unitY = (anchor.y - old.minY) / old.height
        scale = newScale

        let size = NSSize(width: image.size.width * scale, height: image.size.height * scale)
        let originX = anchor.x - unitX * size.width
        let originY = anchor.y - unitY * size.height
        offset = CGSize(
            width: originX - (bounds.midX - size.width / 2),
            height: originY - (bounds.midY - size.height / 2)
        )
        needsDisplay = true
    }

    // MARK: Input

    override func scrollWheel(with event: NSEvent) {
        let delta = event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / 200 : event.deltaY / 20
        guard delta != 0 else { return }
        zoom(by: 1 + delta, about: convert(event.locationInWindow, from: nil))
    }

    override func magnify(with event: NSEvent) {
        zoom(by: 1 + event.magnification, about: convert(event.locationInWindow, from: nil))
    }

    override func mouseDown(with event: NSEvent) { didDrag = false }

    override func mouseDragged(with event: NSEvent) {
        didDrag = true
        offset.width += event.deltaX
        offset.height -= event.deltaY
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if event.clickCount == 2 {
            // Fit ⇄ actual size, the standard image-viewer double-click.
            scale = abs(scale - fitScale) < 0.001 ? 1 : fitScale
            offset = .zero
            needsDisplay = true
            return
        }
        guard !didDrag else { return }
        let point = convert(event.locationInWindow, from: nil)
        if !imageRect.contains(point) { onDismiss?() }
    }

    override func keyDown(with event: NSEvent) {
        switch KeyBinding.key(for: event) {
        case "escape": onDismiss?()
        case "space": onDismiss?()
        default: super.keyDown(with: event)
        }
    }

    override func cancelOperation(_ sender: Any?) { onDismiss?() }

    override func resetCursorRects() {
        addCursorRect(imageRect, cursor: .openHand)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Opaque under Reduce Transparency; a scrim is decoration, and the
        // setting says not to depend on it.
        let opaque = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        NSColor.black.withAlphaComponent(opaque ? 1 : 0.88).setFill()
        dirtyRect.fill()

        let rect = imageRect
        if rect.intersects(dirtyRect) {
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        }

        guard let caption else { return }
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: NSColor.white,
        ]
        let size = (caption as NSString).size(withAttributes: attributes)
        let pill = NSRect(
            x: bounds.midX - size.width / 2 - 10,
            y: captionInset - 5,
            width: min(bounds.width - 80, size.width + 20),
            height: size.height + 10
        )
        NSColor.white.withAlphaComponent(0.12).setFill()
        NSBezierPath(roundedRect: pill, xRadius: 6, yRadius: 6).fill()
        (caption as NSString).draw(
            in: pill.insetBy(dx: 10, dy: 5),
            withAttributes: attributes
        )
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        needsDisplay = true
    }
}
