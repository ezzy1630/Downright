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
    // MARK: Widths
    //
    // Three tiers, not a number per panel.  A panel picks the shape its rows
    // need — a name, a name plus a detail line, or a working surface — and the
    // set of panel widths in the app stays three wide instead of eight.

    /// One line per row: outline, siblings, workspace, reader profiles.
    static let listWidth: CGFloat = 300
    /// A title plus a detail line, and usually a row action: tasks, lens,
    /// health, render targets, assets, reviews, search results, front matter.
    static let detailWidth: CGFloat = 336
    /// A working surface that is not a trailing panel: table editor, palette.
    static let wideWidth: CGFloat = 520

    // MARK: Row heights
    //
    // The same three tiers, for the same reason.

    /// A single line of text.
    static let listRowHeight: CGFloat = 30
    /// A title over a detail line.
    static let detailRowHeight: CGFloat = 46
    /// A title, a detail line, and a third line or an action row.
    static let wideRowHeight: CGFloat = 60
    /// Group headers sit under their own rule: they carry one small caption.
    static let groupRowHeight: CGFloat = 22

    /// Thin enough to replace a scrollbar rather than become a sidebar (§8.6).
    static let gutterWidth: CGFloat = 14
    static let barHeight: CGFloat = 32
    static let reviewBarHeight: CGFloat = 30
    static let inset: CGFloat = 10
    static let headerTopPadding: CGFloat = 8
    static let cornerRadius: CGFloat = 6
    static let hairline: CGFloat = 1

    /// The shape a row's own surface takes — selection, hover, a completion
    /// wash.  One rect, so a row cannot be hovered in one shape and selected in
    /// another (§11.4).
    static func rowSurface(in bounds: NSRect) -> NSRect {
        bounds.insetBy(dx: 3, dy: 1)
    }

    static let rowSurfaceRadius: CGFloat = 6
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
    private static var adjustment: CGFloat { Preferences.shared.values.textSizeAdjustment }
    private static func size(_ base: CGFloat) -> CGFloat { max(11, min(22, base + adjustment)) }
    static func system(_ base: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: size(base), weight: weight)
    }
    static func monospaced(_ base: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: size(base), weight: weight)
    }
    static var row: NSFont { .systemFont(ofSize: size(12.5)) }
    static var rowEmphasised: NSFont { .systemFont(ofSize: size(12.5), weight: .semibold) }
    static var secondary: NSFont { .systemFont(ofSize: size(11.5)) }
    static var header: NSFont { .systemFont(ofSize: size(12), weight: .semibold) }
    static var group: NSFont { .systemFont(ofSize: size(11.5), weight: .semibold) }
    static var title: NSFont { .systemFont(ofSize: size(13), weight: .semibold) }
}

// MARK: - Motion

enum PanelAnimation {
    /// Every animated transition in this directory goes through here, so there
    /// is exactly one place Reduce Motion is honoured (§11.4).
    ///
    /// The default is `Motion.standard`: this used to carry its own 0.18s,
    /// which is a fourth duration pretending to be one of the three.  Pass
    /// `Motion.quick` for pointer feedback that must not be noticed.
    ///
    /// `reduceMotion` should come from `styleSheet.reduceMotion`, not from
    /// `NSWorkspace` — a Reader Profile can force it on and only the style
    /// sheet knows that (§11.4).
    static func run(
        reduceMotion: Bool,
        duration: TimeInterval = Motion.standard,
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
    /// When true, the material blends with the window's own content so the
    /// document ghosts through the chrome — the glassy read the inspector and
    /// other docked panels want (§11.4).  When false the material samples the
    /// desktop instead, which is what a transient popover wants.
    var blendsWithinWindow = false {
        didSet {
            effect.blendingMode = blendsWithinWindow ? .withinWindow : .behindWindow
            applyStyle()
        }
    }
    /// Darkens or lightens the glass on top of the material so a panel stays
    /// legible over whatever is behind it.  0 is the raw material.
    var veilAlpha: CGFloat = 0 {
        didSet {
            veilLayer.opacity = Float(min(max(veilAlpha, 0), 1))
            applyStyle()
        }
    }

    private let effect = NSVisualEffectView()
    /// Drawn between the material and the content: a themed wash that keeps
    /// text readable without flattening the glass into an opaque slab.
    private let veilLayer = CALayer()

    init(
        styleSheet: StyleSheet,
        material: NSVisualEffectView.Material = .sidebar,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        wantsLayer = true
        effect.material = material
        effect.blendingMode = blendingMode
        effect.state = .followsWindowActiveState
        effect.autoresizingMask = [.width, .height]
        effect.frame = bounds
        addSubview(effect)
        veilLayer.actions = [
            "position": NSNull(), "bounds": NSNull(), "opacity": NSNull(),
            "backgroundColor": NSNull(),
        ]
        layer?.addSublayer(veilLayer)
        veilLayer.opacity = Float(min(max(veilAlpha, 0), 1))
        applyStyle()
    }

    override func layout() {
        super.layout()
        veilLayer.frame = bounds
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private var prefersOpaque: Bool {
        styleSheet.reduceTransparency || styleSheet.increaseContrast
    }

    private func applyStyle() {
        effect.isHidden = prefersOpaque || usesSurfaceFill
        // The veil only exists to calm the glass; over an opaque fill there is
        // nothing to ghost, so it would only muddy the colour.
        veilLayer.isHidden = effect.isHidden
        veilLayer.backgroundColor = styleSheet.background.cgColor
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
    /// Handed the clicked row (or -1 for the background); return the menu to
    /// show, or nil to fall back to the view's own.
    var onMenu: ((Int) -> NSMenu?)?

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

    override func menu(for event: NSEvent) -> NSMenu? {
        let row = row(at: convert(event.locationInWindow, from: nil))
        return onMenu?(row)
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

    /// The one row-background every panel list uses.  `PanelSelectionRowView`
    /// exists precisely so a list does not look like a system table dropped on
    /// a themed panel; supplying it from here is what makes that true of every
    /// panel rather than one of them (§11.4).
    static func selectionRow(
        in tableView: NSTableView,
        owner: Any?,
        styleSheet: StyleSheet
    ) -> PanelSelectionRowView {
        let identifier = NSUserInterfaceItemIdentifier("panelSelectionRow")
        let view = tableView.makeView(withIdentifier: identifier, owner: owner) as? PanelSelectionRowView
            ?? PanelSelectionRowView()
        view.identifier = identifier
        view.styleSheet = styleSheet
        return view
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
    private var leading: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        label.font = PanelFont.group
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        let leadingConstraint = label.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: PanelMetrics.inset
        )
        NSLayoutConstraint.activate([
            leadingConstraint,
            label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PanelMetrics.inset),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3),
        ])
        leading = leadingConstraint
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
        button.font = PanelFont.system(12)
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
        button.font = PanelFont.system(12)
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
            invalidateIntrinsicContentSize()
        }
    }

    /// Width that actually fits this bar's message and its actions.  A bar
    /// pinned by a constant width truncates the one sentence it exists to say.
    var fittedWidth: CGFloat {
        let labelWidth = ceil(label.attributedStringValue.size().width)
        let actionsWidth = ceil(actionStack.fittingSize.width)
        return PanelMetrics.inset + stripeWidth + labelWidth + 12 + actionsWidth + 8 + 28 + PanelMetrics.inset
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
        statusLabel.layer?.cornerRadius = PanelMetrics.cornerRadius
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
        label.font = PanelFont.system(12.5, weight: .medium)
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
    private static let minimumSegmentWidth: CGFloat = 46
    private static let labelPadding: CGFloat = 20
    private static var labelFont: NSFont { PanelFont.system(11.5, weight: .semibold) }

    /// The track's radius follows its height, so the same control reads as one
    /// shape whether a header gives it 22pt or 26pt.
    private static func trackRadius(forHeight height: CGFloat) -> CGFloat {
        max(5, min(8, (height / 3).rounded()))
    }

    private let backgroundLayer = CALayer()
    private let thumbLayer = CALayer()
    private var textLayers: [CATextLayer] = []
    private var trackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var hoveredIndex: Int?
    private var isScrubbing = false
    private var thumbIdleColor: NSColor = .clear
    /// Segments a caller has switched off — a section with nothing in it is
    /// still listed, so the set of sections does not change shape under you.
    private var disabledIndices: Set<Int> = []
    /// Natural width per segment, measured from the label rather than assumed,
    /// so a seven-item control does not truncate every tab to fit a constant.
    private let naturalWidths: [CGFloat]

    override var intrinsicContentSize: NSSize {
        NSSize(width: naturalWidths.reduce(0, +), height: Self.controlHeight)
    }

    /// Segment widths for the current bounds: natural widths, scaled together
    /// when the control is stretched or squeezed so the thumb, the labels, and
    /// hit-testing all agree.
    private var laidOutWidths: [CGFloat] {
        let natural = naturalWidths.reduce(0, +)
        guard natural > 0, bounds.width > 0 else { return naturalWidths }
        let scale = bounds.width / natural
        return naturalWidths.map { $0 * scale }
    }

    private func segmentOrigin(_ index: Int) -> CGFloat {
        laidOutWidths.prefix(index).reduce(0, +)
    }

    func setEnabled(_ enabled: Bool, forSegment index: Int) {
        guard items.indices.contains(index) else { return }
        if enabled { disabledIndices.remove(index) } else { disabledIndices.insert(index) }
        applySelectionColors()
    }

    func isEnabled(segment index: Int) -> Bool { !disabledIndices.contains(index) }

    init(items: [String], selectedIndex: Int = 0, styleSheet: StyleSheet) {
        self.items = items
        self.selectedIndex = min(max(selectedIndex, 0), max(0, items.count - 1))
        self.styleSheet = styleSheet
        self.naturalWidths = items.map { item in
            let width = (item as NSString).size(withAttributes: [.font: Self.labelFont]).width
            return max(Self.minimumSegmentWidth, ceil(width) + Self.labelPadding)
        }
        super.init(frame: .zero)
        wantsLayer = true

        backgroundLayer.cornerRadius = Self.trackRadius(forHeight: Self.controlHeight)
        layer?.addSublayer(backgroundLayer)

        thumbLayer.cornerRadius = Self.trackRadius(forHeight: Self.controlHeight) - 2
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
        let widths = laidOutWidths
        backgroundLayer.frame = bounds
        backgroundLayer.cornerRadius = Self.trackRadius(forHeight: bounds.height)
        thumbLayer.frame = thumbFrame()
        thumbLayer.cornerRadius = Self.trackRadius(forHeight: bounds.height) - 2
        // A `CATextLayer` draws its first line from the *top* of its bounds, so
        // a layer sized to the control sits the label high inside the track —
        // which is what made every filter in the app look a point or two off
        // its thumb.  Give the layer exactly one line and centre that.
        let lineHeight = ceil(Self.labelFont.ascender - Self.labelFont.descender)
        var x: CGFloat = 0
        for (index, textLayer) in textLayers.enumerated() {
            let width = widths.element(at: index) ?? 0
            textLayer.frame = NSRect(
                x: x,
                y: ((bounds.height - lineHeight) / 2).rounded(),
                width: width,
                height: lineHeight
            )
            x += width
        }
        CATransaction.commit()
    }

    private func thumbFrame() -> NSRect {
        let widths = laidOutWidths
        return NSRect(
            x: segmentOrigin(selectedIndex) + 1,
            y: 1,
            width: max(0, (widths.element(at: selectedIndex) ?? 0) - 2),
            height: bounds.height - 2
        )
    }

    private func updateThumb(animated: Bool) {
        let target = thumbFrame()
        guard animated, !styleSheet.reduceMotion, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            thumbLayer.frame = target
            CATransaction.commit()
            return
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.standard)
        CATransaction.setAnimationTimingFunction(Motion.timing(.decelerate))
        thumbLayer.frame = target
        CATransaction.commit()
    }

    private func applySelectionColors() {
        for (index, textLayer) in textLayers.enumerated() {
            let selected = index == selectedIndex
            textLayer.font = (selected
                ? Self.labelFont
                : PanelFont.system(11.5, weight: .medium)) as CTFont
            textLayer.fontSize = Self.labelFont.pointSize
            let alpha: CGFloat = disabledIndices.contains(index)
                ? (styleSheet.increaseContrast ? 0.45 : 0.30)
                : (selected ? 1 : dimmedAlpha(for: index))
            textLayer.foregroundColor = color(forSegment: index, selected: selected)
                .withAlphaComponent(alpha).cgColor
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
        guard !styleSheet.reduceMotion, window != nil else {
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
            settle.timingFunctions = [Motion.timing(.decelerate), Motion.timing(.easeOut)]
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
        refreshTrackingArea(
            &trackingArea,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited]
        )
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
        var offset: CGFloat = 0
        for (index, width) in laidOutWidths.enumerated() {
            offset += width
            if x < offset { return index }
        }
        return max(0, items.count - 1)
    }

    private func selectIfChanged(_ x: CGFloat) {
        let index = segment(at: x)
        guard !disabledIndices.contains(index) else { return }
        let previous = selectedIndex
        setSelectedIndex(index)
        if selectedIndex != previous {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            onChange?(selectedIndex)
        }
    }

    private func step(_ delta: Int) -> Bool {
        var candidate = selectedIndex + delta
        while items.indices.contains(candidate), disabledIndices.contains(candidate) {
            candidate += delta
        }
        guard items.indices.contains(candidate) else { return false }
        setSelectedIndex(candidate, animated: true)
        onChange?(selectedIndex)
        return true
    }

    override func accessibilityPerformIncrement() -> Bool { step(1) }

    override func accessibilityPerformDecrement() -> Bool { step(-1) }

    // MARK: - Keyboard

    /// A filter you can see but not reach with the keyboard is not a control —
    /// but a filter that wears a focus ring the moment it is clicked is not one
    /// either, so the ring follows Full Keyboard Access like AppKit's own.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        let radius = Self.trackRadius(forHeight: bounds.height)
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func keyDown(with event: NSEvent) {
        switch KeyBinding.key(for: event) {
        case "left", "up":
            if step(-1) { return }
        case "right", "down", "space":
            if step(1) { return }
        default:
            break
        }
        super.keyDown(with: event)
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
        // A fill narrower than its own corner radius draws as a smear, so the
        // bar keeps a minimum stub as soon as anything is done and shows
        // nothing at all at zero.  The stub is a full round cap, not a square
        // sliver, which is why it is the bar's height rather than half of it.
        let width = bounds.width * fraction
        let minimum = fraction > 0 ? bounds.height : 0
        let target = NSRect(x: 0, y: 0, width: max(minimum, width), height: bounds.height)
        // A 0-wide layer with a capsule corner radius still rasterises its two
        // semicircles as an hourglass sliver — nothing done must draw nothing.
        fillLayer.isHidden = target.width == 0
        guard animated, !styleSheet.reduceMotion, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            fillLayer.frame = target
            CATransaction.commit()
            return
        }
        // Implicit animation of bounds/position gives a single smooth glide.
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.deliberate)
        CATransaction.setAnimationTimingFunction(Motion.timing(.decelerate))
        fillLayer.frame = target
        CATransaction.commit()
    }

    private func applyStyle() {
        let contrast = styleSheet.increaseContrast
        // The unfinished part of a plan is information too.  At 0.08 the track
        // vanished, so the bar read as a line that stopped in mid-air rather
        // than as a fraction of a whole.
        trackLayer.backgroundColor = styleSheet.text
            .panelAlpha(0.13, increaseContrast: contrast).cgColor
        fillLayer.backgroundColor = styleSheet.accent.cgColor
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

// MARK: - Checkbox

/// The one checkbox in the app.
///
/// It is drawn, not templated, and it is drawn from the *document's* geometry:
/// `ListOrnamentFragment` paints the same task inside the page, so every
/// measurement here is that box's measurement expressed as a fraction of the
/// side.  A panel checkbox is therefore the document checkbox at a smaller
/// size, never a second checkbox that happens to look similar (§8.5).
///
/// A stock `.switch` button cannot pop its fill or stroke its check, and that
/// half-second is the whole reason ticking a task feels like completing one.
/// `.mixed` draws a dash, for a group that is partly done.
@MainActor
final class PanelCheckbox: NSView {
    enum CheckState: Equatable { case off, on, mixed }

    /// The document's 20pt box, as ratios.  Changing the size changes nothing
    /// about the drawing except its scale, which is what keeps the two
    /// checkboxes one control.
    enum Geometry {
        /// Panel type is 12.5pt against the document's 16pt, so the panel box
        /// is the document box at the same optical weight, not the same points.
        static let panelSide: CGFloat = 16
        /// The pointer target around the drawn box.  A 16pt square is a
        /// precision task at the end of a mouse; the document gives the same
        /// control 28pt and the panel row is only 30pt tall, so the box claims
        /// the air either side of itself instead of growing.
        static let hitInset: CGFloat = 6

        static let cornerRatio = RenderMetrics.taskBoxCornerRatio
        static let openStrokeRatio = RenderMetrics.taskBoxStrokeRatio
        static let checkStrokeRatio = RenderMetrics.taskTickStrokeRatio

        /// The document's tick, scaled — see `RenderMetrics.taskTick`.
        static let tick = RenderMetrics.taskTick
        /// The dash for `.mixed`, on the same unit grid.
        static let dashInset: CGFloat = 0.28
    }

    var onToggle: (() -> Void)?
    /// Lets the owning row compress with the checkbox so the press reads as
    /// one physical surface rather than a stamp on top of a still row.
    var onPressChange: ((Bool) -> Void)?

    private var styleSheet: StyleSheet = .current
    private let borderLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let checkLayer = CAShapeLayer()
    private let rippleLayer = CAShapeLayer()
    private let dashLayer = CAShapeLayer()
    private(set) var state: CheckState = .off
    private var isFilled: Bool { state != .off }
    private var isHovering = false
    private var isPressed = false
    private let side: CGFloat

    override var intrinsicContentSize: NSSize { NSSize(width: side, height: side) }

    init(side: CGFloat = Geometry.panelSide) {
        self.side = side
        super.init(frame: NSRect(x: 0, y: 0, width: side, height: side))
        wantsLayer = true
        for layer in [fillLayer, borderLayer, rippleLayer, checkLayer, dashLayer] {
            layer.fillColor = NSColor.clear.cgColor
            layer.actions = ["position": NSNull(), "bounds": NSNull()]
            self.layer?.addSublayer(layer)
        }
        rippleLayer.opacity = 0
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue("Unchecked")
    }

    // MARK: - Pointer target

    /// The rect the pointer may press, which is larger than the box it draws.
    var hitBounds: NSRect {
        bounds.insetBy(dx: -Geometry.hitInset, dy: -Geometry.hitInset)
    }

    /// A view whose frame is the drawn box can still claim the slack around it:
    /// the superview hands every subview the point and lets each decide.  The
    /// gap to the label is wider than the inset, so nothing is stolen from it.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        return hitBounds.contains(convert(point, from: superview)) ? self : nil
    }

    // MARK: - Keyboard

    /// Tab reaches the checkbox and Space ticks it.  Without this the row's
    /// "one toggle path for pointer, keyboard, and VoiceOver" was two paths.
    ///
    /// Gated on Full Keyboard Access for the same reason every AppKit control
    /// is: a view that accepts first responder becomes it on the click that
    /// presses it, and then wears a focus ring nobody asked for.  Ticking a
    /// task must not look like focusing a text field (§11.4).
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var focusRingMaskBounds: NSRect { bounds.insetBy(dx: -2.5, dy: -2.5) }

    override func drawFocusRingMask() {
        // The ring traces the box's own shape one step out, so focus reads as
        // "this checkbox" rather than as a rectangle near it.
        let rect = bounds.insetBy(dx: -2.5, dy: -2.5)
        let radius = side * Geometry.cornerRatio + 2.5
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
    }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard KeyBinding.key(for: event) == "space" else {
            super.keyDown(with: event)
            return
        }
        performToggle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setStyleSheet(_ styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        applyVisual(animated: false)
    }

    func setChecked(_ checked: Bool, animated: Bool) {
        setState(checked ? .on : .off, animated: animated)
    }

    func setState(_ newState: CheckState, animated: Bool) {
        guard newState != state else { return }
        state = newState
        applyVisual(animated: animated)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let side = min(bounds.width, bounds.height)
        // Half the open stroke, so a 1.4pt border sits fully inside the box
        // instead of straddling its edge and reading a hair too large.
        let inset = side * Geometry.openStrokeRatio / 2
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let radius = side * Geometry.cornerRatio
        let box = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

        for layer in [fillLayer, borderLayer, checkLayer, dashLayer, rippleLayer] {
            layer.frame = bounds
        }
        borderLayer.path = box
        fillLayer.path = box
        fillLayer.cornerRadius = radius

        checkLayer.path = Self.tickPath(side: side)
        checkLayer.lineWidth = side * Geometry.checkStrokeRatio
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        checkLayer.strokeStart = 0
        checkLayer.strokeEnd = state == .on ? 1 : 0

        dashLayer.path = Self.dashPath(side: side)
        dashLayer.lineWidth = side * Geometry.checkStrokeRatio
        dashLayer.lineCap = .round

        rippleLayer.path = box
        rippleLayer.lineWidth = max(1, side * Geometry.checkStrokeRatio * 0.9)
        rippleLayer.strokeColor = styleSheet.accent.cgColor
        CATransaction.commit()
    }

    private static func dashPath(side: CGFloat) -> CGPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: side * Geometry.dashInset, y: side / 2))
        path.line(to: NSPoint(x: side * (1 - Geometry.dashInset), y: side / 2))
        return path.cgPath
    }

    /// The renderer's tick, scaled.  Layer geometry is y-up, and the unit
    /// points are already measured from the bottom, so no flip is needed here.
    private static func tickPath(side: CGFloat) -> CGPath {
        let path = NSBezierPath()
        for (index, point) in Geometry.tick.enumerated() {
            let scaled = NSPoint(x: point.x * side, y: point.y * side)
            if index == 0 { path.move(to: scaled) } else { path.line(to: scaled) }
        }
        return path.cgPath
    }

    // MARK: - Visual state

    /// The box's outline: the document ornament's own ring colour at rest, warmed
    /// toward the accent while the pointer is on an open box so the row answers
    /// the hover somewhere other than its lift.
    private var ringColor: NSColor {
        guard !(isHovering && !isFilled) else {
            let contrast = styleSheet.increaseContrast
            return styleSheet.accent.panelAlpha(contrast ? 1 : 0.85, increaseContrast: false)
        }
        return styleSheet.taskRingColor(checked: isFilled)
    }

    private func applyVisual(animated: Bool) {
        let side = min(bounds.width, bounds.height)
        // §8.5: this is the document's checkbox at panel scale, so its paint
        // comes from the same place its geometry does.  It used to draw a solid
        // accent slab with a knocked-out tick; when the document's ornament was
        // restyled to a tinted field, a ring and an accent tick, the two states
        // of one control stopped looking like each other.
        let targetBorder = ringColor
        // Hover on an open box warms the border and lays down the faintest
        // wash.  A filled box carries its own field, so hover shows there as the
        // lift both states share (see `updateTransform`).
        let targetFillAlpha: Float = isFilled ? 1 : (isHovering ? 0.09 : 0)
        let checkEnd: CGFloat = state == .on ? 1 : 0

        // Set outside a transaction, each of these would collect Core
        // Animation's default quarter-second implicit fade — a duration the
        // motion system does not have.  The tick's colours never animate; only
        // its stroke and the fill beneath it do, explicitly, below.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dashLayer.strokeColor = styleSheet.taskTickColor.cgColor
        checkLayer.strokeColor = styleSheet.taskTickColor.cgColor
        fillLayer.backgroundColor = styleSheet.taskFieldColor.cgColor
        CATransaction.commit()

        guard animated, !styleSheet.reduceMotion, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for layer in [fillLayer, checkLayer, borderLayer, dashLayer] { layer.removeAllAnimations() }
            borderLayer.strokeColor = targetBorder.cgColor
            borderLayer.lineWidth = side * Geometry.openStrokeRatio
            fillLayer.opacity = targetFillAlpha
            fillLayer.transform = CATransform3DIdentity
            checkLayer.strokeEnd = checkEnd
            checkLayer.opacity = Float(checkEnd)
            dashLayer.opacity = state == .mixed ? 1 : 0
            CATransaction.commit()
            return
        }

        // The dash follows the fill it sits on rather than appearing on top of
        // a box that is still growing.
        let dashFade = CABasicAnimation(keyPath: "opacity")
        dashFade.fromValue = dashLayer.presentation()?.opacity ?? dashLayer.opacity
        dashFade.toValue = state == .mixed ? 1 : 0
        dashFade.duration = Motion.quick
        dashLayer.removeAllAnimations()
        dashLayer.add(dashFade, forKey: "dash-fade")
        dashLayer.opacity = state == .mixed ? 1 : 0

        let border = CABasicAnimation(keyPath: "strokeColor")
        border.fromValue = borderLayer.presentation()?.strokeColor ?? borderLayer.strokeColor
        border.toValue = targetBorder.cgColor
        border.duration = Motion.quick
        border.timingFunction = Motion.timing(.easeOut)
        borderLayer.strokeColor = targetBorder.cgColor
        borderLayer.lineWidth = side * Geometry.openStrokeRatio
        borderLayer.add(border, forKey: "border")

        if isFilled {
            // The fill lands with one short overshoot and the tick draws over
            // it, so the whole confirmation is over inside `standard` — long
            // enough to see, short enough that ticking six tasks in a row does
            // not queue up six animations.
            let pop = Motion.pop(from: 0.7, overshoot: 1.07, duration: Motion.standard)
            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = Motion.quick

            fillLayer.removeAllAnimations()
            fillLayer.add(pop, forKey: "fill-pop")
            fillLayer.add(fadeIn, forKey: "fill-fade")
            fillLayer.opacity = 1

            checkLayer.removeAllAnimations()
            if state == .on {
                let draw = CABasicAnimation(keyPath: "strokeEnd")
                draw.fromValue = 0
                draw.toValue = 1
                draw.duration = Motion.standard
                draw.timingFunction = Motion.timing(.easeOut)
                checkLayer.add(draw, forKey: "check-draw")
            }
            checkLayer.strokeEnd = checkEnd
            checkLayer.opacity = Float(checkEnd)
        } else {
            // The tick withdraws the way it arrived, then the fill lets go.
            let retract = CABasicAnimation(keyPath: "strokeEnd")
            retract.fromValue = checkLayer.presentation()?.strokeEnd ?? 1
            retract.toValue = 0
            retract.duration = Motion.quick
            retract.timingFunction = Motion.timing(.easeOut)
            checkLayer.removeAllAnimations()
            checkLayer.add(retract, forKey: "check-retract")
            checkLayer.strokeEnd = 0
            checkLayer.opacity = 0

            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = fillLayer.presentation()?.opacity ?? fillLayer.opacity
            fade.toValue = targetFillAlpha
            fade.duration = Motion.quick
            fillLayer.removeAllAnimations()
            fillLayer.add(fade, forKey: "fill-fade-out")
            fillLayer.opacity = targetFillAlpha
        }
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateTransform(animated: true)
        onPressChange?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = hitBounds.contains(convert(event.locationInWindow, from: nil))
        guard inside != isPressed else { return }
        isPressed = inside
        updateTransform(animated: true)
        onPressChange?(isPressed)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = hitBounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updateTransform(animated: true)
        onPressChange?(false)
        if inside {
            performToggle()
        }
    }

    /// One toggle path for pointer, keyboard, and VoiceOver so the feedback —
    /// haptic, ripple, and the drawn check — is identical however it was fired.
    func performToggle() {
        state = state == .on ? .off : .on
        applyVisual(animated: true)
        setAccessibilityValue(state == .on ? "Checked" : (state == .mixed ? "Mixed" : "Unchecked"))
        if isFilled {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            pulseRipple()
        }
        onToggle?()
    }

    /// A soft ring that expands from the box and fades, so a completed task is
    /// answered in place — the same pulse the document renderer draws around a
    /// checkbox the moment it is ticked (§7.1).
    private func pulseRipple() {
        guard window != nil, !styleSheet.reduceMotion else {
            rippleLayer.opacity = 0
            return
        }
        rippleLayer.removeAllAnimations()
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.85
        scale.toValue = 1.6
        scale.duration = Motion.deliberate
        scale.timingFunction = Motion.timing(.decelerate)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.5
        fade.toValue = 0
        fade.duration = Motion.deliberate
        fade.timingFunction = Motion.timing(.easeOut)

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = Motion.deliberate
        rippleLayer.add(group, forKey: "ripple")
        rippleLayer.opacity = 0
    }

    /// Hover lifts the box, a press pushes it back past its resting size.  The
    /// press is shallow — the box is 16pt, so anything deeper reads as the
    /// checkbox jumping rather than yielding — and both live on one transform
    /// so a press during hover cannot fight the lift.
    private func updateTransform(animated: Bool) {
        let scale: CGFloat = isPressed ? 0.9 : (isHovering ? 1.06 : 1)
        let target = CATransform3DMakeScale(scale, scale, 1)
        guard animated, !styleSheet.reduceMotion else {
            layer?.removeAnimation(forKey: "press")
            layer?.transform = target
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer?.presentation()?.transform ?? layer?.transform
        animation.toValue = target
        animation.duration = isPressed
            ? ToolbarChromePolicy.pressInDuration
            : ToolbarChromePolicy.pressOutDuration
        animation.timingFunction = ToolbarChromePolicy.timingFunction()
        layer?.add(animation, forKey: "press")
        layer?.transform = target
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        // Hover must light the box over the whole area that presses it, or the
        // pointer sits on a live target that looks dead.
        addTrackingArea(NSTrackingArea(
            rect: hitBounds,
            options: [.activeInKeyWindow, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isHovering else { return }
        isHovering = true
        applyVisual(animated: true)
        updateTransform(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovering else { return }
        isHovering = false
        applyVisual(animated: true)
        updateTransform(animated: true)
    }

    override func accessibilityPerformPress() -> Bool {
        performToggle()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyVisual(animated: false)
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

    /// Near full strength, because the token is already a *selection* colour —
    /// the same warm sand the document selects text with.  At the 0.18 this
    /// used to draw, the selected row differed from its neighbours by three
    /// levels per channel: a selection nobody could see.
    override func drawSelection(in dirtyRect: NSRect) {
        let contrast = styleSheet.increaseContrast
        styleSheet.selection.panelAlpha(contrast ? 1 : 0.85, increaseContrast: false).setFill()
        NSBezierPath(
            roundedRect: PanelMetrics.rowSurface(in: bounds),
            xRadius: PanelMetrics.rowSurfaceRadius,
            yRadius: PanelMetrics.rowSurfaceRadius
        ).fill()
    }
}

// MARK: - Empty state

/// A two-line empty state with a tinted symbol disc, used wherever a panel has
/// nothing to list.  An empty list is a *state* of the document — "every image
/// resolves", "no headings yet" — and saying so is the difference between a
/// finished panel and a blank rectangle (§11.4).
@MainActor
final class PanelEmptyStateView: NSView {
    private let discLayer = CALayer()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")

    var title: String { titleLabel.stringValue }
    var subtitle: String { subtitleLabel.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .clear
        addSubview(symbolView)

        discLayer.opacity = 0
        layer?.addSublayer(discLayer)

        titleLabel.font = PanelFont.system(12.5, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = PanelFont.secondary
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            symbolView.topAnchor.constraint(equalTo: topAnchor),
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 40),
            symbolView.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.topAnchor.constraint(equalTo: symbolView.bottomAnchor, constant: 10),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    convenience init() { self.init(frame: .zero) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        discLayer.frame = symbolView.frame.insetBy(dx: -2, dy: -2)
        discLayer.cornerRadius = discLayer.bounds.width / 2
        CATransaction.commit()
    }

    func configure(symbol: String, title: String, subtitle: String, styleSheet: StyleSheet) {
        let contrast = styleSheet.increaseContrast
        discLayer.backgroundColor = styleSheet.accent
            .panelAlpha(0.12, increaseContrast: contrast).cgColor
        discLayer.opacity = 1

        symbolView.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        symbolView.contentTintColor = styleSheet.accent

        titleLabel.stringValue = title
        titleLabel.textColor = styleSheet.text
        subtitleLabel.stringValue = subtitle
        subtitleLabel.textColor = styleSheet.textFaint
        setAccessibilityRole(.group)
        setAccessibilityLabel(subtitle.isEmpty ? title : "\(title): \(subtitle)")
    }

    /// Centre the state over `list` and hide it.  Every panel installs it the
    /// same way, so "nothing to show" lands in the same place in each one.
    func install(in panel: NSView, over list: NSView) {
        translatesAutoresizingMaskIntoConstraints = false
        isHidden = true
        panel.addSubview(self)
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: PanelMetrics.inset),
            trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -PanelMetrics.inset),
            centerYAnchor.constraint(equalTo: list.centerYAnchor),
        ])
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

// MARK: - Source positions

/// Turns a UTF-16 source offset into a line number.
///
/// "Source range 1234–1250" is a fact about a byte buffer; a reader locates a
/// finding by line.  Built once per reload and reused for every row, so a long
/// list does not rescan the document per row.
struct SourceLineIndex {
    /// Offset of the first character of each line, line 1 first.
    private let starts: [Int]

    init(text: String) {
        var starts: [Int] = [0]
        let string = text as NSString
        string.enumerateSubstrings(in: NSRange(location: 0, length: string.length),
                                   options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            let next = enclosing.location + enclosing.length
            if next < string.length { starts.append(next) }
        }
        self.starts = starts
    }

    /// 1-based line containing `offset`.
    func line(at offset: Int) -> Int {
        guard offset > 0 else { return 1 }
        var low = 0
        var high = starts.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if starts[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low + 1
    }

    /// "Line 42" or "Lines 42–44" — what a reader can act on.
    func caption(for range: NSRange) -> String {
        let first = line(at: range.location)
        let last = line(at: max(range.location, range.upperBound - 1))
        return first == last ? "Line \(first)" : "Lines \(first)–\(last)"
    }
}

// MARK: - Names

extension Command {
    /// A command title reads as an invocation — "Find in Sibling Files…".  A
    /// panel header names the surface that opened, so it drops the ellipsis and
    /// otherwise stays byte-identical to the menu item that summoned it (§7.2).
    var panelTitle: String {
        title.hasSuffix("…") ? String(title.dropLast()) : title
    }
}

// MARK: - Small helpers

extension Array {
    /// Bounds-checked subscript.  Panels index into parallel arrays a lot and a
    /// crash is a worse answer than "no such segment".
    func element(at index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension NSView {
    /// The inspector this panel was installed into, if it is in one.  Lets a
    /// panel's own Done button perform the same close as the host header's
    /// xmark without the panel having to know its controller.
    var enclosingInspectorHost: InspectorHostView? {
        var candidate = superview
        while let view = candidate {
            if let host = view as? InspectorHostView { return host }
            candidate = view.superview
        }
        return nil
    }

    /// Installs a panel's backdrop as its bottom-most subview, sized to follow
    /// the panel.  Autoresizing rather than constraints: the backdrop predates
    /// every other subview and must never participate in their layout pass.
    func installBackdrop(_ backdrop: PanelBackdrop) {
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)
    }

    /// Swaps `area` for a fresh one covering the current bounds.  `bounds` moves
    /// on every resize and a stale area keeps reporting the old rect, so every
    /// hovering view rebuilds one the same way — once, here.
    func refreshTrackingArea(
        _ area: inout NSTrackingArea?,
        options: NSTrackingArea.Options
    ) {
        if let area { removeTrackingArea(area) }
        let replacement = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(replacement)
        area = replacement
    }
}
