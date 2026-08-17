import AppKit
import MarkdownRender
import QuickLookThumbnailing

/// Six rows fit the compact start window without a scrolling container.
private let startRecentDisplayLimit = 6

/// Internal rather than private so the start window's tests can assert against
/// the constants instead of copies of them: the one that pinned a literal 576
/// broke the moment a recent row grew a second line, which told nobody anything
/// about the window being fixed-size, which is what it meant to check.
enum StartLayout {
    // A fixed, non-resizable welcome surface. The 44pt side gutters keep the
    // column calm, while the extra height gives six two-line recent rows room
    // to breathe under the hero without making the surface scroll.
    static let windowSize = NSSize(width: 680, height: 640)
    static let horizontalInset: CGFloat = 44
    static let bottomInset: CGFloat = 36
    static let sectionSpacing: CGFloat = 20
    static let contentWidth: CGFloat = 592
    static let buttonHeight: CGFloat = 40
    // Both peer actions share a generous well: 196pt fits the longest title,
    // icon, and keycap without truncation while keeping the action group
    // visually compact inside the 592pt welcome column.
    static let actionButtonWidth: CGFloat = 196
    static let actionSpacing: CGFloat = 10
    static let rowHeight: CGFloat = 46
    static let rowSpacing: CGFloat = 2
    static let cornerRadius: CGFloat = 7

    /// What a full recents list measures.  The empty state matches it so the
    /// window does not change weight between having files and not.
    static var populatedListHeight: CGFloat {
        let rows = CGFloat(startRecentDisplayLimit)
        return rows * rowHeight + (rows - 1) * rowSpacing
    }
}

/// The start window draws from the app's selected theme so the welcome surface
/// agrees with the editor it hands off to.  One factory, three users.
private enum StartTheme {
    static func makeSheet() -> StyleSheet {
        StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)
    }
}

/// Where the welcome document sits on the start window.
enum StartGuideOffer {
    /// This build ships no welcome document; the action is not shown.
    case unavailable
    /// A quiet third action beside Open and New.
    case secondary
    /// First launch: the guide leads, because there is nothing to reopen and
    /// nothing to continue.
    case primary
}

@MainActor
final class StartWindowController: NSWindowController {
    static let recentDisplayLimit = startRecentDisplayLimit

    var onOpen: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onNew: (() -> Void)?
    var onOpenGuide: (() -> Void)?
    var onClearRecents: (() -> Void)?

    /// Quiet text-button target for the recents header's Clear action.
    @objc func clearRecents(_ sender: Any?) {
        onClearRecents?()
    }

    private var startView: StartView? { window?.contentView as? StartView }
    fileprivate var isHandingOff = false

    convenience init(recents: [RecentDocument], guide: StartGuideOffer = .unavailable) {
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
        let content = StartView(recents: recents, guide: guide, owner: self)
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
        guard animated, !StartTheme.makeSheet().reduceMotion else {
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

    @objc func openGuide(_ sender: Any?) {
        guard beginHandoff() else { return }
        onOpenGuide?()
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
    // The start surface has enough context to make an icon-only warning
    // discoverable through its tooltip and accessibility label. Keep the
    // titlebar warning from becoming a second hero CTA.
    private let updatePill = UpdateStatusPill(presentation: .compactWarning)
    private var sheet: StyleSheet
    private var didPlayEntrance = false
    private var keyObserver: NSObjectProtocol?
    /// Clear of traffic lights; keep content below chrome.
    private static let titlebarClearance: CGFloat = 44

    var preferredFirstResponder: NSView { hero.leadButton }

    init(recents: [RecentDocument], guide: StartGuideOffer, owner: StartWindowController) {
        self.owner = owner
        self.sheet = StartView.makeSheet()
        self.recentPanel = RecentDocumentsPanel(recents: recents, owner: owner, sheet: sheet)
        self.hero = StartHeroView(
            owner: owner, guide: guide, isReturning: !recents.isEmpty, sheet: sheet
        )
        super.init(frame: .zero)

        wantsLayer = true
        registerForDraggedTypes([.fileURL])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Downright start window")

        let canvas = StartCanvasView()
        canvas.translatesAutoresizingMaskIntoConstraints = false
        addSubview(canvas)

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
            canvas.leadingAnchor.constraint(equalTo: leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: trailingAnchor),
            canvas.topAnchor.constraint(equalTo: topAnchor),
            canvas.bottomAnchor.constraint(equalTo: bottomAnchor),

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
        // while a file is dragged anywhere over the window. There is no idle
        // helper copy: the window only spends visual attention on dropping
        // when a drop is actually possible.
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
            // Give the warning its own titlebar lane: the extra inset keeps
            // the pill off the window edge and visually separates it from the
            // traffic-light/titlebar chrome at small capture sizes.
            updatePill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            updatePill.topAnchor.constraint(equalTo: topAnchor, constant: 10),
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
    /// first responder draws the accent ring.
    /// ⌘1…⌘9 open the nth recent.
    ///
    /// Handled here rather than as menu items: these are only meaningful while
    /// this window is up, and a global menu binding would collide the moment a
    /// document window took over.  `performKeyEquivalent` sees the chord before
    /// the responder chain turns it into a beep.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Command must be down and nothing else the user meant; `.numericPad`
        // is *not* one of those.  macOS sets it on the top-row digits, so an
        // exact `== .command` test never matches ⌘1 and the shortcut silently
        // does nothing.  `.capsLock` rides along the same way.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.contains(.command),
              modifiers.isDisjoint(with: [.shift, .control, .option]),
              let characters = event.charactersIgnoringModifiers,
              let digit = Int(characters), digit >= 1
        else { return super.performKeyEquivalent(with: event) }

        let rows = recentPanel.rowButtons
        guard digit <= rows.count else { return super.performKeyEquivalent(with: event) }
        rows[digit - 1].performClick(nil)
        return true
    }

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
            window?.makeFirstResponder(hero.leadButton)
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
        keyObserver.map(NotificationCenter.default.removeObserver)
        keyObserver = nil
        if let window {
            // Bindings are user-editable, so the hero's shortcut hints are only
            // true at the moment they are drawn.  Refreshing when the window
            // comes forward covers the "rebind ⌘O, come back here" path.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.hero.refreshShortcuts() }
            }
        }
        if !didPlayEntrance, window != nil {
            didPlayEntrance = true
            playEntrance()
        }
    }

    deinit {
        keyObserver.map(NotificationCenter.default.removeObserver)
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
        let reduce = sheet.reduceMotion
        guard !reduce else { return }
        contentStack.wantsLayer = true
        contentStack.layer?.opacity = 0
        contentStack.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: 10))
        Motion.run(reduceMotion: false, duration: Motion.deliberate, curve: .structural) { _ in
            self.contentStack.layer?.opacity = 1
            self.contentStack.layer?.setAffineTransform(.identity)
        }
        recentPanel.revealRows()
    }

    // MARK: - Drag & drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        let urls = droppedURLs(from: sender.draggingPasteboard)
        let ok = !urls.isEmpty
        dropOverlay.setActive(ok)
        return ok ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        dropOverlay.setActive(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropOverlay.setActive(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(from: sender.draggingPasteboard)
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

/// A quiet accent frame that acknowledges a drag before the drop. It is hidden
/// at rest and becomes a dashed border only while a supported file is over the
/// window, so the welcome surface never carries a permanent instruction line.
private final class StartDropOverlay: NSView {
    private var isActive = false
    private var sheet = StartTheme.makeSheet()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.opacity = 0
        apply(sheet: sheet)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        let contrast = sheet.increaseContrast
        layer?.backgroundColor = sheet.accent
            .withAlphaComponent(contrast ? 0.055 : 0.025).cgColor
        needsDisplay = true
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        isHidden = false
        needsDisplay = true
        let reduce = sheet.reduceMotion
        let apply = {
            self.layer?.opacity = active ? 1 : 0
            self.needsDisplay = true
        }
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

    override func draw(_ dirtyRect: NSRect) {
        guard isActive, let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        let path = CGPath(roundedRect: rect, cornerWidth: 13, cornerHeight: 13, transform: nil)
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(1.5)
        context.setLineDash(phase: 0, lengths: [7, 5])
        context.setStrokeColor(sheet.accent.withAlphaComponent(
            sheet.increaseContrast ? 0.8 : 0.52
        ).cgColor)
        context.strokePath()
        context.restoreGState()
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

/// The welcome column: brand, one clear sentence, and two equally weighted
/// entry paths. Dragging is communicated by the window-level overlay, not by a
/// permanent instruction that competes with the actual actions.
private final class StartHeroView: NSView {
    let openButton: StartActionButton
    private let newButton: StartActionButton
    private let guideButton: StartActionButton?
    /// The action the window opens focused on.
    let leadButton: StartActionButton
    private let brandLabel = NSTextField(labelWithString: "")
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")
    private let brand: BrandMarkView
    private let guide: StartGuideOffer
    /// Whether this window has anything of the user's own to show.
    private let isReturning: Bool
    private var sheet: StyleSheet
    init(
        owner: StartWindowController, guide: StartGuideOffer,
        isReturning: Bool, sheet: StyleSheet
    ) {
        self.guide = guide
        self.isReturning = isReturning
        let guideLeads = guide == .primary
        openButton = StartActionButton(
            title: "Open File", icon: "folder", command: .open,
            kind: .secondary, sheet: sheet, target: owner,
            action: #selector(StartWindowController.openPanel(_:))
        )
        newButton = StartActionButton(
            title: "New Document", icon: "doc", command: .newDocument,
            kind: guideLeads ? .secondary : .primary, sheet: sheet, target: owner,
            action: #selector(StartWindowController.newDocument(_:))
        )
        guideButton = guide == .unavailable ? nil : StartActionButton(
            title: "Take the Tour", icon: "sparkles", command: nil,
            kind: guideLeads ? .primary : .secondary, sheet: sheet, target: owner,
            action: #selector(StartWindowController.openGuide(_:))
        )
        leadButton = (guideLeads ? guideButton : nil) ?? newButton
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

        // Peer entry paths, with exactly one carrying primary emphasis. On a
        // normal launch creation is the strongest next step; a first-launch
        // tour temporarily takes that role because it is the onboarding path.
        let actions = NSStackView(views: [openButton, newButton] + (guideButton.map { [$0] } ?? []))
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = StartLayout.actionSpacing
        actions.distribution = .fill

        let stack = NSStackView(views: [brandRow, titleLabel, subtitleLabel, actions])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        addSubview(stack)

        // The two file actions are peer entry points, so they share a control
        // well. The shortcut keycap remains right-aligned inside each well,
        // which keeps the labels readable without turning one action into the
        // visually dominant choice just because its title is longer.
        var constraints: [NSLayoutConstraint] = [
            brand.widthAnchor.constraint(equalToConstant: 38),
            brand.heightAnchor.constraint(equalToConstant: 38),
            openButton.heightAnchor.constraint(equalToConstant: StartLayout.buttonHeight),
            newButton.heightAnchor.constraint(equalToConstant: StartLayout.buttonHeight),
            openButton.widthAnchor.constraint(equalToConstant: StartLayout.actionButtonWidth),
            newButton.widthAnchor.constraint(equalToConstant: StartLayout.actionButtonWidth),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: StartLayout.contentWidth),
            subtitleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: StartLayout.contentWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ]
        if let guideButton {
            // The tour carries no shortcut, so it sizes to its own label rather
            // than padding out to match the two file actions.
            constraints.append(guideButton.heightAnchor.constraint(equalToConstant: StartLayout.buttonHeight))
        }
        NSLayoutConstraint.activate(constraints)

        stack.setCustomSpacing(12, after: brandRow)
        stack.setCustomSpacing(4, after: titleLabel)
        stack.setCustomSpacing(18, after: subtitleLabel)

        apply(sheet: sheet)
        setAccessibilityRole(.group)
        setAccessibilityLabel("Downright welcome")
    }

    required init?(coder: NSCoder) { nil }

    /// Bindings are user-editable, so the hints on the buttons are re-read
    /// rather than baked in at build time.
    func refreshShortcuts() {
        openButton.refreshShortcut()
        newButton.refreshShortcut()
    }

    func apply(sheet: StyleSheet) {
        self.sheet = sheet
        openButton.apply(sheet: sheet)
        newButton.apply(sheet: sheet)
        guideButton?.apply(sheet: sheet)
        brandLabel.attributedStringValue = NSAttributedString(
            string: "Downright",
            attributes: [
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: sheet.text,
            ]
        )
        // Three states, because a returning user does not need to be told how
        // to open a file.  "Open a Markdown file" restated the button directly
        // under it, and a permanent instruction to someone on their fortieth
        // launch reads as an app that never noticed they had learned it.
        let headline: String
        let subheadline: String
        switch (guide, isReturning) {
        case (.primary, _):
            headline = "Welcome to Downright"
            subheadline = "The tour is a real document. It explains the reading tools while you read it."
        case (_, true):
            headline = "Pick up where you left off"
            subheadline = "Read, edit, and review — all in one focused place."
        case (_, false):
            headline = "Open a Markdown file"
            subheadline = "Read, edit, and review it in one focused place."
        }
        titleLabel.attributedStringValue = NSAttributedString(
            string: headline,
            attributes: [
                .font: NSFont.systemFont(ofSize: 24, weight: .semibold),
                .foregroundColor: sheet.text,
                .kern: -0.3,
            ]
        )
        subtitleLabel.stringValue = subheadline
        subtitleLabel.textColor = sheet.textSecondary
        needsDisplay = true
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

/// The recents list: a quiet header (label, shortcut hint) over equal-height
/// rows. Uniform row height and tight spacing make the list read as one gestalt
/// group; the title carries the weight, the timestamp owns a fixed trailing
/// column, and the ordinal keycap appears only for the row under attention.
private final class RecentDocumentsPanel: NSView {
    private weak var owner: StartWindowController?
    private let headerLabel = NSTextField(labelWithString: "Recent files")
    private let countLabel = NSTextField(labelWithString: "")
    private let divider = NSView()
    private let list = NSStackView()
    private var rowViews: [RecentDocumentButton] = []
    private var displayedRecents: [RecentDocument] = []
    private var sheet: StyleSheet

    init(recents: [RecentDocument], owner: StartWindowController, sheet: StyleSheet) {
        self.owner = owner
        self.sheet = sheet
        super.init(frame: .zero)

        menu = Self.makeContextMenu(owner: owner)

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

        list.translatesAutoresizingMaskIntoConstraints = false
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = StartLayout.rowSpacing
        addSubview(list)

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.heightAnchor.constraint(equalToConstant: 1),

            // Keep the section label on the same vertical grid as each file
            // title; the document glyph lives in the small leading gutter.
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 36),
            header.topAnchor.constraint(equalTo: divider.bottomAnchor, constant: 12),

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
        for row in rowViews {
            row.apply(sheet: sheet)
        }
    }

    /// The recent rows, in display order.  StartView walks this for the
    /// arrow-key focus navigation.
    var rowButtons: [RecentDocumentButton] { rowViews }

    func revealRows() {
        let reduce = sheet.reduceMotion
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
        // The count went: it restated something six visible rows already say.
        // This slot now teaches the shortcut the row ordinals stand for, once,
        // where someone reading the list will meet it.
        let shown = min(recents.count, StartWindowController.recentDisplayLimit)
        countLabel.stringValue = shown > 1 ? "⌘1–\(shown)" : ""
        countLabel.isHidden = countLabel.stringValue.isEmpty
        if recents.isEmpty {
            let empty = RecentEmptyState(sheet: sheet)
            empty.translatesAutoresizingMaskIntoConstraints = false
            list.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            // Exactly the height a full list would occupy, so the window is the
            // right size for both compositions and neither leaves a hole under
            // it.  Derived rather than guessed: the old fixed 150 was already
            // 100pt short of six rows, and drifted further the moment a row
            // grew its second line.
            empty.heightAnchor.constraint(
                equalToConstant: StartLayout.populatedListHeight
            ).isActive = true
        } else {
            let titles = RecentRowCopy.disambiguatedTitles(for: recents)
            for (index, recent) in recents.prefix(StartWindowController.recentDisplayLimit).enumerated() {
                let row = RecentDocumentButton(
                    recent: recent,
                    title: titles[index],
                    ordinal: index + 1,
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

    fileprivate static func makeContextMenu(owner: StartWindowController) -> NSMenu {
        let menu = NSMenu()
        let clear = NSMenuItem(
            title: "Clear Recent Files…",
            action: #selector(StartWindowController.clearRecents(_:)),
            keyEquivalent: ""
        )
        clear.target = owner
        menu.addItem(clear)
        return menu
    }
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
    /// The command this button runs, when it has one.  The shortcut hint is
    /// read from the live binding table rather than written into the label:
    /// bindings are user-editable, and a stale "⌘O" is a lie.
    private let command: Command?
    private let shell = NSView()
    private let iconView = NSImageView()
    private let titleLabel: NSTextField
    private let shortcutLabel = NSTextField(labelWithString: "")
    private let contentGroup = NSStackView()
    private var shortcutWidth: NSLayoutConstraint!
    private var isHovered = false
    private var isPressed = false
    private var sheet: StyleSheet

    init(
        title: String,
        icon: String,
        command: Command?,
        kind: Kind,
        sheet: StyleSheet,
        target: AnyObject,
        action: Selector
    ) {
        self.kind = kind
        self.command = command
        self.sheet = sheet
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: .zero)

        self.target = target
        self.action = action
        setButtonType(.momentaryPushIn)
        isBordered = false
        self.title = ""
        focusRingType = .none
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
        wantsLayer = true

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = StartLayout.cornerRadius
        shell.layer?.masksToBounds = true
        addSubview(shell)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        iconView.image = NSImage(systemSymbolName: icon, accessibilityDescription: title)
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.usesSingleLineMode = true
        titleLabel.lineBreakMode = .byTruncatingTail
        configurePassiveLabel(titleLabel)
        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        shortcutLabel.alignment = .center
        shortcutLabel.usesSingleLineMode = true
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.wantsLayer = true
        shortcutLabel.layer?.cornerRadius = 5
        shortcutLabel.layer?.masksToBounds = true
        configurePassiveLabel(shortcutLabel)
        contentGroup.orientation = .horizontal
        contentGroup.alignment = .centerY
        contentGroup.spacing = 10
        contentGroup.detachesHiddenViews = true
        contentGroup.translatesAutoresizingMaskIntoConstraints = false
        contentGroup.addArrangedSubview(iconView)
        contentGroup.addArrangedSubview(titleLabel)
        contentGroup.addArrangedSubview(shortcutLabel)
        contentGroup.setCustomSpacing(12, after: titleLabel)
        shell.addSubview(contentGroup)

        shortcutWidth = shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30)
        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            contentGroup.leadingAnchor.constraint(greaterThanOrEqualTo: shell.leadingAnchor, constant: 12),
            contentGroup.trailingAnchor.constraint(lessThanOrEqualTo: shell.trailingAnchor, constant: -12),
            contentGroup.centerXAnchor.constraint(equalTo: shell.centerXAnchor),
            contentGroup.centerYAnchor.constraint(equalTo: shell.centerYAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            shortcutWidth,
            // A low keycap is enough to signal the binding without becoming a
            // second control inside the control.
            shortcutLabel.heightAnchor.constraint(equalToConstant: 20),
        ])

        // The label must never be the thing that gives: a clipped "New Documen"
        // is worse than a wider button.
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        isEnabled = true
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        refreshShortcut()
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

    /// Re-reads the binding.  A command with no binding shows no hint and the
    /// button closes up around its label.
    func refreshShortcut() {
        let hint = command
            .flatMap { KeybindingStore.shared.primaryBinding(for: $0) }
            .map(\.displayString) ?? ""
        shortcutLabel.stringValue = hint
        shortcutLabel.isHidden = hint.isEmpty
        shortcutWidth.isActive = !hint.isEmpty
        setAccessibilityHelp(hint.isEmpty ? nil : hint)
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    override var mouseDownCanMoveWindow: Bool { false }

    override var intrinsicContentSize: NSSize {
        // fittingSize, not intrinsicContentSize: an NSTextFieldCell reports its
        // cell ~4pt wider than its intrinsic content size, and the layout
        // engine gives the label that wider frame.  Computing the button from
        // the under-reported intrinsic made the shell ~4pt too narrow — the
        // label-to-shortcut gap collapsed below its constant and the longer
        // label clipped.  fittingSize is what the label actually renders at.
        // The content group is centered in the well, so intrinsic sizing is
        // only used by the optional tour button; Open/New receive equal wells
        // from StartHeroView.
        return NSSize(width: ceil(contentGroup.fittingSize.width + 24), height: 34)
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
            let engaged = self.isPressed || self.isHovered || isFocused
            if self.kind == .primary {
                let accent = sheet.startWindowPrimaryAction
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
                self.shortcutLabel.layer?.backgroundColor = NSColor.white.withAlphaComponent(
                    self.isPressed ? 0.18 : (engaged ? 0.12 : 0.08)
                ).cgColor
                self.shortcutLabel.layer?.borderWidth = engaged ? 1 : 0
                self.shortcutLabel.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
            } else {
                let fillAlpha: CGFloat = self.isPressed ? 0.11 : (self.isHovered ? 0.075 : 0.045)
                self.shell.layer?.backgroundColor = sheet.text
                    .withAlphaComponent(contrast ? max(fillAlpha, 0.12) : fillAlpha).cgColor
                self.shell.layer?.borderWidth = isFocused ? 2 : 1
                self.shell.layer?.borderColor = (isFocused ? sheet.accent : sheet.rule)
                    .withAlphaComponent(isFocused ? 0.9 : (contrast ? 0.55 : 0.35)).cgColor
                self.titleLabel.textColor = sheet.text
                self.shortcutLabel.textColor = engaged ? sheet.text : sheet.textSecondary
                self.iconView.contentTintColor = engaged ? sheet.text : sheet.textSecondary
                self.shortcutLabel.layer?.backgroundColor = sheet.text.withAlphaComponent(
                    contrast
                        ? (engaged ? 0.12 : 0.07)
                        : (engaged ? 0.10 : 0.055)
                ).cgColor
                self.shortcutLabel.layer?.borderWidth = engaged ? 1 : 0
                self.shortcutLabel.layer?.borderColor = sheet.text.withAlphaComponent(
                    engaged ? 0.18 : 0.10
                ).cgColor
            }
            self.shell.layer?.setAffineTransform(
                self.isPressed
                    ? CGAffineTransform(scaleX: 0.985, y: 0.985)
                    : self.isHovered
                        ? CGAffineTransform(scaleX: 1.004, y: 1.004)
                        : .identity
            )
        }
        if animated {
            Motion.run(
                reduceMotion: sheet.reduceMotion,
                duration: Motion.hover,
                curve: .easeOut
            ) { _ in changes() }
        } else {
            changes()
        }
    }
}

// MARK: - Recent row

enum RecentRowCopy {
    private static let monthDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d")
        return formatter
    }()
    private static let monthDayYearFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d yyyy")
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

    static func timestamp(for recent: RecentDocument) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(recent.lastOpened) { return "Today" }
        if calendar.isDateInYesterday(recent.lastOpened) { return "Yesterday" }
        let now = Date()
        let year = calendar.component(.year, from: recent.lastOpened)
        let currentYear = calendar.component(.year, from: now)
        return year == currentYear
            ? monthDayFormatter.string(from: recent.lastOpened)
            : monthDayYearFormatter.string(from: recent.lastOpened)
    }

    static func folder(for recent: RecentDocument) -> String {
        let name = URL(fileURLWithPath: recent.path)
            .deletingLastPathComponent()
            .lastPathComponent
        return name == "/" ? "" : name
    }

    /// The row's second line: what the document is *about*.
    ///
    /// The first heading is the point — twelve files called `plan.md` are
    /// twelve identical rows without it, and that is the exact problem this app
    /// exists to solve.  It is skipped only when it would repeat the title
    /// back, in which case the folder is the more informative thing to say.
    static func subtitle(for recent: RecentDocument, title: String) -> String {
        let heading = cleanedHeading(recent.firstHeading)
        let place = folder(for: recent)
        guard !heading.isEmpty, !echoes(heading, of: title) else { return place }
        // `README` in `Downright/` under the heading "Downright" would otherwise
        // render as "Downright · Downright"; saying it once is the whole point.
        guard !place.isEmpty, !echoes(heading, of: place) else { return heading }
        // Both, when the folder is what disambiguates two same-named documents
        // and the heading is what explains them.
        return "\(heading)  ·  \(place)"
    }

    /// A malformed editor write once persisted a partial prose prefix directly
    /// against a capitalized heading (`ThiDownright …`). Keep that stale
    /// metadata from leaking into the welcome surface while leaving ordinary
    /// headings, including `This …`, untouched.
    private static func cleanedHeading(_ rawHeading: String) -> String {
        let heading = rawHeading.trimmingCharacters(in: .whitespacesAndNewlines)
        guard heading.hasPrefix("Thi"),
              heading.dropFirst(3).first?.isUppercase == true
        else { return heading }
        return String(heading.dropFirst(3))
    }

    /// Whether the heading would just restate the title.  Compared without case
    /// or punctuation so "Release Plan" and "release-plan" count as the same
    /// thing being said twice.
    static func echoes(_ heading: String, of title: String) -> Bool {
        func fold(_ text: String) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let left = fold(heading)
        let right = fold(title)
        guard !left.isEmpty, !right.isEmpty else { return true }
        return left == right || left.hasPrefix(right) || right.hasPrefix(left)
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
    private let documentIcon = NSImageView()
    private let titleLabel: NSTextField
    private let titleRow = NSStackView()
    private let subtitleLabel: NSTextField
    private let detailLabel: NSTextField
    private let shortcutLabel = NSTextField(labelWithString: "")
    private var isHovered = false
    private var isPressed = false
    private var sheet: StyleSheet

    init(
        recent: RecentDocument, title: String, ordinal: Int,
        target: StartWindowController, sheet: StyleSheet
    ) {
        documentPath = recent.path
        self.sheet = sheet
        titleLabel = NSTextField(labelWithString: title)
        detailLabel = NSTextField(labelWithString: RecentRowCopy.timestamp(for: recent))
        subtitleLabel = NSTextField(labelWithString: RecentRowCopy.subtitle(for: recent, title: title))
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
        setAccessibilityValue("\(subtitleLabel.stringValue), \(detailLabel.stringValue)")
        setAccessibilityHelp(ordinal <= 9 ? "Press ⌘\(ordinal) to open" : nil)
        wantsLayer = true
        toolTip = recent.path

        shell.translatesAutoresizingMaskIntoConstraints = false
        shell.wantsLayer = true
        shell.layer?.cornerRadius = StartLayout.cornerRadius
        shell.layer?.masksToBounds = true
        addSubview(shell)

        documentIcon.translatesAutoresizingMaskIntoConstraints = false
        documentIcon.image = NSImage(
            systemSymbolName: "doc.text",
            accessibilityDescription: "Markdown document"
        )
        documentIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 14, weight: .regular
        )
        documentIcon.setAccessibilityLabel("Markdown document")
        shell.addSubview(documentIcon)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.maximumNumberOfLines = 1
        configurePassiveLabel(titleLabel)
        shell.addSubview(titleLabel)

        // What the document is actually about.  A folder full of agent output
        // is a folder of interchangeable names; the first heading is the only
        // thing that tells them apart, and showing it here is the app's whole
        // argument made in one line before the user has read any copy.
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.maximumNumberOfLines = 1
        configurePassiveLabel(subtitleLabel)
        shell.addSubview(subtitleLabel)

        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.font = .systemFont(ofSize: 11.5, weight: .regular)
        detailLabel.alignment = .right
        detailLabel.usesSingleLineMode = true
        detailLabel.lineBreakMode = .byTruncatingTail
        detailLabel.maximumNumberOfLines = 1
        configurePassiveLabel(detailLabel)
        shell.addSubview(detailLabel)

        shortcutLabel.translatesAutoresizingMaskIntoConstraints = false
        shortcutLabel.stringValue = ordinal <= 9 ? "⌘\(ordinal)" : ""
        shortcutLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        shortcutLabel.alignment = .center
        shortcutLabel.usesSingleLineMode = true
        shortcutLabel.lineBreakMode = .byTruncatingTail
        shortcutLabel.wantsLayer = true
        shortcutLabel.layer?.cornerRadius = 4
        shortcutLabel.layer?.masksToBounds = true
        shortcutLabel.isHidden = true
        configurePassiveLabel(shortcutLabel)
        shortcutLabel.setAccessibilityLabel("Keyboard shortcut \(shortcutLabel.stringValue)")

        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 7
        titleRow.detachesHiddenViews = true
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.addArrangedSubview(titleLabel)
        titleRow.addArrangedSubview(shortcutLabel)

        menu = RecentDocumentsPanel.makeContextMenu(owner: target)

        let text = NSStackView(views: [titleRow, subtitleLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 1
        text.translatesAutoresizingMaskIntoConstraints = false
        shell.addSubview(text)

        NSLayoutConstraint.activate([
            shell.leadingAnchor.constraint(equalTo: leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: trailingAnchor),
            shell.topAnchor.constraint(equalTo: topAnchor),
            shell.bottomAnchor.constraint(equalTo: bottomAnchor),

            documentIcon.leadingAnchor.constraint(equalTo: shell.leadingAnchor, constant: 11),
            documentIcon.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
            documentIcon.widthAnchor.constraint(equalToConstant: 18),
            documentIcon.heightAnchor.constraint(equalToConstant: 18),

            text.leadingAnchor.constraint(equalTo: documentIcon.trailingAnchor, constant: 7),
            text.trailingAnchor.constraint(lessThanOrEqualTo: detailLabel.leadingAnchor, constant: -16),
            text.centerYAnchor.constraint(equalTo: shell.centerYAnchor),

            shortcutLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30),
            shortcutLabel.heightAnchor.constraint(equalToConstant: 22),
            detailLabel.widthAnchor.constraint(equalToConstant: 74),
            detailLabel.trailingAnchor.constraint(equalTo: shell.trailingAnchor, constant: -12),
            detailLabel.centerYAnchor.constraint(equalTo: shell.centerYAnchor),
        ])

        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detailLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        shortcutLabel.setContentHuggingPriority(.required, for: .horizontal)
        shortcutLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

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
            // The header teaches the ordinal shortcuts once. The row only
            // reveals its own keycap when it is the target of attention, so
            // the timestamp column remains clean at rest.
            self.shortcutLabel.isHidden = !engaged
            self.documentIcon.contentTintColor = engaged ? sheet.text : sheet.textSecondary
            self.titleLabel.textColor = sheet.text
            self.subtitleLabel.textColor = engaged ? sheet.text : sheet.textSecondary
            self.detailLabel.textColor = engaged ? sheet.textSecondary : sheet.textFaint
            self.shortcutLabel.textColor = engaged ? sheet.accent : sheet.textFaint
            self.shortcutLabel.layer?.backgroundColor = sheet.text.withAlphaComponent(
                engaged ? (contrast ? 0.14 : 0.12) : (contrast ? 0.10 : 0.08)
            ).cgColor
            self.shortcutLabel.layer?.borderWidth = 1
            self.shortcutLabel.layer?.borderColor = sheet.text.withAlphaComponent(
                engaged ? 0.24 : 0.16
            ).cgColor
            self.shell.layer?.setAffineTransform(
                self.isPressed
                    ? CGAffineTransform(scaleX: 0.992, y: 0.992)
                    : .identity
            )
        }
        if animated, !sheet.reduceMotion {
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
