import AppKit
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
    static let barHeight: CGFloat = 36
    static let rowHeight: CGFloat = 24
    static let groupRowHeight: CGFloat = 22
    static let inset: CGFloat = 10
    static let cornerRadius: CGFloat = 6
    static let hairline: CGFloat = 1
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
    static let row = NSFont.systemFont(ofSize: 12)
    static let rowEmphasised = NSFont.systemFont(ofSize: 12, weight: .semibold)
    static let secondary = NSFont.systemFont(ofSize: 10.5)
    static let header = NSFont.systemFont(ofSize: 11, weight: .semibold)
    static let group = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
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
        effect.isHidden = prefersOpaque
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard prefersOpaque else { return }
        styleSheet.background.setFill()
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
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
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
        button.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
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
    private let actionStack = NSStackView()
    private var actions: [ButtonAction] = []
    private let stripeWidth: CGFloat = 3

    init(styleSheet: StyleSheet, stripeColor: NSColor) {
        self.styleSheet = styleSheet
        self.stripeColor = stripeColor
        super.init(frame: .zero)

        label.font = PanelFont.row
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        actionStack.orientation = .horizontal
        actionStack.spacing = 6
        actionStack.translatesAutoresizingMaskIntoConstraints = false
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

    func applyStyle() {
        label.textColor = styleSheet.text
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        styleSheet.codeBackground.setFill()
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
