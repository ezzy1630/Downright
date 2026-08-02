import AppKit
import MarkdownRender
import QuickLookThumbnailing

@MainActor
final class StartWindowController: NSWindowController {
    var onOpen: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onNew: (() -> Void)?

    convenience init(recents: [RecentDocument]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 980, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Downright"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 860, height: 560)
        window.backgroundColor = .windowBackgroundColor
        window.center()
        self.init(window: window)
        window.contentView = StartView(recents: recents, owner: self)
    }

    @objc func openRecent(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onOpen?(URL(fileURLWithPath: path))
    }

    @objc func openPanel(_ sender: Any?) { onOpenPanel?() }
    @objc func newDocument(_ sender: Any?) { onNew?() }
}

private final class StartView: NSView {
    private weak var owner: StartWindowController?
    private let dropZone: DropZoneView
    private let background = StartBackgroundView()

    init(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        self.dropZone = DropZoneView()
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
        columns.alignment = .top
        columns.distribution = .fill
        columns.spacing = 34
        canvas.addSubview(columns)

        let hero = StartHeroView(owner: owner, dropZone: dropZone)
        let recentPanel = RecentDocumentsPanel(recents: recents, owner: owner)
        hero.translatesAutoresizingMaskIntoConstraints = false
        recentPanel.translatesAutoresizingMaskIntoConstraints = false
        columns.addArrangedSubview(hero)
        columns.addArrangedSubview(recentPanel)

        hero.setContentHuggingPriority(.defaultLow, for: .horizontal)
        hero.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        recentPanel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        recentPanel.setContentCompressionResistancePriority(.required, for: .horizontal)

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
            columns.topAnchor.constraint(equalTo: canvas.topAnchor, constant: 34),
            columns.bottomAnchor.constraint(equalTo: canvas.bottomAnchor, constant: -42),

            hero.widthAnchor.constraint(equalTo: columns.widthAnchor, multiplier: 0.54),
            recentPanel.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])
    }

    required init?(coder: NSCoder) { nil }

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

private final class StartBackgroundView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let base = NSColor.windowBackgroundColor
        base.setFill()
        dirtyRect.fill()

        let accent = NSColor.controlAccentColor
        let glow = NSGradient(colors: [
            accent.withAlphaComponent(0.10),
            accent.withAlphaComponent(0.035),
            .clear,
        ])
        let glowRect = NSRect(
            x: bounds.maxX - 360,
            y: bounds.maxY - 280,
            width: 460,
            height: 420
        )
        glow?.draw(in: glowRect, relativeCenterPosition: NSPoint(x: 0.35, y: 0.55))

        let secondaryGlow = NSGradient(colors: [
            NSColor.white.withAlphaComponent(0.025),
            .clear,
        ])
        secondaryGlow?.draw(
            in: NSRect(x: -160, y: -120, width: 420, height: 360),
            relativeCenterPosition: NSPoint(x: 0.65, y: 0.35)
        )

        let hairline = NSBezierPath()
        hairline.move(to: NSPoint(x: 52, y: bounds.maxY - 1))
        hairline.line(to: NSPoint(x: bounds.maxX - 52, y: bounds.maxY - 1))
        NSColor.separatorColor.withAlphaComponent(0.22).setStroke()
        hairline.lineWidth = 1
        hairline.stroke()
    }
}

private final class StartHeroView: NSView {
    private let openButton: StartActionButton
    private let newButton: StartActionButton

    init(owner: StartWindowController, dropZone: DropZoneView) {
        openButton = StartActionButton(
            title: "Open file",
            shortcut: "⌘ O",
            symbolName: "arrow.up.right",
            kind: .primary,
            target: owner,
            action: #selector(StartWindowController.openPanel(_:))
        )
        newButton = StartActionButton(
            title: "New document",
            shortcut: "⌘ N",
            symbolName: "plus",
            kind: .secondary,
            target: owner,
            action: #selector(StartWindowController.newDocument(_:))
        )
        super.init(frame: .zero)

        let brand = BrandMarkView()
        brand.translatesAutoresizingMaskIntoConstraints = false
        let brandLabel = NSTextField(labelWithString: "DOWNRIGHT")
        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        brandLabel.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        brandLabel.textColor = .secondaryLabelColor
        brandLabel.setContentHuggingPriority(.required, for: .horizontal)

        let brandRow = NSStackView(views: [brand, brandLabel])
        brandRow.translatesAutoresizingMaskIntoConstraints = false
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 10

        let eyebrow = NSTextField(labelWithString: "YOUR MARKDOWN DESK")
        eyebrow.translatesAutoresizingMaskIntoConstraints = false
        eyebrow.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        eyebrow.textColor = NSColor.controlAccentColor
        eyebrow.setContentHuggingPriority(.required, for: .vertical)

        let title = NSTextField(labelWithString: "Read deeply.\nWrite lightly.")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 40, weight: .bold)
        title.textColor = .labelColor
        title.maximumNumberOfLines = 2
        title.lineBreakMode = .byWordWrapping
        title.attributedStringValue = NSAttributedString(
            string: title.stringValue,
            attributes: [
                .font: NSFont.systemFont(ofSize: 40, weight: .bold),
                .foregroundColor: NSColor.labelColor,
                .kern: -1.3,
            ]
        )

        let subtitle = NSTextField(
            wrappingLabelWithString: "A native home for Markdown that stays out of the way."
        )
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        subtitle.font = .systemFont(ofSize: 16, weight: .regular)
        subtitle.textColor = .secondaryLabelColor
        subtitle.maximumNumberOfLines = 0
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.preferredMaxLayoutWidth = 360

        let actions = NSStackView(views: [openButton, newButton])
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10

        let hint = NSTextField(labelWithString: "Open with ⌘ O  ·  New with ⌘ N")
        hint.translatesAutoresizingMaskIntoConstraints = false
        hint.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        hint.textColor = .tertiaryLabelColor
        hint.lineBreakMode = .byTruncatingTail

        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: 64).isActive = true

        dropZone.translatesAutoresizingMaskIntoConstraints = false

        let footer = NSTextField(
            wrappingLabelWithString: "Drop .md or .markdown files anywhere in this window."
        )
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.font = .systemFont(ofSize: 11, weight: .regular)
        footer.textColor = .tertiaryLabelColor
        footer.maximumNumberOfLines = 2
        footer.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [brandRow, eyebrow, title, subtitle, actions, hint, spacer, dropZone, footer])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        addSubview(stack)

        NSLayoutConstraint.activate([
            brand.widthAnchor.constraint(equalToConstant: 28),
            brand.heightAnchor.constraint(equalToConstant: 28),
            title.widthAnchor.constraint(lessThanOrEqualToConstant: 390),
            subtitle.widthAnchor.constraint(lessThanOrEqualToConstant: 370),
            openButton.widthAnchor.constraint(equalToConstant: 206),
            openButton.heightAnchor.constraint(equalToConstant: 48),
            newButton.widthAnchor.constraint(equalToConstant: 190),
            newButton.heightAnchor.constraint(equalToConstant: 48),
            actions.widthAnchor.constraint(equalToConstant: 406),
            dropZone.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dropZone.heightAnchor.constraint(equalToConstant: 96),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.setCustomSpacing(30, after: brandRow)
        stack.setCustomSpacing(16, after: eyebrow)
        stack.setCustomSpacing(14, after: title)
        stack.setCustomSpacing(24, after: subtitle)
        stack.setCustomSpacing(11, after: actions)
        stack.setCustomSpacing(4, after: hint)
        stack.setCustomSpacing(18, after: dropZone)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Downright welcome")
    }

    required init?(coder: NSCoder) { nil }
}

private final class RecentDocumentsPanel: NSView {
    private var recentCards: [NSView] = []
    private var didAnimateRecentCards = false
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

    init(recents: [RecentDocument], owner: StartWindowController) {
        super.init(frame: .zero)

        let overline = NSTextField(labelWithString: "RECENT")
        overline.translatesAutoresizingMaskIntoConstraints = false
        overline.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        overline.textColor = NSColor.controlAccentColor

        let visibleCount = min(recents.count, 6)
        let countLabel = NSTextField(labelWithString: visibleCount == 1 ? "1 note" : "\(visibleCount) notes")
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedSystemFont(ofSize: 10, weight: .regular)
        countLabel.textColor = .tertiaryLabelColor
        countLabel.alignment = .right

        let overlineRow = NSStackView(views: [overline, countLabel])
        overlineRow.translatesAutoresizingMaskIntoConstraints = false
        overlineRow.orientation = .horizontal
        overlineRow.alignment = .centerY
        overlineRow.distribution = .fill

        let heading = NSTextField(labelWithString: recents.isEmpty ? "Start with a blank page" : "Continue where you left off")
        heading.translatesAutoresizingMaskIntoConstraints = false
        heading.font = .systemFont(ofSize: 20, weight: .semibold)
        heading.textColor = .labelColor
        heading.maximumNumberOfLines = 2
        heading.lineBreakMode = .byWordWrapping

        let detail = NSTextField(
            wrappingLabelWithString: recents.isEmpty
                ? "Your recent Markdown files will appear here."
                : "Your latest Markdown files, one click away."
        )
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 12, weight: .regular)
        detail.textColor = .secondaryLabelColor
        detail.maximumNumberOfLines = 2
        detail.lineBreakMode = .byWordWrapping

        let header = NSStackView(views: [overlineRow, heading, detail])
        header.translatesAutoresizingMaskIntoConstraints = false
        header.orientation = .vertical
        header.alignment = .leading
        header.spacing = 0

        let list = NSStackView()
        list.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .width
        list.distribution = .fill
        list.spacing = 10

        if recents.isEmpty {
            let empty = RecentEmptyState()
            empty.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 224).isActive = true
            recentCards = [empty]
        } else {
            for recent in recents.prefix(6) {
                let card = RecentDocumentButton(recent: recent, target: owner)
                card.translatesAutoresizingMaskIntoConstraints = false
                card.heightAnchor.constraint(equalToConstant: 72).isActive = true
                list.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                recentCards.append(card)
            }
        }

        let panel = SurfaceView()
        panel.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(header)
        panel.addSubview(list)

        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 24),
            header.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -24),
            header.topAnchor.constraint(equalTo: panel.topAnchor, constant: 24),

            list.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 16),
            list.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -16),
            list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 20),
            list.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -16),
        ])

        addSubview(panel)
        NSLayoutConstraint.activate([
            panel.leadingAnchor.constraint(equalTo: leadingAnchor),
            panel.trailingAnchor.constraint(equalTo: trailingAnchor),
            panel.topAnchor.constraint(equalTo: topAnchor),
            panel.bottomAnchor.constraint(equalTo: bottomAnchor),
            panel.widthAnchor.constraint(greaterThanOrEqualToConstant: 340),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Recent Markdown documents")
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didAnimateRecentCards else { return }
        didAnimateRecentCards = true
        guard !reduceMotion else { return }

        for (index, card) in recentCards.enumerated() {
            card.alphaValue = 0
            let delay = 0.045 * Double(index)
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak card] in
                guard let card, card.window != nil else { return }
                Motion.run(
                    reduceMotion: false,
                    duration: Motion.standard,
                    curve: .spring,
                    changes: { _ in card.animator().alphaValue = 1 }
                )
            }
        }
    }
}

private final class RecentEmptyState: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text", accessibilityDescription: "Markdown document")!)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .tertiaryLabelColor

        let title = NSTextField(labelWithString: "Nothing here yet")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 14, weight: .semibold)
        title.textColor = .secondaryLabelColor

        let detail = NSTextField(wrappingLabelWithString: "Open a Markdown file to build your desk.")
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .tertiaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 2

        let stack = NSStackView(views: [icon, title, detail])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 7
        addSubview(stack)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 28),
            icon.heightAnchor.constraint(equalToConstant: 28),
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

private final class SurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 20
        layer?.masksToBounds = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.24).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor
    }

    required init?(coder: NSCoder) { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.24).cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.16).cgColor
    }
}

private final class StartActionButton: NSButton {
    enum Kind { case primary, secondary }

    private let kind: Kind
    private let shell = NSView()
    private let titleLabel: NSTextField
    private let shortcutLabel: NSTextField
    private let iconView: NSImageView
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
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
        focusRingType = .default
        keyEquivalent = shortcut == "⌘ O" ? "o" : "n"
        keyEquivalentModifierMask = [.command]
        setAccessibilityRole(.button)
        setAccessibilityLabel(titleLabel.stringValue)
        setAccessibilityHelp(shortcut)
        wantsLayer = true

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 13
        shell.layer?.masksToBounds = true
        addSubview(shell)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = kind == .primary ? .white : .labelColor
        titleLabel.isSelectable = false
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        shell.addSubview(titleLabel)

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
        shortcutLabel.alignment = .center
        shortcutLabel.textColor = kind == .primary
            ? NSColor.white.withAlphaComponent(0.84)
            : NSColor.secondaryLabelColor
        shortcutLabel.wantsLayer = true
        shortcutLabel.layer?.cornerRadius = 5
        shortcutLabel.layer?.masksToBounds = true
        shell.addSubview(shortcutLabel)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = kind == .primary ? .white : .labelColor
        shell.addSubview(iconView)

        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 16),
            titleLabel.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            shortcutLabel.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            shortcutLabel.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            shortcutLabel.widthAnchor.constraint(equalToConstant: 32),
            shortcutLabel.heightAnchor.constraint(equalToConstant: 20),
            iconView.leadingAnchor.constraint(equalTo: shortcutLabel.trailingAnchor, constant: 10),
            iconView.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -15),
            iconView.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
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
        let changes = {
            let accent = NSColor.controlAccentColor
            let base: NSColor
            if self.kind == .primary {
                base = self.isPressed
                    ? accent.withAlphaComponent(0.76)
                    : accent.withAlphaComponent(self.isHovered ? 0.92 : 0.82)
            } else {
                base = NSColor.controlBackgroundColor.withAlphaComponent(self.isHovered ? 0.82 : 0.58)
            }
            self.shell.layer?.backgroundColor = base.cgColor
            self.shell.layer?.borderWidth = self.kind == .secondary ? 1 : 0
            self.shell.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.30).cgColor
            self.shortcutLabel.layer?.backgroundColor = self.kind == .primary
                ? NSColor.white.withAlphaComponent(0.13).cgColor
                : NSColor.labelColor.withAlphaComponent(0.07).cgColor
            self.iconView.alphaValue = self.isHovered ? 1 : 0.86
        }

        if animated {
            Motion.run(
                reduceMotion: reduceMotion,
                duration: Motion.quick,
                curve: .spring,
                changes: { _ in changes() }
            )
        } else {
            changes()
        }
    }
}

private final class RecentDocumentButton: NSButton {
    private let recent: RecentDocument
    private let shell = NSView()
    private let hoverSurface = NSView()
    private let activeMarker = NSView()
    private let thumbnail = NSImageView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let arrow = NSImageView(image: NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Open")!)
    private let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    private var isHovered = false
    private var isPressed = false

    init(recent: RecentDocument, target: StartWindowController) {
        self.recent = recent
        titleLabel = NSTextField(labelWithString: recent.displayName)
        let words = recent.wordCount == 1 ? "1 word" : "\(recent.wordCount) words"
        let context = recent.firstHeading.isEmpty ? "Markdown document" : recent.firstHeading
        detailLabel = NSTextField(labelWithString: "\(context)  ·  \(words)")
        super.init(frame: .zero)

        self.target = target
        action = #selector(StartWindowController.openRecent(_:))
        identifier = NSUserInterfaceItemIdentifier(recent.path)
        setButtonType(.momentaryPushIn)
        isBordered = false
        self.title = ""
        focusRingType = .default
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(recent.displayName)")
        setAccessibilityValue(detailLabel.stringValue)
        wantsLayer = true

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 14
        shell.layer?.masksToBounds = true
        addSubview(shell)

        hoverSurface.translatesAutoresizingMaskIntoConstraints = false
        hoverSurface.wantsLayer = true
        hoverSurface.layer?.cornerRadius = 14
        hoverSurface.layer?.masksToBounds = true
        hoverSurface.alphaValue = 0
        shell.addSubview(hoverSurface)

        activeMarker.translatesAutoresizingMaskIntoConstraints = false
        activeMarker.wantsLayer = true
        activeMarker.layer?.cornerRadius = 1
        activeMarker.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        activeMarker.alphaValue = 0
        shell.addSubview(activeMarker)

        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: "Markdown document")
        thumbnail.contentTintColor = .secondaryLabelColor
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = 10
        thumbnail.layer?.masksToBounds = true
        shell.addSubview(thumbnail)
        Self.loadThumbnail(for: URL(fileURLWithPath: recent.path), into: thumbnail, expectedPath: recent.path)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        shell.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11, weight: .regular)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        shell.addSubview(detailLabel)

        arrow.translatesAutoresizingMaskIntoConstraints = false
        arrow.imageScaling = .scaleProportionallyUpOrDown
        arrow.contentTintColor = .tertiaryLabelColor
        arrow.alphaValue = 0.56
        arrow.wantsLayer = true
        shell.addSubview(arrow)

        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            hoverSurface.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            hoverSurface.trailingAnchor.constraint(equalTo: shell.trailingAnchor),
            hoverSurface.topAnchor.constraint(equalTo: shell.topAnchor),
            hoverSurface.bottomAnchor.constraint(equalTo: shell.bottomAnchor),

            activeMarker.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 18),
            activeMarker.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -18),
            activeMarker.bottomAnchor.constraint(equalTo: shell.bottomAnchor),
            activeMarker.heightAnchor.constraint(equalToConstant: 2),

            thumbnail.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 12),
            thumbnail.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            thumbnail.widthAnchor.constraint(equalToConstant: 48),
            thumbnail.heightAnchor.constraint(equalToConstant: 48),

            titleLabel.leadingAnchor.constraint(equalTo: thumbnail.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(equalTo: arrow.leadingAnchor, constant: -12),
            titleLabel.topAnchor.constraint(equalTo: shell.topAnchor, constant: 17),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),

            arrow.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -16),
            arrow.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            arrow.widthAnchor.constraint(equalToConstant: 11),
            arrow.heightAnchor.constraint(equalToConstant: 16),
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
        let changes = {
            let background: NSColor
            if self.isPressed {
                background = NSColor.controlAccentColor.withAlphaComponent(0.12)
            } else {
                background = NSColor.controlBackgroundColor.withAlphaComponent(0.30)
            }
            self.shell.layer?.backgroundColor = background.cgColor
            self.shell.layer?.borderWidth = 1
            self.shell.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(self.isHovered ? 0.38 : 0.14).cgColor
            self.hoverSurface.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(
                self.isPressed ? 0.16 : 0.08
            ).cgColor
            let hoverAlpha: CGFloat = self.isHovered ? 1 : 0
            let arrowAlpha: CGFloat = self.isHovered ? 0.96 : 0.56
            if animated {
                self.hoverSurface.animator().alphaValue = hoverAlpha
                self.activeMarker.animator().alphaValue = hoverAlpha
                self.arrow.animator().alphaValue = arrowAlpha
                self.thumbnail.animator().alphaValue = self.isHovered ? 1 : 0.86
            } else {
                self.hoverSurface.alphaValue = hoverAlpha
                self.activeMarker.alphaValue = hoverAlpha
                self.arrow.alphaValue = arrowAlpha
                self.thumbnail.alphaValue = self.isHovered ? 1 : 0.86
            }
            self.arrow.layer?.setAffineTransform(
                CGAffineTransform(translationX: self.isHovered ? 3 : 0, y: 0)
            )
        }

        if animated {
            Motion.run(
                reduceMotion: reduceMotion,
                duration: Motion.quick,
                curve: .spring,
                changes: { _ in changes() }
            )
        } else {
            changes()
        }
    }

    private static func loadThumbnail(for url: URL, into imageView: NSImageView, expectedPath: String) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: NSSize(width: 64, height: 64),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            DispatchQueue.main.async {
                guard imageView.window != nil || imageView.superview != nil else { return }
                guard url.path == expectedPath, let image = thumbnail?.nsImage else { return }
                imageView.image = image
                imageView.contentTintColor = nil
            }
        }
    }
}

private final class DropZoneView: NSView {
    var isActive = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        setAccessibilityRole(.group)
        setAccessibilityLabel("Markdown drop zone")
        setAccessibilityValue("Drop Markdown files here")

        let icon = NSImageView(image: NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: "Drop files")!)
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .secondaryLabelColor

        let title = NSTextField(labelWithString: "Drop files here")
        title.translatesAutoresizingMaskIntoConstraints = false
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        title.textColor = .labelColor

        let detail = NSTextField(labelWithString: "Markdown files open as native documents")
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor

        let copy = NSStackView(views: [title, detail])
        copy.translatesAutoresizingMaskIntoConstraints = false
        copy.orientation = .vertical
        copy.alignment = .leading
        copy.spacing = 3

        addSubview(icon)
        addSubview(copy)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 24),
            icon.heightAnchor.constraint(equalToConstant: 24),
            copy.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 12),
            copy.centerYAnchor.constraint(equalTo: centerYAnchor),
            copy.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),
        ])
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let fill = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 14, yRadius: 14)
        (isActive
            ? NSColor.controlAccentColor.withAlphaComponent(0.13)
            : NSColor.controlBackgroundColor.withAlphaComponent(0.22)
        ).setFill()
        fill.fill()

        let outline = NSBezierPath(roundedRect: bounds.insetBy(dx: 1.5, dy: 1.5), xRadius: 13, yRadius: 13)
        outline.lineWidth = isActive ? 1.5 : 1
        outline.setLineDash([5, 5], count: 2, phase: 0)
        (isActive
            ? NSColor.controlAccentColor
            : NSColor.separatorColor.withAlphaComponent(0.45)
        ).setStroke()
        outline.stroke()
    }
}

private final class BrandMarkView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        let rect = bounds.insetBy(dx: 1, dy: 1)
        let tile = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
        NSColor.controlAccentColor.setFill()
        tile.fill()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.96).cgColor)
        context.setLineWidth(2.2)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: bounds.minX + 8, y: bounds.maxY - 9))
        context.addLine(to: CGPoint(x: bounds.maxX - 8, y: bounds.minY + 9))
        context.move(to: CGPoint(x: bounds.maxX - 13, y: bounds.minY + 9))
        context.addLine(to: CGPoint(x: bounds.maxX - 8, y: bounds.minY + 9))
        context.addLine(to: CGPoint(x: bounds.maxX - 8, y: bounds.minY + 14))
        context.strokePath()
        context.restoreGState()
    }
}
