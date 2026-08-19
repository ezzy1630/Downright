import AppKit
import MarkdownRender

/// The first-run setup panel.
///
/// Everything here could be left to the user to find in System Settings, and
/// that is exactly what made the old install bad: an app downloaded from a
/// website and dragged into Applications had no file association, no `down`,
/// and Quick Look extensions the system had never been told to enable.  One
/// panel, two checkboxes, one button — and the parts that need no decision
/// (registering the extensions, resetting the icon cache) just happen.
///
/// It is shown once.  "Not now" is an answer, and the panel does not come back
/// uninvited; Settings → General keeps every step available afterwards.
@MainActor
final class SetupWindowController: NSWindowController {
    /// Called once the panel is finished with, whatever the user chose.
    var onFinish: (() -> Void)?

    private enum Layout {
        static let windowWidth: CGFloat = 520
        static let inset: CGFloat = 34
        /// Width available to a step's wrapped detail line, which hangs under
        /// the checkbox label rather than under its box.
        static let detailWidth = windowWidth - inset * 2 - 20
    }

    /// A step the user can decline.  Quick Look is not one of these: it needs
    /// no decision and carries no cost, so it runs regardless and is reported
    /// rather than offered.
    enum Step: CaseIterable {
        case moveToApplications
        case defaultApplication
        case commandLineTool
        case agentIntegration

        var title: String {
            switch self {
            case .moveToApplications: return "Move Downright to your Applications folder"
            case .defaultApplication: return "Open Markdown files with Downright"
            case .commandLineTool: return "Install the down command line tool"
            case .agentIntegration: return "Open agent edits in Downright"
            }
        }

        var icon: String {
            switch self {
            case .moveToApplications: return "arrow.down.app"
            case .defaultApplication: return "doc.text"
            case .commandLineTool: return "terminal"
            case .agentIntegration: return "sparkles"
            }
        }

        var detail: String {
            switch self {
            case .moveToApplications:
                return "Downright is running from a temporary copy. Nothing below can stick until it lives in Applications."
            case .defaultApplication:
                return "Double-clicking a .md file opens it here. Other Markdown flavours are left to the apps that own them."
            case .commandLineTool:
                return "Opens files from the terminal: down PLAN.md"
            case .agentIntegration:
                return "Coding agents like Claude Code show Markdown here as they write it. Adds a hook to ~/.claude/settings.json."
            }
        }

        /// Steps start ticked, because every one of them is a registration this
        /// app is asking to make on its own behalf — except the agent hook,
        /// which edits *another* tool's configuration file.  Turning that on by
        /// default would be helping yourself to somebody else's settings.
        var isPreselected: Bool { self != .agentIntegration }

        /// Whether this step is worth showing at all on this Mac right now.
        var isApplicable: Bool {
            switch self {
            case .moveToApplications:
                return SystemIntegration.isAppBundle
                    && !SystemIntegration.isPermanentlyInstalled
                    && SystemIntegration.applicationsDestination != nil
            case .defaultApplication:
                return !SystemIntegration.isDefaultMarkdownHandler
            case .commandLineTool:
                return SystemIntegration.commandLineToolIsBundled
                    && !SystemIntegration.isCommandLineToolInstalled
            case .agentIntegration:
                // The hook runs `down`, so it is only offerable once the CLI
                // exists — either already installed, or about to be by the step
                // above, which runs first.
                return (SystemIntegration.isCommandLineToolInstalled || Step.commandLineTool.isApplicable)
                    && !AgentIntegration.isInstalled
            }
        }
    }

    private let steps: [Step]
    private var checkboxes: [Step: NSButton] = [:]
    private var statusLabels: [Step: NSTextField] = [:]
    private let quickLookStatus = NSTextField(wrappingLabelWithString: "")
    private let quickLookIcon = NSImageView()
    private let primaryButton = NSButton()
    private let secondaryButton = NSButton()
    private let spinner = NSProgressIndicator()
    private var sheet: StyleSheet
    private var isWorking = false

    /// Nil when there is nothing left to set up — the caller skips the panel
    /// entirely rather than showing a card with an empty checklist.
    static func makeIfNeeded() -> SetupWindowController? {
        let applicable = Step.allCases.filter(\.isApplicable)
        // A move is never the only reason to interrupt someone: if the app is
        // already where it belongs and the rest is done, there is no panel.
        guard !applicable.isEmpty else { return nil }
        return SetupWindowController(steps: applicable)
    }

    private init(steps: [Step]) {
        self.steps = steps
        self.sheet = StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Layout.windowWidth, height: 400),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Downright"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isRestorable = false
        super.init(window: window)

        // The card is painted in theme colours but its buttons are drawn by
        // AppKit, so the appearance has to be settled before anything reads a
        // colour — including the sheet the labels below are built from.
        let theme = ThemeStore.shared.current
        window.applyThemeAppearance(for: theme)
        sheet = StyleSheet(theme: theme, appearance: window.effectiveAppearance)

        window.delegate = self
        let content = buildContent()
        window.contentView = content

        // Height follows the checklist.  Two steps and no Quick Look line is a
        // shorter panel than three and one, and a fixed height leaves the
        // difference as dead air above the buttons.
        content.layoutSubtreeIfNeeded()
        let size = NSSize(width: Layout.windowWidth, height: ceil(content.fittingSize.height))
        window.setContentSize(size)
        window.minSize = size
        window.maxSize = size
        window.backgroundColor = sheet.background
        window.initialFirstResponder = primaryButton
        window.center()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Building

    private func buildContent() -> NSView {
        let root = NSView()
        // A fixed width, so every wrapping label resolves a real intrinsic
        // height and `fittingSize` can be trusted.
        root.widthAnchor.constraint(equalToConstant: Layout.windowWidth).isActive = true

        let brand = NSImageView()
        brand.image = NSApp.applicationIconImage
        brand.imageScaling = .scaleProportionallyUpOrDown
        brand.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: "Welcome to Downright")
        title.font = .systemFont(ofSize: 21, weight: .semibold)
        title.textColor = sheet.text

        let subtitle = NSTextField(wrappingLabelWithString: subtitleText())
        subtitle.font = .systemFont(ofSize: 13)
        subtitle.textColor = sheet.textSecondary

        let heading = NSStackView(views: [title, subtitle])
        heading.orientation = .vertical
        heading.alignment = .leading
        heading.spacing = 3

        let header = NSStackView(views: [brand, heading])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14

        let checklist = NSStackView(views: steps.map(makeStepRow))
        checklist.orientation = .vertical
        checklist.alignment = .leading
        checklist.spacing = 16

        let stack = NSStackView(views: [header, makeDivider(), checklist])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(18, after: header)

        // Quick Look gets a status line rather than a checkbox: there is no
        // sensible reason to decline it and no cost to leaving it on, so
        // presenting it as a decision would be a decision made for show.
        if SystemIntegration.quickLookExtensionsAreBundled {
            stack.addArrangedSubview(makeQuickLookRow())
        }

        configure(secondaryButton, title: "Not now", isDefault: false, action: #selector(declineSetup))
        configure(primaryButton, title: "Continue", isDefault: true, action: #selector(runSetup))

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let buttons = NSStackView(views: [spinner, NSView(), secondaryButton, primaryButton])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = 10
        buttons.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(stack)
        root.addSubview(buttons)

        NSLayoutConstraint.activate([
            brand.widthAnchor.constraint(equalToConstant: 52),
            brand.heightAnchor.constraint(equalToConstant: 52),
            subtitle.widthAnchor.constraint(equalToConstant: Layout.windowWidth - Layout.inset * 2 - 66),

            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Layout.inset),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Layout.inset),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 30),

            // An unbroken top-to-bottom chain: without it the root view has no
            // height to fit to and the window falls back to whatever it was
            // created with.
            buttons.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: 26),
            buttons.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: Layout.inset),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -Layout.inset),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -24),
        ])
        return root
    }

    private func subtitleText() -> String {
        steps.contains(.moveToApplications)
            ? "One thing first — Downright isn’t installed yet."
            : "Two quick things and you’re set up."
    }

    private func makeDivider() -> NSView {
        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = sheet.rule
            .withAlphaComponent(sheet.increaseContrast ? 0.6 : 0.4).cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true
        divider.widthAnchor.constraint(equalToConstant: Layout.windowWidth - Layout.inset * 2).isActive = true
        return divider
    }

    private func makeStepRow(_ step: Step) -> NSView {
        let checkbox = NSButton(checkboxWithTitle: step.title, target: nil, action: nil)
        checkbox.font = .systemFont(ofSize: 13, weight: .medium)
        checkbox.contentTintColor = sheet.text
        checkbox.state = step.isPreselected ? .on : .off
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkboxes[step] = checkbox

        let detail = NSTextField(wrappingLabelWithString: step.detail)
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = sheet.textFaint
        detail.translatesAutoresizingMaskIntoConstraints = false

        // Wrapping, not single-line: some outcomes need a whole sentence, and
        // the one that names a System Settings path needs two.
        let status = NSTextField(wrappingLabelWithString: "")
        status.font = .systemFont(ofSize: 11, weight: .medium)
        status.textColor = sheet.textSecondary
        status.isHidden = true
        status.translatesAutoresizingMaskIntoConstraints = false
        statusLabels[step] = status

        let column = NSStackView(views: [checkbox, detail, status])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 2
        column.setCustomSpacing(4, after: detail)
        column.translatesAutoresizingMaskIntoConstraints = false

        // The detail line hangs under the checkbox label, not under its box.
        detail.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 20).isActive = true
        status.leadingAnchor.constraint(equalTo: column.leadingAnchor, constant: 20).isActive = true
        detail.widthAnchor.constraint(equalToConstant: Layout.detailWidth).isActive = true
        status.widthAnchor.constraint(equalToConstant: Layout.detailWidth).isActive = true
        return column
    }

    private func makeQuickLookRow() -> NSView {
        quickLookIcon.image = NSImage(systemSymbolName: "eye", accessibilityDescription: nil)
        quickLookIcon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        quickLookIcon.contentTintColor = sheet.textFaint
        quickLookIcon.translatesAutoresizingMaskIntoConstraints = false
        quickLookIcon.setAccessibilityHidden(true)

        quickLookStatus.stringValue =
            "Quick Look previews and Finder icons for Markdown — set up for you."
        quickLookStatus.font = .systemFont(ofSize: 11)
        quickLookStatus.textColor = sheet.textFaint
        quickLookStatus.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [quickLookIcon, quickLookStatus])
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 6
        quickLookStatus.widthAnchor.constraint(equalToConstant: Layout.detailWidth).isActive = true
        return row
    }

    private func configure(_ button: NSButton, title: String, isDefault: Bool, action: Selector) {
        button.title = title
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
        if isDefault {
            button.keyEquivalent = "\r"
            button.hasDestructiveAction = false
        }
    }

    // MARK: - Actions

    @objc private func declineSetup() {
        finish()
    }

    @objc private func runSetup() {
        guard !isWorking else { return }

        // A move invalidates every path the other steps would write, so it runs
        // alone: copy, relaunch, and let the fresh instance — which sees an
        // unanswered setup — offer the rest from its permanent home.
        if isChecked(.moveToApplications) {
            performMove()
            return
        }

        isWorking = true
        setControlsEnabled(false)
        spinner.startAnimation(nil)
        primaryButton.title = "Setting up…"

        Task { @MainActor in
            defer {
                spinner.stopAnimation(nil)
                isWorking = false
                primaryButton.isEnabled = true
                window?.makeFirstResponder(primaryButton)
            }

            if isChecked(.defaultApplication) {
                let failure = await SystemIntegration.makeDefaultMarkdownHandler()
                report(
                    .defaultApplication,
                    success: failure == nil && SystemIntegration.isDefaultMarkdownHandler,
                    successText: "Markdown files now open in Downright.",
                    failureText: failure.map { "Couldn’t set the default: \($0.localizedDescription)" }
                        ?? "macOS declined the change. Finder’s Get Info → Open With can set it."
                )
            }

            if isChecked(.commandLineTool) {
                installCommandLineTool()
            }

            // After the CLI, never before: the hook stores an absolute path to
            // `down`, and there is nothing to point at until the symlink exists.
            if isChecked(.agentIntegration) {
                installAgentIntegration()
            }

            await registerQuickLook()

            primaryButton.title = "Done"
            primaryButton.action = #selector(finishFromButton)
            secondaryButton.isHidden = true
            window?.makeFirstResponder(primaryButton)
        }
    }

    private func performMove() {
        setControlsEnabled(false)
        spinner.startAnimation(nil)
        primaryButton.title = "Moving…"
        do {
            // Terminates this process once the copy is running; nothing after
            // that point executes.
            try SystemIntegration.moveToApplications { [weak self] error in
                self?.reportMoveFailure(
                    "Copied to Applications, but the new copy wouldn’t start: \(error.localizedDescription). Open it from Applications yourself."
                )
            }
        } catch {
            reportMoveFailure(
                "Couldn’t move the app: \(error.localizedDescription). Drag it to Applications yourself, then reopen it."
            )
        }
    }

    private func reportMoveFailure(_ text: String) {
        spinner.stopAnimation(nil)
        setControlsEnabled(true)
        primaryButton.title = "Continue"
        report(.moveToApplications, success: false, successText: "", failureText: text)
        // Unticked so a second Continue proceeds with the steps that can still
        // work from where the app is, rather than retrying the move forever.
        checkboxes[.moveToApplications]?.state = .off
    }

    private func installCommandLineTool() {
        do {
            let result = try SystemIntegration.installCommandLineTool()
            guard !result.linked.isEmpty else {
                report(
                    .commandLineTool, success: false, successText: "",
                    failureText: "Something else already owns \(result.skipped.joined(separator: " and ")) in \(result.directory.path)."
                )
                return
            }
            let names = result.linked.joined(separator: " and ")
            // Reporting a success the terminal will contradict is worse than
            // reporting the caveat, so an off-PATH directory says so.
            let text = result.isOnPath
                ? "Installed \(names) in \(result.directory.path)."
                : "Installed in \(result.directory.path) — add it to your PATH to use \(names)."
            report(.commandLineTool, success: result.isOnPath, successText: text, failureText: text)
        } catch {
            report(
                .commandLineTool, success: false, successText: "",
                failureText: "Couldn’t install it: \(error.localizedDescription)"
            )
        }
    }

    private func installAgentIntegration() {
        do {
            try AgentIntegration.install()
            report(
                .agentIntegration, success: true,
                successText: "Agent edits now open in Downright.",
                failureText: ""
            )
        } catch {
            // The most likely failure is the CLI step above having failed, which
            // has already reported itself; say what this step needs rather than
            // repeating that.
            report(
                .agentIntegration, success: false, successText: "",
                failureText: error.localizedDescription
            )
        }
    }

    private func registerQuickLook() async {
        guard SystemIntegration.quickLookExtensionsAreBundled else { return }
        quickLookStatus.stringValue = "Registering Quick Look previews and Finder icons…"

        let enabled: Bool = await withCheckedContinuation { continuation in
            SystemIntegration.registerWithSystem(resetThumbnailCache: true) { enabled in
                continuation.resume(returning: enabled)
            }
        }

        if enabled {
            quickLookIcon.image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: nil)
            quickLookIcon.contentTintColor = sheet.accent
            quickLookStatus.stringValue =
                "Quick Look previews and Finder icons are on. Press space on a .md file to try it."
        } else {
            // The extension is installed but the system has not switched it on,
            // which only the user can do — so say where, precisely.
            quickLookIcon.image = NSImage(systemSymbolName: "exclamationmark.circle", accessibilityDescription: nil)
            quickLookIcon.contentTintColor = sheet.textSecondary
            quickLookStatus.stringValue =
                "Quick Look needs one switch from you: System Settings → General → Login Items & Extensions → Quick Look."
            showQuickLookSettingsShortcut()
        }
    }

    private func showQuickLookSettingsShortcut() {
        secondaryButton.isHidden = false
        secondaryButton.title = "Open Settings"
        secondaryButton.action = #selector(openQuickLookSettings)
    }

    @objc private func openQuickLookSettings() {
        SystemIntegration.openQuickLookSettings()
    }

    @objc private func finishFromButton() {
        finish()
    }

    // MARK: - Plumbing

    private func isChecked(_ step: Step) -> Bool {
        checkboxes[step]?.state == .on
    }

    private func setControlsEnabled(_ enabled: Bool) {
        primaryButton.isEnabled = enabled
        secondaryButton.isEnabled = enabled
        for checkbox in checkboxes.values { checkbox.isEnabled = enabled }
    }

    private func report(_ step: Step, success: Bool, successText: String, failureText: String) {
        guard let label = statusLabels[step] else { return }
        label.stringValue = success ? successText : failureText
        label.textColor = success ? sheet.accent : sheet.textSecondary
        label.isHidden = false
    }

    private func finish() {
        Preferences.shared.update { $0.hasAnsweredSetup = true }
        onFinish?()
        window?.close()
    }
}

extension SetupWindowController: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        // Closing the panel mid-run would leave half a setup behind with no
        // way to see how it ended.
        !isWorking
    }

    func windowWillClose(_ notification: Notification) {
        // Covers the red button, which never reaches `finish()`.
        guard !Preferences.shared.values.hasAnsweredSetup else { return }
        Preferences.shared.update { $0.hasAnsweredSetup = true }
        onFinish?()
    }
}
