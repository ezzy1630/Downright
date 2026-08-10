import AppKit
import MarkdownRender

/// One material implementation for transient chrome. Content must be mounted
/// in `contentView`; `NSGlassEffectView` only guarantees compositing order for
/// the content view it owns.
@MainActor
final class ChromeGlass: NSView {
    enum RoundedCorners {
        case all
        case bottomOnly
    }

    enum Tint {
        case panel
        case band
        case control
    }

    var styleSheet: StyleSheet { didSet { updateMaterial() } }
    var cornerRadius: CGFloat { didSet { applyStyle() } }
    var roundedCorners: RoundedCorners { didSet { applyStyle() } }
    var tint: Tint { didSet { updateMaterial() } }
    var shadowRadius: CGFloat = 18 { didSet { applyStyle() } }
    var shadowOffset = NSSize(width: 0, height: -4) { didSet { applyStyle() } }
    var shadowOpacity: Float? { didSet { applyStyle() } }
    var showsFocus = false {
        didSet {
            guard showsFocus != oldValue else { return }
            updateFocus(animated: window != nil)
        }
    }
    var passesThroughHits = false

    let contentView = NSView()

    private let fallback: PanelBackdrop
    private let rimGradient = CAGradientLayer()
    private let rimMask = CAShapeLayer()
    private let focusLayer = CAShapeLayer()
    private var material: NSView?
    private(set) var usesGlass = false

    @available(macOS 26.0, *)
    private var glassEffect: NSGlassEffectView? { material as? NSGlassEffectView }

    init(
        styleSheet: StyleSheet,
        cornerRadius: CGFloat,
        roundedCorners: RoundedCorners = .all,
        tint: Tint = .panel
    ) {
        self.styleSheet = styleSheet
        self.cornerRadius = cornerRadius
        self.roundedCorners = roundedCorners
        self.tint = tint
        fallback = PanelBackdrop(
            styleSheet: styleSheet,
            material: tint == .band ? .titlebar : .headerView,
            blendingMode: .withinWindow
        )
        super.init(frame: .zero)
        finishInit()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    static func supportsGlass(_ styleSheet: StyleSheet) -> Bool {
        guard #available(macOS 26.0, *) else { return false }
        return supportsGlass(
            osSupportsGlass: true,
            reduceTransparency: styleSheet.reduceTransparency,
            increaseContrast: styleSheet.increaseContrast
        )
    }

    static func supportsGlass(
        osSupportsGlass: Bool,
        reduceTransparency: Bool,
        increaseContrast: Bool
    ) -> Bool {
        osSupportsGlass && !reduceTransparency && !increaseContrast
    }

    static func isDarkBackground(_ color: NSColor) -> Bool {
        guard let rgb = color.usingColorSpace(.sRGB) else { return false }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        return luminance < 0.5
    }

    static func glassTint(_ styleSheet: StyleSheet, tint: Tint) -> NSColor {
        let dark = isDarkBackground(styleSheet.background)
        let alpha: CGFloat = switch tint {
        case .panel: dark ? 0.08 : 0.025
        case .band: dark ? 0.16 : 0.06
        case .control: dark ? 0.11 : 0.035
        }
        return styleSheet.background.withAlphaComponent(alpha)
    }

    static func materialAppearance(_ styleSheet: StyleSheet) -> NSAppearance? {
        let name: NSAppearance.Name = isDarkBackground(styleSheet.background)
            ? .darkAqua
            : .aqua
        return NSAppearance(named: name)
    }

    static func opaqueFallbackColor(_ styleSheet: StyleSheet, tint: Tint) -> NSColor {
        switch tint {
        case .band:
            styleSheet.surface.blended(
                withFraction: isDarkBackground(styleSheet.background) ? 0.30 : 0.55,
                of: styleSheet.background
            ) ?? styleSheet.surface
        case .panel, .control:
            styleSheet.surface
        }
    }

    private func finishInit() {
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor

        fallback.blendsWithinWindow = true
        fallback.usesSurfaceFill = styleSheet.reduceTransparency || styleSheet.increaseContrast
        fallback.opaqueSurfaceColor = Self.opaqueFallbackColor(styleSheet, tint: tint)

        contentView.autoresizingMask = [.width, .height]
        contentView.setAccessibilityRole(.group)

        rimMask.fillColor = NSColor.clear.cgColor
        rimMask.strokeColor = NSColor.white.cgColor
        rimMask.actions = ["path": NSNull(), "frame": NSNull(), "lineWidth": NSNull()]
        rimGradient.mask = rimMask
        rimGradient.actions = ["frame": NSNull(), "colors": NSNull(), "isHidden": NSNull()]
        rimGradient.zPosition = 100
        layer?.addSublayer(rimGradient)

        focusLayer.fillColor = NSColor.clear.cgColor
        focusLayer.actions = ["path": NSNull(), "frame": NSNull(), "strokeColor": NSNull(), "opacity": NSNull()]
        focusLayer.zPosition = 101
        layer?.addSublayer(focusLayer)

        setAccessibilityRole(.group)
        updateMaterial()
    }

    private func updateMaterial() {
        appearance = Self.materialAppearance(styleSheet)
        contentView.appearance = appearance
        fallback.appearance = appearance
        let wantsGlass = Self.supportsGlass(styleSheet)
        if wantsGlass {
            if !usesGlass, #available(macOS 26.0, *) { mountGlass() }
            if #available(macOS 26.0, *) {
                glassEffect?.appearance = Self.materialAppearance(styleSheet)
                glassEffect?.tintColor = Self.glassTint(styleSheet, tint: tint)
            }
        } else if usesGlass || contentView.superview !== self {
            mountFallback()
        }
        fallback.styleSheet = styleSheet
        fallback.usesSurfaceFill = styleSheet.reduceTransparency || styleSheet.increaseContrast
        fallback.opaqueSurfaceColor = Self.opaqueFallbackColor(styleSheet, tint: tint)
        applyStyle()
    }

    @available(macOS 26.0, *)
    private func mountGlass() {
        contentView.removeFromSuperview()
        fallback.removeFromSuperview()
        material?.removeFromSuperview()

        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.appearance = Self.materialAppearance(styleSheet)
        glass.tintColor = Self.glassTint(styleSheet, tint: tint)
        if glass.responds(to: Selector(("setEffectIsInteractive:"))) {
            glass.setValue(true, forKey: "effectIsInteractive")
        }
        glass.wantsLayer = true
        glass.layer?.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.autoresizingMask = [.width, .height]
        glass.frame = bounds
        glass.contentView = contentView
        addSubview(glass)
        material = glass
        usesGlass = true
        PanelBackdrop.resolveDetachedGlass(in: contentView)
    }

    private func mountFallback() {
        contentView.removeFromSuperview()
        material?.removeFromSuperview()
        material = nil
        usesGlass = false
        fallback.frame = bounds
        fallback.autoresizingMask = [.width, .height]
        if fallback.superview !== self { addSubview(fallback) }
        contentView.frame = bounds
        if contentView.superview !== self {
            addSubview(contentView, positioned: .above, relativeTo: fallback)
        }
        PanelBackdrop.resolveDetachedGlass(in: contentView)
    }

    func refreshGlassAfterWindowAttach() {
        guard usesGlass, #available(macOS 26.0, *) else { return }
        mountGlass()
        applyStyle()
    }

    override func layout() {
        super.layout()
        material?.frame = bounds
        fallback.frame = bounds
        contentView.frame = bounds
        applyStyle()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        passesThroughHits ? nil : super.hitTest(point)
    }

    private func applyStyle() {
        guard let layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)

        let path = chromePath(in: bounds, inset: 0)
        let insetPath = chromePath(in: bounds.insetBy(dx: 0.75, dy: 0.75), inset: 0.75)
        let dark = Self.isDarkBackground(styleSheet.background)

        layer.shadowRadius = shadowRadius
        layer.shadowOffset = shadowOffset
        layer.shadowOpacity = shadowOpacity ?? Float(
            styleSheet.increaseContrast ? 0.30 : (dark ? 0.28 : 0.16)
        )
        layer.shadowPath = path

        material?.layer?.mask = maskLayer(path: path)
        fallback.layer?.mask = maskLayer(path: path)

        rimGradient.frame = bounds
        rimMask.frame = bounds
        rimMask.path = insetPath
        rimMask.lineWidth = styleSheet.increaseContrast ? 1.5 : 1
        let rimAlpha: CGFloat = styleSheet.increaseContrast ? 0.95 : (dark ? 0.72 : 0.86)
        rimGradient.colors = [
            NSColor.white.withAlphaComponent(rimAlpha).cgColor,
            NSColor.white.withAlphaComponent(rimAlpha * 0.42).cgColor,
            NSColor.white.withAlphaComponent(dark ? 0.10 : 0.16).cgColor,
            NSColor.white.withAlphaComponent(0.025).cgColor,
        ]
        rimGradient.startPoint = CGPoint(x: 0.08, y: 0.98)
        rimGradient.endPoint = CGPoint(x: 0.92, y: 0.02)
        rimGradient.isHidden = usesGlass && !styleSheet.increaseContrast

        focusLayer.frame = bounds
        focusLayer.path = chromePath(in: bounds.insetBy(dx: 1.5, dy: 1.5), inset: 1.5)
        focusLayer.strokeColor = styleSheet.accent.cgColor
        focusLayer.lineWidth = 1.5
        focusLayer.opacity = showsFocus ? 0.92 : 0
        CATransaction.commit()
    }

    private func updateFocus(animated: Bool) {
        let target: Float = showsFocus ? 0.92 : 0
        guard animated, !styleSheet.reduceMotion else {
            focusLayer.removeAnimation(forKey: "focus")
            focusLayer.opacity = target
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = focusLayer.presentation()?.opacity ?? focusLayer.opacity
        animation.toValue = target
        animation.duration = Motion.hover
        animation.timingFunction = Motion.timing(.decelerate)
        focusLayer.add(animation, forKey: "focus")
        focusLayer.opacity = target
    }

    private func maskLayer(path: CGPath) -> CAShapeLayer {
        let mask = CAShapeLayer()
        mask.frame = bounds
        mask.path = path
        mask.fillColor = NSColor.black.cgColor
        mask.actions = ["path": NSNull(), "frame": NSNull()]
        return mask
    }

    private func chromePath(in rect: CGRect, inset: CGFloat) -> CGPath {
        switch roundedCorners {
        case .all:
            PanelMetrics.continuousRoundedPath(
                rect: rect,
                radius: max(0, cornerRadius - inset)
            )
        case .bottomOnly:
            bottomRoundedPath(rect: rect, radius: max(0, cornerRadius - inset))
        }
    }

    private func bottomRoundedPath(rect: CGRect, radius: CGFloat) -> CGPath {
        let r = min(max(0, radius), min(rect.width, rect.height) / 2)
        let control = r * 0.447_715
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + r))
        path.addCurve(
            to: CGPoint(x: rect.maxX - r, y: rect.minY),
            control1: CGPoint(x: rect.maxX, y: rect.minY + control),
            control2: CGPoint(x: rect.maxX - control, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.minY))
        path.addCurve(
            to: CGPoint(x: rect.minX, y: rect.minY + r),
            control1: CGPoint(x: rect.minX + control, y: rect.minY),
            control2: CGPoint(x: rect.minX, y: rect.minY + control)
        )
        path.closeSubpath()
        return path
    }

    var rendersOpaqueFallbackForTesting: Bool { !usesGlass && fallback.superview === self }
}
