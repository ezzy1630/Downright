import AppKit
import MarkdownRender
import QuickLookThumbnailing

/// Six rows fit the compact start window without vertical scroll or dead space.
private let startRecentDisplayLimit = 6

private enum StartLayout {
    // A fixed, non-resizable welcome surface.  44pt side gutters keep the
    // column calm without dead air; the extra height (vs. the old 500) lets the
    // six recent rows breathe under the hero.
    static let windowSize = NSSize(width: 680, height: 576)
    static let horizontalInset: CGFloat = 44
    static let bottomInset: CGFloat = 40
    static let sectionSpacing: CGFloat = 22
    static let contentWidth: CGFloat = 592
    static let actionWidth: CGFloat = 164
    static let buttonHeight: CGFloat = 38
    static let rowHeight: CGFloat = 40
    static let cornerRadius: CGFloat = 7
}

/// The start window draws from the app's selected theme so the welcome surface
/// agrees with the editor it hands off to.  One factory, three users.
private enum StartTheme {
    static func makeSheet() -> StyleSheet {
        StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)
    }
}

@MainActor
final class StartWindowController: NSWindowController {
    static let recentDisplayLimit = startRecentDisplayLimit

    var onOpen: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onNew: (() -> Void)?
    var onClearRecents: (() -> Void)?

    /// Quiet text-button target for the recents header's Clear action.
    @objc func clearRecents(_ sender: Any?) {
        onClearRecents?()
    }

    private var startView: StartView? { window?.contentView as? StartView }
    fileprivate var isHandingOff = false

    convenience init(recents: [RecentDocument]) {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: StartLayout.windowSize),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Downright"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.minSize = StartLayout.windowSize
        window.maxSize = StartLayout.windowSize
        window.isRestorable = false
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

/// One task path: choose an action, then a recent file.  The start window is a
/// single left-aligned column — brand, title, actions, recents — so the eye
/// travels once, top-down, instead of choosing between two visual centres.
/// Colours come from the app's `StyleSheet` so the welcome surface agrees with
/// the editor it hands off to.
private final class StartView: NSView {
    private weak var owner: StartWindowController?
    private let recentPanel: RecentDocumentsPanel
    private let hero: StartHeroView
    private let dropOverlay = StartDropOverlay()
    private let contentStack = NSStackView()
    private let updatePill = UpdateStatusPill()
    private var sheet: StyleSheet
    private var didPlayEntrance = false
    /// Clear of traffic lights; keep content below chrome.
    private static let titlebarClearance: CGFloat = 44

    var preferredFirstResponder: NSView { hero.openButton }

    init(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        self.sheet = StartView.makeSheet()
        self.recentPanel = RecentDocumentsPanel(recents: recents, owner: owner, sheet: sheet)
        self.hero = StartHeroView(owner: owner, sheet: sheet)
        super.init(frame: .zero)

        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Downright start window")

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.scrollerStyle = .overlay
        addSubview(scroll)

        let canvas = StartCanvasView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = canvas

        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.orientation = .vertical
        contentStack.alignment = .width
        contentStack.distribution = .fill
        contentStack.spacing = StartLayout.sectionSpacing
        canvas.addSubview(contentStack)

        hero.translatesAutoresizingMaskIntoConstraints = false
        recentPanel.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(hero)
        contentStack.addArrangedSubview(recentPanel)

        let centerY = contentStack.centerYAnchor.constraint(equalTo: canvas.centerYAnchor, constant: -2)
        centerY.priority = .defaultHigh
        let centerX = contentStack.centerXAnchor.constraint(equalTo: canvas.centerXAnchor)
        centerX.priority = .defaultHigh

        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            canvas.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            canvas.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            canvas.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),

            contentStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: canvas.leadingAnchor,
                constant: StartLayout.horizontalInset
            ),
            contentStack.trailingAnchor.constraint(
                lessThanOrEqualTo: canvas.trailingAnchor,
                constant: -StartLayout.horizontalInset
            ),
            contentStack.topAnchor.constraint(greaterThanOrEqualTo: canvas.topAnchor, constant: Self.titlebarClearance),
            contentStack.bottomAnchor.constraint(
                lessThanOrEqualTo: canvas.bottomAnchor,
                constant: -StartLayout.bottomInset
            ),
            centerX,
            centerY,
            contentStack.widthAnchor.constraint(equalToConstant: StartLayout.contentWidth),
            hero.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
            recentPanel.widthAnchor.constraint(equalTo: contentStack.widthAnchor),
        ])

        // The drop affordance is a non-interactive accent frame that appears
        // while a file is dragged anywhere over the window.
        dropOverlay.translatesAutoresizingMaskIntoConstraints = false
        dropOverlay.isHidden = true
        addSubview(dropOverlay)
        NSLayoutConstraint.activate([
            dropOverlay.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            dropOverlay.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            dropOverlay.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            dropOverlay.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])

        // The update pill sits in the transparent titlebar strip, clear of the
        // hero and the traffic lights, and stays collapsed to zero width until
        // the coordinator has something to say.
        updatePill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(updatePill)
        NSLayoutConstraint.activate([
            updatePill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            updatePill.topAnchor.constraint(equalTo: topAnchor, constant: 7),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private static func makeSheet() -> StyleSheet { StartTheme.makeSheet() }

    func reloadRecents(_ recents: [RecentDocument]) {
        guard let owner else { return }
        recentPanel.reload(recents: recents, owner: owner)
    }

    // MARK: - Keyboard navigation

    /// Arrow keys move focus through the recent rows; Space opens the focused
    /// row natively, Return is handled here so keyboard-only users get both
    /// keys.  One focus model, no separate selection state: the row under the
    /// first responder draws the accent ring (§row focus).
    override func keyDown(with event: NSEvent) {
        // Key codes rather than `specialKey`: the latter is resolved through
        // the active keyboard layout, so synthetic events and unusual layouts
        // can report nil for arrow keys.  Key codes are stable.
        switch event.keyCode {
        case 125: // ↓
            moveRecentFocus(+1)
            return
        case 126: // ↑
            moveRecentFocus(-1)
            return
        case 36, 76: // ⏎ and keypad enter
            if let row = window?.firstResponder as? RecentDocumentButton {
                row.performClick(nil)
                return
            }
        default:
            break
        }
        super.keyDown(with: event)
    }

    private func moveRecentFocus(_ delta: Int) {
        let rows = recentPanel.rowButtons
        guard !rows.isEmpty, let window else { return }
        // No focus yet: Down lands on the first row, Up on the last.
        let current = rows.firstIndex { $0 === window.firstResponder }
            ?? (delta > 0 ? -1 : rows.count)
        let next = min(max(current + delta, 0), rows.count - 1)
        window.makeFirstResponder(rows[next])
    }

    /// Escape returns focus to the primary action, unwinding the recents
    /// selection without opening anything.
    override func cancelOperation(_ sender: Any?) {
        if window?.firstResponder is RecentDocumentButton {
            window?.makeFirstResponder(hero.openButton)
        } else {
            super.cancelOperation(sender)
        }
    }

    // MARK: - Entrance

    /// A short fade-up for first layout (DESIGN §Motion): the column lands as
    /// one unit, then the recent rows settle in beneath it.  Input stays live
    /// throughout — the first responder is set before the animation runs.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.backgroundColor = sheet.background
        if !didPlayEntrance, window != nil {
            didPlayEntrance = true
            playEntrance()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        sheet = Self.makeSheet()
        window?.backgroundColor = sheet.background
        hero.apply(sheet: sheet)
        recentPanel.apply(sheet: sheet)
        dropOverlay.apply(sheet: sheet)
    }

    private func playEntrance() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduce else { return }
        contentStack.wantsLayer = true
        contentStack.layer?.opacity = 0
        contentStack.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 10))
        Motion.run(reduceMotion: false, duration: Motion.deliberate, curve: .spring) { _ in
            self.contentStack.layer?.opacity = 1
            self.contentStack.layer?.setAffineTransform(.identity)
        }
        recentPanel.revealRows()
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = droppedURLs(from: sender.draggingPasteboard)
        let ok = !urls.isEmpty
        hero.setDropActive(ok)
        dropOverlay.setActive(ok)
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        hero.setDropActive(false)
        dropOverlay.setActive(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        hero.setDropActive(false)
        dropOverlay.setActive(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(from: sender.draggingPasteboard)
        hero.setDropActive(false)
        dropOverlay.setActive(false)
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

/// A quiet accent frame that acknowledges a drag before the drop.  It draws
/// nothing on its own state — just a filled border that appears and fades,
/// and it never takes a hit so the content underneath stays interactive.
private final class StartDropOverlay: NSView {
    private var isActive = false
    private var sheet = StartTheme.makeSheet()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.borderWidth = 1.5
        layer?.opacity = 0
        apply(sheet: sheet)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        let contrast = sheet.increaseContrast
        layer?.borderColor = sheet.accent.cgColor
        layer?.backgroundColor = sheet.accent
            .withAlphaComponent(contrast ? 0.12 : 0.07).cgColor
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        isHidden = false
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let apply = { self.layer?.opacity = active ? 1 : 0 }
        if reduce {
            apply()
            if !active { isHidden = true }
        } else {
            Motion.run(reduceMotion: false, duration: Motion.quick, curve: .easeOut) { _ in apply() }
            if !active {
                DispatchQueue.main.asyncAfter(deadline: .now() + Motion.quick) { [weak self] in
                    guard let self, !self.isActive else { return }
                    self.isHidden = true
                }
            }
        }
    }
}

/// The scroll canvas takes keyboard focus when clicked, so a blank-area click
/// does not strand arrow-key navigation (the content view is covered by the
/// scroll view and cannot grab focus itself).
private final class StartCanvasView: NSView {
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
}

// MARK: - Hero

/// The welcome column: brand, one clear sentence, two entry paths, and a quiet
/// drop hint.  The primary action is the only filled accent shape in the hero
/// (Von Restorff: one strong cue per screen), and the hint under it is passive
/// copy, not a third button (Hick: two choices at the decision point).
private final class StartHeroView: NSView {
    let openButton: StartActionButton
    private let newButton: StartActionButton
    private let brandLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(
        wrappingLabelWithString: "Read, edit, and review it in one focused place."
    )
    private let dropHint = NSTextField(labelWithString: "")
    private let dropIcon = NSImageView()
    private let brand: BrandMarkView
    private var sheet: StyleSheet
    private var isDropActive = false
    private static let idleDropHint = "You can also drop a file anywhere"

    init(owner: StartWindowController, sheet: StyleSheet) {
        openButton = StartActionButton(
            title: "Open File", icon: "folder", shortcut: "⌘O",
            kind: .primary, sheet: sheet, target: owner,
            action: #selector(StartWindowController.openPanel(_:))
        )
        newButton = StartActionButton(
            title: "New Document", icon: "doc", shortcut: "⌘N",
            kind: .secondary, sheet: sheet, target: owner,
            action: #selector(StartWindowController.newDocument(_:))
        )
        brand = BrandMarkView()
        self.sheet = sheet
        super.init(frame: .zero)

        brand.translatesAutoresizingMaskIntoConstraints = false
        brandLabel.translatesAutoresizingMaskIntoConstraints = false
        brandLabel.setContentHuggingPriority(.required, for: .horizontal)
        configurePassiveLabel(brandLabel)

        let brandRow = NSStackView(views: [brand, brandLabel])
        brandRow.orientation = .horizontal
        brandRow.alignment = .centerY
        brandRow.spacing = 12

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.maximumNumberOfLines = 1
        configurePassiveLabel(titleLabel)

        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.maximumNumberOfLines = 2
        subtitleLabel.preferredMaxLayoutWidth = StartLayout.contentWidth
        configurePassiveLabel(subtitleLabel)

        // Two peer entry paths, with Open File carrying primary emphasis.
        let actions = NSStackView(views: [openButton, newButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 8
        actions.distribution = .fill

        dropIcon.translatesAutoresizingMaskIntoConstraints = false
        dropIcon.image = NSImage(systemSymbolName: "arrow.down.doc", accessibilityDescription: nil)
        dropIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        dropIcon.setContentHuggingPriority(.required, for: .horizontal)

        dropHint.translatesAutoresizingMaskIntoConstraints = false
        dropHint.font = .systemFont(ofSize: 12, weight: .regular)
        dropHint.alignment = .left
        configurePassiveLabel(dropHint)

        let dropSlot = NSStackView(views: [dropIcon, dropHint])
        dropSlot.orientation = .horizontal
        dropSlot.alignment = .centerY
        dropSlot.spacing = 6
        dropSlot.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [brandRow, titleLabel, subtitleLabel, actions, dropSlot])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        addSubview(stack)

        NSLayoutConstraint.activate([
            brand.widthAnchor.constraint(equalToConstant: 38),
            brand.heightAnchor.constraint(equalToConstant: 38),
            openButton.heightAnchor.constraint(equalToConstant: StartLayout.buttonHeight),
            newButton.heightAnchor.constraint(equalToConstant: StartLayout.buttonHeight),
            openButton.widthAnchor.constraint(equalToConstant: StartLayout.actionWidth),
            newButton.widthAnchor.constraint(equalToConstant: StartLayout.actionWidth),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: StartLayout.contentWidth),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: StartLayout.contentWidth),
            dropSlot.widthAnchor.constraint(equalTo: stack.widthAnchor),

            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        stack.setCustomSpacing(16, after: brandRow)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(20, after: subtitleLabel)
        stack.setCustomSpacing(9, after: actions)

        apply(sheet: sheet)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Downright welcome")
    }

    required init?(coder: NSCoder) { nil }

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        openButton.apply(sheet: sheet)
        newButton.apply(sheet: sheet)
        brandLabel.attributedStringValue = NSAttributedString(
            string: "Downright",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: sheet.text,
            ]
        )
        titleLabel.attributedStringValue = NSAttributedString(
            string: "Open a Markdown file",
            attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: sheet.text,
                .kern: -0.3,
            ]
        )
        subtitleLabel.textColor = sheet.textSecondary
        dropHint.textColor = isDropActive ? sheet.accent : sheet.textSecondary
        dropIcon.contentTintColor = isDropActive ? sheet.accent : sheet.textFaint
        if !isDropActive { dropHint.stringValue = Self.idleDropHint }
        needsDisplay = true
    }

    func setDropActive(_ active: Bool) {
        guard active != isDropActive else { return }
        isDropActive = active
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let changes = {
            self.dropHint.textColor = active ? self.sheet.accent : self.sheet.textSecondary
            self.dropIcon.contentTintColor = active ? self.sheet.accent : self.sheet.textFaint
            self.dropHint.stringValue = active ? "Release to open" : Self.idleDropHint
        }
        if reduceMotion {
            changes()
        } else {
            Motion.run(reduceMotion: false, duration: Motion.quick, curve: .easeOut) { _ in changes() }
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

/// The recents list: a quiet header (label, count, clear) over equal-height
/// rows.  Uniform row height and tight spacing make the list read as one
/// gestalt group; the title carries the weight and the trailing detail stays
/// faint so names are found pre-attentively.
private final class RecentDocumentsPanel: NSView {
    private weak var owner: StartWindowController?
    private let headerLabel = NSTextField(labelWithString: "Recent files")
    private let countLabel = NSTextField(labelWithString: "")
    private let clearButton: StartTextButton
    private let divider = NSView()
    private let list = NSStackView()
    private var rowViews: [RecentDocumentButton] = []
    private var displayedRecents: [RecentDocument] = []
    private var sheet: StyleSheet
    private var clearAction: ButtonAction?

    init(recents: [RecentDocument], owner: StartWindowController, sheet: StyleSheet) {
        self.owner = owner
        self.sheet = sheet
        let clear = StartTextButton(title: "Clear")
        self.clearButton = clear
        super.init(frame: .zero)

        let action = ButtonAction { [weak owner] in owner?.onClearRecents?() }
        clearAction = action
        clear.target = action
        clear.action = #selector(ButtonAction.fire(_:))
        clear.setAccessibilityLabel("Clear recent files")
        clear.toolTip = "Clear the recent files list"

        // A hairline rule separates the decide phase (hero) from the continue
        // phase (recents); two kinds of work should not share one silent gap.
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.wantsLayer = true
        addSubview(divider)

        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerLabel.font = .systemFont(ofSize: 12, weight: .semibold)
        configurePassiveLabel(headerLabel)

        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)
        configurePassiveLabel(countLabel)

        let header = NSStackView(views: [headerLabel, countLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 7
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        clearButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(clearButton)

        list.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 2
        addSubview(list)

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            header.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),

            clearButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            clearButton.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            clearButton.leadingAnchor.constraint(greaterThanOrEqualTo: header.trailingAnchor, constant: 12),

            list.leadingAnchor.constraint(equalTo: leadingAnchor),
            list.trailingAnchor.constraint(equalTo: trailingAnchor),
            list.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 8),
            list.bottomAnchor.constraint(equalTo: bottomAnchor),

            widthAnchor.constraint(equalToConstant: StartLayout.contentWidth),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Recent Markdown documents")
        apply(sheet: sheet)
        rebuild(recents: recents)
    }

    required init?(coder: NSCoder) { nil }

    func reload(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        guard recents != displayedRecents else { return }
        rebuild(recents: recents)
    }

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        divider.layer?.backgroundColor = sheet.rule
            .withAlphaComponent(sheet.increaseContrast ? 0.6 : 0.4).cgColor
        headerLabel.textColor = sheet.textSecondary
        countLabel.textColor = sheet.textFaint
        clearButton.apply(sheet: sheet)
        for row in rowViews {
            row.apply(sheet: sheet)
        }
    }

    /// The recent rows, in display order.  StartView walks this for the
    /// arrow-key focus navigation.
    var rowButtons: [RecentDocumentButton] { rowViews }

    func revealRows() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduce, !rowViews.isEmpty else { return }
        for (index, row) in rowViews.enumerated() {
            row.wantsLayer = true
            row.layer?.opacity = 0
            let delay = 0.05 + Double(index) * 0.04
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak row] in
                guard let row else { return }
                Motion.run(reduceMotion: false, duration: Motion.standard, curve: .easeOut) { _ in
                    row.layer?.opacity = 1
                }
            }
        }
    }

    private func rebuild(recents: [RecentDocument]) {
        for view in list.arrangedSubviews {
            list.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        rowViews = []
        displayedRecents = recents

        guard let owner else { return }
        countLabel.stringValue = recents.isEmpty ? "" : "\(recents.count)"
        countLabel.isHidden = recents.isEmpty
        clearButton.isHidden = recents.isEmpty

        if recents.isEmpty {
            let empty = RecentEmptyState(sheet: sheet)
            empty.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            // Keep the no-recents panel close to the populated panel's visual
            // weight so the start screen does not jump between two compositions.
            empty.heightAnchor.constraint(equalToConstant: 150).isActive = true
        } else {
            let titles = RecentRowCopy.disambiguatedTitles(for: recents)
            for (index, recent) in recents.prefix(StartWindowController.recentDisplayLimit).enumerated() {
                let row = RecentDocumentButton(
                    recent: recent,
                    title: titles[index],
                    target: owner,
                    sheet: sheet
                )
                row.translatesAutoresizingMaskIntoConstraints = false
                row.heightAnchor.constraint(equalToConstant: StartLayout.rowHeight).isActive = true
                list.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
                rowViews.append(row)
            }
        }
    }
}

/// A quiet text button (header-level Clear) with its own hover: faint at rest,
/// a step brighter under the pointer, always a plain label — never a bezel.
private final class StartTextButton: NSButton {
    private var isHovered = false
    private var sheet: StyleSheet = StartTheme.makeSheet()

    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryChange)
        focusRingType = .none
        font = .systemFont(ofSize: 11.5, weight: .regular)
        setAccessibilityRole(.button)
        wantsLayer = true
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        apply(sheet: sheet)
    }

    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize {
        NSSize(width: ceil(title.size(withAttributes: [.font: font ?? .systemFont(ofSize: 11.5)]).width), height: 20)
    }

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        attributedTitle = NSAttributedString(
            string: title,
            attributes: [
                .font: NSFont.systemFont(ofSize: 11.5, weight: .regular),
                .foregroundColor: isHovered ? sheet.textSecondary : sheet.textFaint,
            ]
        )
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        apply(sheet: sheet)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        apply(sheet: sheet)
    }

    override func highlight(_ flag: Bool) {}
}

private final class RecentEmptyState: NSView {
    init(sheet: StyleSheet) {
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: "doc.text", accessibilityDescription: nil)
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 26, weight: .light)
        icon.contentTintColor = sheet.textFaint

        let title = NSTextField(labelWithString: "No recent files")
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.textColor = sheet.textSecondary
        title.translatesAutoresizingMaskIntoConstraints = false

        let detail = NSTextField(wrappingLabelWithString: "Open a Markdown file to see it here.")
        detail.font = .systemFont(ofSize: 12)
        detail.textColor = sheet.textFaint
        detail.alignment = .center
        detail.maximumNumberOfLines = 2
        detail.translatesAutoresizingMaskIntoConstraints = false
        configurePassiveLabel(detail)
        configurePassiveLabel(title)

        let stack = NSStackView(views: [icon, title, detail])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 5
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

/// A large, calm target with an icon, a label, and the shortcut visible at the
/// far edge.  The shell is the only painted thing — the button itself stays
/// transparent — and pressed/hover/focus are all expressed on that shell so
/// the state is one step instead of three.  Pointer events use the simple
/// down/dragged/up cycle rather than an event-draining loop, so the click
/// resolves as soon as the user lets go.
private final class StartActionButton: NSButton {
    enum Kind { case primary, secondary }

    private let kind: Kind
    private let shell = NSView()
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let shortcutLabel: NSTextField
    private var isHovered = false
    private var isPressed = false
    private var sheet: StyleSheet

    init(
        title: String,
        icon: String,
        shortcut: String,
        kind: Kind,
        sheet: StyleSheet,
        target: AnyObject,
        action: Selector
    ) {
        self.kind = kind
        self.sheet = sheet
        titleLabel = NSTextField(labelWithString: title)
        shortcutLabel = NSTextField(labelWithString: shortcut)
        super.init(frame: .zero)

        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        isBordered = false
        self.title = ""
        focusRingType = .none
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        setAccessibilityHelp(shortcut)
        wantsLayer = true

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = StartLayout.cornerRadius
        shell.layer?.masksToBounds = true
        addSubview(shell)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        shell.addSubview(iconView)

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

            iconView.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 14),
            iconView.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 14),
            iconView.heightAnchor.constraint(equalToConstant: 14),

            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 7),
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

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        updateSurface(animated: false)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        let titleW = titleLabel.intrinsicContentSize.width
        let shortW = shortcutLabel.intrinsicContentSize.width
        // Trailing shortcut sits at the far edge; leave room so labels never clip.
        return NSSize(width: ceil(14 + 14 + 7 + titleW + 12 + shortW + 14), height: 34)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        window?.makeFirstResponder(self)
        isPressed = true
        isHovered = true
        updateSurface(animated: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = inside
        isHovered = inside
        updateSurface(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        isHovered = inside
        updateSurface(animated: true)
        if inside { sendAction(action, to: target) }
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
        // Custom mouseDown/Dragged/Up owns pressed state so AppKit highlight can't desync clicks.
    }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        defer { updateSurface(animated: false) }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { updateSurface(animated: false) }
        return super.resignFirstResponder()
    }

    private var keyObservers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers.forEach(NotificationCenter.default.removeObserver)
        keyObservers = []
        guard let window else { return }
        // Token-based so cleanup touches only the two observers we own.
        keyObservers = [
            NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.windowKeyStateChanged() },
            NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification, object: window, queue: .main
            ) { [weak self] _ in self?.windowKeyStateChanged() },
        ]
        updateSurface(animated: false)
    }

    deinit {
        keyObservers.forEach(NotificationCenter.default.removeObserver)
    }

    private func windowKeyStateChanged() {
        updateSurface(animated: false)
    }

    private func updateSurface(animated: Bool) {
        let sheet = self.sheet
        let contrast = sheet.increaseContrast
        let isFocused = window?.firstResponder === self && window?.isKeyWindow == true
        let changes = {
            if self.kind == .primary {
                let accent = sheet.accent
                let fill: NSColor
                if self.isPressed {
                    fill = accent.blended(withFraction: 0.18, of: .black) ?? accent
                } else if self.isHovered {
                    fill = accent.blended(withFraction: 0.08, of: .white) ?? accent
                } else {
                    fill = accent
                }
                self.shell.layer?.backgroundColor = fill.cgColor
                self.shell.layer?.borderWidth = isFocused ? 2 : 0
                self.shell.layer?.borderColor = NSColor.white.withAlphaComponent(0.72).cgColor
                self.titleLabel.textColor = .white
                self.shortcutLabel.textColor = .white
                self.iconView.contentTintColor = .white
            } else {
                let fillAlpha: CGFloat = self.isPressed ? 0.11 : (self.isHovered ? 0.075 : 0.045)
                self.shell.layer?.backgroundColor = sheet.text
                    .withAlphaComponent(contrast ? max(fillAlpha, 0.12) : fillAlpha).cgColor
                self.shell.layer?.borderWidth = isFocused ? 2 : 1
                self.shell.layer?.borderColor = (isFocused ? sheet.accent : sheet.rule)
                    .withAlphaComponent(isFocused ? 0.9 : (contrast ? 0.55 : 0.35)).cgColor
                self.titleLabel.textColor = sheet.text
                self.shortcutLabel.textColor = sheet.textSecondary
                self.iconView.contentTintColor = self.isHovered ? sheet.text : sheet.textSecondary
            }
            self.shell.layer?.setAffineTransform(
                self.isPressed
                    ? CGAffineTransform(scaleX: 0.98, y: 0.98)
                    : self.isHovered
                        ? CGAffineTransform(scaleX: 1.01, y: 1.01)
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
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let detailLabel: NSTextField
    private let chevron = NSImageView()
    private var isHovered = false
    private var isPressed = false
    private var sheet: StyleSheet

    init(recent: RecentDocument, title: String, target: StartWindowController, sheet: StyleSheet) {
        documentPath = recent.path
        self.sheet = sheet
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(labelWithString: RecentRowCopy.detail(for: recent))
        super.init(frame: .zero)

        self.target = target
        action = #selector(StartWindowController.openRecent(_:))
        identifier = NSUserInterfaceItemIdentifier(recent.path)
        setButtonType(.momentaryChange)
        isBordered = false
        self.title = ""
        focusRingType = .none
        setAccessibilityRole(.button)
        setAccessibilityLabel("Open \(title)")
        setAccessibilityValue(detailLabel.stringValue)
        wantsLayer = true
        toolTip = recent.path

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = StartLayout.cornerRadius
        shell.layer?.masksToBounds = true
        addSubview(shell)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: "doc", accessibilityDescription: nil)
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12.5, weight: .regular)
        shell.addSubview(iconView)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        configurePassiveLabel(titleLabel)
        shell.addSubview(titleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.maximumNumberOfLines = 1
        configurePassiveLabel(detailLabel)
        shell.addSubview(detailLabel)

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Open")
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .semibold)
        chevron.wantsLayer = true
        chevron.layer?.opacity = 0
        shell.addSubview(chevron)

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

            detailLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 20),
            detailLabel.trailingAnchor.constraint(equalTo: chevron.leadingAnchor, constant: -6),
            detailLabel.centerYAnchor.constraint(equalTo: shell.centerYAnchor),

            chevron.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -12),
            chevron.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),
        ])

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
        updateSurface(animated: false)
    }

    required init?(coder: NSCoder) { nil }

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        updateSurface(animated: false)
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        return bounds.contains(local) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        // Keep "selection = first responder" coherent: a click that does not
        // complete a handoff leaves arrow navigation pointing at this row.
        window?.makeFirstResponder(self)
        isPressed = true
        isHovered = true
        updateSurface(animated: false)
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isHovered = inside
        isPressed = inside
        updateSurface(animated: false)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        isHovered = inside
        updateSurface(animated: true)
        if inside {
            sendAction(action, to: target)
        }
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

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        defer { updateSurface(animated: true) }
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        defer { updateSurface(animated: false) }
        return super.resignFirstResponder()
    }

    private func updateSurface(animated: Bool) {
        let sheet = self.sheet
        let contrast = sheet.increaseContrast
        // Keyboard focus and selection are one thing: the row under the first
        // responder draws an accent ring, so arrow-key navigation has a clear
        // and native-feeling destination.
        let isFocused = window?.firstResponder === self && window?.isKeyWindow == true
        let engaged = isHovered || isPressed || isFocused
        let fill: NSColor
        if isPressed {
            fill = sheet.accent.withAlphaComponent(contrast ? 0.28 : 0.18)
        } else if isHovered {
            fill = sheet.text.withAlphaComponent(contrast ? 0.12 : 0.07)
        } else if isFocused {
            fill = sheet.accent.withAlphaComponent(contrast ? 0.12 : 0.07)
        } else {
            fill = .clear
        }
        let apply = {
            self.shell.layer?.backgroundColor = fill.cgColor
            self.shell.layer?.borderWidth = isFocused ? 1.5 : 0
            self.shell.layer?.borderColor = sheet.accent.cgColor
            self.iconView.contentTintColor = engaged ? sheet.accent : sheet.textFaint
            self.detailLabel.textColor = engaged ? sheet.textSecondary : sheet.textFaint
            self.chevron.contentTintColor = sheet.accent
            self.chevron.layer?.opacity = engaged ? 1 : 0
            self.chevron.layer?.setAffineTransform(
                engaged ? .identity : CGAffineTransform(translationX: 4, y: 0)
            )
            self.shell.layer?.setAffineTransform(
                self.isPressed
                    ? CGAffineTransform(scaleX: 0.992, y: 0.992)
                    : .identity
            )
        }
        if animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            Motion.run(reduceMotion: false, duration: Motion.quick, curve: .easeOut) { _ in apply() }
        } else {
            apply()
        }
    }
}

// MARK: - Brand

private final class BrandMarkView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityRole(.image)
        setAccessibilityLabel("Downright app icon")
    }

    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard let icon = Self.icon else { return }
        let iconRect = bounds.insetBy(dx: 1, dy: 1)
        let radius = iconRect.width * 0.24

        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.setShadow(
            offset: CGSize(width: 0, height: -1.5),
            blur: 3.5,
            color: NSColor.black.withAlphaComponent(0.22).cgColor
        )
        NSColor.white.withAlphaComponent(0.96).setFill()
        NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius).fill()
        context.restoreGState()

        NSGraphicsContext.saveGraphicsState()
        NSBezierPath(roundedRect: iconRect, xRadius: radius, yRadius: radius).addClip()
        icon.draw(
            in: iconRect,
            from: .zero,
            operation: .sourceOver,
            fraction: 1,
            respectFlipped: true,
            hints: [.interpolation: NSImageInterpolation.high]
        )
        NSGraphicsContext.restoreGraphicsState()
    }

    private static let icon: NSImage? = {
        let url = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Resources/AppIcon.png")
        return NSImage(contentsOf: url)
    }()
}
