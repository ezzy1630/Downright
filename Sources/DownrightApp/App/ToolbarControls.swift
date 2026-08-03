import AppKit

/// A two-state toolbar control for the document surface.  It keeps the native
/// button semantics and focus ring, while drawing a quieter segmented surface
/// than the default capsule treatment.
@MainActor
final class ToolbarPresentationControl: NSView {
    private enum Metrics {
        static let width: CGFloat = 204
        static let height: CGFloat = 28
        static let documentWidth: CGFloat = 108
        static let sourceWidth: CGFloat = 94
    }

    private static let cornerRadius: CGFloat = 7

    private let documentButton: ToolbarModeButton
    private let sourceButton: ToolbarModeButton
    private(set) var selectedSegment = -1

    var onChange: ((Int) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    var segmentTitles: [String] {
        [documentButton.displayTitle, sourceButton.displayTitle]
    }

    init(onChange: @escaping (Int) -> Void) {
        documentButton = ToolbarModeButton(
            title: "Document", symbolName: "doc.text", accessibilityLabel: "Document"
        )
        sourceButton = ToolbarModeButton(
            title: "Source", symbolName: "chevron.left.forwardslash.chevron.right", accessibilityLabel: "Source"
        )
        self.onChange = onChange
        super.init(frame: .zero)

        documentButton.tag = 0
        sourceButton.tag = 1
        documentButton.target = self
        sourceButton.target = self
        documentButton.action = #selector(segmentPressed(_:))
        sourceButton.action = #selector(segmentPressed(_:))

        for button in [documentButton, sourceButton] {
            button.translatesAutoresizingMaskIntoConstraints = false
            addSubview(button)
        }

        NSLayoutConstraint.activate([
            documentButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 1),
            documentButton.topAnchor.constraint(equalTo: topAnchor, constant: 1),
            documentButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
            sourceButton.topAnchor.constraint(equalTo: documentButton.topAnchor),
            sourceButton.bottomAnchor.constraint(equalTo: documentButton.bottomAnchor),
            sourceButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            sourceButton.leadingAnchor.constraint(equalTo: documentButton.trailingAnchor),
            documentButton.widthAnchor.constraint(equalToConstant: Metrics.documentWidth),
            sourceButton.widthAnchor.constraint(equalToConstant: Metrics.sourceWidth),
        ])

        setSelectedSegment(0)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document presentation")
        setAccessibilityHelp("Switch between rendered Document and raw Source")
    }

    required init?(coder: NSCoder) { nil }

    func setSelectedSegment(_ segment: Int) {
        let normalized = min(max(segment, 0), 1)
        guard normalized != selectedSegment else { return }
        selectedSegment = normalized
        documentButton.isSelected = normalized == 0
        sourceButton.isSelected = normalized == 1
        setAccessibilityValue(segmentTitles[normalized])
    }

    @objc private func segmentPressed(_ sender: NSButton) {
        setSelectedSegment(sender.tag)
        onChange?(sender.tag)
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Self.cornerRadius,
            yRadius: Self.cornerRadius
        )
        NSColor.controlBackgroundColor.withAlphaComponent(0.46).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.32).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// One segment in `ToolbarPresentationControl`.  The button owns its hover,
/// pressed, selected, and focus states so the control stays responsive without
/// introducing a second animation system.
@MainActor
private final class ToolbarModeButton: NSButton {
    let displayTitle: String

    private let iconView: NSImageView
    private let titleView: NSTextField
    private let contentStack: NSStackView

    var isSelected = false {
        didSet {
            let color: NSColor = isSelected ? .labelColor : .secondaryLabelColor
            iconView.contentTintColor = color
            titleView.textColor = color
            setAccessibilityValue(isSelected ? "Selected" : "Not selected")
            needsDisplay = true
        }
    }

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(title: String, symbolName: String, accessibilityLabel: String) {
        displayTitle = title
        let image = NSImage(
            systemSymbolName: symbolName,
            accessibilityDescription: accessibilityLabel
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        iconView = NSImageView(image: image ?? NSImage())
        titleView = NSTextField(labelWithString: title)
        contentStack = NSStackView()
        super.init(frame: .zero)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 6
        contentStack.distribution = .fill
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleView.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleView.alignment = .center
        titleView.lineBreakMode = .byClipping
        titleView.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(iconView)
        contentStack.addArrangedSubview(titleView)
        addSubview(contentStack)

        NSLayoutConstraint.activate([
            contentStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            contentStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),
        ])

        // The button's visual content is the stack above. Keep the NSButton
        // title/image empty so AppKit cannot lay them out independently.
        self.title = ""
        bezelStyle = .regularSquare
        controlSize = .regular
        isBordered = false
        focusRingType = .default
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
    }

    required init?(coder: NSCoder) { nil }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: rect, xRadius: 5.5, yRadius: 5.5)
        if isSelected {
            NSColor.selectedContentBackgroundColor.withAlphaComponent(0.16).setFill()
            path.fill()
            NSColor.labelColor.withAlphaComponent(0.13).setStroke()
            path.lineWidth = 0.5
            path.stroke()
        } else if isHovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.07).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}

/// Compact trailing menu button.  `NSMenuToolbarItem` adds a second pill and
/// chevron around the symbol; this keeps one deliberate icon and lets the
/// menu itself provide the disclosure affordance when opened.
@MainActor
final class ToolbarMenuButton: NSButton {
    private enum Metrics {
        static let width: CGFloat = 30
        static let height: CGFloat = 28
        static let cornerRadius: CGFloat = 7
    }

    private let popupMenu: NSMenu

    var popupMenuItems: [NSMenuItem] { popupMenu.items }

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(menu: NSMenu) {
        popupMenu = menu
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: "ellipsis",
            accessibilityDescription: "More actions"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        bezelStyle = .accessoryBarAction
        controlSize = .regular
        isBordered = false
        focusRingType = .default
        setAccessibilityRole(.button)
        setAccessibilityLabel("More actions")
        setAccessibilityHelp("Open document actions")
        toolTip = "More document actions"
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self,
            userInfo: nil
        ))
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
    }

    private var isPressed = false {
        didSet { needsDisplay = true }
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        defer { isPressed = false }
        popupMenu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.minY), in: self)
    }

    override func accessibilityPerformPress() -> Bool {
        popupMenu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.minY), in: self)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(
            roundedRect: rect,
            xRadius: Metrics.cornerRadius,
            yRadius: Metrics.cornerRadius
        )
        if isHovered || isHighlighted || isPressed {
            NSColor.labelColor.withAlphaComponent(isPressed ? 0.14 : 0.08).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}
