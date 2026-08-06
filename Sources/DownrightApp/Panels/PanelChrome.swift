import AppKit
import CoreText
import MarkdownCore
import MarkdownRender

// Chrome shared by every summonable surface (§11.4).
//
// "No permanent sidebars, panels, or status bar.  Everything summonable,
// nothing resident."  Nothing in this directory may assume it is on screen: a
// panel reports the width a host should animate it to, holds no document state
// of its own, and draws from the `StyleSheet` it is handed rather than caching
// colours — which is also what makes a theme change a property assignment
// instead of a rebuild.

enum PanelMetrics {
    static let listWidth: CGFloat = 264
    static let searchResultsWidth: CGFloat = 380
    /// Thin enough to replace a scrollbar rather than become a sidebar (§8.6).
    static let gutterWidth: CGFloat = 14
    static let headerHeight: CGFloat = 32
    static let barHeight: CGFloat = 32
    static let reviewBarHeight: CGFloat = 30
    static let rowHeight: CGFloat = 24
    static let groupRowHeight: CGFloat = 22
    static let inset: CGFloat = 10
    static let cornerRadius: CGFloat = 6
    static let hairline: CGFloat = 1
}

/// A count in transient chrome is context, not another action.  Give it a
/// quiet, fixed shape so it cannot be confused with the neighbouring buttons.
private final class PanelStatusBadge: NSTextField {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: size.width + 12, height: 20)
    }
}

/// A transient side surface.  `preferredWidth` exists so a host can animate the
/// panel in from zero without knowing what is inside it (§11.4).
@MainActor
protocol PanelSurface: NSView {
    var preferredWidth: CGFloat { get }
}

// MARK: - Type

/// Panels are chrome, not the document, so their labels use the system face at
/// system sizes — a 16pt New York body font in a 264pt sidebar reads as a
/// mistake.  Only genuinely document-derived text (code snippets, tidy
/// before/after) borrows the theme's faces.  Colour always comes from the
/// `StyleSheet`.
enum PanelFont {
    static let row = NSFont.systemFont(ofSize: 12.5)
    static let rowEmphasised = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
    static let secondary = NSFont.systemFont(ofSize: 11.5)
    static let header = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let group = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let title = NSFont.systemFont(ofSize: 13, weight: .semibold)
}

// MARK: - Motion

enum PanelAnimation {
    /// Every animated transition in this directory goes through here, so there
    /// is exactly one place Reduce Motion is honoured (§11.4).
    static func run(
        reduceMotion: Bool,
        duration: TimeInterval = 0.18,
        _ changes: (NSAnimationContext) -> Void,
        completion: (() -> Void)? = nil
    ) {
        Motion.run(reduceMotion: reduceMotion, duration: duration,
                   changes: changes, completion: completion)
    }
}

// MARK: - Time

enum RelativeTime {
    private static let abbreviatedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()

    private static let namedFormatter: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        f.dateTimeStyle = .named
        return f
    }()

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// "2m", "3h" — for a list where the column is a few characters wide.
    static func short(_ date: Date, now: Date = Date()) -> String {
        if now.timeIntervalSince(date) < 60 { return "now" }
        return abbreviatedFormatter.localizedString(for: date, relativeTo: now)
    }

    /// "3 minutes ago", "yesterday".
    static func long(_ date: Date, now: Date = Date()) -> String {
        namedFormatter.localizedString(for: date, relativeTo: now)
    }

    static func stamp(_ date: Date) -> String {
        stampFormatter.string(from: date)
    }
}

// MARK: - Backgrounds

/// Panel background: vibrancy where the system allows it, a flat themed fill
/// where Reduce Transparency or Increase Contrast is on (§11.4).  The fill is
/// drawn rather than set on a layer so a dynamic `NSColor` re-resolves when the
/// effective appearance changes.
final class PanelBackdrop: NSView {
    var styleSheet: StyleSheet { didSet { applyStyle() } }
    /// When true, draws the theme's `surface` colour instead of vibrancy — for
    /// panels that must read as a distinct card against the page rather than
    /// chrome that dissolves into it (§11.4).
    var usesSurfaceFill = false { didSet { applyStyle() } }

    private let effect = NSVisualEffectView()

    init(
        styleSheet: StyleSheet,
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        effect.material = material
        effect.blendingMode = blendingMode
        effect.state = .followsWindowActiveState
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var prefersOpaque: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency || styleSheet.increaseContrast
    }

    private func applyStyle() {
        effect.isHidden = prefersOpaque || usesSurfaceFill
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard prefersOpaque || usesSurfaceFill else { return }
        (usesSurfaceFill ? styleSheet.surface : styleSheet.background).setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Lists

/// Table view that reports `⏎` on the selected row.  AppKit hands you
/// double-click for free but not Return, and a panel you can reach with the
/// keyboard but not act on with it is not keyboard-navigable (§11.4).
final class PanelTableView: NSTableView {
    var onActivate: (() -> Void)?
    /// Handed the normalised key name; return true to swallow the event.
    var onKeyDown: ((String) -> Bool)?

    override func keyDown(with event: NSEvent) {
        guard let key = KeyBinding.key(for: event) else {
            super.keyDown(with: event)
            return
        }
        if onKeyDown?(key) == true { return }
        if key == "return", selectedRow >= 0 {
            onActivate?()
            return
        }
        super.keyDown(with: event)
    }
}

enum PanelList {
    static func makeScrollView(documentView: NSView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.setAccessibilityRole(.scrollArea)
        scroll.documentView = documentView
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return scroll
    }

    static func makeTableView(identifier: String) -> PanelTableView {
        let table = PanelTableView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.style = .plain
        table.gridStyleMask = []
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.selectionHighlightStyle = .regular
        table.allowsEmptySelection = true
        table.allowsMultipleSelection = false
        table.usesAlternatingRowBackgroundColors = false
        table.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        table.setAccessibilityRole(.list)
        table.focusRingType = .default
        return table
    }

}

/// Group header used by the task panel, the sibling sidebar, the tidy sheet and
/// the search results panel — the four places where rows belong to a parent.
///
/// A container rather than a bare `NSTextField`: a table sets its cell views'
/// frames directly, so a cell view must keep its autoresizing translation on
/// and inset its own contents.
final class PanelGroupRowView: NSView {
    private let label = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        label.font = PanelFont.group
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PanelMetrics.inset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(text: String, color: NSColor) {
        label.stringValue = text
        label.textColor = color
        setAccessibilityRole(.row)
        setAccessibilityLabel(text)
    }
}

// MARK: - Buttons

/// Closure-backed button target.  Panels wire up a lot of one-line buttons and
/// a selector per button would be noise; the panel keeps these alive.
final class ButtonAction: NSObject {
    private let handler: () -> Void

    init(_ handler: @escaping () -> Void) { self.handler = handler }

    @objc func fire(_ sender: Any?) { handler() }
}

enum PanelButton {
    static func symbol(
        _ name: String,
        label: String,
        action: ButtonAction
    ) -> NSButton {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: label)
        let button = PanelSymbolButton(image: image ?? NSImage(), target: action, action: #selector(ButtonAction.fire(_:)))
        button.isBordered = false
        button.bezelStyle = .accessoryBarAction
        button.imagePosition = .imageOnly
        button.focusRingType = .default
        button.setAccessibilityLabel(label)
        button.setAccessibilityRole(.button)
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    static func text(_ title: String, action: ButtonAction, isDefault: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: action, action: #selector(ButtonAction.fire(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 12)
        if isDefault { button.keyEquivalent = "\r" }
        button.focusRingType = .default
        button.setAccessibilityLabel(title)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }

    /// On/off pill for the find bar's regex, case, whole-word and in-selection
    /// switches.
    static func toggle(_ title: String, label: String, action: ButtonAction) -> NSButton {
        let button = NSButton(title: title, target: action, action: #selector(ButtonAction.fire(_:)))
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = NSFont.systemFont(ofSize: 12)
        button.focusRingType = .default
        button.setAccessibilityLabel(label)
        button.setAccessibilityRole(.checkBox)
        button.toolTip = label
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}

/// Keep the glyph visually small while giving keyboard and pointer users a
/// comfortable target. Callers with an explicit compact layout can still
/// constrain the button; normal panel chrome uses this intrinsic size.
private final class PanelSymbolButton: NSButton {
    override var intrinsicContentSize: NSSize {
        let size = super.intrinsicContentSize
        return NSSize(width: max(28, size.width), height: max(28, size.height))
    }
}

// MARK: - Non-modal bars (§8.1)

/// The shape both §8.1 bars take: a message, a few actions, and a dismiss.
///
/// **Never a sheet, never a dialog.**  A file changing on disk while you read
/// is not an error and must not steal the keyboard or block the document — the
/// bar has to be ignorable, so it takes no first responder, has no default
/// button that swallows `⏎`, and disappears the moment it is dismissed.
class MessageBarView: NSView {
    var styleSheet: StyleSheet { didSet { applyStyle() } }

    var message: String = "" {
        didSet {
            label.stringValue = message
            setAccessibilityLabel(message)
        }
    }

    /// The bar's one strong colour, drawn as a leading stripe so the two bars
    /// are distinguishable at a glance without either shouting.
    var stripeColor: NSColor { didSet { needsDisplay = true } }

    var onDismiss: (() -> Void)?

    private let label = NSTextField(labelWithString: "")
    private let statusLabel = PanelStatusBadge(labelWithString: "")
    private let actionStack = NSStackView()
    private var actions: [ButtonAction] = []
    private let stripeWidth: CGFloat = 2

    init(styleSheet: StyleSheet, stripeColor: NSColor) {
        self.styleSheet = styleSheet
        self.stripeColor = stripeColor
        super.init(frame: .zero)

        label.font = PanelFont.row
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        statusLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = styleSheet.textFaint
        statusLabel.alignment = .center
        statusLabel.wantsLayer = true
        statusLabel.layer?.cornerRadius = 5
        statusLabel.isHidden = true
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        actionStack.orientation = .horizontal
        actionStack.spacing = 4
        actionStack.translatesAutoresizingMaskIntoConstraints = false
        actionStack.addArrangedSubview(statusLabel)
        addSubview(actionStack)

        let dismiss = ButtonAction { [weak self] in self?.onDismiss?() }
        actions.append(dismiss)
        let close = PanelButton.symbol("xmark", label: "Dismiss", action: dismiss)
        addSubview(close)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset + stripeWidth),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionStack.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            actionStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.leadingAnchor.constraint(equalTo: actionStack.trailingAnchor, constant: 8),
            close.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            close.centerYAnchor.constraint(equalTo: centerYAnchor),
            close.widthAnchor.constraint(equalToConstant: 28),
        ])

        setAccessibilityRole(.group)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: PanelMetrics.barHeight)
    }

    /// Bars sit above the document, so they must not become first responder on
    /// a click that was meant for the text underneath.
    override var acceptsFirstResponder: Bool { false }

    @discardableResult
    func addAction(_ title: String, handler: @escaping () -> Void) -> NSButton {
        let action = ButtonAction(handler)
        actions.append(action)
        let button = PanelButton.text(title, action: action)
        actionStack.addArrangedSubview(button)
        return button
    }

    @discardableResult
    func addSymbolAction(
        _ symbol: String,
        label: String,
        handler: @escaping () -> Void
    ) -> NSButton {
        let action = ButtonAction(handler)
        actions.append(action)
        let button = PanelButton.symbol(symbol, label: label, action: action)
        actionStack.addArrangedSubview(button)
        return button
    }

    func setStatus(_ text: String) {
        statusLabel.stringValue = text
        statusLabel.isHidden = text.isEmpty
        statusLabel.setAccessibilityLabel(text)
    }

    func useReviewBarLayout() {
        label.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        actionStack.spacing = 3
        invalidateIntrinsicContentSize()
    }

    func applyStyle() {
        label.textColor = styleSheet.text
        statusLabel.textColor = styleSheet.textFaint
        statusLabel.layer?.backgroundColor = styleSheet.text
            .withAlphaComponent(styleSheet.increaseContrast ? 0.11 : 0.06)
            .cgColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        styleSheet.background.setFill()
        bounds.fill()
        styleSheet.text.withAlphaComponent(styleSheet.increaseContrast ? 0.08 : 0.035).setFill()
        bounds.fill()

        stripeColor.setFill()
        NSRect(x: 0, y: 0, width: stripeWidth, height: bounds.height).fill()

        // A hairline rather than a border: the bar is part of the document
        // surface, not a card floating over it (§11.3).  It sits above the
        // document, so the rule goes on the bottom edge.
        styleSheet.rule.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: PanelMetrics.hairline).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

// MARK: - Themed segmented control

/// A quiet, animated two-or-more-way filter.  The default `NSSegmentedControl`
/// ships a clunky two-piece border that reads as a template control against the
/// panel's themed backdrop; this one draws its own track with a sliding thumb
/// so selection feels sprung rather than swapped, and scrubbing across the
/// control picks up neighbours as the pointer moves (§11.4).
@MainActor
final class PanelSegmentedControl: NSView {
    private let items: [String]
    var styleSheet: StyleSheet { didSet { applyStyle() } }
    private(set) var selectedIndex: Int
    var onChange: ((Int) -> Void)?

    static let controlHeight: CGFloat = 26
    private static let segmentWidth: CGFloat = 56

    private let backgroundLayer = CALayer()
    private let thumbLayer = CALayer()
    private var textLayers: [CATextLayer] = []
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var hoveredIndex: Int?
    private var isScrubbing = false
    private var thumbIdleColor: NSColor = .clear

    override var intrinsicContentSize: NSSize {
        NSSize(width: Self.segmentWidth * CGFloat(items.count), height: Self.controlHeight)
    }

    init(items: [String], selectedIndex: Int = 0, styleSheet: StyleSheet) {
        self.items = items
        self.selectedIndex = min(max(selectedIndex, 0), max(0, items.count - 1))
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        wantsLayer = true

        backgroundLayer.cornerRadius = 7
        layer?.addSublayer(backgroundLayer)

        thumbLayer.cornerRadius = 5
        layer?.addSublayer(thumbLayer)

        for item in items {
            let textLayer = CATextLayer()
            textLayer.alignmentMode = .center
            textLayer.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
            textLayer.string = item
            layer?.addSublayer(textLayer)
            textLayers.append(textLayer)
        }

        applyStyle()
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(items.joined(separator: "/"))
        setAccessibilityValue(items[selectedIndex])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setSelectedIndex(_ index: Int, animated: Bool = true) {
        let normalized = min(max(index, 0), max(0, items.count - 1))
        guard normalized != selectedIndex else { return }
        selectedIndex = normalized
        setAccessibilityValue(items[selectedIndex])
        updateThumb(animated: animated)
        applySelectionColors()
    }

    // MARK: - Layout & drawing

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let segmentWidth = bounds.width / CGFloat(items.count)
        backgroundLayer.frame = bounds
        thumbLayer.frame = thumbFrame(segmentWidth: segmentWidth)
        for (index, textLayer) in textLayers.enumerated() {
            textLayer.frame = NSRect(x: CGFloat(index) * segmentWidth, y: 0, width: segmentWidth, height: bounds.height)
        }
        CATransaction.commit()
    }

    private func thumbFrame(segmentWidth: CGFloat) -> NSRect {
        NSRect(
            x: CGFloat(selectedIndex) * segmentWidth + 1,
            y: 1,
            width: segmentWidth - 2,
            height: bounds.height - 2
        )
    }

    private func updateThumb(animated: Bool) {
        let segmentWidth = bounds.width / CGFloat(items.count)
        let target = thumbFrame(segmentWidth: segmentWidth)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduce, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbLayer.frame = target
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.standard)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1))
        thumbLayer.frame = target
        CATransaction.commit()
    }

    private func applySelectionColors() {
        for (index, textLayer) in textLayers.enumerated() {
            let selected = index == selectedIndex
            textLayer.font = (selected
                ? NSFont.systemFont(ofSize: 11.5, weight: .semibold)
                : NSFont.systemFont(ofSize: 11.5, weight: .medium)) as CTFont
            textLayer.fontSize = 11.5
            textLayer.foregroundColor = color(forSegment: index, selected: selected)
                .withAlphaComponent(selected ? 1 : dimmedAlpha(for: index)).cgColor
        }
    }

    private func color(forSegment index: Int, selected: Bool) -> NSColor {
        selected ? styleSheet.text : styleSheet.textSecondary
    }

    private func dimmedAlpha(for index: Int) -> CGFloat {
        let contrast = styleSheet.increaseContrast
        if isPointerInside, hoveredIndex == index { return contrast ? 0.92 : 0.78 }
        return contrast ? 0.82 : 0.62
    }

    private func applyStyle() {
        let contrast = styleSheet.increaseContrast
        backgroundLayer.backgroundColor = styleSheet.text
            .panelAlpha(0.06, increaseContrast: contrast).cgColor
        thumbIdleColor = styleSheet.text.panelAlpha(0.13, increaseContrast: contrast)
        thumbLayer.backgroundColor = thumbIdleColor.cgColor
        applySelectionColors()
        needsDisplay = true
    }

    /// The thumb recesses while the pointer holds it — the one physical read in
    /// the control — and springs back past full size on release, so switching
    /// segments lands rather than just sliding.  Scrubbing keeps it held down
    /// while the thumb travels under the pointer.
    private func setThumbPressed(_ pressed: Bool) {
        let contrast = styleSheet.increaseContrast
        let pressedColor = styleSheet.text.panelAlpha(
            contrast ? 0.22 : 0.18,
            increaseContrast: contrast
        )
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduce, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbLayer.transform = CATransform3DIdentity
            thumbLayer.backgroundColor = thumbIdleColor.cgColor
            CATransaction.commit()
            return
        }

        if pressed {
            let press = CABasicAnimation(keyPath: "transform")
            press.fromValue = thumbLayer.presentation()?.transform ?? thumbLayer.transform
            press.toValue = CATransform3DMakeScale(0.92, 0.92, 1)
            press.duration = ToolbarChromePolicy.pressInDuration
            press.timingFunction = ToolbarChromePolicy.timingFunction()
            let color = CABasicAnimation(keyPath: "backgroundColor")
            color.fromValue = thumbLayer.backgroundColor
            color.toValue = pressedColor.cgColor
            color.duration = ToolbarChromePolicy.pressInDuration
            thumbLayer.removeAnimation(forKey: "thumb-settle")
            thumbLayer.add(press, forKey: "thumb-press")
            thumbLayer.add(color, forKey: "thumb-press-color")
            thumbLayer.transform = CATransform3DMakeScale(0.92, 0.92, 1)
            thumbLayer.backgroundColor = pressedColor.cgColor
        } else {
            let from = thumbLayer.presentation()?.transform ?? thumbLayer.transform
            let settle = CAKeyframeAnimation(keyPath: "transform")
            settle.values = [
                NSValue(caTransform3D: from),
                NSValue(caTransform3D: CATransform3DMakeScale(1.06, 1.06, 1)),
                NSValue(caTransform3D: CATransform3DIdentity),
            ]
            settle.keyTimes = [0, 0.45, 1]
            settle.duration = Motion.standard
            settle.timingFunctions = [
                CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1),
                CAMediaTimingFunction(name: .easeOut),
            ]
            let color = CABasicAnimation(keyPath: "backgroundColor")
            color.fromValue = thumbLayer.backgroundColor
            color.toValue = thumbIdleColor.cgColor
            color.duration = Motion.quick
            thumbLayer.removeAnimation(forKey: "thumb-press")
            thumbLayer.removeAnimation(forKey: "thumb-press-color")
            thumbLayer.add(settle, forKey: "thumb-settle")
            thumbLayer.add(color, forKey: "thumb-color-settle")
            thumbLayer.transform = CATransform3DIdentity
            thumbLayer.backgroundColor = thumbIdleColor.cgColor
        }
    }

    // MARK: - Interaction

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        hoveredIndex = segment(at: convert(event.locationInWindow, from: nil).x)
        applySelectionColors()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        hoveredIndex = nil
        applySelectionColors()
    }

    override func mouseDown(with event: NSEvent) {
        isScrubbing = true
        setThumbPressed(true)
        selectIfChanged(convert(event.locationInWindow, from: nil).x)
    }

    override func mouseDragged(with event: NSEvent) {
        hoveredIndex = segment(at: convert(event.locationInWindow, from: nil).x)
        applySelectionColors()
        selectIfChanged(convert(event.locationInWindow, from: nil).x)
    }

    override func mouseUp(with event: NSEvent) {
        isScrubbing = false
        setThumbPressed(false)
        hoveredIndex = nil
        isPointerInside = bounds.contains(convert(event.locationInWindow, from: nil))
        selectIfChanged(convert(event.locationInWindow, from: nil).x)
        applySelectionColors()
    }

    private func segment(at x: CGFloat) -> Int {
        guard bounds.width > 0 else { return 0 }
        return min(max(Int(floor(x / (bounds.width / CGFloat(items.count)))), 0), items.count - 1)
    }

    private func selectIfChanged(_ x: CGFloat) {
        let index = segment(at: x)
        let previous = selectedIndex
        setSelectedIndex(index)
        if selectedIndex != previous {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            onChange?(selectedIndex)
        }
    }

    override func accessibilityPerformIncrement() -> Bool {
        guard selectedIndex < items.count - 1 else { return false }
        setSelectedIndex(selectedIndex + 1, animated: true)
        onChange?(selectedIndex)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        guard selectedIndex > 0 else { return false }
        setSelectedIndex(selectedIndex - 1, animated: true)
        onChange?(selectedIndex)
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for textLayer in textLayers {
            textLayer.contentsScale = scale
        }
    }
}

// MARK: - Progress bar

/// A thin, animated completion bar used by the task panel header.  Two quiet
/// shapes — a faint track and an accent fill — make completed-fraction readable
/// at a glance without a ring or a number, and the fill glides rather than
/// jumps when the count changes (§8.5).
@MainActor
final class PanelProgressBar: NSView {
    var styleSheet: StyleSheet { didSet { applyStyle() } }
    var fraction: CGFloat = 0 {
        didSet {
            let clamped = min(max(fraction, 0), 1)
            guard clamped != oldValue else { return }
            fraction = clamped
            placeFill(animated: window != nil)
        }
    }

    private let trackLayer = CALayer()
    private let fillLayer = CALayer()

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 4)
    }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.cornerRadius = bounds.height / 2
        fillLayer.cornerRadius = bounds.height / 2
        placeFill(animated: false)
        CATransaction.commit()
    }

    private func placeFill(animated: Bool) {
        let width = bounds.width * fraction
        let target = NSRect(x: 0, y: 0, width: max(0, width), height: bounds.height)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduce, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.frame = target
            CATransaction.commit()
            return
        }
        // Implicit animation of bounds/position gives a single smooth glide.
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.deliberate)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1))
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        fillLayer.frame = target
        CATransaction.commit()
    }

    private func applyStyle() {
        let contrast = styleSheet.increaseContrast
        trackLayer.backgroundColor = styleSheet.text
            .panelAlpha(0.08, increaseContrast: contrast).cgColor
        fillLayer.backgroundColor = styleSheet.accent.cgColor
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

// MARK: - Row selection

/// Row selection drawn in the panel's own language instead of the system
/// accent.  AppKit's default highlight is cobalt; against a warm themed panel
/// it reads as "the system made this", which is exactly what the panels refuse
/// to feel.  A short, rounded, faint fill replaces it (§11.4).
final class PanelSelectionRowView: NSTableRowView {
    var styleSheet: StyleSheet = .current {
        didSet { needsDisplay = true }
    }

    override func drawBackground(in dirtyRect: NSRect) {
        // Transparent: the panel backdrop shows through the table.
    }

    override func drawSelection(in dirtyRect: NSRect) {
        let contrast = styleSheet.increaseContrast
        styleSheet.selection.panelAlpha(contrast ? 0.30 : 0.18, increaseContrast: contrast).setFill()
        NSBezierPath(
            roundedRect: bounds.insetBy(dx: 3, dy: 1),
            xRadius: 6, yRadius: 6
        ).fill()
    }
}

// MARK: - Small helpers

extension NSView {
    func pinEdges(to other: NSView, inset: CGFloat = 0) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: other.leadingAnchor, constant: inset),
            trailingAnchor.constraint(equalTo: other.trailingAnchor, constant: -inset),
            topAnchor.constraint(equalTo: other.topAnchor, constant: inset),
            bottomAnchor.constraint(equalTo: other.bottomAnchor, constant: -inset),
        ])
    }
}

extension NSColor {
    /// Alpha that steps up under Increase Contrast, so every faint fill in the
    /// panels strengthens together rather than one at a time (§11.4).
}
