import AppKit
import MarkdownCore

/// The single view the app installs.
///
/// Owns the scroll view, the text view, and the left gutter rail (§6.1a), and
/// leaves two documented seams for the pieces other parts of the app add
/// later: the density gutter on the trailing edge (§8.6) and the sticky
/// breadcrumb pinned at the top (§5.1).  Neither is built here — this view
/// only guarantees them a place to live and a layout that accounts for them.
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

    /// Accessory installed on the right edge; the density gutter goes here.
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

    /// Accessory pinned at the top; the sticky breadcrumb goes here.
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
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
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
        let topHeight = topAccessory.map { $0.fittingSize.height > 0 ? $0.fittingSize.height : 28 } ?? 0
        let trailingWidth = trailingAccessory.map { $0.fittingSize.width > 0 ? $0.fittingSize.width : 14 } ?? 0

        let accessoryWidth = min(max(160, textView.styleSheet.measureWidth), max(160, bounds.width - 80))
        topAccessory?.frame = NSRect(x: (bounds.width - accessoryWidth) / 2, y: 8,
                                     width: accessoryWidth, height: topHeight)
        trailingAccessory?.frame = NSRect(x: bounds.width - trailingWidth, y: 0,
                                          width: trailingWidth, height: bounds.height)

        scrollView.frame = NSRect(x: 0, y: 0,
                                  width: max(0, bounds.width - trailingWidth),
                                  height: bounds.height)

        // The text column is centred in the measure (§11.1); the rail sits
        // immediately to its left, so markers track the text rather than the
        // window edge.
        // The inset is measured to where the *text* starts, not to where the
        // text view starts: the view carries `revealSlack` of its own lead-in
        // so a caret-anchored reveal can shift a line left (§6.1c).
        let responsiveCharacters: CGFloat = bounds.width < 900 ? 66 : (bounds.width > 1200 ? 74 : textView.styleSheet.theme.typography.measureCharacters)
        let preferredMeasure = textView.styleSheet.averageCharacterWidth * responsiveCharacters
        let measure = min(preferredMeasure, max(240, scrollView.frame.width - RenderMetrics.revealSlack * 2))
        textView.applyResponsiveMeasure(measure)
        let textLeft = max(gutterWidth + RenderMetrics.revealSlack, (scrollView.frame.width - measure) / 2)
        let columnOrigin = textLeft - RenderMetrics.revealSlack
        textView.minSize = NSSize(width: measure + RenderMetrics.revealSlack * 2, height: 0)
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: columnOrigin, bottom: 0, right: 0)

        gutter.frame = NSRect(x: max(0, textLeft - gutterWidth), y: 0,
                              width: gutterWidth, height: scrollView.frame.height)

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
