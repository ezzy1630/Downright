import AppKit
import MarkdownRender
import QuickLookThumbnailing

@MainActor
final class StartWindowController: NSWindowController {
    static let recentDisplayLimit = 8

    var onOpen: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onNew: (() -> Void)?

    private var startView: StartView? { window?.contentView as? StartView }
    /// Prevents double-open while a handoff is already in flight.
    private var isHandingOff = false

    convenience init(recents: [RecentDocument]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Downright"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 840, height: 540)
        window.backgroundColor = .windowBackgroundColor
        window.center()
        self.init(window: window)
        let content = StartView(recents: recents, owner: self)
        window.contentView = content
        window.initialFirstResponder = content.preferredFirstResponder
    }

    func reloadRecents(_ recents: [RecentDocument]) {
        isHandingOff = false
        startView?.reloadRecents(Array(recents.prefix(Self.recentDisplayLimit)))
    }

    /// Fades the start window out, then closes it. Reduce Motion callers pass `animated: false`.
    func dismiss(animated: Bool, completion: (() -> Void)? = nil) {
        guard let window else {
            completion?()
            return
        }
        let finish = {
            window.alphaValue = 1
            window.close()
            completion?()
        }
        guard animated else {
            finish()
            return
        }
        Motion.run(
            reduceMotion: false,
            duration: Motion.quick,
            curve: .easeOut,
            changes: { _ in window.animator().alphaValue = 0 },
            completion: finish
        )
    }

    private func beginHandoff() -> Bool {
        guard !isHandingOff else { return false }
        isHandingOff = true
        return true
    }

    @objc func openRecent(_ sender: NSButton) {
        guard beginHandoff(), let path = sender.identifier?.rawValue else { return }
        onOpen?(URL(fileURLWithPath: path))
    }

    @objc func openPanel(_ sender: Any?) {
        guard beginHandoff() else { return }
        onOpenPanel?()
        // Open panel is modal; if the user cancels, allow another attempt.
        isHandingOff = false
    }

    @objc func newDocument(_ sender: Any?) {
        guard beginHandoff() else { return }
        onNew?()
        isHandingOff = false
    }
}

// MARK: - Root

private final class StartView: NSView {
    private weak var owner: StartWindowController?
    private let dropZone = DropZoneView()
    private let background = StartBackgroundView()
    private let recentPanel: RecentDocumentsPanel
    private let hero: StartHeroView
    /// Clear of traffic lights under `fullSizeContentView`.
    private static let titlebarClearance: CGFloat = 56

    var preferredFirstResponder: NSView { hero.openButton }

    init(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        self.recentPanel = RecentDocumentsPanel(recents: recents, owner: owner)
        self.hero = StartHeroView(owner: owner, dropZone: dropZone)
        super.init(frame: .zero)

        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Downright start window")

        background.translatesAutoresizingMaskIntoConstraints = false
        addSubview(background)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        scroll.setAccessibilityLabel("Downright start window content")
        addSubview(scroll)

        let canvas = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = canvas

        let columns = NSStackView()
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.orientation = .horizontal
        columns.alignment = .centerY
        columns.distribution = .fill
        columns.spacing = 36
        canvas.addSubview(columns)

        hero.translatesAutoresizingMaskIntoConstraints = false
        recentPanel.translatesAutoresizingMaskIntoConstraints = false
        columns.addArrangedSubview(hero)
        columns.addArrangedSubview(recentPanel)

        hero.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hero.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recentPanel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        recentPanel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let centerY = columns.centerYAnchor.constraint(equalTo: canvas.centerYAnchor)
        centerY.priority = .defaultHigh

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: leadingAnchor),
            background.trailingAnchor.constraint(equalTo: trailingAnchor),
            background.topAnchor.constraint(equalTo: topAnchor),
            background.bottomAnchor.constraint(equalTo: bottomAnchor),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            canvas.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            canvas.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),

            columns.leadingAnchor.constraint(equalTo: canvas.leadingAnchor, constant: 52),
            columns.trailingAnchor.constraint(equalTo: canvas.trailingAnchor, constant: -52),
            columns.topAnchor.constraint(greaterThanOrEqualTo: canvas.topAnchor, constant: Self.titlebarClearance),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: canvas.bottomAnchor, constant: -40),
            centerY,

            hero.widthAnchor.constraint(equalTo: columns.widthAnchor, multiplier: 0.5),
            recentPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 352),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func reloadRecents(_ recents: [RecentDocument]) {
        guard let owner else { return }
        recentPanel.reload(recents: recents, owner: owner)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        background.needsDisplay = true
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = droppedURLs(from: sender.draggingPasteboard)
        dropZone.isActive = !urls.isEmpty
        return urls.isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropZone.isActive = false
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(from: sender.draggingPasteboard)
        dropZone.isActive = false
        guard !urls.isEmpty else { return false }
        urls.forEach { owner?.onOpen?($0) }
        return true
    }

    private func droppedURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] ?? []
        return urls.filter {
            DocumentTypes.isMarkdown($0.pathExtension)
                && FileManager.default.fileExists(atPath: $0.path)
        }
    }
}

// MARK: - Background

private final class StartBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

// MARK: - Hero

private final class StartHeroView: NSView {
    let openButton: StartActionButton
    private let newButton: StartActionButton

    init(owner: StartWindowController, dropZone: DropZoneView) {
        openButton = StartActionButton(
            title: "Open…",
            shortcut: "⌘O",
            symbolName: "folder",
            kind: .primary,
            target: owner,
            action: #selector(StartWindowController.openPanel(_:))
        )
        newButton = StartActionButton(
            title: "New Document…",
            shortcut: "⌘N",
            symbolName: "plus",
            kind: .secondary,
            target: owner,
            action: #selector(StartWindowController.newDocument(_:))
        )
        super.init(frame: .zero)

        let brand = BrandMarkView()
        brand.translatesAutoresizingMaskIntoConstraints = false
        let brandLabel = NSTextField(labelWithString: "")
        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        brandLabel.attributedStringValue = NSAttributedString(
            string: "DOWNRIGHT",
            attributes: [
                .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .semibold),
                .foregroundColor: NSColor.tertiaryLabelColor,
                .kern: 1.2,
            ]
        )
        brandLabel.setContentHuggingPriority(.required, for: .horizontal)

        let brandRow = NSStackView(views: [brand, brandLabel])
        brandRow.translatesAutoresizingMaskIntoConstraints = false
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 8

        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineSpacing = 2
        titleParagraph.maximumLineHeight = 38
        titleParagraph.minimumLineHeight = 36

        let title = NSTextField(labelWithString: "Read deeply.\nWrite lightly.")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.setContentHuggingPriority(.required, for: .vertical)
        title.attributedStringValue = NSAttributedString(
            string: "Read deeply.\nWrite lightly.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 30, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .kern: -0.4,
                .paragraphStyle: titleParagraph,
            ]
        )

        let subtitle = NSTextField(
            wrappingLabelWithString: "Exact Markdown. Quiet chrome."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 14, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.preferredMaxLayoutWidth = 320

        let actions = NSStackView(views: [openButton, newButton])
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.distribution = .fillEqually
        actions.spacing = 10
        actions.setHuggingPriority(.required, for: .vertical)

        dropZone.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [brandRow, title, subtitle, actions, dropZone])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        addSubview(stack)

        NSLayoutConstraint.activate([
            brand.widthAnchor.constraint(equalToConstant: 22),
            brand.heightAnchor.constraint(equalToConstant: 22),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 320),
            openButton.heightAnchor.constraint(equalToConstant: 38),
            newButton.heightAnchor.constraint(equalToConstant: 38),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dropZone.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dropZone.heightAnchor.constraint(equalToConstant: 64),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.setCustomSpacing(18, after: brandRow)
        stack.setCustomSpacing(10, after: title)
        stack.setCustomSpacing(18, after: subtitle)
        stack.setCustomSpacing(24, after: actions)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Downright welcome")
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        playArrivalIfNeeded()
    }

    private var didPlayArrival = false

    private func playArrivalIfNeeded() {
        guard !didPlayArrival else { return }
        didPlayArrival = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else { return }
        wantsLayer = true
        alphaValue = 0
        layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -5))
        Motion.run(
            reduceMotion: false,
            duration: Motion.standard,
            curve: .easeOut,
            changes: { _ in
                self.animator().alphaValue = 1
                self.layer?.setAffineTransform(.identity)
            }
        )
    }
}

// MARK: - Recents

private final class RecentDocumentsPanel: NSView {
    private weak var owner: StartWindowController?
    private let headerLabel = NSTextField(labelWithString: "Recent")
    private let countLabel = NSTextField(labelWithString: "")
    private let list = NSStackView()
    private let panel = SurfaceView()
    private var recentCards: [NSView] = []
    private var displayedPaths: [String] = []
    private var didAnimateRecentCards = false
    private var emptyFillConstraint: NSLayoutConstraint?

    init(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        super.init(frame: .zero)

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .systemFont(ofSize: 11, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right

        let header = NSStackView(views: [headerLabel, countLabel])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .horizontal
        header.alignment = .centerY
        header.distribution = .fill
        header.spacing = 8
        headerLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        list.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .width
        list.distribution = .fill
        list.spacing = 2

        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(header)
        panel.addSubview(list)
        addSubview(panel)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 14),

            list.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 8),
            list.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -8),
            list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),

            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 352),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Recent Markdown documents")
        rebuild(recents: recents, animate: false)
    }

    required init?(coder: NSCoder) { nil }

    func reload(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        let paths = recents.map(\.path)
        guard paths != displayedPaths else { return }
        rebuild(recents: recents, animate: window != nil)
    }

    private func rebuild(recents: [RecentDocument], animate: Bool) {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        recentCards.removeAll()
        emptyFillConstraint?.isActive = false
        emptyFillConstraint = nil
        displayedPaths = recents.map(\.path)
        didAnimateRecentCards = false
        countLabel.stringValue = recents.isEmpty ? "" : "\(min(recents.count, StartWindowController.recentDisplayLimit))"

        guard let owner else { return }

        if recents.isEmpty {
            let empty = RecentEmptyState()
            empty.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            let fill = empty.heightAnchor.constraint(greaterThanOrEqualToConstant: 200)
            fill.priority = .defaultHigh
            fill.isActive = true
            emptyFillConstraint = fill
            recentCards = [empty]
        } else {
            for recent in recents.prefix(StartWindowController.recentDisplayLimit) {
                let card = RecentDocumentButton(recent: recent, target: owner)
                card.translatesAutoresizingMaskIntoConstraints = false
                card.heightAnchor.constraint(equalToConstant: 52).isActive = true
                list.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                recentCards.append(card)
            }
        }

        if animate {
            animateCardsIn()
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        animateCardsIn()
    }

    private func animateCardsIn() {
        guard !didAnimateRecentCards else { return }
        didAnimateRecentCards = true
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduceMotion else { return }

        for (index, card) in recentCards.enumerated() {
            card.alphaValue = 0
            let delay = 0.03 * Double(index)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak card] in
                guard let card, card.window != nil else { return }
                Motion.run(
                    reduceMotion: false,
                    duration: Motion.standard,
                    curve: .easeOut,
                    changes: { _ in card.animator().alphaValue = 1 }
                )
            }
        }
    }
}

private final class RecentEmptyState: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView(
            image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Markdown document")!
        )
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "No recent files")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let detail = NSTextField(
            wrappingLabelWithString: "Open… or drop a .md file anywhere in this window."
        )
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 3

        let stack = NSStackView(views: [icon, title, detail])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 22),
            icon.heightAnchor.constraint(equalToConstant: 22),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class SurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        applyAppearance()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAppearance()
    }

    private func applyAppearance() {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        let fillAlpha: CGFloat = (increaseContrast || reduceTransparency) ? 0.95 : 0.38
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(fillAlpha).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(increaseContrast ? 0.6 : 0.18).cgColor
    }
}

// MARK: - Actions

private final class StartActionButton: NSButton {
    enum Kind { case primary, secondary }

    private let kind: Kind
    private let shell = NSView()
    private let titleLabel: NSTextField
    private let shortcutBadge = NSView()
    private let shortcutLabel: NSTextField
    private let iconView: NSImageView
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var isHovered = false
    private var isPressed = false

    init(
        title: String,
        shortcut: String,
        symbolName: String,
        kind: Kind,
        target: AnyObject,
        action: Selector
    ) {
        self.kind = kind
        titleLabel = NSTextField(labelWithString: title)
        shortcutLabel = NSTextField(labelWithString: shortcut)
        iconView = NSImageView(image: NSImage(systemSymbolName: symbolName, accessibilityDescription: title)!)
        super.init(frame: .zero)

        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        isBordered = false
        self.title = ""
        focusRingType = .exterior
        // Menus own ⌘O / ⌘N; badges are instructional only — avoids double-fire.
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(shortcut)
        wantsLayer = true

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 9
        shell.layer?.masksToBounds = true
        addSubview(shell)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = kind == .primary ? .white : .secondaryLabelColor
        shell.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = kind == .primary ? .white : .labelColor
        titleLabel.isSelectable = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        shell.addSubview(titleLabel)

        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.alignment = .center
        shortcutLabel.textColor = kind == .primary
            ? NSColor.white.withAlphaComponent(0.86)
            : NSColor.secondaryLabelColor
        shortcutBadge.translatesAutoresizingMaskIntoConstraints = false
        shortcutBadge.wantsLayer = true
        shortcutBadge.layer?.cornerRadius = 4
        shortcutBadge.layer?.masksToBounds = true
        shell.addSubview(shortcutBadge)

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutBadge.addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            iconView.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 12),
            iconView.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 13),
            iconView.heightAnchor.constraint(equalToConstant: 13),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleLabel.centerYAnchor.constraint(equalTo: shell.centerYAnchor),

            shortcutBadge.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 10),
            shortcutBadge.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -10),
            shortcutBadge.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            shortcutBadge.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
            shortcutBadge.heightAnchor.constraint(equalToConstant: 18),
            shortcutLabel.leadingAnchor.constraint(equalTo: shortcutBadge.leadingAnchor, constant: 5),
            shortcutLabel.trailingAnchor.constraint(equalTo: shortcutBadge.trailingAnchor, constant: -5),
            shortcutLabel.topAnchor.constraint(equalTo: shortcutBadge.topAnchor),
            shortcutLabel.bottomAnchor.constraint(equalTo: shortcutBadge.bottomAnchor),
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)

        updateSurface(animated: false)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 38)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateSurface(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateSurface(animated: true)
    }

    override func highlight(_ flag: Bool) {
        super.highlight(flag)
        isPressed = flag
        guard shell.superview != nil else { return }
        updateSurface(animated: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface(animated: false)
    }

    private func updateSurface(animated: Bool) {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let changes = {
            let accent = NSColor.controlAccentColor
            let base: NSColor
            if self.kind == .primary {
                base = self.isPressed
                    ? (accent.blended(withFraction: 0.2, of: .black) ?? accent)
                    : (self.isHovered ? accent : accent.withAlphaComponent(increaseContrast ? 1 : 0.94))
            } else {
                let idleAlpha: CGFloat = increaseContrast ? 0.96 : 0.7
                let hoverAlpha: CGFloat = increaseContrast ? 1 : 0.88
                base = NSColor.controlBackgroundColor.withAlphaComponent(self.isHovered ? hoverAlpha : idleAlpha)
            }
            self.shell.layer?.backgroundColor = base.cgColor
            self.shell.layer?.borderWidth = self.kind == .secondary ? 1 : 0
            self.shell.layer?.borderColor = NSColor.separatorColor
                .withAlphaComponent(increaseContrast ? 0.55 : 0.26).cgColor
            self.shortcutBadge.layer?.backgroundColor = self.kind == .primary
                ? NSColor.white.withAlphaComponent(0.14).cgColor
                : NSColor.labelColor.withAlphaComponent(0.06).cgColor
            self.shell.layer?.setAffineTransform(
                self.isPressed ? CGAffineTransform(scaleX: 0.985, y: 0.985) : .identity
            )
            self.iconView.alphaValue = self.isHovered ? 1 : 0.92
        }

        if animated {
            Motion.run(
                reduceMotion: reduceMotion,
                duration: Motion.quick,
                curve: .easeOut,
                changes: { _ in changes() }
            )
        } else {
            changes()
        }
    }
}

// MARK: - Recent row

private enum RecentRowCopy {
    private static let relativeFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    static func detail(for recent: RecentDocument) -> String {
        let folder = URL(fileURLWithPath: recent.path)
            .deletingLastPathComponent()
            .lastPathComponent
        let when = relativeFormatter.localizedString(for: recent.lastOpened, relativeTo: Date())
        return "\(folder)  ·  \(when)"
    }

    static func accessibilityDetail(for recent: RecentDocument) -> String {
        let base = detail(for: recent)
        if recent.firstHeading.isEmpty { return base }
        return "\(recent.firstHeading). \(base)"
    }
}

private final class RecentDocumentButton: NSButton {
    private let recent: RecentDocument
    private let shell = NSView()
    private let thumbnail = NSImageView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let arrow = NSImageView(
        image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Open")!
    )
    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
    private var isHovered = false
    private var isPressed = false
    private var thumbnailRequest: QLThumbnailGenerator.Request?

    init(recent: RecentDocument, target: StartWindowController) {
        self.recent = recent
        titleLabel = NSTextField(labelWithString: recent.displayName)
        let detail = RecentRowCopy.detail(for: recent)
        detailLabel = NSTextField(labelWithString: detail)
        super.init(frame: .zero)

        self.target = target
        action = #selector(StartWindowController.openRecent(_:))
        identifier = NSUserInterfaceItemIdentifier(recent.path)
        setButtonType(.momentaryPushIn)
        isBordered = false
        self.title = ""
        focusRingType = .exterior
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(recent.displayName)")
        setAccessibilityValue(RecentRowCopy.accessibilityDetail(for: recent))
        wantsLayer = true

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 8
        shell.layer?.masksToBounds = true
        addSubview(shell)

        let thumbWell = NSView()
        thumbWell.translatesAutoresizingMaskIntoConstraints = false
        thumbWell.wantsLayer = true
        thumbWell.layer?.cornerRadius = 6
        thumbWell.layer?.masksToBounds = true
        thumbWell.layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.05).cgColor
        shell.addSubview(thumbWell)

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.image = NSImage(
            systemSymbolName: "doc.richtext",
            accessibilityDescription: "Markdown document"
        )
        thumbnail.contentTintColor = .tertiaryLabelColor
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbWell.addSubview(thumbnail)
        loadThumbnail()

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        shell.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .tertiaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        shell.addSubview(detailLabel)

        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.imageScaling = .scaleProportionallyUpOrDown
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.alphaValue = 0
        arrow.wantsLayer = true
        shell.addSubview(arrow)

        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            thumbWell.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 8),
            thumbWell.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            thumbWell.widthAnchor.constraint(equalToConstant: 34),
            thumbWell.heightAnchor.constraint(equalToConstant: 34),

            thumbnail.leadingAnchor.constraint(equalTo: thumbWell.leadingAnchor, constant: 5),
            thumbnail.trailingAnchor.constraint(equalTo: thumbWell.trailingAnchor, constant: -5),
            thumbnail.topAnchor.constraint(equalTo: thumbWell.topAnchor, constant: 5),
            thumbnail.bottomAnchor.constraint(equalTo: thumbWell.bottomAnchor, constant: -5),

            titleLabel.leadingAnchor.constraint(equalTo: thumbWell.trailingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -8),
            titleLabel.topAnchor.constraint(equalTo: shell.topAnchor, constant: 9),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),

            arrow.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -10),
            arrow.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 9),
            arrow.heightAnchor.constraint(equalToConstant: 12),
        ])

        updateSurface(animated: false)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        if let thumbnailRequest {
            QLThumbnailGenerator.shared.cancel(thumbnailRequest)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateSurface(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        updateSurface(animated: true)
    }

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updateSurface(animated: true)
        super.mouseDown(with: event)
        isPressed = false
        updateSurface(animated: true)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface(animated: false)
    }

    private func updateSurface(animated: Bool) {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let changes = {
            let background: NSColor
            if self.isPressed {
                background = NSColor.controlAccentColor.withAlphaComponent(0.14)
            } else if self.isHovered {
                background = NSColor.controlAccentColor.withAlphaComponent(increaseContrast ? 0.12 : 0.08)
            } else {
                background = .clear
            }
            self.shell.layer?.backgroundColor = background.cgColor
            self.shell.layer?.borderWidth = 0
            let arrowAlpha: CGFloat = self.isHovered ? 0.85 : 0
            if animated {
                self.arrow.animator().alphaValue = arrowAlpha
                self.thumbnail.animator().alphaValue = self.isHovered ? 1 : 0.9
            } else {
                self.arrow.alphaValue = arrowAlpha
                self.thumbnail.alphaValue = self.isHovered ? 1 : 0.9
            }
            self.arrow.layer?.setAffineTransform(
                CGAffineTransform(translationX: self.isHovered ? 2 : 0, y: 0)
            )
        }

        if animated {
            Motion.run(
                reduceMotion: reduceMotion,
                duration: Motion.quick,
                curve: .easeOut,
                changes: { _ in changes() }
            )
        } else {
            changes()
        }
    }

    private func loadThumbnail() {
        let url = URL(fileURLWithPath: recent.path)
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: NSSize(width: 64, height: 64),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        thumbnailRequest = request
        let expectedPath = recent.path
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] thumbnail, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                guard self.thumbnail.superview != nil else { return }
                guard url.path == expectedPath, let image = thumbnail?.nsImage else { return }
                let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                self.thumbnail.alphaValue = reduceMotion ? 1 : 0
                self.thumbnail.image = image
                self.thumbnail.contentTintColor = nil
                guard !reduceMotion else { return }
                Motion.run(
                    reduceMotion: false,
                    duration: Motion.quick,
                    curve: .easeOut,
                    changes: { _ in self.thumbnail.animator().alphaValue = 1 }
                )
            }
        }
    }
}

// MARK: - Drop zone

private final class DropZoneView: NSView {
    private let iconView = NSImageView(
        image: NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Drop files")!
    )
    private let titleLabel = NSTextField(labelWithString: "Drop a Markdown file")
    private let detailLabel = NSTextField(labelWithString: "Anywhere in this window")

    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            needsDisplay = true
            applyLabelColors()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Markdown drop zone")
        setAccessibilityValue("Drop a Markdown file anywhere in this window")

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 12, weight: .medium)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)

        let copy = NSStackView(views: [titleLabel, detailLabel])
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 1

        addSubview(iconView)
        addSubview(copy)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            copy.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            copy.centerYAnchor.constraint(equalTo: centerYAnchor),
            copy.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -14),
        ])
        applyLabelColors()
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
        applyLabelColors()
    }

    private func applyLabelColors() {
        iconView.contentTintColor = isActive ? .controlAccentColor : .tertiaryLabelColor
        titleLabel.textColor = isActive ? .labelColor : .secondaryLabelColor
        detailLabel.textColor = isActive ? .controlAccentColor : .tertiaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let fill = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        if isActive {
            NSColor.controlAccentColor.withAlphaComponent(0.1).setFill()
        } else {
            NSColor.controlBackgroundColor
                .withAlphaComponent(increaseContrast ? 0.88 : 0.22)
                .setFill()
        }
        fill.fill()

        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7)
        outline.lineWidth = isActive ? 1.25 : 1
        if isActive {
            outline.setLineDash([3.5, 3.5], count: 2, phase: 0)
            NSColor.controlAccentColor.setStroke()
        } else {
            outline.setLineDash([3, 4], count: 2, phase: 0)
            NSColor.separatorColor.withAlphaComponent(increaseContrast ? 0.55 : 0.32).setStroke()
        }
        outline.stroke()
    }
}

// MARK: - Brand

private final class BrandMarkView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let tile = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        NSColor.controlAccentColor.setFill()
        tile.fill()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(1.6)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: bounds.minX + 6, y: bounds.maxY - 7))
        context.addLine(to: CGPoint(x: bounds.maxX - 6, y: bounds.minY + 7))
        context.move(to: CGPoint(x: bounds.maxX - 10, y: bounds.minY + 7))
        context.addLine(to: CGPoint(x: bounds.maxX - 6, y: bounds.minY + 7))
        context.addLine(to: CGPoint(x: bounds.maxX - 6, y: bounds.minY + 11))
        context.strokePath()
        context.restoreGState()
    }
}
