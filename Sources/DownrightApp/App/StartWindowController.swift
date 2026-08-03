import AppKit
import MarkdownRender
import QuickLookThumbnailing

/// Six rows fit the compact start window without vertical scroll or dead space.
private let startRecentDisplayLimit = 6

@MainActor
final class StartWindowController: NSWindowController {
    static let recentDisplayLimit = startRecentDisplayLimit

    var onOpen: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onNew: (() -> Void)?

    private var startView: StartView? { window?.contentView as? StartView }
    fileprivate var isHandingOff = false

    convenience init(recents: [RecentDocument]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 740, height: 430),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Downright"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 660, height: 390)
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
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
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

    fileprivate func beginHandoff() -> Bool {
        guard !isHandingOff else { return false }
        isHandingOff = true
        return true
    }

    @objc func openRecent(_ sender: NSButton) {
        guard beginHandoff() else { return }
        let path = sender.identifier?.rawValue
            ?? (sender as? RecentDocumentButton).map(\.documentPath)
        guard let path, !path.isEmpty else {
            isHandingOff = false
            return
        }
        onOpen?(URL(fileURLWithPath: path))
        // Failed opens leave this window visible — unlock so the user can retry.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.isHandingOff = false
        }
    }

    @objc func openPanel(_ sender: Any?) {
        guard beginHandoff() else { return }
        onOpenPanel?()
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
    private let background = StartBackgroundView()
    private let recentPanel: RecentDocumentsPanel
    private let hero: StartHeroView
    /// Clear of traffic lights; keep content below chrome.
    private static let titlebarClearance: CGFloat = 44

    var preferredFirstResponder: NSView { hero.openButton }

    init(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        self.recentPanel = RecentDocumentsPanel(recents: recents, owner: owner)
        self.hero = StartHeroView(owner: owner)
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
        addSubview(scroll)

        let canvas = NSView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = canvas

        // One compact composition: hero + recents, centered — no stretched columns.
        let columns = NSStackView()
        columns.translatesAutoresizingMaskIntoConstraints = false
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.distribution = .fill
        columns.spacing = 32
        canvas.addSubview(columns)

        hero.translatesAutoresizingMaskIntoConstraints = false
        recentPanel.translatesAutoresizingMaskIntoConstraints = false
        columns.addArrangedSubview(hero)
        columns.addArrangedSubview(recentPanel)

        hero.setContentHuggingPriority(.required, for: .horizontal)
        hero.setContentCompressionResistancePriority(.required, for: .horizontal)
        recentPanel.setContentHuggingPriority(.required, for: .horizontal)
        recentPanel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let centerY = columns.centerYAnchor.constraint(equalTo: canvas.centerYAnchor, constant: -4)
        centerY.priority = .defaultHigh
        let centerX = columns.centerXAnchor.constraint(equalTo: canvas.centerXAnchor)
        centerX.priority = .defaultHigh

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

            columns.leadingAnchor.constraint(greaterThanOrEqualTo: canvas.leadingAnchor, constant: 32),
            columns.trailingAnchor.constraint(lessThanOrEqualTo: canvas.trailingAnchor, constant: -32),
            columns.topAnchor.constraint(greaterThanOrEqualTo: canvas.topAnchor, constant: Self.titlebarClearance),
            columns.bottomAnchor.constraint(lessThanOrEqualTo: canvas.bottomAnchor, constant: -24),
            centerX,
            centerY,

            hero.widthAnchor.constraint(equalToConstant: 248),
            recentPanel.widthAnchor.constraint(equalToConstant: 312),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func reloadRecents(_ recents: [RecentDocument]) {
        guard let owner else { return }
        recentPanel.reload(recents: recents, owner: owner)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = droppedURLs(from: sender.draggingPasteboard)
        let ok = !urls.isEmpty
        hero.setDropActive(ok)
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hero.setDropActive(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(from: sender.draggingPasteboard)
        hero.setDropActive(false)
        guard !urls.isEmpty else { return false }
        guard owner?.beginHandoff() == true else { return false }
        urls.forEach { owner?.onOpen?($0) }
        DispatchQueue.main.async { [weak owner] in
            guard let owner, owner.window?.isVisible == true else { return }
            owner.isHandingOff = false
        }
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
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

// MARK: - Hero

private final class StartHeroView: NSView {
    let openButton: StartActionButton
    private let newButton: StartActionButton
    private let brandLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "Open a Markdown file and stay with it.")
    private let dropHint = NSTextField(labelWithString: "Or drop a file anywhere")
    private var didPlayArrival = false
    private var isDropActive = false
    private static let idleDropHint = "Or drop a file anywhere"

    init(owner: StartWindowController) {
        // No trailing ellipsis on the start screen — it reads as truncated text.
        // Menus keep the HIG "…" for dialogs.
        openButton = StartActionButton(
            title: "Open File",
            shortcut: "⌘O",
            kind: .primary,
            target: owner,
            action: #selector(StartWindowController.openPanel(_:))
        )
        newButton = StartActionButton(
            title: "New Document",
            shortcut: "⌘N",
            kind: .secondary,
            target: owner,
            action: #selector(StartWindowController.newDocument(_:))
        )
        super.init(frame: .zero)

        let brand = BrandMarkView()
        brand.translatesAutoresizingMaskIntoConstraints = false

        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        brandLabel.setContentHuggingPriority(.required, for: .horizontal)
        configurePassiveLabel(brandLabel)

        let brandRow = NSStackView(views: [brand, brandLabel])
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 8

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.maximumNumberOfLines = 2
        configurePassiveLabel(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = 240
        configurePassiveLabel(subtitleLabel)

        // Keep the actions on one optical axis. Their intrinsic widths differ,
        // so leading or trailing alignment makes the group feel off-balance.
        let actions = NSStackView(views: [openButton, newButton])
        actions.orientation = .vertical
        actions.alignment = .centerX
        actions.spacing = 8
        actions.distribution = .fillEqually

        dropHint.translatesAutoresizingMaskIntoConstraints = false
        dropHint.font = .systemFont(ofSize: 12, weight: .regular)
        dropHint.textColor = .secondaryLabelColor
        dropHint.alignment = .center
        configurePassiveLabel(dropHint)

        let dropSlot = NSView()
        dropSlot.translatesAutoresizingMaskIntoConstraints = false
        dropSlot.addSubview(dropHint)

        let stack = NSStackView(views: [brandRow, titleLabel, subtitleLabel, actions, dropSlot])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        addSubview(stack)

        NSLayoutConstraint.activate([
            brand.widthAnchor.constraint(equalToConstant: 18),
            brand.heightAnchor.constraint(equalToConstant: 18),
            openButton.heightAnchor.constraint(equalToConstant: 34),
            newButton.heightAnchor.constraint(equalToConstant: 34),
            openButton.widthAnchor.constraint(equalToConstant: 156),
            newButton.widthAnchor.constraint(equalTo: openButton.widthAnchor),
            actions.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 248),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 240),
            dropSlot.widthAnchor.constraint(equalTo: stack.widthAnchor),
            dropHint.centerXAnchor.constraint(equalTo: dropSlot.centerXAnchor),
            dropHint.topAnchor.constraint(equalTo: dropSlot.topAnchor),
            dropHint.bottomAnchor.constraint(equalTo: dropSlot.bottomAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.setCustomSpacing(14, after: brandRow)
        stack.setCustomSpacing(8, after: titleLabel)
        stack.setCustomSpacing(18, after: subtitleLabel)
        stack.setCustomSpacing(16, after: actions)

        applyTextColors()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Downright welcome")
    }

    required init?(coder: NSCoder) { nil }

    func setDropActive(_ active: Bool) {
        guard active != isDropActive else { return }
        isDropActive = active
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let changes = {
            self.dropHint.textColor = active ? NSColor.controlAccentColor : NSColor.secondaryLabelColor
            self.dropHint.stringValue = active
                ? "Release to open"
                : Self.idleDropHint
        }
        if reduceMotion {
            changes()
        } else {
            Motion.run(reduceMotion: false, duration: Motion.quick, curve: .easeOut) { _ in changes() }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTextColors()
    }

    private func applyTextColors() {
        let titleParagraph = NSMutableParagraphStyle()
        titleParagraph.lineSpacing = 1
        brandLabel.attributedStringValue = NSAttributedString(
            string: "DOWNRIGHT",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: NSColor.secondaryLabelColor,
                .kern: 0.8,
            ]
        )
        titleLabel.attributedStringValue = NSAttributedString(
            string: "Read deeply.\nWrite lightly.",
            attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: NSColor.labelColor,
                .kern: -0.3,
                .paragraphStyle: titleParagraph,
            ]
        )
        subtitleLabel.textColor = .secondaryLabelColor
        dropHint.textColor = isDropActive ? .controlAccentColor : .secondaryLabelColor
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !didPlayArrival else { return }
        didPlayArrival = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        wantsLayer = true
        alphaValue = 0
        layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -4))
        Motion.run(reduceMotion: false, duration: Motion.standard, curve: .easeOut) { _ in
            self.animator().alphaValue = 1
            self.layer?.setAffineTransform(.identity)
        }
    }
}

private func configurePassiveLabel(_ field: NSTextField) {
    field.isEditable = false
    field.isSelectable = false
    field.isBezeled = false
    field.drawsBackground = false
    field.refusesFirstResponder = true
}

// MARK: - Recents

private final class RecentDocumentsPanel: NSView {
    private weak var owner: StartWindowController?
    private let headerLabel = NSTextField(labelWithString: "Recent")
    private let list = NSStackView()
    private var recentCards: [NSView] = []
    private var displayedRecents: [RecentDocument] = []
    private var didAnimate = false

    init(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        super.init(frame: .zero)

        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 14
        layer?.shadowOffset = NSSize(width: 0, height: -4)
        applySurface()

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        configurePassiveLabel(headerLabel)

        list.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 3

        addSubview(headerLabel)
        addSubview(list)

        NSLayoutConstraint.activate([
            headerLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            headerLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            headerLabel.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            list.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            list.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            list.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),

            widthAnchor.constraint(equalToConstant: 312),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Recent Markdown documents")
        rebuild(recents: recents, animate: false)
    }

    required init?(coder: NSCoder) { nil }

    func reload(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        guard recents != displayedRecents else { return }
        rebuild(recents: recents, animate: window != nil)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applySurface()
        headerLabel.textColor = .secondaryLabelColor
    }

    private func applySurface() {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let reduceTransparency = NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency
        // Keep the panel solid enough that secondary text stays readable over the
        // window backdrop — 0.45 was washing metadata into the background.
        let alpha: CGFloat = (increaseContrast || reduceTransparency) ? 0.98 : 0.78
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(alpha).cgColor
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(increaseContrast ? 0.55 : 0.30).cgColor
    }

    private func rebuild(recents: [RecentDocument], animate: Bool) {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        recentCards = []
        displayedRecents = recents
        didAnimate = false

        guard let owner else { return }

        if recents.isEmpty {
            let empty = RecentEmptyState()
            empty.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            // Keep the no-recents panel close to the populated panel's visual
            // weight so the start screen does not jump between two compositions.
            empty.heightAnchor.constraint(equalToConstant: 180).isActive = true
            recentCards = [empty]
        } else {
            let titles = RecentRowCopy.disambiguatedTitles(for: recents)
            for (index, recent) in recents.prefix(StartWindowController.recentDisplayLimit).enumerated() {
                let card = RecentDocumentButton(
                    recent: recent,
                    title: titles[index],
                    target: owner
                )
                card.translatesAutoresizingMaskIntoConstraints = false
                card.heightAnchor.constraint(equalToConstant: 42).isActive = true
                list.addArrangedSubview(card)
                card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                recentCards.append(card)
            }
        }

        if animate { animateIn() }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        animateIn()
    }

    private func animateIn() {
        guard !didAnimate else { return }
        didAnimate = true
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        // Slide/fade from a near-opaque start so hit-testing and hover stay
        // honest during arrival — full alpha 0 left the first row "sticky".
        for (index, card) in recentCards.enumerated() {
            card.alphaValue = 0.01
            card.layer?.transform = CATransform3DMakeTranslation(0, 6, 0)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.028 * Double(index)) { [weak card] in
                guard let card, card.window != nil else { return }
                Motion.run(reduceMotion: false, duration: Motion.standard, curve: .easeOut) { _ in
                    card.animator().alphaValue = 1
                    card.layer?.transform = CATransform3DIdentity
                }
            }
        }
    }
}

private final class RecentEmptyState: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "No recent files")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = .secondaryLabelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(wrappingLabelWithString: "Open a Markdown file to see it here.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = .secondaryLabelColor
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        detail.translatesAutoresizingMaskIntoConstraints = false
        configurePassiveLabel(detail)
        configurePassiveLabel(title)

        let stack = NSStackView(views: [title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            detail.widthAnchor.constraint(lessThanOrEqualToConstant: 200),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }
}

// MARK: - Action button

private final class StartActionButton: NSButton {
    enum Kind { case primary, secondary }

    private let kind: Kind
    private let shell = NSView()
    private let titleLabel: NSTextField
    private let shortcutLabel: NSTextField
    private var isHovered = false
    private var isPressed = false

    init(title: String, shortcut: String, kind: Kind, target: AnyObject, action: Selector) {
        self.kind = kind
        titleLabel = NSTextField(labelWithString: title)
        shortcutLabel = NSTextField(labelWithString: shortcut)
        super.init(frame: .zero)

        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        isBordered = false
        self.title = ""
        focusRingType = .exterior
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(shortcut)
        wantsLayer = true

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 6
        shell.layer?.masksToBounds = true
        addSubview(shell)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byClipping
        configurePassiveLabel(titleLabel)
        shell.addSubview(titleLabel)

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .semibold)
        shortcutLabel.lineBreakMode = .byClipping
        configurePassiveLabel(shortcutLabel)
        shell.addSubview(shortcutLabel)

        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 14),
            titleLabel.centerYAnchor.constraint(equalTo: shell.centerYAnchor),

            shortcutLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 12),
            shortcutLabel.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -14),
            shortcutLabel.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
        ])

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        isEnabled = true
        // The hero owns the action width so both controls share one visual
        // column. Let the button expand beyond its intrinsic label width.
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
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

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        let titleW = titleLabel.intrinsicContentSize.width
        let shortW = shortcutLabel.intrinsicContentSize.width
        // Trailing shortcut sits at the far edge; leave room so labels never clip.
        return NSSize(width: ceil(14 + titleW + 12 + shortW + 14), height: 34)
    }

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        isPressed = true
        updateSurface(animated: false)

        var keepTracking = true
        while keepTracking {
            guard let next = window.nextEvent(matching: [.leftMouseUp, .leftMouseDragged]) else { break }
            let local = convert(next.locationInWindow, from: nil)
            let inside = bounds.contains(local)
            switch next.type {
            case .leftMouseDragged:
                isPressed = inside
                updateSurface(animated: false)
            case .leftMouseUp:
                isPressed = false
                isHovered = inside
                updateSurface(animated: true)
                if inside { sendAction(action, to: target) }
                keepTracking = false
            default:
                break
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        // mouseDown owns the tracking loop.
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        updateSurface(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        isPressed = false
        updateSurface(animated: true)
    }

    override func highlight(_ flag: Bool) {
        // Custom mouseDown/Up owns pressed state so AppKit highlight can't desync clicks.
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateSurface(animated: false)
    }

    private func updateSurface(animated: Bool) {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let changes = {
            if self.kind == .primary {
                let accent = NSColor.controlAccentColor
                let fill: NSColor
                if self.isPressed {
                    fill = accent.blended(withFraction: 0.18, of: .black) ?? accent
                } else if self.isHovered {
                    fill = accent.blended(withFraction: 0.08, of: .white) ?? accent
                } else {
                    fill = accent
                }
                self.shell.layer?.backgroundColor = fill.cgColor
                self.shell.layer?.borderWidth = 0
                self.titleLabel.textColor = .white
                self.shortcutLabel.textColor = .white
            } else {
                let alpha: CGFloat = self.isHovered ? 1 : (increaseContrast ? 1 : 0.88)
                self.shell.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(alpha).cgColor
                self.shell.layer?.borderWidth = 1
                self.shell.layer?.borderColor = NSColor.separatorColor
                    .withAlphaComponent(increaseContrast ? 0.55 : 0.35).cgColor
                self.titleLabel.textColor = .labelColor
                self.shortcutLabel.textColor = .secondaryLabelColor
            }
            self.shell.layer?.setAffineTransform(
                self.isPressed
                    ? CGAffineTransform(scaleX: 0.985, y: 0.985)
                    : self.isHovered
                        ? CGAffineTransform(scaleX: 1.008, y: 1.008)
                        : .identity
            )
        }
        if animated {
            Motion.run(
                reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                duration: Motion.quick,
                curve: .easeOut
            ) { _ in changes() }
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

    private static let genericHeadings: Set<String> = [
        "title", "untitled", "heading", "document", "readme",
    ]

    static func preferredTitle(for recent: RecentDocument) -> String {
        let heading = recent.firstHeading.trimmingCharacters(in: .whitespacesAndNewlines)
        let headingIsUseful = !heading.isEmpty
            && !genericHeadings.contains(heading.lowercased())
        if looksMachineGenerated(recent.displayName) {
            if headingIsUseful { return heading }
            return stripUUIDSuffix(recent.displayName)
        }
        return recent.displayName
    }

    static func disambiguatedTitles(for recents: [RecentDocument]) -> [String] {
        let limited = Array(recents.prefix(startRecentDisplayLimit))
        var titles = limited.map(preferredTitle(for:))

        // Pass 1: same title → append parent folder when folders differ.
        var counts = Dictionary(grouping: titles, by: { $0 }).mapValues(\.count)
        titles = zip(limited, titles).map { recent, title in
            guard counts[title, default: 0] > 1 else { return title }
            let folder = URL(fileURLWithPath: recent.path)
                .deletingLastPathComponent()
                .lastPathComponent
            guard !folder.isEmpty, folder != "/" else { return title }
            return "\(title) (\(folder))"
        }

        // Pass 2: still colliding (same folder) → short unique id from the file name.
        counts = Dictionary(grouping: titles, by: { $0 }).mapValues(\.count)
        titles = zip(limited, titles).map { recent, title in
            guard counts[title, default: 0] > 1 else { return title }
            let base = preferredTitle(for: recent)
            let id = uniqueFragment(from: recent.displayName)
            return "\(base) · \(id)"
        }
        return titles
    }

    static func detail(for recent: RecentDocument) -> String {
        let folder = URL(fileURLWithPath: recent.path)
            .deletingLastPathComponent()
            .lastPathComponent
        let when = relativeFormatter.localizedString(for: recent.lastOpened, relativeTo: Date())
        if folder.isEmpty || folder == "/" {
            return when
        }
        return "\(folder) · \(when)"
    }

    static func looksMachineGenerated(_ name: String) -> Bool {
        if name.count > 36 { return true }
        return name.range(
            of: #"[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-"#,
            options: .regularExpression
        ) != nil
    }

    /// `EditingKeyRepro-92C5F190-…` → `EditingKeyRepro`
    static func stripUUIDSuffix(_ name: String) -> String {
        guard let range = name.range(
            of: #"-[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-"#,
            options: .regularExpression
        ) else { return name }
        let trimmed = String(name[..<range.lowerBound])
        return trimmed.isEmpty ? name : trimmed
    }

    /// Prefer the first UUID octet from generated names; otherwise a short tail.
    static func uniqueFragment(from displayName: String) -> String {
        if let range = displayName.range(
            of: #"[0-9A-Fa-f]{8}"#,
            options: .regularExpression
        ) {
            return String(displayName[range]).uppercased()
        }
        let tail = displayName.suffix(6)
        return tail.isEmpty ? displayName : String(tail)
    }
}

private final class RecentDocumentButton: NSButton {
    let documentPath: String
    private let shell = NSView()
    private let hoverRule = NSView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private var isHovered = false
    private var isPressed = false

    init(recent: RecentDocument, title: String, target: StartWindowController) {
        documentPath = recent.path
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(labelWithString: RecentRowCopy.detail(for: recent))
        super.init(frame: .zero)

        self.target = target
        action = #selector(StartWindowController.openRecent(_:))
        identifier = NSUserInterfaceItemIdentifier(recent.path)
        setButtonType(.momentaryChange)
        isBordered = false
        self.title = ""
        focusRingType = .exterior
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(title)")
        setAccessibilityValue(detailLabel.stringValue)
        wantsLayer = true
        toolTip = recent.path

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = 7
        shell.layer?.masksToBounds = true
        addSubview(shell)

        hoverRule.translatesAutoresizingMaskIntoConstraints = false
        hoverRule.wantsLayer = true
        hoverRule.layer?.cornerRadius = 1
        hoverRule.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        hoverRule.alphaValue = 0
        shell.addSubview(hoverRule)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        configurePassiveLabel(titleLabel)
        shell.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .medium)
        // Secondary label on a translucent panel falls below readable contrast;
        // keep it clearly subordinate but still legible in dark and light.
        detailLabel.textColor = NSColor.labelColor.withAlphaComponent(0.62)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        configurePassiveLabel(detailLabel)
        shell.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            hoverRule.leadingAnchor.constraint(equalTo: shell.leadingAnchor),
            hoverRule.topAnchor.constraint(equalTo: shell.topAnchor, constant: 7),
            hoverRule.bottomAnchor.constraint(equalTo: shell.bottomAnchor, constant: -7),
            hoverRule.widthAnchor.constraint(equalToConstant: 2),

            titleLabel.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 10),
            titleLabel.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -10),
            titleLabel.topAnchor.constraint(equalTo: shell.topAnchor, constant: 6),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
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

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled, let window else { return }
        isPressed = true
        updateSurface(animated: false)

        // Track the click ourselves so the movable-background window cannot
        // steal the drag and leave a stuck accent fill on the wrong row.
        var keepTracking = true
        while keepTracking {
            guard let next = window.nextEvent(matching: [
                .leftMouseUp, .leftMouseDragged,
            ]) else { break }

            let local = convert(next.locationInWindow, from: nil)
            let inside = bounds.contains(local)

            switch next.type {
            case .leftMouseDragged:
                isHovered = inside
                isPressed = inside
                updateSurface(animated: false)
            case .leftMouseUp:
                isPressed = false
                isHovered = inside
                updateSurface(animated: true)
                if inside {
                    sendAction(action, to: target)
                }
                keepTracking = false
            default:
                break
            }
        }
    }

    override func mouseUp(with event: NSEvent) {
        // mouseDown owns the tracking loop.
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isPressed else { return }
        isHovered = true
        updateSurface(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isPressed else { return }
        isHovered = false
        updateSurface(animated: true)
    }

    override func highlight(_ flag: Bool) {
        // Custom tracking owns pressed/hover so AppKit highlight can't desync.
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        detailLabel.textColor = NSColor.labelColor.withAlphaComponent(0.62)
        updateSurface(animated: false)
    }

    private func updateSurface(animated: Bool) {
        let increaseContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        let fill: NSColor
        if isPressed {
            fill = NSColor.controlAccentColor.withAlphaComponent(increaseContrast ? 0.28 : 0.18)
        } else if isHovered {
            fill = NSColor.labelColor.withAlphaComponent(increaseContrast ? 0.12 : 0.07)
        } else {
            fill = .clear
        }
        let apply = {
            self.shell.layer?.backgroundColor = fill.cgColor
            self.hoverRule.alphaValue = self.isHovered || self.isPressed ? 1 : 0
            self.shell.layer?.setAffineTransform(
                self.isPressed
                    ? CGAffineTransform(scaleX: 0.985, y: 0.985)
                    : self.isHovered
                        ? CGAffineTransform(scaleX: 1.008, y: 1.008)
                        : .identity
            )
        }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.12
                context.allowsImplicitAnimation = true
                apply()
            }
        } else {
            apply()
        }
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
        NSColor.controlAccentColor.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.95).cgColor)
        context.setLineWidth(1.5)
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.move(to: CGPoint(x: bounds.minX + 5.5, y: bounds.maxY - 6))
        context.addLine(to: CGPoint(x: bounds.maxX - 5.5, y: bounds.minY + 6))
        context.move(to: CGPoint(x: bounds.maxX - 9, y: bounds.minY + 6))
        context.addLine(to: CGPoint(x: bounds.maxX - 5.5, y: bounds.minY + 6))
        context.addLine(to: CGPoint(x: bounds.maxX - 5.5, y: bounds.minY + 9.5))
        context.strokePath()
        context.restoreGState()
    }
}
