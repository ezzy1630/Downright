import AppKit
import MarkdownCore
import MarkdownRender

private enum UpdateWindowLayout {
    static let width: CGFloat = 540
    static let regularHeight: CGFloat = 480
    static let failureHeight: CGFloat = 340
    static let minimumHeight: CGFloat = 320
}

/// The one nonmodal update surface.  Documents stay usable while it is open;
/// it never activates the app over another application, and closing it is
/// always safe (any pending Sparkle choice resolves to "later").
///
/// The panel is a pure projection of the coordinator's state machine: it
/// rebuilds its content when the *kind* of state changes and patches only the
/// progress numbers while a download advances.
@MainActor
final class UpdateWindowController: NSWindowController, NSWindowDelegate {
    private weak var coordinator: UpdateCoordinator?
    private var panelView: UpdatePanelView!
    private var stateObserver: NSObjectProtocol?

    convenience init(coordinator: UpdateCoordinator) {
        let view = UpdatePanelView(coordinator: coordinator)
        let window = NSWindow(
            contentRect: NSRect(
                x: 0, y: 0,
                width: UpdateWindowLayout.width,
                height: UpdateWindowLayout.regularHeight
            ),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Updates"
        window.titlebarAppearsTransparent = true
        // The panel has its own branded header. Leaving the native title visible
        // puts a second "Updates" label directly above it in the full-content
        // titlebar and makes the icon/title stack look collided.
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 480, height: UpdateWindowLayout.minimumHeight)
        window.isRestorable = false
        window.contentView = view
        window.center()
        self.init(window: window)
        panelView = view
        self.coordinator = coordinator
        // Closing the window must resolve whatever Sparkle capability is
        // pending — otherwise the updater waits on a reply nobody can give and
        // `canCheckForUpdates` stays false until the app restarts.
        window.delegate = self
        stateObserver = NotificationCenter.default.addObserver(
            forName: UpdateCoordinator.stateDidChange, object: coordinator, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.panelView?.refresh() }
        }
    }

    deinit {
        if let stateObserver { NotificationCenter.default.removeObserver(stateObserver) }
    }

    func windowWillClose(_ notification: Notification) {
        coordinator?.userDidDismissPanel()
    }

    /// Esc closes the update window, like every other summonable surface.
    override func cancelOperation(_ sender: Any?) {
        window?.performClose(sender)
    }
}

// MARK: - Root view

@MainActor
private final class UpdatePanelView: NSView {
    private weak var coordinator: UpdateCoordinator?
    private let header = UpdatePanelHeader()
    private let contentContainer = NSView()
    private let footer = UpdatePanelFooter()
    private var sheet: StyleSheet
    private var lastKind: UpdatePanelContent.Kind?

    init(coordinator: UpdateCoordinator) {
        self.coordinator = coordinator
        self.sheet = UpdatePanelView.makeSheet()
        super.init(frame: .zero)

        wantsLayer = true
        header.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.translatesAutoresizingMaskIntoConstraints = false
        footer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)
        addSubview(contentContainer)
        addSubview(footer)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 18),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 14),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -22),
            footer.topAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: 14),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -18),
        ])
        refresh()
        viewDidChangeEffectiveAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    private static func makeSheet() -> StyleSheet {
        StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sheet = Self.makeSheet()
        window?.backgroundColor = sheet.background
        layer?.backgroundColor = sheet.background.cgColor
        header.apply(sheet: sheet)
        footer.apply(sheet: sheet)
    }

    func refresh() {
        guard let coordinator else { return }
        header.apply(sheet: sheet)
        header.update(coordinator: coordinator)

        let content = UpdatePanelContent(coordinator: coordinator)
        // Progress keeps the same subview and only patches numbers.
        if content.kind == lastKind, case .downloading = content.kind,
           let existing = contentContainer.subviews.first as? UpdateProgressView {
            existing.update(received: content.received, expected: content.expected)
            return
        }
        lastKind = content.kind
        for subview in contentContainer.subviews { subview.removeFromSuperview() }
        let contentView = content.makeView(coordinator: coordinator, sheet: sheet)
        contentView.translatesAutoresizingMaskIntoConstraints = false
        contentContainer.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: contentContainer.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: contentContainer.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: contentContainer.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: contentContainer.bottomAnchor),
        ])
        footer.update(coordinator: coordinator)
        resizeForContent(content.kind)
    }

    private func resizeForContent(_ kind: UpdatePanelContent.Kind) {
        guard let window else { return }
        let desiredHeight: CGFloat = kind == .failed
            ? UpdateWindowLayout.failureHeight
            : UpdateWindowLayout.regularHeight
        guard abs(window.frame.height - desiredHeight) > 0.5 else { return }

        var frame = window.frame
        frame.origin.y += (frame.height - desiredHeight) / 2
        frame.size.height = desiredHeight
        window.setFrame(frame, display: true, animate: false)
    }
}

// MARK: - Header

@MainActor
private final class UpdatePanelHeader: NSView {
    private let iconView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let versionsLabel = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSApp.applicationIconImage
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.wantsLayer = true
        iconView.layer?.cornerRadius = 10
        iconView.layer?.cornerCurve = .continuous
        iconView.layer?.masksToBounds = true
        iconView.layer?.shadowColor = NSColor.black.cgColor
        iconView.layer?.shadowOpacity = 0.20
        iconView.layer?.shadowOffset = CGSize(width: 0, height: -1.5)
        iconView.layer?.shadowRadius = 4
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        addSubview(titleLabel)

        versionsLabel.translatesAutoresizingMaskIntoConstraints = false
        versionsLabel.font = PanelFont.secondary
        addSubview(versionsLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            versionsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            versionsLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 3),
            versionsLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func apply(sheet: StyleSheet) {
        titleLabel.textColor = sheet.text
        versionsLabel.textColor = sheet.textSecondary
    }

    func update(coordinator: UpdateCoordinator) {
        let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"

        var target: (String, String)?
        switch coordinator.phase {
        case .available(let metadata, _), .informational(let metadata):
            target = (metadata.displayVersionString, metadata.versionString)
        case .idle, .downloading, .extracting, .readyToRelaunch, .waitingForTermination, .installing:
            target = coordinator.downloadedUpdate.map { ($0.displayVersionString, $0.versionString) }
        default:
            break
        }

        if let target {
            titleLabel.stringValue = "Update Downright to \(target.0)"
            versionsLabel.stringValue = "Installed \(installed) (\(build))  →  \(target.0) (\(target.1))"
        } else if case .upToDate = coordinator.phase {
            titleLabel.stringValue = "Downright is Up to Date"
            versionsLabel.stringValue = "Version \(installed) (\(build))"
        } else {
            titleLabel.stringValue = "Downright Updates"
            versionsLabel.stringValue = "Version \(installed) (\(build))"
        }
    }
}

// MARK: - Footer

@MainActor
private final class UpdatePanelFooter: NSView {
    private let leadingStack = NSStackView()
    private let trailingStack = NSStackView()
    private var buttons: [UpdatePanelButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        leadingStack.translatesAutoresizingMaskIntoConstraints = false
        leadingStack.orientation = .horizontal
        leadingStack.alignment = .centerY
        leadingStack.spacing = 10

        trailingStack.translatesAutoresizingMaskIntoConstraints = false
        trailingStack.orientation = .horizontal
        trailingStack.alignment = .centerY
        trailingStack.spacing = 10

        addSubview(leadingStack)
        addSubview(trailingStack)

        NSLayoutConstraint.activate([
            leadingStack.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            leadingStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            leadingStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            trailingStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            trailingStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            trailingStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            trailingStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingStack.trailingAnchor, constant: 16),

            heightAnchor.constraint(equalToConstant: 34),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func apply(sheet: StyleSheet) {
        for button in buttons { button.apply(sheet: sheet) }
    }

    func update(coordinator: UpdateCoordinator) {
        for button in buttons {
            leadingStack.removeArrangedSubview(button)
            trailingStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons = []

        func addLeading(title: String, action: @escaping () -> Void) {
            let button = UpdatePanelButton(title: title, kind: .secondary) { action() }
            button.setAccessibilityLabel(title)
            buttons.append(button)
            leadingStack.addArrangedSubview(button)
        }

        func addTrailing(title: String, kind: UpdatePanelButton.Kind = .secondary, action: @escaping () -> Void) {
            let button = UpdatePanelButton(title: title, kind: kind) { action() }
            button.setAccessibilityLabel(title)
            buttons.append(button)
            trailingStack.addArrangedSubview(button)
        }

        switch coordinator.phase {
        case .checking:
            addTrailing(title: "Cancel", action: { coordinator.userDidCancelCheck() })
        case .idle where coordinator.downloadedUpdate != nil:
            addTrailing(title: "Later") { coordinator.userDidChooseLater() }
            addTrailing(title: "Update & Relaunch", kind: .primary) {
                coordinator.userDidChooseInstall()
            }
        case .available(let metadata, let stage):
            if !metadata.isCritical {
                addLeading(title: "Skip This Version") { coordinator.userDidChooseSkip() }
            }
            addTrailing(title: "Later") { coordinator.userDidChooseLater() }
            let installTitle = stage == .notDownloaded ? "Update" : "Update & Relaunch"
            addTrailing(title: installTitle, kind: .primary) {
                coordinator.userDidChooseInstall()
            }
        case .downloading:
            addTrailing(title: "Cancel Download") { coordinator.userDidCancelDownload() }
        case .extracting:
            break
        case .readyToRelaunch:
            addTrailing(title: "Later") { coordinator.userDidChooseLater() }
            addTrailing(title: "Update & Relaunch", kind: .primary) {
                coordinator.userDidChooseInstall()
            }
        case .waitingForTermination:
            addTrailing(title: "Later") { coordinator.userDidChooseLater() }
            addTrailing(title: "Retry Quit", kind: .primary) {
                coordinator.userDidRetryTermination()
            }
        case .installing:
            break
        case .informational(let metadata):
            addLeading(title: "Skip This Version") { coordinator.userDidChooseSkip() }
            addTrailing(title: "Later") { coordinator.userDidChooseLater() }
            addTrailing(title: "Learn More", kind: .primary) {
                coordinator.userDidRequestLearnMore(metadata)
            }
        case .upToDate:
            addTrailing(title: "OK", kind: .primary) { coordinator.userDidChooseLater() }
        case .failed(_, let retryable):
            addTrailing(title: "Later") { coordinator.userDidChooseLater() }
            if retryable {
                addTrailing(title: "Retry", kind: .primary) { coordinator.userDidRetry() }
            }
        case .idle:
            break
        }
    }
}

// MARK: - Content

@MainActor
private final class UpdatePanelContent {
    enum Kind: Equatable {
        case checking, available, downloading, extracting, ready, waiting, installing,
             informational, upToDate, failed
    }

    let kind: Kind
    let received: UInt64
    let expected: UInt64?

    init(coordinator: UpdateCoordinator) {
        switch coordinator.phase {
        case .checking:
            kind = .checking; received = 0; expected = nil
        case .available:
            kind = .available; received = 0; expected = nil
        case .idle where coordinator.downloadedUpdate != nil:
            // A background download that finished while the machine stayed
            // idle: the panel presents the ready-to-relaunch surface.
            kind = .ready; received = 0; expected = nil
        case .downloading(let received, let expected):
            kind = .downloading; self.received = received; self.expected = expected
        case .extracting:
            kind = .extracting; received = 0; expected = nil
        case .readyToRelaunch:
            kind = .ready; received = 0; expected = nil
        case .waitingForTermination:
            kind = .waiting; received = 0; expected = nil
        case .installing:
            kind = .installing; received = 0; expected = nil
        case .informational:
            kind = .informational; received = 0; expected = nil
        case .upToDate:
            kind = .upToDate; received = 0; expected = nil
        case .failed:
            kind = .failed; received = 0; expected = nil
        case .idle:
            kind = .checking; received = 0; expected = nil  // unreachable; panel not shown when idle
        }
    }

    func makeView(coordinator: UpdateCoordinator, sheet: StyleSheet) -> NSView {
        switch kind {
        case .checking:
            return UpdateStatusMessageView(
                text: "Checking for updates…",
                detail: "Connecting to the update server…",
                spinner: true,
                sheet: sheet
            )
        case .available, .informational, .ready:
            return UpdateNotesView(coordinator: coordinator, sheet: sheet)
        case .downloading:
            return UpdateProgressView(received: received, expected: expected, sheet: sheet)
        case .extracting:
            return UpdateStatusMessageView(
                text: "Extracting the update…",
                detail: "This usually takes a moment.",
                spinner: true,
                sheet: sheet
            )
        case .waiting:
            return UpdateStatusMessageView(
                text: "Downright needs to quit to finish installing.",
                detail: "If a document still has unsaved changes, save it and the update continues on quit. Retry Quit asks again now.",
                spinner: false,
                iconName: "clock.arrow.circlepath",
                iconColor: sheet.accent,
                sheet: sheet
            )
        case .installing:
            return UpdateStatusMessageView(
                text: "Installing the update…",
                detail: "Downright will relaunch automatically.",
                spinner: true,
                sheet: sheet
            )
        case .upToDate:
            let lastCheck = coordinator.lastUpdateCheckDate
            return UpdateStatusMessageView(
                text: "Downright is up to date.",
                detail: lastCheck.map {
                    "You're on the latest version. Last check: \(UpdatePanelDateFormatter.string(from: $0))"
                } ?? "You're on the latest version.",
                spinner: false,
                iconName: "checkmark.circle.fill",
                iconColor: sheet.accent,
                sheet: sheet
            )
        case .failed:
            return UpdateFailureView(coordinator: coordinator, sheet: sheet)
        }
    }
}

// MARK: - Notes view (release notes through the real renderer)

@MainActor
private final class UpdateNotesView: NSView {
    init(coordinator: UpdateCoordinator, sheet: StyleSheet) {
        super.init(frame: .zero)

        var metadata: UpdateMetadata?
        let notesState = coordinator.releaseNotes
        switch coordinator.phase {
        case .available(let candidate, _), .informational(let candidate):
            metadata = candidate
        default:
            metadata = coordinator.downloadedUpdate
        }

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        if let metadata {
            let sizeLabel = NSTextField(labelWithString: UpdateNotesView.sizeText(metadata.contentLength))
            sizeLabel.font = PanelFont.secondary
            sizeLabel.textColor = sheet.textSecondary
            stack.addArrangedSubview(sizeLabel)
        }

        if case .informational = coordinator.phase {
            let info = NSTextField(wrappingLabelWithString: "This update is informational — there is nothing to download. The details are below, or open the full announcement in your browser.")
            info.font = PanelFont.row
            info.textColor = sheet.textSecondary
            stack.addArrangedSubview(info)
        }

        let notesTitle = NSTextField(labelWithString: "What's New")
        notesTitle.font = PanelFont.header
        notesTitle.textColor = sheet.textSecondary
        stack.addArrangedSubview(notesTitle)

        let notesCard = NSView()
        notesCard.translatesAutoresizingMaskIntoConstraints = false
        notesCard.wantsLayer = true
        notesCard.layer?.cornerRadius = 10
        notesCard.layer?.cornerCurve = .continuous
        notesCard.layer?.masksToBounds = true
        let contrast = sheet.increaseContrast
        notesCard.layer?.backgroundColor = sheet.text.withAlphaComponent(contrast ? 0.05 : 0.025).cgColor
        notesCard.layer?.borderWidth = 1
        notesCard.layer?.borderColor = sheet.rule.withAlphaComponent(contrast ? 0.70 : 0.45).cgColor
        notesCard.setContentHuggingPriority(.defaultLow, for: .vertical)
        notesCard.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        stack.addArrangedSubview(notesCard)
        notesCard.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        notesCard.heightAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        notesCard.addSubview(scroll)

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: notesCard.leadingAnchor, constant: 8),
            scroll.trailingAnchor.constraint(equalTo: notesCard.trailingAnchor, constant: -8),
            scroll.topAnchor.constraint(equalTo: notesCard.topAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: notesCard.bottomAnchor, constant: -8),
        ])

        switch notesState {
        case .loaded(let data):
            scroll.documentView = UpdateNotesView.releaseNotesTextView(for: data, sheet: sheet)
        case .failed:
            let failed = NSTextField(wrappingLabelWithString: "Release notes couldn't be downloaded.")
            failed.font = PanelFont.row
            failed.textColor = sheet.textFaint
            stack.addArrangedSubview(failed)
        case .none:
            if let markdown = metadata?.itemDescription, !markdown.isEmpty {
                scroll.documentView = UpdateNotesView.markdownTextView(for: markdown, sheet: sheet)
            } else if let url = metadata?.releaseNotesURL {
                let loading = NSTextField(wrappingLabelWithString: "Loading release notes from \(url.host ?? "")…")
                loading.font = PanelFont.row
                loading.textColor = sheet.textFaint
                stack.addArrangedSubview(loading)
            } else {
                let empty = NSTextField(wrappingLabelWithString: "No release notes for this update.")
                empty.font = PanelFont.row
                empty.textColor = sheet.textFaint
                stack.addArrangedSubview(empty)
            }
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func sizeText(_ bytes: UInt64) -> String {
        guard bytes > 0 else { return "" }
        return "Download size: \(ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file))"
    }

    /// Release notes embedded as Markdown in the appcast description — the
    /// pipeline's normal path — rendered through Downright's own renderer.
    static func markdownTextView(for markdown: String, sheet: StyleSheet) -> MarkdownTextView {
        let storage = NSTextStorage(string: markdown)
        let textView = MarkdownTextView(frame: .zero, storage: storage, styleSheet: sheet)
        textView.mode = .read
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 8)
        // The panel's scroll view owns the width; wrap to it rather than the
        // document measure cap (which can exceed a small panel).
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.update(document: MarkdownParser.parse(markdown), dirty: .wholesale)
        return textView
    }

    /// Linked release notes arrive as HTML.  A web view is out of proportion
    /// for a small panel; convert to a readable attributed string instead.
    static func releaseNotesTextView(for data: Data, sheet: StyleSheet) -> NSTextView {
        let sample = String(data: data.prefix(1_024), encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if sample.hasPrefix("<"),
            let attributed = try? NSAttributedString(
                data: data,
                options: [.documentType: NSAttributedString.DocumentType.html],
                documentAttributes: nil
            ) {
            let textView = NSTextView(frame: .zero)
            textView.textStorage?.setAttributedString(attributed)
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            textView.textContainerInset = NSSize(width: 4, height: 8)
            return textView
        }
        // Not HTML — treat as plain text (or Markdown that Sparkle fetched raw).
        return markdownTextView(for: String(data: data, encoding: .utf8) ?? "", sheet: sheet)
    }
}

// MARK: - Progress

@MainActor
private final class UpdateProgressView: NSView {
    private let bar = NSProgressIndicator()
    private let detailLabel = NSTextField(labelWithString: "")
    private let sheet: StyleSheet

    init(received: UInt64, expected: UInt64?, sheet: StyleSheet) {
        self.sheet = sheet
        super.init(frame: .zero)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        let contrast = sheet.increaseContrast
        container.layer?.backgroundColor = sheet.text.withAlphaComponent(contrast ? 0.04 : 0.02).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = sheet.rule.withAlphaComponent(contrast ? 0.6 : 0.35).cgColor
        addSubview(container)

        let title = NSTextField(labelWithString: "Downloading update…")
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = sheet.text
        title.translatesAutoresizingMaskIntoConstraints = false

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        detailLabel.textColor = sheet.textSecondary

        let stack = NSStackView(views: [title, bar, detailLabel])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        container.addSubview(stack)

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),

            bar.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        update(received: received, expected: expected)
        setAccessibilityRole(.progressIndicator)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func update(received: UInt64, expected: UInt64?) {
        if let expected, expected > 0 {
            let fraction = min(1, Double(received) / Double(expected))
            bar.doubleValue = fraction * 100
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
            let total = ByteCountFormatter.string(fromByteCount: Int64(expected), countStyle: .file)
            detailLabel.stringValue = "\(formatted) of \(total)  (\(Int(fraction * 100))%)"
            setAccessibilityValue("\(Int(fraction * 100)) percent downloaded")
        } else {
            bar.isIndeterminate = true
            bar.startAnimation(nil)
            let formatted = ByteCountFormatter.string(fromByteCount: Int64(received), countStyle: .file)
            detailLabel.stringValue = "Downloaded \(formatted) so far"
            setAccessibilityValue("Downloading, \(formatted) received")
        }
    }
}

// MARK: - Status message

@MainActor
private final class UpdateStatusMessageView: NSView {
    init(
        text: String,
        detail: String?,
        spinner: Bool,
        iconName: String? = nil,
        iconColor: NSColor? = nil,
        sheet: StyleSheet
    ) {
        super.init(frame: .zero)

        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.cornerCurve = .continuous
        let contrast = sheet.increaseContrast
        container.layer?.backgroundColor = sheet.text.withAlphaComponent(contrast ? 0.04 : 0.02).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = sheet.rule.withAlphaComponent(contrast ? 0.6 : 0.35).cgColor
        addSubview(container)

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        container.addSubview(stack)

        if let iconName {
            let iconWell = NSView()
            iconWell.translatesAutoresizingMaskIntoConstraints = false
            iconWell.wantsLayer = true
            iconWell.layer?.cornerRadius = 24
            iconWell.layer?.cornerCurve = .continuous
            let tint = iconColor ?? sheet.accent
            iconWell.layer?.backgroundColor = tint.withAlphaComponent(contrast ? 0.18 : 0.12).cgColor

            let icon = NSImageView()
            icon.translatesAutoresizingMaskIntoConstraints = false
            icon.image = NSImage(systemSymbolName: iconName, accessibilityDescription: nil)
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 22, weight: .semibold)
            icon.contentTintColor = tint
            iconWell.addSubview(icon)

            NSLayoutConstraint.activate([
                iconWell.widthAnchor.constraint(equalToConstant: 48),
                iconWell.heightAnchor.constraint(equalToConstant: 48),
                icon.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
                icon.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
            ])
            stack.addArrangedSubview(iconWell)
            stack.setCustomSpacing(12, after: iconWell)
        } else if spinner {
            let spinWell = NSView()
            spinWell.translatesAutoresizingMaskIntoConstraints = false
            spinWell.wantsLayer = true
            spinWell.layer?.cornerRadius = 24
            spinWell.layer?.cornerCurve = .continuous
            spinWell.layer?.backgroundColor = sheet.text.withAlphaComponent(contrast ? 0.08 : 0.04).cgColor

            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .regular
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.startAnimation(nil)
            spinWell.addSubview(indicator)

            NSLayoutConstraint.activate([
                spinWell.widthAnchor.constraint(equalToConstant: 48),
                spinWell.heightAnchor.constraint(equalToConstant: 48),
                indicator.centerXAnchor.constraint(equalTo: spinWell.centerXAnchor),
                indicator.centerYAnchor.constraint(equalTo: spinWell.centerYAnchor),
            ])
            stack.addArrangedSubview(spinWell)
            stack.setCustomSpacing(12, after: spinWell)
        }

        let title = NSTextField(wrappingLabelWithString: text)
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        title.textColor = sheet.text
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(title)

        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12.5, weight: .regular)
            detailLabel.textColor = sheet.textSecondary
            detailLabel.alignment = .center
            detailLabel.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(detailLabel)
            stack.setCustomSpacing(4, after: title)
        }

        NSLayoutConstraint.activate([
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: container.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

// MARK: - Failure

@MainActor
private final class UpdateFailureView: NSView {
    private let detailDisclosure = NSButton(title: "Technical Details", target: nil, action: nil)
    private let detailPanel = NSView()
    private let detailLabel = NSTextField(labelWithString: "")

    init(coordinator: UpdateCoordinator, sheet: StyleSheet) {
        super.init(frame: .zero)
        guard case .failed(let failure, _) = coordinator.phase else { return }

        let danger = sheet.calloutColor(.danger)

        let iconWell = NSView()
        iconWell.translatesAutoresizingMaskIntoConstraints = false
        iconWell.wantsLayer = true
        iconWell.layer?.cornerRadius = 12
        iconWell.layer?.cornerCurve = .continuous
        iconWell.layer?.masksToBounds = true
        iconWell.layer?.backgroundColor = danger.withAlphaComponent(
            sheet.increaseContrast ? 0.20 : 0.12
        ).cgColor

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Update unavailable"
        )
        icon.contentTintColor = danger
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        icon.setAccessibilityRole(.image)
        icon.setAccessibilityLabel("Update unavailable")
        iconWell.addSubview(icon)
        NSLayoutConstraint.activate([
            iconWell.widthAnchor.constraint(equalToConstant: 40),
            iconWell.heightAnchor.constraint(equalToConstant: 40),
            icon.centerXAnchor.constraint(equalTo: iconWell.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconWell.centerYAnchor),
        ])

        let status = NSTextField(labelWithString: "Update unavailable")
        status.font = PanelFont.header
        status.textColor = danger

        let summary = NSTextField(wrappingLabelWithString: failure.message)
        summary.font = PanelFont.system(15, weight: .semibold)
        summary.textColor = sheet.text
        summary.maximumNumberOfLines = 2
        summary.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let reassurance = NSTextField(wrappingLabelWithString: "Your files are safe. Nothing was changed on disk.")
        reassurance.font = PanelFont.row
        reassurance.textColor = sheet.textSecondary
        reassurance.maximumNumberOfLines = 2
        reassurance.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let messageStack = NSStackView(views: [status, summary, reassurance])
        messageStack.orientation = .vertical
        messageStack.alignment = .leading
        messageStack.spacing = 4
        messageStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let hero = NSStackView(views: [iconWell, messageStack])
        hero.orientation = .horizontal
        hero.alignment = .centerY
        hero.spacing = 12

        detailLabel.stringValue = failure.technicalDetail ?? "Error code \(failure.code)"
        detailLabel.font = PanelFont.monospaced(10.5)
        detailLabel.textColor = sheet.textFaint
        detailLabel.lineBreakMode = .byCharWrapping
        detailLabel.maximumNumberOfLines = 3
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.translatesAutoresizingMaskIntoConstraints = false
        detailPanel.wantsLayer = true
        detailPanel.layer?.cornerRadius = 8
        detailPanel.layer?.cornerCurve = .continuous
        detailPanel.layer?.masksToBounds = true
        detailPanel.layer?.backgroundColor = sheet.codeBackground.withAlphaComponent(0.72).cgColor
        detailPanel.layer?.borderWidth = 1
        detailPanel.layer?.borderColor = sheet.rule.withAlphaComponent(0.65).cgColor
        detailPanel.isHidden = true
        detailPanel.addSubview(detailLabel)
        NSLayoutConstraint.activate([
            detailLabel.leadingAnchor.constraint(equalTo: detailPanel.leadingAnchor, constant: 10),
            detailLabel.trailingAnchor.constraint(equalTo: detailPanel.trailingAnchor, constant: -10),
            detailLabel.topAnchor.constraint(equalTo: detailPanel.topAnchor, constant: 8),
            detailLabel.bottomAnchor.constraint(equalTo: detailPanel.bottomAnchor, constant: -8),
        ])

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        addSubview(stack)

        detailDisclosure.translatesAutoresizingMaskIntoConstraints = false
        detailDisclosure.setButtonType(.pushOnPushOff)
        detailDisclosure.isBordered = false
        detailDisclosure.font = PanelFont.secondary
        detailDisclosure.contentTintColor = sheet.textSecondary
        detailDisclosure.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "Show technical details"
        )
        detailDisclosure.imagePosition = .imageLeading
        detailDisclosure.imageHugsTitle = true
        detailDisclosure.alignment = .left
        detailDisclosure.toolTip = "Show technical details"
        detailDisclosure.wantsLayer = true
        detailDisclosure.layer?.cornerRadius = 7
        detailDisclosure.layer?.cornerCurve = .continuous
        detailDisclosure.layer?.masksToBounds = true
        detailDisclosure.layer?.backgroundColor = sheet.text.withAlphaComponent(
            sheet.increaseContrast ? 0.12 : 0.07
        ).cgColor
        detailDisclosure.layer?.borderWidth = 1
        detailDisclosure.layer?.borderColor = sheet.text.withAlphaComponent(0.14).cgColor
        detailDisclosure.attributedTitle = NSAttributedString(
            string: detailDisclosure.title,
            attributes: [
                .font: detailDisclosure.font as Any,
                .foregroundColor: sheet.textSecondary,
            ]
        )
        detailDisclosure.heightAnchor.constraint(equalToConstant: 28).isActive = true
        detailDisclosure.setContentHuggingPriority(.required, for: .horizontal)
        detailDisclosure.target = self
        detailDisclosure.action = #selector(toggleDetail)

        let copy = UpdatePanelButton(title: "Copy Diagnostics", kind: .secondary) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                UpdatePanelContent.diagnostics(coordinator: coordinator, failure: failure),
                forType: .string
            )
        }
        copy.setAccessibilityLabel("Copy diagnostics")

        let diagnosticsActions = NSStackView(views: [detailDisclosure, copy])
        diagnosticsActions.orientation = .horizontal
        diagnosticsActions.alignment = .centerY
        diagnosticsActions.spacing = 8

        stack.addArrangedSubview(hero)
        stack.addArrangedSubview(diagnosticsActions)
        stack.addArrangedSubview(detailPanel)

        // Keep the body on one horizontal grid when the disclosure opens. A
        // hidden NSView has no fitting width, so relying on stack alignment
        // alone lets AppKit shrink the whole stack to the diagnostic label.
        for view in [hero, diagnosticsActions, detailPanel] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func toggleDetail() {
        detailPanel.isHidden.toggle()
        detailDisclosure.state = detailPanel.isHidden ? .off : .on
        detailDisclosure.image = NSImage(
            systemSymbolName: detailPanel.isHidden ? "chevron.right" : "chevron.down",
            accessibilityDescription: detailPanel.isHidden
                ? "Show technical details"
                : "Hide technical details"
        )
        detailDisclosure.toolTip = detailPanel.isHidden
            ? "Show technical details"
            : "Hide technical details"
        needsLayout = true
        superview?.needsLayout = true
    }
}

// MARK: - Shared bits

extension UpdatePanelContent {
    static func diagnostics(coordinator: UpdateCoordinator, failure: UpdateFailure) -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let feed = bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String ?? "(updates disabled)"
        var lines = [
            "Downright \(version) (\(build))",
            "Error: \(failure.message)",
            "Code: \(failure.code)",
            "Feed: \(feed)",
        ]
        if let detail = failure.technicalDetail {
            lines.append("Detail: \(detail)")
        }
        if let lastCheck = coordinator.lastUpdateCheckDate {
            lines.append("Last check: \(UpdatePanelDateFormatter.string(from: lastCheck))")
        }
        return lines.joined(separator: "\n")
    }
}

@MainActor
final class UpdatePanelButton: NSButton {
    enum Kind: Equatable { case primary, secondary }

    private let kind: Kind
    private let buttonTitle: String
    var isPrimary: Bool { kind == .primary }
    private var sheet: StyleSheet
    private let actionTarget: ActionTarget
    private var isHovered = false
    private var isPressed = false

    override var intrinsicContentSize: NSSize {
        let textWidth = (attributedTitle.size().width).rounded(.up)
        let width = max(76, textWidth + 30)
        return NSSize(width: width, height: 32)
    }

    init(title: String, kind: Kind, sheet: StyleSheet? = nil, action: @escaping () -> Void) {
        self.kind = kind
        self.buttonTitle = title
        self.sheet = sheet ?? StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)
        let actionTarget = ActionTarget(action)
        self.actionTarget = actionTarget
        super.init(frame: .zero)
        self.title = ""
        setButtonType(.momentaryPushIn)
        isBordered = false
        focusRingType = .none
        wantsLayer = true
        layer?.cornerRadius = 7
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        target = actionTarget
        self.action = #selector(ActionTarget.run(_:))
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)

        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
        widthAnchor.constraint(greaterThanOrEqualToConstant: 76).isActive = true

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))

        apply(sheet: self.sheet)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        isPressed = true
        updateVisuals()
        super.mouseDown(with: event)
        isPressed = false
        updateVisuals()
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateVisuals()
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateVisuals()
    }

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        updateVisuals()
    }

    private func updateVisuals() {
        let sheet = self.sheet
        let contrast = sheet.increaseContrast
        let isFocused = window?.firstResponder === self && window?.isKeyWindow == true

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let titleColor: NSColor
        switch kind {
        case .primary:
            titleColor = .white
            contentTintColor = .white
            let base = sheet.startWindowPrimaryAction
            let fill: NSColor
            if isPressed {
                fill = base.blended(withFraction: 0.18, of: .black) ?? base
            } else if isHovered {
                fill = base.blended(withFraction: 0.08, of: .white) ?? base
            } else {
                fill = base
            }
            layer?.backgroundColor = fill.cgColor
            layer?.borderWidth = isFocused ? 2 : 1
            layer?.borderColor = (isFocused ? NSColor.white : base.blended(withFraction: 0.20, of: .white))?.withAlphaComponent(isFocused ? 0.9 : 0.4).cgColor
        case .secondary:
            titleColor = sheet.text
            contentTintColor = sheet.text
            let alpha: CGFloat = isPressed ? 0.14 : (isHovered ? 0.09 : 0.05)
            layer?.backgroundColor = sheet.text.withAlphaComponent(contrast ? max(alpha, 0.12) : alpha).cgColor
            layer?.borderWidth = isFocused ? 2 : 1
            layer?.borderColor = (isFocused ? sheet.accent : sheet.rule)
                .withAlphaComponent(isFocused ? 0.9 : (contrast ? 0.60 : 0.35)).cgColor
        }

        attributedTitle = NSAttributedString(
            string: buttonTitle,
            attributes: [
                .font: PanelFont.system(13, weight: kind == .primary ? .semibold : .medium),
                .foregroundColor: titleColor,
                .paragraphStyle: paragraph,
            ]
        )
    }
}

private enum UpdatePanelDateFormatter {
    static func string(from date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
    }
}

/// Tiny retained target so buttons and controls don't need a view-controller
/// back-pointer.
@MainActor
private final class ActionTarget: NSObject {
    private let block: () -> Void
    init(_ block: @escaping () -> Void) { self.block = block }
    @objc func run(_ sender: Any?) { block() }
}
