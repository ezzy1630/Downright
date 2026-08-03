import AppKit

/// A two-state toolbar control for the document surface.  It keeps the native
/// button semantics and focus ring, while drawing a quieter segmented surface
/// than the default capsule treatment.
@MainActor
final class ToolbarPresentationControl: NSView {
    private static let cornerRadius: CGFloat = 9

    private let documentButton: ToolbarModeButton
    private let sourceButton: ToolbarModeButton
    private(set) var selectedSegment = 0

    var onChange: ((Int) -> Void)?

    override var intrinsicContentSize: NSSize {
        NSSize(width: 224, height: 32)
    }

    var segmentTitles: [String] {
        [documentButton.title, sourceButton.title]
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

        wantsLayer = true
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
            documentButton.widthAnchor.constraint(equalTo: sourceButton.widthAnchor),
        ])

        setSelectedSegment(0)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document presentation")
        setAccessibilityHelp("Switch between rendered Document and raw Source")
    }

    required init?(coder: NSCoder) { nil }

    func setSelectedSegment(_ segment: Int) {
        let normalized = min(max(segment, 0), 1)
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
        NSColor.controlBackgroundColor.withAlphaComponent(0.72).setFill()
        path.fill()
        NSColor.separatorColor.withAlphaComponent(0.58).setStroke()
        path.lineWidth = 1
        path.stroke()
    }
}

/// One segment in `ToolbarPresentationControl`.  The button owns its hover,
/// pressed, selected, and focus states so the control stays responsive without
/// introducing a second animation system.
@MainActor
private final class ToolbarModeButton: NSButton {
    var isSelected = false {
        didSet {
            contentTintColor = isSelected ? .labelColor : .secondaryLabelColor
            setAccessibilityValue(isSelected ? "Selected" : "Not selected")
            needsDisplay = true
        }
    }

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(title: String, symbolName: String, accessibilityLabel: String) {
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityLabel)
        imagePosition = .imageLeading
        imageScaling = .scaleProportionallyDown
        alignment = .center
        bezelStyle = .regularSquare
        controlSize = .regular
        font = NSFont.systemFont(ofSize: 13, weight: .semibold)
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
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
        if isSelected {
            NSColor.unemphasizedSelectedContentBackgroundColor.setFill()
            path.fill()
        } else if isHovered || isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.09).setFill()
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
    private let popupMenu: NSMenu

    var popupMenuItems: [NSMenuItem] { popupMenu.items }

    private var isHovered = false {
        didSet { needsDisplay = true }
    }

    init(menu: NSMenu) {
        popupMenu = menu
        super.init(frame: .zero)
        image = NSImage(systemSymbolName: "slider.horizontal.3", accessibilityDescription: "More actions")
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
        NSSize(width: 32, height: 32)
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

    override func mouseDown(with event: NSEvent) {
        popupMenu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.minY), in: self)
    }

    override func accessibilityPerformPress() -> Bool {
        popupMenu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.minY), in: self)
        return true
    }

    override func draw(_ dirtyRect: NSRect) {
        if isHovered || isHighlighted {
            let rect = bounds.insetBy(dx: 1, dy: 1)
            let path = NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8)
            NSColor.labelColor.withAlphaComponent(0.1).setFill()
            path.fill()
        }
        super.draw(dirtyRect)
    }
}
