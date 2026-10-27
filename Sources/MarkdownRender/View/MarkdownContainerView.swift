import AppKit
import MarkdownCore

/// The single view the app installs.
///
/// Owns the scroll view, the text view, and the left gutter rail (§6.1a), and
/// leaves three documented seams for the pieces other parts of the app add
/// later: a contents map on the leading edge (§8.6), a trailing accessory, and
/// the sticky breadcrumb pinned at the top (§5.1). Neither is built here —
/// this view only guarantees them a place to live and a layout that accounts
/// for them.
public final class MarkdownContainerView: NSView {

    public let textView: MarkdownTextView
    public let scrollView: NSScrollView
    private let gutter: GutterRailView
    private let footnoteMargin: FootnoteMarginView
    private let backgroundOverlay: MarkdownDecorationOverlay
    private let foregroundOverlay: MarkdownDecorationOverlay

    public var styleSheet: StyleSheet {
        get { textView.styleSheet }
        set {
            textView.styleSheet = newValue
            scrollView.backgroundColor = newValue.background
            needsDisplay = true
            needsLayout = true
        }
    }

    /// Width reserved on the left for block markers in Live mode (§6.1a).
    public private(set) var gutterWidth: CGFloat = RenderMetrics.gutterWidth

    /// Optional contents map. A density map owns the quiet leading lane; its
    /// preview opens inward only when the reader asks for it.
    public var leadingAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let leadingAccessory {
                leadingAccessory.translatesAutoresizingMaskIntoConstraints = true
                addSubview(leadingAccessory, positioned: .above, relativeTo: nil)
            }
            needsLayout = true
        }
    }

    /// Optional accessory installed on the right edge.
    public var trailingAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let trailingAccessory {
                trailingAccessory.translatesAutoresizingMaskIntoConstraints = true
                addSubview(trailingAccessory)
            }
            needsLayout = true
        }
    }

    /// Accessory in a reserved lane above the scroller. The document never
    /// moves underneath it, so orientation chrome cannot cover prose.
    public var topAccessory: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let topAccessory {
                topAccessory.translatesAutoresizingMaskIntoConstraints = true
                addSubview(topAccessory)
            }
            needsLayout = true
        }
    }

    /// A transient orientation control may float over the page instead of
    /// reserving a permanent second title row. The host owns its visibility.
    public var topAccessoryOverlaysContent = false {
        didSet { needsLayout = true }
    }

    public convenience init(storage: NSTextStorage) {
        self.init(storage: storage, styleSheet: MarkdownTextView.fallbackStyleSheet())
    }

    public init(
        storage: NSTextStorage, styleSheet: StyleSheet,
        sharingPresentationOf source: MarkdownTextView? = nil
    ) {
        // Let AppKit establish the scroll surface against an empty buffer.
        // Attaching a nonempty shared buffer makes its origin calculation
        // resolve the entire document before it has viewport geometry.
        let initialStorage = source == nil ? storage : NSTextStorage()
        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: styleSheet.measureWidth, height: 100),
                                    storage: initialStorage, styleSheet: styleSheet, sharingPresentationOf: source)
        scrollView = NSScrollView(frame: .zero)
        gutter = GutterRailView(textView: textView)
        footnoteMargin = FootnoteMarginView(textView: textView)
        backgroundOverlay = MarkdownDecorationOverlay(textView: textView, phase: .background)
        foregroundOverlay = MarkdownDecorationOverlay(textView: textView, phase: .foreground)
        super.init(frame: .zero)

        scrollView.documentView = textView
        if let source { textView.attachSharedStorage(storage, presentationOf: source) }
        // The contents map is the document's persistent scroll affordance, and
        // an overlay thumb (invisible until the user scrolls) gives position
        // feedback without a second, unrelated right-hand sidebar.  Overlay
        // scrollers reserve no layout space, so the measure constraint below
        // keeps the column out from under the thumb (§7).
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        // The text column's width is `layout()`'s decision; leaving the
        // automatic adjustment on silently discards the centring inset, and
        // the document view's autoresizing mask would stretch it to the clip
        // view and throw away the measure cap (§11.1).
        scrollView.automaticallyAdjustsContentInsets = false
        textView.autoresizingMask = []
        // The container supplies the opaque page; its background ornaments
        // remain below native text and fragment backgrounds.
        scrollView.drawsBackground = false
        textView.drawsBackground = false
        scrollView.backgroundColor = styleSheet.background
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        addSubview(backgroundOverlay)
        addSubview(scrollView)
        addSubview(foregroundOverlay, positioned: .above, relativeTo: scrollView)
        textView.foregroundInvalidationHandler = { [weak overlay = foregroundOverlay, weak view = textView] rect in
            guard let overlay, let view else { return }
            if let rect { overlay.setNeedsDisplay(overlay.convert(rect, from: view)) }
            else { overlay.needsDisplay = true }
        }
        // The rail floats over the scroll view rather than inside it, so it
        // never scrolls horizontally away from the text it annotates.
        addSubview(gutter)
        addSubview(footnoteMargin, positioned: .above, relativeTo: scrollView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(scrolled(_:)),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )
        gutter.reload()
    }

    public required init?(coder: NSCoder) { nil }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func scrolled(_ note: Notification) {
        footnoteMargin.needsDisplay = true
        backgroundOverlay.needsDisplay = true
        foregroundOverlay.needsDisplay = true
    }

    public func refreshMarginNotes() { footnoteMargin.needsDisplay = true }

    public override var isFlipped: Bool { true }

    /// The container paints the page colour itself so there is never a
    /// transparent gap behind the rail or beside the measure, and so an
    /// offscreen capture of this view has a defined background.
    public override func draw(_ dirtyRect: NSRect) {
        textView.styleSheet.background.setFill()
        // `bounds`-clipped, for the reason spelled out in `GutterRailView`.
        dirtyRect.intersection(bounds).fill()
    }

    /// Height of the accessory's own lane above the scrolling content.
    ///
    /// Public because it is not only this view's business: chrome the *window*
    /// floats over the document — the change and conflict bars — has to clear
    /// the same lane the breadcrumb reserves, and computing that from a second
    /// copy of this formula is how the two drift apart.  Zero when the accessory
    /// overlays the content, or when there is no accessory to reserve for.
    public var topLaneHeight: CGFloat {
        guard !topAccessoryOverlaysContent else { return 0 }
        let height = topAccessoryHeight
        return height > 0 ? height + 8 : 0
    }

    private var topAccessoryHeight: CGFloat {
        topAccessory.map { accessory in
            guard !accessory.isHidden else { return 0 }
            let height = accessory.fittingSize.height
            return height > 0 ? height : 24
        } ?? 0
    }

    public override func layout() {
        super.layout()
        let topHeight = topAccessoryHeight
        let topLaneHeight = self.topLaneHeight
        let densityMap = (leadingAccessory as? DensityGutterView)
            ?? (trailingAccessory as? DensityGutterView)
        let hasLeadingDensityMap = leadingAccessory is DensityGutterView
        var leadingWidth = hasLeadingDensityMap
            ? (leadingAccessory?.fittingSize.width ?? DensityGutterView.width)
            : (leadingAccessory.map { $0.fittingSize.width > 0 ? $0.fittingSize.width : 24 } ?? 0)
        var trailingWidth = trailingAccessory.map {
            if $0 is DensityGutterView {
                return $0.fittingSize.width > 0 ? $0.fittingSize.width : DensityGutterView.width
            }
            return $0.fittingSize.width > 0 ? $0.fittingSize.width : 14
        } ?? 0
        // A compact pane needs the marker rail and fixed code bleed before
        // it can afford the document map. Keep Focus Mode's visibility owned
        // by the controller; only remove the map's geometric reservation.
        let minimumContentWidth = RenderMetrics.minimumProseWidth + RenderMetrics.codeBleed
            + gutterWidth + RenderMetrics.revealSlack
            + NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        if bounds.width - leadingWidth - trailingWidth < minimumContentWidth {
            if leadingAccessory is DensityGutterView { leadingWidth = 0 }
            if trailingAccessory is DensityGutterView { trailingWidth = 0 }
        }
        let contentWidth = max(0, bounds.width - leadingWidth - trailingWidth)
        let showsNoteLane = bounds.width >= 1100 && textView.mode != .source
        let noteLane: CGFloat = showsNoteLane ? 230 : 0
        let noteGap: CGFloat = showsNoteLane ? 24 : 0

        leadingAccessory?.frame = NSRect(x: 0, y: 0,
                                         width: leadingWidth, height: bounds.height)
        trailingAccessory?.frame = NSRect(x: bounds.width - trailingWidth, y: 0,
                                          width: trailingWidth, height: bounds.height)

        scrollView.frame = NSRect(x: leadingWidth, y: topLaneHeight,
                                  width: contentWidth,
                                  height: max(0, bounds.height - topLaneHeight))

        // The text column is centred in the measure (§11.1). The document map
        // stays on the window wall: moving it beside the reading measure makes
        // it look detached and puts its hover card over the prose.
        // The inset is measured to where the *text* starts, not to where the
        // text view starts: the view carries `revealSlack` of its own lead-in
        // so a caret-anchored reveal can shift a line left (§6.1c).
        // Keep the same measure across Document and Source. Widening source to
        // 90ch recenters the column and slides the left gutter rail, which
        // reads as the leading chrome teleporting on every mode switch.
        let preferredMeasure = textView.styleSheet.theme.typography.measureCharacters == TypographyConfig.fullWidthMeasure
            ? CGFloat.greatestFiniteMagnitude : textView.styleSheet.measureWidth
        // Keep the column out from under the overlay thumb when the measure is
        // capped by a narrow window; a wide window's centring margin already
        // clears it (§7).
        let overlayThumbWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        // The container is the reading measure plus a trailing bleed lane that
        // fenced blocks, diagrams, tables, and display math may use while prose
        // is held back off it (§11.1).  The lane extends into the right margin,
        // which a centred column leaves empty anyway; the marker rail sits in
        // the left one, which is why the lane is trailing-only.
        let bleed = RenderMetrics.codeBleed
        let available = max(
            RenderMetrics.minimumProseWidth + bleed,
            contentWidth - gutterWidth - RenderMetrics.revealSlack - overlayThumbWidth
        )
        let column = min(preferredMeasure + bleed, available)
        let measure = column - bleed
        textView.applyResponsiveMeasure(column)
        // Centre the column in the *whole* surface, not just in the scroll
        // view: the leading lane (document map) would otherwise push the text
        // off centre by half its own width, which reads as the column being
        // pressed against the map wall while the trailing margin stays empty.
        //
        // Centred on the reading measure plus *half* the bleed lane.  Centring on
        // the bare measure left every fenced block, table and diagram growing
        // into the right margin alone, so a page with any of them read visibly
        // right-heavy; centring on the whole container instead pushed the prose —
        // which is most of the page — half a lane left of centre.  Splitting the
        // lane balances the two: prose sits a touch left of dead centre, full
        // bleed blocks overhang it evenly on both sides.
        // Centre prose independently. Margin notes consume otherwise-empty
        // space to its right; they must never shift the reading measure left.
        let opticalLeft = max(0, (bounds.width - measure) / 2 - leadingWidth)
        let textLeft = max(gutterWidth + RenderMetrics.revealSlack, opticalLeft)
        let columnOrigin = textLeft - RenderMetrics.revealSlack
        textView.minSize = NSSize(width: column + RenderMetrics.revealSlack * 2, height: 0)
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: columnOrigin, bottom: 0, right: 0)

        let textOrigin = scrollView.frame.minX + textLeft
        let noteX = textOrigin + column + noteGap
        let availableNoteWidth = max(0, bounds.width - trailingWidth - noteX - 16)
        let resolvedNoteWidth = min(noteLane, availableNoteWidth)
        footnoteMargin.isHidden = !showsNoteLane || resolvedNoteWidth < 100
        footnoteMargin.frame = NSRect(
            x: noteX,
            y: scrollView.frame.minY,
            width: resolvedNoteWidth,
            height: scrollView.frame.height
        )
        topAccessory?.frame = NSRect(
            x: textOrigin,
            y: topAccessoryOverlaysContent ? 8 : 4,
            width: min(measure, max(0, bounds.width - textOrigin - trailingWidth)),
            height: max(topHeight, 0)
        )
        if topAccessoryOverlaysContent, let topAccessory {
            addSubview(topAccessory, positioned: .above, relativeTo: nil)
        }
        gutter.frame = NSRect(x: max(0, textOrigin - gutterWidth), y: topLaneHeight,
                              width: gutterWidth, height: scrollView.frame.height)

        if let densityMap {
            // Sticky full-height map on the selected wall. The mark stack is
            // centred in the window, not the scrolled document — so the map
            // never rides with the text and never shrinks under the breadcrumb.
            densityMap.frame = NSRect(
                x: hasLeadingDensityMap ? 0 : bounds.width - trailingWidth,
                y: 0,
                width: hasLeadingDensityMap ? leadingWidth : trailingWidth,
                height: bounds.height
            )
            // AppKit allows sublayers to draw outside a zero-width view.
            // Clip only the compact map so no stray ticks remain over text.
            densityMap.clipsToBounds = densityMap.frame.width == 0
            // Keep the stick above the scroll view / marker rail so its hit
            // lane stays responsive.
            addSubview(densityMap, positioned: .above, relativeTo: nil)
            densityMap.containerGeometryDidChange()
        }

        if !footnoteMargin.isHidden {
            addSubview(footnoteMargin, positioned: .above, relativeTo: scrollView)
            footnoteMargin.needsDisplay = true
        }
        backgroundOverlay.frame = scrollView.frame
        foregroundOverlay.frame = scrollView.frame
        backgroundOverlay.needsDisplay = true
        foregroundOverlay.needsDisplay = true
    }

    public override func viewWillDraw() {
        super.viewWillDraw()
        backgroundOverlay.needsDisplay = true
        foregroundOverlay.needsDisplay = true
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // §11.2: the palette is derived from `NSColor` system colours, so a
        // light/dark or Increase Contrast change is a stylesheet rebuild, not
        // a theme reload.
        textView.styleSheet = StyleSheet(theme: textView.styleSheet.theme,
                                         appearance: effectiveAppearance)
        scrollView.backgroundColor = textView.styleSheet.background
        gutter.reload()
        needsLayout = true
    }

}

/// Viewport-sized ornaments, independent of TextKit's rendering surfaces.
/// It never owns input, source storage, or a document-sized backing surface.
private final class MarkdownDecorationOverlay: NSView {
    enum Phase { case background, foreground }
    private weak var textView: MarkdownTextView?
    private let phase: Phase

    init(textView: MarkdownTextView, phase: Phase) {
        self.textView = textView
        self.phase = phase
        super.init(frame: .zero)
        clipsToBounds = true
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, let context = NSGraphicsContext.current?.cgContext else { return }
        let origin = convert(NSPoint.zero, from: textView)
        let textRect = textView.convert(dirtyRect, from: self)
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        context.translateBy(x: origin.x, y: origin.y)
        switch phase {
        case .background: textView.drawPageBackground(in: textRect)
        case .foreground: textView.drawForeground(in: textRect)
        }
    }
}
