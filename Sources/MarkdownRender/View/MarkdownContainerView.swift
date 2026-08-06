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

    public init(storage: NSTextStorage, styleSheet: StyleSheet) {
        textView = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: styleSheet.measureWidth, height: 100),
                                    storage: storage, styleSheet: styleSheet)
        scrollView = NSScrollView(frame: .zero)
        gutter = GutterRailView(textView: textView)
        super.init(frame: .zero)

        scrollView.documentView = textView
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
        scrollView.drawsBackground = true
        scrollView.backgroundColor = styleSheet.background
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        addSubview(scrollView)
        // The rail floats over the scroll view rather than inside it, so it
        // never scrolls horizontally away from the text it annotates.
        addSubview(gutter)
        gutter.reload()
    }

    public required init?(coder: NSCoder) { nil }

    public override var isFlipped: Bool { true }

    /// The container paints the page colour itself so there is never a
    /// transparent gap behind the rail or beside the measure, and so an
    /// offscreen capture of this view has a defined background.
    public override func draw(_ dirtyRect: NSRect) {
        textView.styleSheet.background.setFill()
        // `bounds`-clipped, for the reason spelled out in `GutterRailView`.
        dirtyRect.intersection(bounds).fill()
    }

    public override func layout() {
        super.layout()
        let accessoryFitting = topAccessory.map { accessory -> CGFloat in
            guard !accessory.isHidden else { return 0 }
            let height = accessory.fittingSize.height
            return height > 0 ? height : 24
        } ?? 0
        let topHeight = accessoryFitting
        let topLaneHeight = topAccessoryOverlaysContent
            ? 0
            : (topHeight > 0 ? topHeight + 8 : 0)
        let isFloatingDensityMap = leadingAccessory is DensityGutterView
        let leadingWidth = isFloatingDensityMap
            ? (leadingAccessory?.fittingSize.width ?? DensityGutterView.width)
            : (leadingAccessory.map { $0.fittingSize.width > 0 ? $0.fittingSize.width : 24 } ?? 0)
        let trailingWidth = trailingAccessory.map { $0.fittingSize.width > 0 ? $0.fittingSize.width : 14 } ?? 0
        let contentWidth = max(0, bounds.width - leadingWidth - trailingWidth)

        leadingAccessory?.frame = NSRect(x: 0, y: 0,
                                         width: leadingWidth, height: bounds.height)
        trailingAccessory?.frame = NSRect(x: bounds.width - trailingWidth, y: 0,
                                          width: trailingWidth, height: bounds.height)

        scrollView.frame = NSRect(x: leadingWidth, y: topLaneHeight,
                                  width: contentWidth,
                                  height: max(0, bounds.height - topLaneHeight))

        // The text column is centred in the measure (§11.1). The document map
        // is intentionally kept in the quiet leading lane so it does not
        // masquerade as a second scrollbar beside the text.
        // The inset is measured to where the *text* starts, not to where the
        // text view starts: the view carries `revealSlack` of its own lead-in
        // so a caret-anchored reveal can shift a line left (§6.1c).
        // Keep the same measure across Document and Source. Widening source to
        // 90ch recenters the column and slides the left gutter rail, which
        // reads as the leading chrome teleporting on every mode switch.
        let renderedTarget = min(
            72,
            max(68, textView.styleSheet.theme.typography.measureCharacters)
        )
        let responsiveCharacters: CGFloat
        if bounds.width < 900 {
            responsiveCharacters = 68
        } else if bounds.width > 1200 {
            responsiveCharacters = 72
        } else {
            responsiveCharacters = renderedTarget
        }
        let preferredMeasure = textView.styleSheet.averageCharacterWidth * responsiveCharacters
        // Keep the column out from under the overlay thumb when the measure is
        // capped by a narrow window; a wide window's centring margin already
        // clears it (§7).
        let overlayThumbWidth = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .overlay)
        let measure = min(preferredMeasure,
                          max(240, contentWidth - RenderMetrics.revealSlack * 2 - overlayThumbWidth))
        textView.applyResponsiveMeasure(measure)
        // Centre the column in the *whole* surface, not just in the scroll
        // view: the leading lane (document map) would otherwise push the text
        // off centre by half its own width, which reads as the column being
        // pressed against the map wall while the trailing margin stays empty.
        let opticalLeft = max(0, (bounds.width - measure) / 2 - leadingWidth)
        let textLeft = max(gutterWidth + RenderMetrics.revealSlack, opticalLeft)
        let columnOrigin = textLeft - RenderMetrics.revealSlack
        textView.minSize = NSSize(width: measure + RenderMetrics.revealSlack * 2, height: 0)
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: columnOrigin, bottom: 0, right: 0)

        let textOrigin = scrollView.frame.minX + textLeft
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

        if isFloatingDensityMap, let leadingAccessory {
            // Sticky full-height stick on the leading edge. The mark stack is
            // centred in the window, not the scrolled document — so the map
            // never rides with the text and never shrinks under the breadcrumb.
            leadingAccessory.frame = NSRect(
                x: 0,
                y: 0,
                width: leadingWidth,
                height: bounds.height
            )
            // Keep the stick above the scroll view / marker rail so the left
            // hit lane stays responsive.
            addSubview(leadingAccessory, positioned: .above, relativeTo: nil)
        }

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
