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
    private enum Metrics {
        static let height: CGFloat = 26
        static let cornerRadius: CGFloat = 13
        static let horizontalPadding: CGFloat = 11
        static let iconSize: CGFloat = 13
    }

    private let shell = NSView()
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
        let textWidth = ceil(label.attributedStringValue.size().width)
        let iconWidth: CGFloat = {
            if case .progress = currentModel { return Metrics.iconSize + 3 }
            return Metrics.iconSize + 3
        }()
        return NSSize(width: Metrics.horizontalPadding * 2 + iconWidth + textWidth, height: Metrics.height)
    }

    init() {
        self.sheet = UpdateStatusPill.makeSheet()
        super.init(frame: .zero)
        wantsLayer = true

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = Metrics.cornerRadius
        addSubview(shell)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: Metrics.iconSize, weight: .medium)
        iconView.contentTintColor = .secondaryLabelColor
        shell.addSubview(iconView)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 11.5, weight: .semibold)
        label.maximumNumberOfLines = 1
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
        setButtonType(.momentaryChange)
        focusRingType = .default
        target = self
        action = #selector(clicked(_:))
        setAccessibilityRole(.button)
        setAccessibilityHelp("Open the update panel")

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

    // MARK: - Coordinator binding

    private func refreshFromCoordinator() {
        let model = UpdateCoordinator.shared.pillModel
        let changed = model != currentModel
        currentModel = model
        refreshAppearance()
        guard changed else { return }
        let visible = model != UpdatePillModel.hidden
        if visible {
            isHidden = false
            setAccessibilityLabel(accessibilityLabel(for: model))
            setAccessibilityValue(label.stringValue)
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
            iconView.contentTintColor = .systemOrange
            label.textColor = .systemOrange
            label.stringValue = "Update Failed"
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            iconView.isHidden = false
            shell.layer?.backgroundColor = NSColor.systemOrange.withAlphaComponent(contrast ? 0.22 : 0.12).cgColor
            shell.layer?.borderWidth = contrast ? 1 : 0
            shell.layer?.borderColor = NSColor.systemOrange.cgColor

        case .informational(let version):
            iconView.image = NSImage(systemSymbolName: "info.circle.fill", accessibilityDescription: "Update information")
            iconView.contentTintColor = sheet.accent
            label.textColor = sheet.textSecondary
            label.stringValue = "Update \(version)"
            progressIndicator.stopAnimation(nil)
            progressIndicator.isHidden = true
            iconView.isHidden = false
            shell.layer?.backgroundColor = sheet.surface.cgColor
            shell.layer?.borderWidth = contrast ? 1 : 0
            shell.layer?.borderColor = sheet.rule.cgColor
        }
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
