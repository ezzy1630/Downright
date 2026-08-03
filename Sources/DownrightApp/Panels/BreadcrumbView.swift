import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol BreadcrumbDelegate: AnyObject {
    func breadcrumb(_ view: BreadcrumbView, didSelectHeadingAt index: Int)
}

/// Stable current-section control (§5.1).
///
/// The document title already lives in the toolbar. Repeating every ancestor
/// here makes the quiet reading lane look like a second title bar, so the
/// control shows only the section the reader is in. The complete path remains
/// one click away in a native menu.
final class BreadcrumbView: NSView {
    private enum Metrics {
        /// Fixed chrome height. An empty or temporarily reparsing heading list
        /// must never move the document under the reader's eyes.
        static let height: CGFloat = 28
        static let buttonHeight: CGFloat = 24
        static let maximumButtonWidth: CGFloat = 360
        static let horizontalContentAllowance: CGFloat = 26
        static let sectionChangeDuration: CFTimeInterval = 0.12
    }

    weak var delegate: BreadcrumbDelegate?

    var styleSheet: StyleSheet {
        didSet {
            rebuild()
        }
    }

    /// Ancestor chain, root first.  Indices are into the document's headings.
    var trail: [(index: Int, title: String, level: Int)] = [] {
        didSet {
            guard !Self.sameTrail(oldValue, trail) else { return }
            let crossedSectionBoundary = oldValue.last?.index != nil
                && trail.last?.index != nil
                && oldValue.last?.index != trail.last?.index
            rebuild(animated: crossedSectionBoundary)
        }
    }

    private let sectionButton = ToolbarInteractiveButton(frame: .zero)
    private var sectionAction: ButtonAction?

    var currentTitleOrigin: CGFloat {
        let titleRect = (sectionButton.cell as? NSButtonCell)?.titleRect(forBounds: sectionButton.bounds)
            ?? sectionButton.bounds
        return sectionButton.frame.minX + titleRect.minX
    }

    /// Scroll callbacks arrive continuously, but section identity changes only
    /// at heading boundaries. Avoid rebuilding AppKit controls for identical
    /// paths so scrolling stays direct and allocation-free.
    static func sameTrail(
        _ lhs: [(index: Int, title: String, level: Int)],
        _ rhs: [(index: Int, title: String, level: Int)]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.index == right.index
                && left.title == right.title
                && left.level == right.level
        }
    }

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)

        let action = ButtonAction { [weak self] in self?.showPathMenu() }
        sectionAction = action
        sectionButton.feedbackInsetX = 0
        sectionButton.feedbackInsetY = 1
        sectionButton.feedbackCornerRadius = 4
        sectionButton.isBordered = false
        sectionButton.bezelStyle = .accessoryBarAction
        sectionButton.focusRingType = .default
        sectionButton.imagePosition = .imageTrailing
        sectionButton.imageScaling = .scaleProportionallyDown
        sectionButton.target = action
        sectionButton.action = #selector(ButtonAction.fire(_:))
        (sectionButton.cell as? NSButtonCell)?.lineBreakMode = .byTruncatingTail
        addSubview(sectionButton)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Current section")
        rebuild(animated: false)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.maximumButtonWidth, height: Metrics.height)
    }

    // MARK: - Building

    private func rebuild(animated: Bool = false) {
        guard let current = trail.last else {
            sectionButton.isHidden = true
            sectionButton.attributedTitle = NSAttributedString()
            sectionButton.image = nil
            setAccessibilityLabel("Current section")
            needsLayout = true
            return
        }

        sectionButton.isHidden = false
        prepareSectionChangeTransitionIfNeeded(animated)
        sectionButton.attributedTitle = styledTitle(current.title)
        sectionButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        sectionButton.contentTintColor = styleSheet.textFaint
        sectionButton.toolTip = trail.map(\.title).joined(separator: " › ")
        sectionButton.setAccessibilityLabel("Current section: \(current.title)")
        sectionButton.setAccessibilityHelp(
            "Jump to this section or an ancestor. Path: "
                + trail.map(\.title).joined(separator: ", ")
        )
        setAccessibilityLabel("Current section: \(current.title)")
        needsLayout = true
    }

    private func styledTitle(_ text: String) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            // Chrome should remain visibly distinct from the document heading
            // it names. Medium system text reads as navigation, not content.
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: styleSheet.textSecondary,
        ])
    }

    /// A section boundary should register in peripheral vision without making
    /// the title feel delayed or absent. Install the compositor transition
    /// before the immediate title swap so old and new pixels crossfade.
    private func prepareSectionChangeTransitionIfNeeded(_ animated: Bool) {
        guard animated,
              !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
              let layer = sectionButton.layer
        else { return }

        layer.removeAnimation(forKey: "section-change")
        let transition = CATransition()
        transition.type = .fade
        transition.duration = Metrics.sectionChangeDuration
        transition.timingFunction = ToolbarChromePolicy.timingFunction()
        layer.add(transition, forKey: "section-change")
    }

    // MARK: - Layout

    override func layout() {
        super.layout()
        guard let current = trail.last else { return }
        let titleWidth = styledTitle(current.title).size().width
        let availableWidth = min(bounds.width, Metrics.maximumButtonWidth)
        let width = min(availableWidth, titleWidth + Metrics.horizontalContentAllowance)
        sectionButton.frame = NSRect(
            x: 0,
            y: (bounds.height - Metrics.buttonHeight) / 2,
            width: max(44, width),
            height: Metrics.buttonHeight
        )
        // Borderless NSButton cells retain a small native content inset. Shift
        // the control, not its text, so the visible title shares the document's
        // exact leading axis while the hit target and feedback stay native.
        sectionButton.frame.origin.x -= currentTitleOrigin

        discardCursorRects()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        if !sectionButton.isHidden {
            addCursorRect(sectionButton.frame, cursor: .pointingHand)
        }
    }

    private func showPathMenu() {
        guard !trail.isEmpty else { return }
        let menu = makePathMenu()
        menu.popUp(positioning: menu.items.last, at: NSPoint(x: 0, y: 0), in: self)
    }

    func makePathMenu() -> NSMenu {
        let menu = NSMenu()
        let baseLevel = trail.first?.level ?? 1
        for (position, crumb) in trail.enumerated() {
            let item = NSMenuItem(
                title: crumb.title,
                action: #selector(selectPathItem(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = crumb.index
            item.indentationLevel = max(0, crumb.level - baseLevel)
            item.state = position == trail.count - 1 ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    @objc private func selectPathItem(_ sender: NSMenuItem) {
        guard let index = sender.representedObject as? Int else { return }
        delegate?.breadcrumb(self, didSelectHeadingAt: index)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild(animated: false)
    }
}
