import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol BreadcrumbDelegate: AnyObject {
    func breadcrumb(_ view: BreadcrumbView, didSelectHeadingAt index: Int)
}

/// Sticky heading breadcrumb (§5.1).
///
/// "On a long agent document this is the difference between knowing where you
/// are and not."  It pins to the top of the viewport with a vibrant background
/// so the document scrolls *under* it legibly rather than colliding with it.
///
/// When the chain does not fit, the middle goes and the last element never
/// does — the crumb you need is the one you are inside.  What was elided is
/// still reachable: the ellipsis opens a menu of the hidden ancestors.
final class BreadcrumbView: NSView {
    weak var delegate: BreadcrumbDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            rebuild()
        }
    }

    /// Ancestor chain, root first.  Indices are into the document's headings.
    var trail: [(index: Int, title: String, level: Int)] = [] {
        didSet {
            invalidateIntrinsicContentSize()
            rebuild()
        }
    }

    private let backdrop: PanelBackdrop
    private var crumbButtons: [NSButton] = []
    private var crumbActions: [ButtonAction] = []
    private let ellipsisButton = NSButton()
    private var ellipsisAction: ButtonAction?
    /// Crumbs hidden by the middle truncation, for the ellipsis menu.
    private var elidedCrumbs: [(index: Int, title: String, level: Int)] = []
    /// Separator positions, in view coordinates, filled by `layout()`.
    private var separatorOrigins: [CGFloat] = []

    private let separator = " › "
    private let crumbPadding: CGFloat = 4

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        // Within-window blending is the point: the blur has to be of the
        // document underneath, not of the desktop behind the app.
        self.backdrop = PanelBackdrop(styleSheet: styleSheet, material: .hudWindow, blendingMode: .withinWindow)
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.masksToBounds = true

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        let action = ButtonAction { [weak self] in self?.showElidedMenu() }
        ellipsisAction = action
        ellipsisButton.isBordered = false
        ellipsisButton.target = action
        ellipsisButton.action = #selector(ButtonAction.fire(_:))
        ellipsisButton.setAccessibilityLabel("Show hidden ancestors")
        ellipsisButton.isHidden = true
        addSubview(ellipsisButton)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Heading breadcrumb")

    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 360, height: trail.isEmpty ? 0 : 28)
    }

    // MARK: - Building

    private func rebuild() {
        for button in crumbButtons { button.removeFromSuperview() }
        crumbButtons.removeAll()
        crumbActions.removeAll()

        for crumb in trail {
            let action = ButtonAction { [weak self] in
                guard let self else { return }
                self.delegate?.breadcrumb(self, didSelectHeadingAt: crumb.index)
            }
            crumbActions.append(action)

            let button = NSButton(title: crumb.title, target: action, action: #selector(ButtonAction.fire(_:)))
            button.isBordered = false
            button.bezelStyle = .accessoryBarAction
            button.setAccessibilityLabel(crumb.title)
            button.setAccessibilityRole(.button)
            (button.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
            crumbButtons.append(button)
            addSubview(button)
        }

        ellipsisButton.attributedTitle = styledTitle("…", isLast: false)
        setAccessibilityLabel("Heading breadcrumb: " + trail.map(\.title).joined(separator: " › "))
        needsLayout = true
        needsDisplay = true
    }

    private func styledTitle(_ text: String, isLast: Bool) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: isLast ? PanelFont.rowEmphasised : PanelFont.row,
            .foregroundColor: isLast ? styleSheet.text : styleSheet.textSecondary,
        ])
    }

    private func width(of text: String, isLast: Bool) -> CGFloat {
        styledTitle(text, isLast: isLast).size().width + crumbPadding * 2
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        separatorOrigins.removeAll(keepingCapacity: true)
        elidedCrumbs.removeAll(keepingCapacity: true)
        ellipsisButton.isHidden = true
        for button in crumbButtons { button.isHidden = true }
        guard !trail.isEmpty else { return }

        let available = bounds.width - PanelMetrics.inset * 2
        let separatorWidth = (separator as NSString)
            .size(withAttributes: [.font: PanelFont.row]).width
        let ellipsisWidth = width(of: "…", isLast: false)

        var widths: [CGFloat] = []
        for (offset, crumb) in trail.enumerated() {
            widths.append(width(of: crumb.title, isLast: offset == trail.count - 1))
        }

        let full = widths.reduce(0, +) + separatorWidth * CGFloat(max(0, trail.count - 1))
        var visible: [Int]
        var ellipsisAfter: Int?

        if full <= available {
            visible = Array(trail.indices)
        } else {
            // Keep the root for orientation and the tail for specificity; the
            // middle is what goes.
            var tail: [Int] = [trail.count - 1]
            var used = widths[trail.count - 1] + ellipsisWidth + separatorWidth * 2
            let keepsRoot = trail.count > 1 && used + widths[0] <= available
            if keepsRoot { used += widths[0] }

            var candidate = trail.count - 2
            while candidate > 0, used + widths[candidate] + separatorWidth <= available {
                tail.insert(candidate, at: 0)
                used += widths[candidate] + separatorWidth
                candidate -= 1
            }

            visible = (keepsRoot ? [0] : []) + tail
            ellipsisAfter = keepsRoot ? 0 : nil
            elidedCrumbs = trail.indices
                .filter { !visible.contains($0) }
                .map { trail[$0] }
            if !elidedCrumbs.isEmpty && !keepsRoot { ellipsisAfter = -1 }
        }

        var x = PanelMetrics.inset
        let height: CGFloat = 18
        let y = (bounds.height - height) / 2

        if ellipsisAfter == -1 {
            ellipsisButton.isHidden = false
            ellipsisButton.frame = NSRect(x: x, y: y, width: ellipsisWidth, height: height)
            x += ellipsisWidth
            separatorOrigins.append(x)
            x += separatorWidth
        }

        for (position, index) in visible.enumerated() {
            let isLast = index == trail.count - 1
            let button = crumbButtons[index]
            button.attributedTitle = styledTitle(trail[index].title, isLast: isLast)
            button.isHidden = false
            // The last crumb never disappears; if it has to, it truncates.
            let remaining = bounds.width - PanelMetrics.inset - x
            button.frame = NSRect(x: x, y: y, width: min(widths[index], max(24, remaining)), height: height)
            x += button.frame.width

            if position < visible.count - 1 {
                separatorOrigins.append(x)
                x += separatorWidth
            }
            if ellipsisAfter == index, !elidedCrumbs.isEmpty {
                ellipsisButton.isHidden = false
                ellipsisButton.frame = NSRect(x: x, y: y, width: ellipsisWidth, height: height)
                x += ellipsisWidth
                separatorOrigins.append(x)
                x += separatorWidth
            }
        }

        discardCursorRects()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func resetCursorRects() {
        for button in crumbButtons where !button.isHidden {
            addCursorRect(button.frame, cursor: .pointingHand)
        }
        if !ellipsisButton.isHidden {
            addCursorRect(ellipsisButton.frame, cursor: .pointingHand)
        }
    }

    private func showElidedMenu() {
        guard !elidedCrumbs.isEmpty else { return }
        let menu = NSMenu()
        for crumb in elidedCrumbs {
            let item = NSMenuItem(
                title: String(repeating: "  ", count: max(0, crumb.level - 1)) + crumb.title,
                action: #selector(selectElided(_:)), keyEquivalent: ""
            )
            item.target = self
            item.representedObject = crumb.index
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: ellipsisButton.frame.minX, y: 0), in: self)
    }

    @objc private func selectElided(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        delegate?.breadcrumb(self, didSelectHeadingAt: index)
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PanelFont.row,
            .foregroundColor: styleSheet.textFaint,
        ]
        let size = (separator as NSString).size(withAttributes: attributes)
        let y = (bounds.height - size.height) / 2
        for origin in separatorOrigins {
            (separator as NSString).draw(at: NSPoint(x: origin, y: y), withAttributes: attributes)
        }

    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }
}
