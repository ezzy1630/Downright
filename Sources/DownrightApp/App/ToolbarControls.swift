import AppKit
import MarkdownRender

/// One policy for toolbar motion and emphasis. Keeping these decisions pure
/// prevents individual controls from drifting into different timings or tones.
enum ToolbarChromePolicy {
    enum InteractionState {
        case idle
        case hover
        case pressed
    }

    struct ScrubState: Equatable {
        let indicatorCenterX: CGFloat
        let segment: Int
    }

    // Timing is `Motion`'s to decide, not this file's.  These names stay
    // because the controls read better for them, but they are views onto the
    // one vocabulary rather than a second set of numbers that can drift.
    static let hoverDuration: CFTimeInterval = Motion.hover
    static let pressInDuration: CFTimeInterval = Motion.pressIn
    static let pressOutDuration: CFTimeInterval = Motion.pressOut
    static let selectionDuration: CFTimeInterval = Motion.selection
    static let emphasisDuration: CFTimeInterval = Motion.emphasis
    static let pressedScale: CGFloat = 0.985
    /// The task ring's press dips further than a plate button's: the glyph
    /// itself compresses, so the travel has to read at 22pt — a 1.5% dip
    /// would be invisible on a ring that small.
    static let ringPressedScale: CGFloat = 0.86

    static func timingFunction() -> CAMediaTimingFunction {
        Motion.timing(.snap)
    }

    static func feedbackOpacity(
        for state: InteractionState,
        increaseContrast: Bool
    ) -> Float {
        switch (state, increaseContrast) {
        case (.idle, _): 0
        case (.hover, false): 0.075
        case (.hover, true): 0.11
        case (.pressed, false): 0.14
        case (.pressed, true): 0.19
        }
    }

    static func indicatorOpacity(isWindowActive: Bool, increaseContrast: Bool) -> Float {
        switch (isWindowActive, increaseContrast) {
        case (true, false): 0.82
        case (true, true): 1
        case (false, false): 0.38
        case (false, true): 0.56
        }
    }

    static func scrubState(
        pointerX: CGFloat,
        leftCenterX: CGFloat,
        rightCenterX: CGFloat
    ) -> ScrubState {
        let lowerBound = min(leftCenterX, rightCenterX)
        let upperBound = max(leftCenterX, rightCenterX)
        let centerX = min(max(pointerX, lowerBound), upperBound)
        return ScrubState(
            indicatorCenterX: centerX,
            segment: centerX < ((lowerBound + upperBound) / 2) ? 0 : 1
        )
    }
}

enum ToolbarScrubPhase {
    case began
    case changed
    case ended
    case cancelled
}

/// Leading titlebar identity. It mirrors the window's document title while
/// preserving a deliberate two-line hierarchy and the titlebar drag region.
/// A quiet proxy opens the path menu; an edited dot marks unsaved work.
@MainActor
final class ToolbarDocumentIdentityView: NSView {
    private enum Metrics {
        static let width: CGFloat = 220
        static let height: CGFloat = 32
        static let proxySize: CGFloat = 16
        static let dirtySize: CGFloat = 6
        static let titleSize: CGFloat = 12
        static let contextSize: CGFloat = 10
        static let lineGap: CGFloat = 1
    }

    private weak var hostWindow: NSWindow?
    private let proxyButton = ToolbarInteractiveButton(frame: .zero)
    private let dirtyDot = NSView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(labelWithString: "")
    private let titleRow = NSStackView()
    private let textColumn = NSStackView()
    private var titleObservation: NSKeyValueObservation?
    private var subtitleObservation: NSKeyValueObservation?
    private var editedObservation: NSKeyValueObservation?
    private var urlObservation: NSKeyValueObservation?
    private var activationObservers: [NSObjectProtocol] = []

    var isEdited: Bool = false {
        didSet {
            guard isEdited != oldValue else { return }
            dirtyDot.isHidden = !isEdited
            refreshAccessibility()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    init(window: NSWindow) {
        hostWindow = window
        super.init(frame: .zero)

        proxyButton.feedbackInsetX = 1
        proxyButton.feedbackInsetY = 1
        proxyButton.feedbackCornerRadius = 3
        proxyButton.image = NSImage(
            systemSymbolName: "doc.text",
            accessibilityDescription: "Document path"
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        proxyButton.imagePosition = .imageOnly
        proxyButton.imageScaling = .scaleProportionallyDown
        proxyButton.isBordered = false
        proxyButton.bezelStyle = .inline
        proxyButton.focusRingType = .default
        proxyButton.setAccessibilityRole(.button)
        proxyButton.setAccessibilityLabel("Document path")
        proxyButton.toolTip = "Show document path"
        proxyButton.target = self
        proxyButton.action = #selector(showPathMenu(_:))

        dirtyDot.wantsLayer = true
        dirtyDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        dirtyDot.layer?.cornerRadius = Metrics.dirtySize / 2
        dirtyDot.isHidden = true
        dirtyDot.setContentHuggingPriority(.required, for: .horizontal)
        dirtyDot.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.font = .systemFont(ofSize: Metrics.titleSize, weight: .semibold)
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        contextLabel.lineBreakMode = .byTruncatingMiddle
        contextLabel.maximumNumberOfLines = 1
        contextLabel.font = .systemFont(ofSize: Metrics.contextSize, weight: .medium)
        contextLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        contextLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 5
        titleRow.detachesHiddenViews = true
        titleRow.addArrangedSubview(dirtyDot)
        titleRow.addArrangedSubview(titleLabel)

        textColumn.orientation = .vertical
        textColumn.alignment = .leading
        textColumn.spacing = Metrics.lineGap
        textColumn.addArrangedSubview(titleRow)
        textColumn.addArrangedSubview(contextLabel)

        proxyButton.translatesAutoresizingMaskIntoConstraints = false
        textColumn.translatesAutoresizingMaskIntoConstraints = false
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        addSubview(proxyButton)
        addSubview(textColumn)

        setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)

        NSLayoutConstraint.activate([
            proxyButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            proxyButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            proxyButton.widthAnchor.constraint(equalToConstant: Metrics.proxySize + 2),
            proxyButton.heightAnchor.constraint(equalToConstant: Metrics.proxySize + 2),

            dirtyDot.widthAnchor.constraint(equalToConstant: Metrics.dirtySize),
            dirtyDot.heightAnchor.constraint(equalToConstant: Metrics.dirtySize),

            textColumn.leadingAnchor.constraint(equalTo: proxyButton.trailingAnchor, constant: 5),
            textColumn.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            textColumn.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        titleObservation = window.observe(\.title, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.update(title: window.title, context: window.subtitle) }
        }
        subtitleObservation = window.observe(\.subtitle, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.update(title: window.title, context: window.subtitle) }
        }
        editedObservation = window.observe(\.isDocumentEdited, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.isEdited = window.isDocumentEdited }
        }
        urlObservation = window.observe(\.representedURL, options: [.initial, .new]) { [weak self] window, _ in
            MainActor.assumeIsolated { self?.updateProxyIcon(for: window.representedURL) }
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
        // The observations retain the window they observe and their closures
        // capture it strongly.  Without invalidating them here, closing the
        // document window leaves the whole toolbar chain — window, toolbar,
        // item, this view — alive in a retain cycle.
        titleObservation?.invalidate()
        subtitleObservation?.invalidate()
        editedObservation?.invalidate()
        urlObservation?.invalidate()
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    override var mouseDownCanMoveWindow: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        // `point` is in the superview's coordinate space.
        let pointInSelf = convert(point, from: superview)
        if proxyButton.frame.insetBy(dx: -2, dy: -2).contains(pointInSelf) {
            return proxyButton
        }
        return self
    }

    /// The proxy wears the document's own icon, the way the titlebar proxy in
    /// every other macOS document window does.  A generic `doc.text` symbol is
    /// the single clearest tell that a titlebar was hand-built: it says the
    /// same thing for a Markdown file, a folder, and an alias.
    private func updateProxyIcon(for url: URL?) {
        guard let url, FileManager.default.fileExists(atPath: url.path) else {
            proxyButton.image = NSImage(
                systemSymbolName: "doc.text", accessibilityDescription: "Document path"
            )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .medium))
            proxyButton.contentTintColor = hostWindow?.isKeyWindow == true
                ? .secondaryLabelColor
                : .tertiaryLabelColor
            return
        }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: Metrics.proxySize, height: Metrics.proxySize)
        proxyButton.image = icon
        // A file icon is already coloured; tinting it would flatten it to a
        // silhouette.
        proxyButton.contentTintColor = nil
    }

    /// Dragging the proxy hands the file to whatever is under the pointer —
    /// Finder, Mail, a terminal.  It is the other half of what makes a proxy a
    /// proxy rather than a button with a picture on it.
    override func mouseDragged(with event: NSEvent) {
        let start = convert(event.locationInWindow, from: nil)
        guard proxyButton.frame.insetBy(dx: -2, dy: -2).contains(start),
              let url = hostWindow?.representedURL,
              FileManager.default.fileExists(atPath: url.path) else {
            super.mouseDragged(with: event)
            return
        }
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 32, height: 32)
        item.setDraggingFrame(
            NSRect(x: start.x - 16, y: start.y - 16, width: 32, height: 32),
            contents: icon
        )
        beginDraggingSession(with: [item], event: event, source: self)
    }

    @objc private func showPathMenu(_ sender: Any?) {
        guard let window = hostWindow, let url = window.representedURL else {
            NSSound.beep()
            return
        }
        let menu = NSMenu(title: "Document Path")
        var current = url.absoluteURL
        var urls: [URL] = []
        while current.path != "/" {
            urls.append(current)
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        for pathURL in urls {
            let item = NSMenuItem(
                title: pathURL.lastPathComponent,
                action: #selector(openPathComponent(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = pathURL
            item.image = NSWorkspace.shared.icon(forFile: pathURL.path)
            item.image?.size = NSSize(width: 16, height: 16)
            menu.addItem(item)
        }
        menu.addItem(.separator())
        let reveal = NSMenuItem(
            title: "Reveal in Finder",
            action: #selector(revealInFinder(_:)),
            keyEquivalent: ""
        )
        reveal.target = self
        reveal.representedObject = url
        menu.addItem(reveal)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.minY), in: self)
    }

    @objc private func openPathComponent(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        if url == hostWindow?.representedURL {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: url.path)
        }
    }

    @objc private func revealInFinder(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL ?? hostWindow?.representedURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func update(title: String, context: String) {
        titleLabel.stringValue = title
        contextLabel.stringValue = context
        contextLabel.isHidden = context.isEmpty
        toolTip = context.isEmpty ? title : "\(title) — \(context)"
        refreshAccessibility()
    }

    private func refreshAccessibility() {
        let base = contextLabel.stringValue.isEmpty
            ? titleLabel.stringValue
            : "\(titleLabel.stringValue), \(contextLabel.stringValue)"
        let label = isEdited ? "\(base), edited" : base
        setAccessibilityRole(.group)
        setAccessibilityLabel(label)
    }

    private func refreshEmphasis() {
        titleLabel.textColor = hostWindow?.isKeyWindow == true ? .labelColor : .secondaryLabelColor
        contextLabel.textColor = .tertiaryLabelColor
        dirtyDot.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        updateProxyIcon(for: hostWindow?.representedURL)
    }
}

extension ToolbarDocumentIdentityView: NSDraggingSource {
    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .link] : .copy
    }
}

/// A two-state titlebar rail for the document surface. Selection is expressed
/// by typography and one baseline, not a capsule competing with the document.
@MainActor
final class ToolbarPresentationControl: NSView {
    var styleSheet: StyleSheet = .current {
        didSet {
            documentButton.styleSheet = styleSheet
            sourceButton.styleSheet = styleSheet
        }
    }
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
    private var accessibilityObserver: NSObjectProtocol?
    private var scrubbedSegment: Int?
    private(set) var selectedSegment = -1

    let onChange: (Int) -> Void
    let performHapticFeedback: () -> Void

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    var segmentTitles: [String] {
        [documentButton.displayTitle, sourceButton.displayTitle]
    }

    init(
        onChange: @escaping (Int) -> Void,
        performHapticFeedback: @escaping () -> Void = {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    ) {
        documentButton = ToolbarModeButton(
            title: "Document",
            typography: .document,
            accessibilityLabel: "Rendered document"
        )
        sourceButton = ToolbarModeButton(
            title: "Source",
            typography: .source,
            accessibilityLabel: "Source Focus"
        )
        self.onChange = onChange
        self.performHapticFeedback = performHapticFeedback
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
        addGestureRecognizer(NSPanGestureRecognizer(target: self, action: #selector(scrubSelection(_:))))

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
        setAccessibilityLabel("Source Focus")
        setAccessibilityHelp("Switch between rendered Document and Source Focus")
        documentButton.toolTip = "Rendered document"
        sourceButton.toolTip = "Source Focus — show raw Markdown"
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshWindowEmphasis(animated: false) }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        for observer in activationObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
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
        if scrubbedSegment == nil {
            updateSelectionIndicator(animated: false)
        }
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
        applyVisualSelection(normalized)
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

    @objc private func scrubSelection(_ recognizer: NSPanGestureRecognizer) {
        switch recognizer.state {
        case .began:
            updateScrub(at: recognizer.location(in: self).x, phase: .began)
        case .changed:
            updateScrub(at: recognizer.location(in: self).x, phase: .changed)
        case .ended:
            updateScrub(at: recognizer.location(in: self).x, phase: .ended)
        case .cancelled, .failed:
            updateScrub(at: recognizer.location(in: self).x, phase: .cancelled)
        case .possible:
            break
        @unknown default:
            updateScrub(at: recognizer.location(in: self).x, phase: .cancelled)
        }
    }

    func updateScrub(at pointerX: CGFloat, phase: ToolbarScrubPhase) {
        let state = ToolbarChromePolicy.scrubState(
            pointerX: pointerX,
            leftCenterX: documentButton.frame.midX,
            rightCenterX: sourceButton.frame.midX
        )

        switch phase {
        case .began, .changed:
            let previousSegment = scrubbedSegment
            scrubbedSegment = state.segment
            applyVisualSelection(state.segment)
            updateSelectionIndicator(centerX: state.indicatorCenterX)
            if let previousSegment, previousSegment != state.segment {
                performHapticFeedback()
            }
        case .ended:
            scrubbedSegment = nil
            commitScrubbedSegment(state.segment)
        case .cancelled:
            scrubbedSegment = nil
            applyVisualSelection(selectedSegment)
            updateSelectionIndicator(animated: true)
        }
    }

    private func applyVisualSelection(_ segment: Int) {
        documentButton.isSelected = segment == 0
        sourceButton.isSelected = segment == 1
    }

    private func commitScrubbedSegment(_ segment: Int) {
        guard segment != selectedSegment else {
            applyVisualSelection(selectedSegment)
            updateSelectionIndicator(animated: true)
            return
        }
        setSelectedSegment(segment)
        onChange(segment)
    }

    private func updateSelectionIndicator(centerX: CGFloat) {
        selectionIndicator.removeAnimation(forKey: "selection-change")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        selectionIndicator.frame = NSRect(
            x: centerX - (Metrics.indicatorWidth / 2),
            y: 2,
            width: Metrics.indicatorWidth,
            height: Metrics.indicatorHeight
        )
        CATransaction.commit()
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
        guard animated, !styleSheet.reduceMotion else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            selectionIndicator.frame = frame
            CATransaction.commit()
            return
        }
        let currentFrame = selectionIndicator.presentation()?.frame ?? selectionIndicator.frame
        let animation = CABasicAnimation(keyPath: "position")
        animation.fromValue = NSValue(point: NSPoint(x: currentFrame.midX, y: currentFrame.midY))
        animation.duration = ToolbarChromePolicy.selectionDuration
        animation.timingFunction = ToolbarChromePolicy.timingFunction()
        selectionIndicator.add(animation, forKey: "selection-change")
        selectionIndicator.frame = frame
    }

    private func refreshWindowEmphasis(animated: Bool) {
        let active = window?.isKeyWindow == true
        documentButton.setWindowActive(active)
        sourceButton.setWindowActive(active)
        let opacity = ToolbarChromePolicy.indicatorOpacity(
            isWindowActive: active,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        guard animated, !styleSheet.reduceMotion else {
            selectionIndicator.removeAnimation(forKey: "window-emphasis")
            selectionIndicator.opacity = opacity
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = selectionIndicator.presentation()?.opacity ?? selectionIndicator.opacity
        animation.toValue = opacity
        animation.duration = ToolbarChromePolicy.emphasisDuration
        animation.timingFunction = ToolbarChromePolicy.timingFunction()
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
    var styleSheet: StyleSheet = .current { didSet { styleSheetDidChange() } }
    func styleSheetDidChange() {}
    var feedbackInsetX: CGFloat = 5
    var feedbackInsetY: CGFloat = 3
    var feedbackCornerRadius: CGFloat = 5
    var permitsHoverFeedback: Bool { true }

    private let feedbackLayer = CALayer()
    private var isPointerInside = false
    private var isPressedForFeedback = false
    private var accessibilityObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        feedbackLayer.opacity = 0
        layer?.insertSublayer(feedbackLayer, at: 0)
        refreshFeedbackColor()
        accessibilityObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshInteractionFeedback(animated: false) }
        }
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let accessibilityObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(accessibilityObserver)
        }
    }

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
        let state: ToolbarChromePolicy.InteractionState = if isPressedForFeedback {
            .pressed
        } else if isPointerInside, permitsHoverFeedback {
            .hover
        } else {
            .idle
        }
        let targetOpacity = ToolbarChromePolicy.feedbackOpacity(
            for: state,
            increaseContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        )
        animateFeedbackOpacity(to: targetOpacity, animated: animated)
    }

    private func refreshFeedbackColor() {
        feedbackLayer.backgroundColor = NSColor.labelColor.cgColor
    }

    private func animateFeedbackOpacity(to opacity: Float, animated: Bool) {
        let reduceMotion = styleSheet.reduceMotion
        guard animated, !reduceMotion else {
            feedbackLayer.removeAnimation(forKey: "feedback-opacity")
            feedbackLayer.opacity = opacity
            return
        }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = feedbackLayer.presentation()?.opacity ?? feedbackLayer.opacity
        animation.toValue = opacity
        animation.duration = ToolbarChromePolicy.hoverDuration
        animation.timingFunction = ToolbarChromePolicy.timingFunction()
        feedbackLayer.add(animation, forKey: "feedback-opacity")
        feedbackLayer.opacity = opacity
    }

    private func updatePressTransform(animated: Bool) {
        let scale = isPressedForFeedback ? ToolbarChromePolicy.pressedScale : 1
        let transform = CATransform3DMakeScale(scale, scale, 1)
        let reduceMotion = styleSheet.reduceMotion
        guard animated, !reduceMotion else {
            layer?.transform = transform
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer?.presentation()?.transform ?? layer?.transform
        animation.toValue = transform
        animation.duration = isPressedForFeedback
            ? ToolbarChromePolicy.pressInDuration
            : ToolbarChromePolicy.pressOutDuration
        animation.timingFunction = ToolbarChromePolicy.timingFunction()
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
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        switch (isWindowActive, isSelected) {
        case (true, true): return .labelColor
        case (true, false) where increaseContrast: return .labelColor
        case (true, false), (false, true): return .secondaryLabelColor
        case (false, false): return .tertiaryLabelColor
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
        // A real target/action is what makes Space and Return reach the menu:
        // `mouseDown` never calls super, so without this the button had no
        // keyboard path at all and only VoiceOver's press worked.
        target = self
        action = #selector(showMenu(_:))
        setAccessibilityRole(.popUpButton)
        setAccessibilityLabel("More actions")
        setAccessibilityHelp("Open document actions")
        toolTip = "More document actions"
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.width, height: Metrics.height)
    }

    override func mouseDown(with event: NSEvent) {
        presentMenu()
    }

    @objc private func showMenu(_ sender: Any?) {
        presentMenu()
    }

    override func accessibilityPerformPress() -> Bool {
        presentMenu()
        return true
    }

    private func presentMenu() {
        setPressedFeedback(true)
        defer { setPressedFeedback(false) }
        popupMenu.popUp(positioning: nil, at: NSPoint(x: bounds.maxX, y: bounds.minY), in: self)
    }
}

/// A plain symbol button for the toolbar's trailing cluster.
///
/// The toolbar used to carry exactly one interactive control on the right — the
/// `···` overflow — with Outline, Find, and everything else folded inside it.
/// That is a lot of the app to hide behind an unlabelled glyph in a window that
/// has room for three more buttons, and it made the two panels a reader reaches
/// for constantly cost a menu each time.
///
/// It shares `ToolbarInteractiveButton`'s hover plate and press feedback with
/// `ToolbarMenuButton`, and its 30pt square is the same geometry, so the
/// cluster reads as one row of controls rather than as a row of near-misses.
final class ToolbarActionButton: ToolbarInteractiveButton {
    private enum Metrics {
        static let side: CGFloat = 30
        static let cornerRadius: CGFloat = 7
    }

    /// Lit the way the task ring lights when its panel is open, so "this panel
    /// is showing" is said the same way by every control that owns one.
    var isOn: Bool = false {
        didSet {
            guard isOn != oldValue else { return }
            refreshInteractionFeedback(animated: window != nil)
            needsDisplay = true
        }
    }

    override func styleSheetDidChange() { applyTint() }

    init(symbol: String, label: String, help: String, target: AnyObject?, action: Selector) {
        super.init(frame: .zero)
        feedbackInsetX = 1
        feedbackInsetY = 1
        feedbackCornerRadius = Metrics.cornerRadius
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .medium))
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        bezelStyle = .accessoryBarAction
        controlSize = .regular
        isBordered = false
        self.target = target
        self.action = action
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilityHelp(help)
        toolTip = help
        applyTint()
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Metrics.side, height: Metrics.side)
    }

    private func applyTint() {
        contentTintColor = isOn ? styleSheet.accent : nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTint()
    }
}
