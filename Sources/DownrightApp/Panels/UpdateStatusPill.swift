import AppKit
import MarkdownRender

/// A compact, themed status control for the update flow.  One instance lives
/// in every document titlebar and one in the start window; each observes the
/// coordinator and renders the same `pillModel`, so all surfaces agree.
///
/// It remains absent (zero width, hidden) when the coordinator is idle, and
/// appears with a restrained fade/slide for the states the spec surfaces:
/// "Update 1.1", a progress ring, "Restart to Update", and a warning/retry
/// badge.  All motion honors Reduce Motion.
@MainActor
final class UpdateStatusPill: NSButton {
    enum Presentation {
        case standard
        /// The start window already has a strong task hierarchy. An update
        /// failure stays actionable, but collapses to a quiet warning button
        /// instead of competing with Open/New.
        case compactWarning
    }

    private enum Metrics {
        static let height: CGFloat = 26
        static let cornerRadius: CGFloat = 13
        static let horizontalPadding: CGFloat = 11
        static let iconSize: CGFloat = 13
        static let compactWarningWidth: CGFloat = 34
    }

    private let presentation: Presentation
    private let shell = NSView()
    /// The same hover/press wash every neighbouring toolbar control uses, so
    /// the pill answers the pointer instead of sitting inert among controls
    /// that do (§11.3).
    private let feedbackLayer = CALayer()
    private var interaction: ToolbarChromePolicy.InteractionState = .idle {
        didSet {
            guard interaction != oldValue else { return }
            applyFeedback()
        }
    }
    private var trackingArea: NSTrackingArea?
    private let iconView = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()
    private var widthConstraint: NSLayoutConstraint!
    private var stateObserver: NSObjectProtocol?
    private var sheet: StyleSheet
    private var currentModel: UpdatePillModel?

    override var intrinsicContentSize: NSSize {
        guard let currentModel, currentModel != UpdatePillModel.hidden else {
            // Absent-but-in-the-toolbar: a zero width makes AppKit log an
            // ambiguous-layout warning on every launch. 1 is invisible yet
            // unambiguous; the pill's own width constraint collapses it.
            return NSSize(width: 1, height: Metrics.height)
        }
        if presentation == .compactWarning, currentModel == .warning {
            return NSSize(width: Metrics.compactWarningWidth, height: Metrics.height)
        }
        // NSTextField's attributed-string measurement can under-report a
        // fallback glyph such as the warning copy at small sizes. fittingSize
        // reflects the actual cell layout; retain the explicit measurement as
        // a lower-bound guard for custom fonts/themes.
        let textWidth = ceil(max(
            label.fittingSize.width,
            label.attributedStringValue.size().width
        )) + 2
        let iconWidth: CGFloat = {
            if case .progress = currentModel { return Metrics.iconSize + 3 }
            return Metrics.iconSize + 3
        }()
        return NSSize(width: Metrics.horizontalPadding * 2 + iconWidth + textWidth, height: Metrics.height)
    }

    init(presentation: Presentation = .standard) {
        self.presentation = presentation
        self.sheet = UpdateStatusPill.makeSheet()
        super.init(frame: .zero)
        wantsLayer = true

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = Metrics.cornerRadius
        shell.layer?.cornerCurve = .continuous
        feedbackLayer.cornerRadius = Metrics.cornerRadius
        feedbackLayer.cornerCurve = .continuous
        feedbackLayer.opacity = 0
        shell.layer?.addSublayer(feedbackLayer)
        addSubview(shell)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Metrics.iconSize, weight: .medium)
        iconView.contentTintColor = .secondaryLabelColor
        shell.addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = PanelFont.system(11.5, weight: .semibold)
        label.maximumNumberOfLines = 1
        label.usesSingleLineMode = true
        label.isEditable = false
        label.isSelectable = false
        label.isBezeled = false
        label.drawsBackground = false
        label.lineBreakMode = .byTruncatingTail
        shell.addSubview(label)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        shell.addSubview(progressIndicator)

        isBordered = false
        // The pill owns its content through `shell` and `label`; leaving the
        // NSButton title in place draws a second, colliding string underneath.
        title = ""
        setButtonType(.momentaryChange)
        focusRingType = .default
        target = self
        action = #selector(clicked(_:))
        setAccessibilityRole(.button)
        setAccessibilityHelp("Open the update panel")
        // Pointer users get the same sentence VoiceOver does.
        toolTip = "Open the update panel"

        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: Metrics.horizontalPadding),
            iconView.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: Metrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: Metrics.iconSize),

            label.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            label.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: shell.trailingAnchor, constant: -Metrics.horizontalPadding),

            progressIndicator.leadingAnchor.constraint(equalTo: iconView.leadingAnchor),
            progressIndicator.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalToConstant: Metrics.iconSize + 2),
            progressIndicator.heightAnchor.constraint(equalToConstant: Metrics.iconSize + 2),
        ])

        widthConstraint = widthAnchor.constraint(equalToConstant: 0)
        widthConstraint.isActive = true
        heightAnchor.constraint(equalToConstant: Metrics.height).isActive = true
        setHidden(true, animated: false)

        stateObserver = NotificationCenter.default.addObserver(
            forName: UpdateCoordinator.stateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshFromCoordinator() }
        }
        refreshFromCoordinator()

        viewDidChangeEffectiveAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    deinit {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    }

    private static func makeSheet() -> StyleSheet {
        StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sheet = Self.makeSheet()
        refreshAppearance()
    }

    @objc private func clicked(_ sender: Any?) {
        UpdateCoordinator.shared.showPanel()
    }

    // MARK: - Pointer feedback

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        feedbackLayer.frame = shell.bounds
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea(&trackingArea, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect])
    }

    override func mouseEntered(with event: NSEvent) { interaction = .hover }
    override func mouseExited(with event: NSEvent) { interaction = .idle }

    override func mouseDown(with event: NSEvent) {
        interaction = .pressed
        super.mouseDown(with: event)
        interaction = bounds.contains(convert(event.locationInWindow, from: nil)) ? .hover : .idle
    }

    private func applyFeedback() {
        feedbackLayer.backgroundColor = sheet.text.cgColor
        let opacity = ToolbarChromePolicy.feedbackOpacity(
            for: interaction, increaseContrast: sheet.increaseContrast
        )
        guard !sheet.reduceMotion, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            feedbackLayer.opacity = opacity
            CATransaction.commit()
            return
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = feedbackLayer.presentation()?.opacity ?? feedbackLayer.opacity
        fade.toValue = opacity
        fade.duration = interaction == .pressed
            ? ToolbarChromePolicy.pressInDuration
            : ToolbarChromePolicy.hoverDuration
        fade.timingFunction = ToolbarChromePolicy.timingFunction()
        feedbackLayer.add(fade, forKey: "feedback")
        feedbackLayer.opacity = opacity
    }

    // MARK: - Coordinator binding

    private func refreshFromCoordinator() {
        let model = UpdateCoordinator.shared.pillModel
        let changed = model != currentModel
        currentModel = model
        refreshAppearance()
        guard changed else { return }
        let visible = model != UpdatePillModel.hidden
        // Set in both branches: a hidden control that still reports the last
        // visible state is a stale answer for VoiceOver.
        setAccessibilityLabel(accessibilityLabel(for: model))
        setAccessibilityValue(visible ? label.stringValue : "")
        if visible { isHidden = false }
        let reduce = sheet.reduceMotion
        // Collapse to 1pt, never 0: the toolbar auto-measures this view and a
        // zero-width frame logs an ambiguous-layout warning on every launch.
        let targetWidth: CGFloat = visible ? intrinsicContentSize.width : 1
        if reduce {
            widthConstraint.constant = targetWidth
            if !visible { isHidden = true }
            shell.alphaValue = visible ? 1 : 0
            layoutSubtreeIfNeeded()
        } else {
            widthConstraint.animator().constant = targetWidth
            shell.animator().alphaValue = visible ? 1 : 0
            if !visible {
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.standard) { [weak self] in
                    guard let self, self.currentModel == .hidden else { return }
                    self.isHidden = true
                }
            }
        }
    }

    private func refreshAppearance() {
        guard let model = currentModel else { return }
        let contrast = sheet.increaseContrast
        switch model {
        case .available(let version):
            iconView.image = NSImage(systemSymbolName: "arrow.down.circle.fill", accessibilityDescription: "Update available")
            iconView.contentTintColor = sheet.accent
            label.textColor = sheet.textSecondary
            label.stringValue = "Update \(version)"
            label.isHidden = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            iconView.isHidden = false
            shell.layer?.backgroundColor = sheet.surface
                .blended(withFraction: contrast ? 0.5 : 0.3, of: sheet.accent)?.cgColor
                ?? sheet.surface.cgColor
            shell.layer?.borderWidth = 0

        case .restartToUpdate:
            iconView.image = NSImage(systemSymbolName: "arrow.clockwise.circle.fill", accessibilityDescription: "Restart to update")
            iconView.contentTintColor = sheet.accent
            label.textColor = sheet.text
            label.stringValue = "Restart to Update"
            label.isHidden = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            iconView.isHidden = false
            shell.layer?.backgroundColor = sheet.surface
                .blended(withFraction: contrast ? 0.5 : 0.3, of: sheet.accent)?.cgColor
                ?? sheet.surface.cgColor
            shell.layer?.borderWidth = 0

        case .progress(let title, let fraction):
            label.textColor = sheet.textSecondary
            label.stringValue = title
            label.isHidden = false
            iconView.isHidden = true
            progressIndicator.isHidden = false
            if let fraction {
                progressIndicator.style = .bar
                progressIndicator.doubleValue = fraction * 100
            } else {
                progressIndicator.style = .spinning
                progressIndicator.startAnimation(nil)
            }
            shell.layer?.backgroundColor = sheet.surface.cgColor
            shell.layer?.borderWidth = contrast ? 1 : 0
            shell.layer?.borderColor = sheet.rule.cgColor

        case .warning:
            iconView.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Update failed")
            // The theme owns the warning colour; a raw system orange ignores
            // the warm light and dark palettes entirely (§11.3).
            let warning = sheet.calloutColor(.warning)
            iconView.contentTintColor = warning
            label.textColor = warning
            label.stringValue = "Update Failed"
            label.isHidden = presentation == .compactWarning
            toolTip = presentation == .compactWarning
                ? "Update failed — click for details"
                : "Open the update panel"
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            iconView.isHidden = false
            if presentation == .compactWarning {
                shell.layer?.backgroundColor = warning
                    .panelAlpha(contrast ? 0.12 : 0.07, increaseContrast: false).cgColor
                shell.layer?.borderWidth = 1
                shell.layer?.borderColor = warning
                    .withAlphaComponent(contrast ? 0.55 : 0.32).cgColor
            } else {
                shell.layer?.backgroundColor = warning
                    .panelAlpha(contrast ? 0.22 : 0.12, increaseContrast: false).cgColor
                shell.layer?.borderWidth = contrast ? 1 : 0
                shell.layer?.borderColor = warning.cgColor
            }

        case .informational(let version):
            iconView.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "Update information")
            iconView.contentTintColor = sheet.accent
            label.textColor = sheet.textSecondary
            label.stringValue = "Update \(version)"
            label.isHidden = false
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            iconView.isHidden = false
            shell.layer?.backgroundColor = sheet.surface.cgColor
            shell.layer?.borderWidth = contrast ? 1 : 0
            shell.layer?.borderColor = sheet.rule.cgColor
        }
        applyFeedback()
        needsDisplay = true
    }

    private func accessibilityLabel(for model: UpdatePillModel?) -> String {
        switch model {
        case .available(let version): return "Update \(version) available"
        case .restartToUpdate: return "Update ready. Restart Downright to update"
        case .progress(let title, _): return title
        case .warning: return "Update failed. Open the update panel for details"
        case .informational(let version): return "Update \(version) information"
        case .hidden, nil: return "No update status"
        }
    }

    private func setHidden(_ hidden: Bool, animated: Bool) {
        isHidden = hidden
        shell.alphaValue = hidden ? 0 : 1
        // 1pt rather than 0 — see `refreshFromCoordinator`.
        widthConstraint.constant = hidden ? 1 : intrinsicContentSize.width
    }
}
