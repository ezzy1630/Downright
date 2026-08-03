import AppKit

/// Leading titlebar identity. It mirrors the window's document title while
/// preserving a deliberate two-line hierarchy and the titlebar drag region.
@MainActor
final class ToolbarDocumentIdentityView: NSView {
    private enum Metrics {
        static let width: CGFloat = 214
        static let height: CGFloat = 36
    }

    private weak var hostWindow: NSWindow?
    private let titleLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private var titleObservation: NSKeyValueObservation?
    private var subtitleObservation: NSKeyValueObservation?
    private var activationObservers: [NSObjectProtocol] = []

    var displayedTitle: String { titleLabel.stringValue }
    var displayedContext: String { contextLabel.stringValue }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    init(window: NSWindow) {
        hostWindow = window
        super.init(frame: .zero)

        for label in [titleLabel, contextLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingMiddle
            label.maximumNumberOfLines = 1
            addSubview(label)
        }
        titleLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        contextLabel.font = .systemFont(ofSize: 10.5, weight: .medium)
        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            contextLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            contextLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            contextLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: -1),
        ])

        titleObservation = window.observe(\.title, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.update(title: window.title, context: window.subtitle) }
        }
        subtitleObservation = window.observe(\.subtitle, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.update(title: window.title, context: window.subtitle) }
        }
        activationObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshEmphasis() }
            }
        }
        refreshEmphasis()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    private func update(title: String, context: String) {
        titleLabel.stringValue = title
        contextLabel.stringValue = context
        contextLabel.isHidden = context.isEmpty
        toolTip = context.isEmpty ? title : "\(title) - \(context)"
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(context.isEmpty ? title : "\(title), \(context)")
    }

    private func refreshEmphasis() {
        titleLabel.textColor = hostWindow?.isKeyWindow == true ? .labelColor : .secondaryLabelColor
        contextLabel.textColor = .tertiaryLabelColor
    }
}

/// A two-state titlebar rail for the document surface. Selection is expressed
/// by typography and one baseline, not a capsule competing with the document.
@MainActor
final class ToolbarPresentationControl: NSView {
    private enum Metrics {
        static let width: CGFloat = 176
        static let height: CGFloat = 32
        static let segmentWidth: CGFloat = 88
        static let indicatorWidth: CGFloat = 30
        static let indicatorHeight: CGFloat = 1.5
    }

    private let documentButton: ToolbarModeButton
    private let sourceButton: ToolbarModeButton
    private let selectionIndicator = CALayer()
    private var activationObservers: [NSObjectProtocol] = []
    private(set) var selectedSegment = -1

    let onChange: (Int) -> Void

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    var segmentTitles: [String] {
        [documentButton.displayTitle, sourceButton.displayTitle]
    }

    init(onChange: @escaping (Int) -> Void) {
        documentButton = ToolbarModeButton(
            title: "Document", typography: .document, accessibilityLabel: "Document"
        )
        sourceButton = ToolbarModeButton(
            title: "Source", typography: .source, accessibilityLabel: "Source"
        )
        self.onChange = onChange
        super.init(frame: .zero)

        wantsLayer = true
        selectionIndicator.cornerRadius = Metrics.indicatorHeight / 2
        layer?.addSublayer(selectionIndicator)

        documentButton.tag = 0
        sourceButton.tag = 1
        documentButton.target = self
        sourceButton.target = self
        documentButton.action = #selector(segmentPressed(_:))
        sourceButton.action = #selector(segmentPressed(_:))
        documentButton.onNavigate = { [weak self] target in self?.selectFromKeyboard(target) }
        sourceButton.onNavigate = { [weak self] target in self?.selectFromKeyboard(target) }

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
            documentButton.widthAnchor.constraint(equalToConstant: Metrics.segmentWidth),
            sourceButton.widthAnchor.constraint(equalTo: documentButton.widthAnchor),
        ])

        setSelectedSegment(0)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Document presentation")
        setAccessibilityHelp("Switch between rendered Document and raw Source")
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stopObservingWindowActivation()
        guard let window else { return }
        activationObservers = [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshWindowEmphasis(animated: true) }
            }
        }
        refreshWindowEmphasis(animated: false)
    }

    override func layout() {
        super.layout()
        updateSelectionIndicator(animated: false)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        selectionIndicator.backgroundColor = NSColor.labelColor.cgColor
        refreshWindowEmphasis(animated: false)
    }

    func setSelectedSegment(_ segment: Int) {
        let normalized = min(max(segment, 0), 1)
        guard normalized != selectedSegment else { return }
        selectedSegment = normalized
        documentButton.isSelected = normalized == 0
        sourceButton.isSelected = normalized == 1
        setAccessibilityValue(segmentTitles[normalized])
        updateSelectionIndicator(animated: window != nil)
    }

    @objc private func segmentPressed(_ sender: NSButton) {
        guard sender.tag != selectedSegment else { return }
        setSelectedSegment(sender.tag)
        onChange(sender.tag)
    }

    private func selectFromKeyboard(_ target: Int) {
        guard target != selectedSegment else { return }
        setSelectedSegment(target)
        onChange(target)
        window?.makeFirstResponder(target == 0 ? documentButton : sourceButton)
    }

    private func updateSelectionIndicator(animated: Bool) {
        guard selectedSegment >= 0 else { return }
        let selectedFrame = selectedSegment == 0 ? documentButton.frame : sourceButton.frame
        let frame = NSRect(
            x: selectedFrame.midX - (Metrics.indicatorWidth / 2),
            y: 2,
            width: Metrics.indicatorWidth,
            height: Metrics.indicatorHeight
        )
        selectionIndicator.backgroundColor = NSColor.labelColor.cgColor
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selectionIndicator.frame = frame
            CATransaction.commit()
            return
        }
        let currentFrame = selectionIndicator.presentation()?.frame ?? selectionIndicator.frame
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: NSPoint(x: currentFrame.midX, y: currentFrame.midY))
        animation.duration = 0.14
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        selectionIndicator.add(animation, forKey: "selection-change")
        selectionIndicator.frame = frame
    }

    private func refreshWindowEmphasis(animated: Bool) {
        let active = window?.isKeyWindow == true
        documentButton.setWindowActive(active)
        sourceButton.setWindowActive(active)
        let opacity: Float = active ? 0.82 : 0.38
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            selectionIndicator.opacity = opacity
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = selectionIndicator.presentation()?.opacity ?? selectionIndicator.opacity
        animation.toValue = opacity
        animation.duration = 0.12
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        selectionIndicator.add(animation, forKey: "window-emphasis")
        selectionIndicator.opacity = opacity
    }

    private func stopObservingWindowActivation() {
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        activationObservers.removeAll(keepingCapacity: true)
    }
}

/// Shared compositor-only pointer feedback for titlebar buttons. One owner
/// keeps hover timing, press scale, tracking, and Reduce Motion behavior in
/// sync across the mode rail and trailing menu.
@MainActor
class ToolbarInteractiveButton: NSButton {
    var feedbackInsetX: CGFloat = 5
    var feedbackInsetY: CGFloat = 3
    var feedbackCornerRadius: CGFloat = 5
    var permitsHoverFeedback: Bool { true }

    private let feedbackLayer = CALayer()
    private var isPointerInside = false
    private var isPressedForFeedback = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        feedbackLayer.opacity = 0
        layer?.insertSublayer(feedbackLayer, at: 0)
        refreshFeedbackColor()
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feedbackLayer.frame = bounds.insetBy(dx: feedbackInsetX, dy: feedbackInsetY)
        feedbackLayer.cornerRadius = feedbackCornerRadius
        CATransaction.commit()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshFeedbackColor()
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
        isPointerInside = true
        refreshInteractionFeedback(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        refreshInteractionFeedback(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        setPressedFeedback(true)
        defer { setPressedFeedback(false) }
        super.mouseDown(with: event)
    }

    func setPressedFeedback(_ pressed: Bool) {
        guard pressed != isPressedForFeedback else { return }
        isPressedForFeedback = pressed
        refreshInteractionFeedback(animated: true)
        updatePressTransform(animated: true)
    }

    func refreshInteractionFeedback(animated: Bool) {
        let targetOpacity: Float
        if isPressedForFeedback {
            targetOpacity = 0.14
        } else if isPointerInside, permitsHoverFeedback {
            targetOpacity = 0.075
        } else {
            targetOpacity = 0
        }
        animateFeedbackOpacity(to: targetOpacity, animated: animated)
    }

    private func refreshFeedbackColor() {
        feedbackLayer.backgroundColor = NSColor.labelColor.cgColor
    }

    private func animateFeedbackOpacity(to opacity: Float, animated: Bool) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            feedbackLayer.removeAnimation(forKey: "feedback-opacity")
            feedbackLayer.opacity = opacity
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = feedbackLayer.presentation()?.opacity ?? feedbackLayer.opacity
        animation.toValue = opacity
        animation.duration = 0.12
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        feedbackLayer.add(animation, forKey: "feedback-opacity")
        feedbackLayer.opacity = opacity
    }

    private func updatePressTransform(animated: Bool) {
        let scale: CGFloat = isPressedForFeedback ? 0.985 : 1
        let transform = CATransform3DMakeScale(scale, scale, 1)
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduceMotion else {
            layer?.transform = transform
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer?.presentation()?.transform ?? layer?.transform
        animation.toValue = transform
        animation.duration = isPressedForFeedback ? 0.08 : 0.12
        animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer?.add(animation, forKey: "press-transform")
        layer?.transform = transform
    }
}

/// One segment in `ToolbarPresentationControl`.
@MainActor
private final class ToolbarModeButton: ToolbarInteractiveButton {
    enum Typography {
        case document
        case source
    }

    let displayTitle: String
    private let typography: Typography
    private var isWindowActive = true
    var onNavigate: ((Int) -> Void)?

    override var permitsHoverFeedback: Bool { !isSelected }

    var isSelected = false {
        didSet {
            guard isSelected != oldValue else { return }
            updateTitle()
            setAccessibilityValue(isSelected ? "Selected" : "Not selected")
            refreshInteractionFeedback(animated: true)
        }
    }

    init(title: String, typography: Typography, accessibilityLabel: String) {
        displayTitle = title
        self.typography = typography
        super.init(frame: .zero)

        self.title = title
        bezelStyle = .regularSquare
        controlSize = .small
        isBordered = false
        alignment = .center
        focusRingType = .default
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(accessibilityLabel)
        toolTip = accessibilityLabel
        updateTitle()
    }

    required init?(coder: NSCoder) { nil }

    private func updateTitle() {
        let font: NSFont = switch typography {
        case .document:
            .systemFont(ofSize: 12, weight: isSelected ? .semibold : .medium)
        case .source:
            .monospacedSystemFont(ofSize: 11.5, weight: isSelected ? .semibold : .medium)
        }
        attributedTitle = NSAttributedString(
            string: displayTitle,
            attributes: [
                .font: font,
                .foregroundColor: titleColor,
            ]
        )
    }

    private var titleColor: NSColor {
        switch (isWindowActive, isSelected) {
        case (true, true): .labelColor
        case (true, false), (false, true): .secondaryLabelColor
        case (false, false): .tertiaryLabelColor
        }
    }

    func setWindowActive(_ active: Bool) {
        guard active != isWindowActive else { return }
        isWindowActive = active
        updateTitle()
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123:
            onNavigate?(0)
        case 124:
            onNavigate?(1)
        default:
            super.keyDown(with: event)
        }
    }

}

/// Compact trailing menu button.  `NSMenuToolbarItem` adds a second pill and
/// chevron around the symbol; this keeps one deliberate icon and lets the
/// menu itself provide the disclosure affordance when opened.
@MainActor
final class ToolbarMenuButton: ToolbarInteractiveButton {
    private enum Metrics {
        static let width: CGFloat = 30
        static let height: CGFloat = 30
        static let cornerRadius: CGFloat = 7
    }

    private let popupMenu: NSMenu

    var popupMenuItems: [NSMenuItem] { popupMenu.items }

    init(menu: NSMenu) {
        popupMenu = menu
        super.init(frame: .zero)
        feedbackInsetX = 1
        feedbackInsetY = 1
        feedbackCornerRadius = Metrics.cornerRadius
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

    override func mouseDown(with event: NSEvent) {
        setPressedFeedback(true)
        defer { setPressedFeedback(false) }
        popupMenu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.minY), in: self)
    }

    override func accessibilityPerformPress() -> Bool {
        popupMenu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.minY), in: self)
        return true
    }
}
