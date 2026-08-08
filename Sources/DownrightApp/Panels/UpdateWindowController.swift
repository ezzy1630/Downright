import AppKit
import MarkdownCore
import MarkdownRender

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
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 600),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Updates"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 480, height: 480)
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
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            header.topAnchor.constraint(equalTo: topAnchor, constant: 16),

            contentContainer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            contentContainer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            contentContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),

            footer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            footer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -20),
            footer.topAnchor.constraint(equalTo: contentContainer.bottomAnchor, constant: 12),
            footer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
        ])
        refresh()
        viewDidChangeEffectiveAppearance()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private static func makeSheet() -> StyleSheet {
        StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sheet = Self.makeSheet()
        window?.backgroundColor = sheet.background
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
        addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 17, weight: .semibold)
        addSubview(titleLabel)

        versionsLabel.translatesAutoresizingMaskIntoConstraints = false
        versionsLabel.font = .systemFont(ofSize: 11)
        addSubview(versionsLabel)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor),
            iconView.topAnchor.constraint(equalTo: topAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 44),
            iconView.heightAnchor.constraint(equalToConstant: 44),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 12),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),

            versionsLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            versionsLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            versionsLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func apply(sheet: StyleSheet) {
        titleLabel.textColor = sheet.text
        versionsLabel.textColor = sheet.textFaint
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
        } else {
            titleLabel.stringValue = "Downright Updates"
            versionsLabel.stringValue = "Version \(installed) (\(build))"
        }
    }
}

// MARK: - Footer

@MainActor
private final class UpdatePanelFooter: NSView {
    private let buttonsStack = NSStackView()
    private var buttons: [NSButton] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buttonsStack.translatesAutoresizingMaskIntoConstraints = false
        buttonsStack.orientation = .horizontal
        buttonsStack.alignment = .centerY
        buttonsStack.spacing = 8
        addSubview(buttonsStack)
        NSLayoutConstraint.activate([
            buttonsStack.trailingAnchor.constraint(equalTo: trailingAnchor),
            buttonsStack.topAnchor.constraint(equalTo: topAnchor),
            buttonsStack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func apply(sheet: StyleSheet) {
        for button in buttons { (button as? UpdatePanelButton)?.apply(sheet: sheet) }
    }

    func update(coordinator: UpdateCoordinator) {
        for button in buttons {
            buttonsStack.removeArrangedSubview(button)
            button.removeFromSuperview()
        }
        buttons = []

        func add(title: String, key: String, kind: UpdatePanelButton.Kind = .secondary, action: @escaping () -> Void) {
            let button = UpdatePanelButton(title: title, kind: kind) { action() }
            button.setAccessibilityLabel(title)
            buttons.append(button)
            if kind == .secondary,
               buttonsStack.arrangedSubviews.contains(where: { ($0 as? UpdatePanelButton)?.isPrimary == true }) {
                buttonsStack.insertArrangedSubview(button, at: 0)
            } else {
                buttonsStack.addArrangedSubview(button)
            }
        }

        switch coordinator.phase {
        case .checking:
            add(title: "Cancel", key: "xmark", action: { coordinator.userDidCancelCheck() })
        case .idle where coordinator.downloadedUpdate != nil:
            add(title: "Update & Relaunch", key: "arrow.clockwise.circle.fill", kind: .primary) {
                coordinator.userDidChooseInstall()
            }
            add(title: "Later", key: "") { coordinator.userDidChooseLater() }
        case .available(let metadata, let stage):
            let installTitle = stage == .notDownloaded ? "Update" : "Update & Relaunch"
            add(title: installTitle, key: "arrow.down.circle.fill", kind: .primary) {
                coordinator.userDidChooseInstall()
            }
            add(title: "Later", key: "") { coordinator.userDidChooseLater() }
            if !metadata.isCritical {
                add(title: "Skip This Version", key: "") { coordinator.userDidChooseSkip() }
            }
        case .downloading:
            add(title: "Cancel Download", key: "xmark") { coordinator.userDidCancelDownload() }
        case .extracting:
            break
        case .readyToRelaunch:
            add(title: "Update & Relaunch", key: "arrow.clockwise.circle.fill", kind: .primary) {
                coordinator.userDidChooseInstall()
            }
            add(title: "Later", key: "") { coordinator.userDidChooseLater() }
        case .waitingForTermination:
            add(title: "Retry Quit", key: "arrow.clockwise", kind: .primary) {
                coordinator.userDidRetryTermination()
            }
            // Later dismisses the panel; the pending install still happens on
            // quit (the windowWillClose path discards the retry capability).
            add(title: "Later", key: "") { coordinator.userDidChooseLater() }
        case .installing:
            break
        case .informational(let metadata):
            add(title: "Learn More", key: "arrow.up.right.square", kind: .primary) {
                coordinator.userDidRequestLearnMore(metadata)
            }
            add(title: "Later", key: "") { coordinator.userDidChooseLater() }
            add(title: "Skip This Version", key: "") { coordinator.userDidChooseSkip() }
        case .upToDate:
            // userDidChooseLater closes the panel (nothing is armed in the
            // up-to-date state; the acknowledgement was already delivered).
            add(title: "OK", key: "", kind: .primary) { coordinator.userDidChooseLater() }
        case .failed(_, let retryable):
            if retryable {
                add(title: "Retry", key: "arrow.clockwise", kind: .primary) { coordinator.userDidRetry() }
            }
            // Later closes the panel; closing fires windowWillClose, which
            // delivers the pending acknowledgement exactly once.
            add(title: "Later", key: "") { coordinator.userDidChooseLater() }
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
                detail: nil,
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
            sizeLabel.font = .systemFont(ofSize: 11)
            sizeLabel.textColor = sheet.textFaint
            stack.addArrangedSubview(sizeLabel)
        }

        if case .informational = coordinator.phase {
            let info = NSTextField(wrappingLabelWithString: "This update is informational — there is nothing to download. The details are below, or open the full announcement in your browser.")
            info.font = .systemFont(ofSize: 12)
            info.textColor = sheet.textSecondary
            stack.addArrangedSubview(info)
        }

        let notesTitle = NSTextField(labelWithString: "What's New")
        notesTitle.font = .systemFont(ofSize: 12, weight: .semibold)
        notesTitle.textColor = sheet.textSecondary
        stack.addArrangedSubview(notesTitle)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        stack.addArrangedSubview(scroll)
        scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 220).isActive = true
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        switch notesState {
        case .loaded(let data):
            scroll.documentView = UpdateNotesView.releaseNotesTextView(for: data, sheet: sheet)
        case .failed:
            let failed = NSTextField(wrappingLabelWithString: "Release notes couldn't be downloaded.")
            failed.font = .systemFont(ofSize: 12)
            failed.textColor = sheet.textFaint
            stack.addArrangedSubview(failed)
        case .none:
            if let markdown = metadata?.itemDescription, !markdown.isEmpty {
                scroll.documentView = UpdateNotesView.markdownTextView(for: markdown, sheet: sheet)
            } else if let url = metadata?.releaseNotesURL {
                let loading = NSTextField(wrappingLabelWithString: "Loading release notes from \(url.host ?? "")…")
                loading.font = .systemFont(ofSize: 12)
                loading.textColor = sheet.textFaint
                stack.addArrangedSubview(loading)
            } else {
                let empty = NSTextField(wrappingLabelWithString: "No release notes for this update.")
                empty.font = .systemFont(ofSize: 12)
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

        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 100
        addSubview(bar)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = sheet.textFaint
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            detailLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 6),
            detailLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
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
    init(text: String, detail: String?, spinner: Bool, sheet: StyleSheet) {
        super.init(frame: .zero)
        let title = NSTextField(wrappingLabelWithString: text)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = sheet.text
        title.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [title])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        if let detail {
            let detailLabel = NSTextField(wrappingLabelWithString: detail)
            detailLabel.font = .systemFont(ofSize: 12)
            detailLabel.textColor = sheet.textSecondary
            stack.addArrangedSubview(detailLabel)
        }
        if spinner {
            let indicator = NSProgressIndicator()
            indicator.style = .spinning
            indicator.controlSize = .small
            indicator.translatesAutoresizingMaskIntoConstraints = false
            indicator.startAnimation(nil)
            let row = NSStackView(views: [indicator])
            row.orientation = .horizontal
            stack.addArrangedSubview(row)
        }
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }
}

// MARK: - Failure

@MainActor
private final class UpdateFailureView: NSView {
    private let detailDisclosure = NSButton(title: "Technical Details", target: nil, action: nil)

    init(coordinator: UpdateCoordinator, sheet: StyleSheet) {
        super.init(frame: .zero)
        guard case .failed(let failure, _) = coordinator.phase else { return }

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        addSubview(stack)

        let summary = NSTextField(wrappingLabelWithString: failure.message)
        summary.font = .systemFont(ofSize: 13, weight: .medium)
        summary.textColor = .systemOrange
        summary.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(summary)

        let explanation = NSTextField(wrappingLabelWithString: "Nothing has been changed on disk. You can try again, or check later.")
        explanation.font = .systemFont(ofSize: 12)
        explanation.textColor = sheet.textSecondary
        stack.addArrangedSubview(explanation)

        detailDisclosure.translatesAutoresizingMaskIntoConstraints = false
        detailDisclosure.setButtonType(.pushOnPushOff)
        detailDisclosure.bezelStyle = .inline
        detailDisclosure.font = .systemFont(ofSize: 11)
        detailDisclosure.target = self
        detailDisclosure.action = #selector(toggleDetail)
        stack.addArrangedSubview(detailDisclosure)

        let detailLabel = NSTextField(wrappingLabelWithString: failure.technicalDetail ?? "\(failure.code)")
        detailLabel.font = .monospacedSystemFont(ofSize: 10.5, weight: .regular)
        detailLabel.textColor = sheet.textFaint
        detailLabel.isHidden = true
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(detailLabel)

        let copy = UpdatePanelButton(title: "Copy Diagnostics", kind: .secondary) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(
                UpdatePanelContent.diagnostics(coordinator: coordinator, failure: failure),
                forType: .string
            )
        }
        copy.setAccessibilityLabel("Copy diagnostics")
        stack.addArrangedSubview(copy)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    @objc private func toggleDetail() {
        guard let detail = subviews.first?.subviews.compactMap({ $0 as? NSTextField }).last else { return }
        detail.isHidden.toggle()
        detailDisclosure.state = detail.isHidden ? .off : .on
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
    var isPrimary: Bool { kind == .primary }
    private var sheet: StyleSheet
    /// `target` is weak; without a strong reference the action object would
    /// deallocate the moment the button is created.
    private let actionTarget: ActionTarget

    init(title: String, kind: Kind, sheet: StyleSheet? = nil, action: @escaping () -> Void) {
        self.kind = kind
        self.sheet = sheet ?? StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)
        let actionTarget = ActionTarget(action)
        self.actionTarget = actionTarget
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .rounded
        font = .systemFont(ofSize: 12, weight: .medium)
        controlSize = .regular
        focusRingType = .default
        target = actionTarget
        self.action = #selector(ActionTarget.run(_:))
        setAccessibilityRole(.button)
        apply(sheet: self.sheet)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        switch kind {
        case .primary:
            contentTintColor = .white
            bezelColor = sheet.accent
        case .secondary:
            contentTintColor = sheet.text
            bezelColor = sheet.surface
        }
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
