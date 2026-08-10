import AppKit
import MarkdownRender

/// The owned titlebar material. It follows the content safe area instead of
/// duplicating AppKit's toolbar-height calculation.
@MainActor
final class ToolbarGlassBand: NSView {
    var styleSheet: StyleSheet { didSet { glass.styleSheet = styleSheet } }
    private let glass: ChromeGlass

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        glass = ChromeGlass(
            styleSheet: styleSheet,
            cornerRadius: PanelMetrics.bandCornerRadius,
            roundedCorners: .bottomOnly,
            tint: .band
        )
        super.init(frame: .zero)
        glass.passesThroughHits = true
        glass.shadowRadius = 12
        glass.shadowOffset = NSSize(width: 0, height: -3)
        glass.shadowOpacity = 0.10
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        glass.frame = bounds
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
