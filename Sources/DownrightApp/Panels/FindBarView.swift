import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol FindBarDelegate: AnyObject {
    func findBar(_ bar: FindBarView, didChange query: FindQuery)
    func findBar(_ bar: FindBarView, didRequestAdvance forward: Bool)
    func findBar(_ bar: FindBarView, didRequestReplace replacement: String, all: Bool)
    func findBarDidRequestClose(_ bar: FindBarView)
}

/// Find bar (§9.4).
///
/// Find-as-you-type: every keystroke emits a query, because a live match count
/// and live gutter ticks are the whole point of searching a document you are
/// looking at.  A half-typed regex is not an error — the field warns quietly
/// and the document keeps its previous highlighting rather than throwing a
/// dialog per character.

/// The find bar's typographic span. The document stack compresses this with a
/// high-priority cap so a narrow window shrinks the pill instead of clipping it.
enum FindBarDensity {
    static let barWidth: CGFloat = 480
    static let barHeight: CGFloat = 42
    static let replaceHeight: CGFloat = 80
}

// MARK: - Focus ring

/// The find bar's fields draw their own focus ring (§9.4).  The platform ring
/// is a heavy blurred halo that floats outside the bezel; on a bar this
/// compact it reads as a thick bubble, and at `.small` control size the glow
/// never quite centres on the field.  A single crisp stroke tight on the
/// bezel is thinner, and concentric with the bezel by construction.
private enum FindFieldRing {
    /// Inset from the field's edge, so the stroke lands just inside the bezel
    /// outline instead of reaching over the chrome outside it.
    static let inset: CGFloat = 1
    static let lineWidth: CGFloat = 1.5

    /// The platform ring's visibility rule, kept: the field owns the key
    /// window's first responder.
    static func isVisible(in field: NSTextField) -> Bool {
        guard let window = field.window, window.isKeyWindow else { return false }
        return window.firstResponder === field.currentEditor() || window.firstResponder === field
    }

    static func stroke(in field: NSTextField, cornerRadius: CGFloat, color: NSColor) {
        let bezel = field.bounds.insetBy(dx: inset, dy: inset)
        let path = NSBezierPath(roundedRect: bezel, xRadius: cornerRadius, yRadius: cornerRadius)
        path.lineWidth = lineWidth
        color.setStroke()
        path.stroke()
    }

    /// With the system ring retired, AppKit no longer drives ring repaints, so
    /// the field repaints itself when its window's key status flips.
    /// Observers from a previous window are retired first; leaving the window
    /// (or `deinit`) clears them again.
    static func reinstallKeyStatusRedraw(
        on field: NSTextField,
        replacing old: [NSObjectProtocol]
    ) -> [NSObjectProtocol] {
        old.forEach(NotificationCenter.default.removeObserver)
        guard let window = field.window else { return [] }
        return [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak field] _ in
                field?.needsDisplay = true
            }
        }
    }
}

/// The find field itself.  Its bezel is a capsule, so the ring's radius comes
/// from the ring rect's own height — the stroke and the bezel can never
/// drift apart.
private final class FindBarSearchField: NSSearchField {}

/// The replace row's field draws the same ring so the two rows never
/// disagree; its bezel is the standard rounded rect rather than a capsule.
private final class FindBarReplaceField: NSTextField {
    var ringColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    private var keyObservers: [NSObjectProtocol] = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard FindFieldRing.isVisible(in: self) else { return }
        FindFieldRing.stroke(in: self, cornerRadius: 5, color: ringColor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers = FindFieldRing.reinstallKeyStatusRedraw(on: self, replacing: keyObservers)
    }

    deinit { keyObservers.forEach(NotificationCenter.default.removeObserver) }
}

final class FindBarView: NSView {
    enum Presentation {
        case bar
        case inspector
    }

    weak var delegate: FindBarDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            glass?.styleSheet = styleSheet
            applyStyle()
        }
    }

    var showsReplace: Bool = false {
        didSet {
            guard showsReplace != oldValue else { return }
            setReplaceRowVisible(showsReplace)
        }
    }

    /// Animates the replace row into and out of the bar.
    ///
    /// The row is a stack member, so its height collapse is the stack's own
    /// business; what this owns is that the *content* never snaps like the old
    /// bare `isHidden` flip did.  It fades and slides up on its way in and
    /// slips down and fades on the way out, then only leaves the stack once it
    /// is invisible — the same retire-after-material has gone that the floating
    /// pill uses on dismissal.  The pill's own height rides alongside as a
    /// glide (`glideBarHeight`), so the bar grows around the arriving row
    /// instead of jumping to its new size and filling in afterwards.  Outside
    /// a window (measurement during tests) and under Reduce Motion the row
    /// simply appears or disappears, so no timing code ever runs on a surface
    /// nobody is looking at.
    private func setReplaceRowVisible(_ visible: Bool) {
        guard window != nil, !styleSheet.reduceMotion else {
            replaceRow.isHidden = !visible
            invalidateIntrinsicContentSize()
            return
        }
        if visible {
            replaceRow.isHidden = false
            replaceRow.alphaValue = 0
            replaceRow.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -5))
            glideBarHeight()
            Motion.run(reduceMotion: false, duration: Motion.standard, curve: .easeOut) { _ in
                self.replaceRow.animator().alphaValue = 1
                self.replaceRow.layer?.setAffineTransform(.identity)
            }
        } else {
            Motion.run(reduceMotion: false, duration: Motion.quick, curve: .easeOut) { _ in
                self.replaceRow.animator().alphaValue = 0
                self.replaceRow.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -5))
            } completion: { [weak self] in
                guard let self, !self.showsReplace else { return }
                self.replaceRow.isHidden = true
                self.replaceRow.alphaValue = 1
                self.replaceRow.layer?.setAffineTransform(.identity)
                self.glideBarHeight()
            }
        }
    }

    /// The pill's height follows its rows with a glide, not a jump.  The
    /// intrinsic size answers immediately — it is the layout pass that
    /// animates — so the bar and the document below it resize as one surface.
    /// The inspector presentation carries no intrinsic height; its host owns
    /// the equivalent animation (`SearchInspectorView.showsReplace`).
    private func glideBarHeight() {
        invalidateIntrinsicContentSize()
        guard presentation == .bar, let content = window?.contentView else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.standard
            context.timingFunction = Motion.timing(.structural)
            context.allowsImplicitAnimation = true
            content.layoutSubtreeIfNeeded()
        }
    }

    var statusText: String = "" {
        didSet {
            guard statusText != oldValue else { return }
            setStatusLabelText(statusText)
            statusLabel.setAccessibilityLabel(statusText.isEmpty ? "No search" : statusText)
            applyStatusColor()
            updateControlEnablement()
        }
    }

    /// The count crossfades rather than swapping mid-read, and the tray it
    /// lives in glides open and closed through the stack's own member
    /// animation: a hidden stack member takes no width, so the field
    /// stretches to fill the row instead of leaving a measured gap of dead
    /// air — but it *stretches*, it never snaps sideways.
    private func setStatusLabelText(_ text: String) {
        let becomingHidden = text.isEmpty
        let live = window != nil && !styleSheet.reduceMotion
        guard live, becomingHidden != statusLabel.isHidden else {
            // A count arriving while its own fade-out is still running wins:
            // the fade is retired before it can park the label at alpha 0.
            if live {
                statusLabel.layer?.removeAllAnimations()
                if !becomingHidden, statusLabel.stringValue != text {
                    let fade = CATransition()
                    fade.type = .fade
                    fade.duration = Motion.quick
                    fade.timingFunction = Motion.timing(.easeOut)
                    statusLabel.layer?.add(fade, forKey: "find-status")
                }
            }
            statusLabel.stringValue = text
            statusLabel.isHidden = becomingHidden
            statusLabel.alphaValue = 1
            return
        }
        if becomingHidden {
            Motion.run(reduceMotion: false, duration: Motion.quick) { _ in
                self.statusLabel.animator().alphaValue = 0
            } completion: { [weak self] in
                guard let self else { return }
                guard self.statusText.isEmpty else {
                    self.statusLabel.layer?.removeAllAnimations()
                    self.statusLabel.alphaValue = 1
                    return
                }
                self.statusLabel.stringValue = ""
                Motion.run(reduceMotion: false, duration: Motion.quick) { _ in
                    self.statusLabel.animator().isHidden = true
                    self.layoutSubtreeIfNeeded()
                }
                self.statusLabel.alphaValue = 1
            }
        } else {
            statusLabel.layer?.removeAllAnimations()
            statusLabel.stringValue = text
            statusLabel.alphaValue = 0
            statusLabel.isHidden = false
            Motion.run(reduceMotion: false, duration: Motion.quick) { _ in
                self.statusLabel.animator().alphaValue = 1
                self.layoutSubtreeIfNeeded()
            }
        }
    }

    var isQueryValid: Bool = true {
        didSet {
            guard isQueryValid != oldValue else { return }
            applyValidity()
        }
    }

    /// Range the "in selection" toggle scopes to.  The bar cannot know the
    /// document's selection, so the host pushes it in; the toggle is disabled
    /// while it is nil.
    var selectionScope: NSRange? {
        didSet {
            scopeToggle.isEnabled = selectionScope != nil
            if selectionScope == nil, scopeToggle.state == .on {
                scopeToggle.state = .off
                emitQuery()
            }
        }
    }

    // MARK: - Views

    private let backdrop: PanelBackdrop
    private var glass: ChromeGlass?
    private let inspectorWell = NSView()
    private let searchField = FindBarSearchField()
    private let replaceField = FindBarReplaceField()
    private let leadingGlyph = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let warningImage = NSImageView()
    private let trailerDivider = NSView()
    private let optionsDivider = NSView()
    private let regexToggle: NSButton
    private let caseToggle: NSButton
    private let wordToggle: NSButton
    private let scopeToggle: NSButton
    private let optionsButton: NSButton
    /// Assigned in `buildFindRow()` so `applyStyle()` can keep every chrome
    /// glyph on the same quiet tint instead of AppKit's default white.
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    /// Assigned in `buildReplaceRow()` so `updateControlEnablement()` can park
    /// them when there is nothing to replace.
    private var replaceButton: NSButton!
    private var replaceAllButton: NSButton!
    private var closeButton: NSButton?
    private let findRow = NSStackView()
    private let replaceRow = NSStackView()
    private let rows = NSStackView()
    private var entranceGeneration = 0
    private var actions: [ButtonAction] = []
    private var optionsAction: ButtonAction?
    private let presentation: Presentation

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current, presentation: .bar) }

    init(styleSheet: StyleSheet, presentation: Presentation = .bar) {
        self.styleSheet = styleSheet
        self.presentation = presentation
        self.backdrop = PanelBackdrop(styleSheet: styleSheet, material: .headerView, blendingMode: .withinWindow)

        // Targets are rebound below; the toggles have to exist before
        // `super.init`, and their real handler needs `self`.
        let placeholder = ButtonAction {}
        self.regexToggle = PanelButton.toggle(".*", label: "Regular expression", action: placeholder)
        self.caseToggle = PanelButton.toggle("Aa", label: "Match case", action: placeholder)
        self.wordToggle = PanelButton.toggle("W", label: "Whole word", action: placeholder)
        self.scopeToggle = PanelButton.toggle("In Selection", label: "Search in selection", action: placeholder)
        self.optionsButton = PanelButton.symbol(
            "slider.horizontal.3",
            label: "Find options",
            action: placeholder
        )

        super.init(frame: .zero)

        let contentHost: NSView
        if presentation == .bar {
            let glass = ChromeGlass(
                styleSheet: styleSheet,
                cornerRadius: PanelMetrics.chromePillRadius,
                tint: .panel
            )
            glass.autoresizingMask = [.width, .height]
            glass.frame = bounds
            glass.shadowRadius = 18
            glass.shadowOffset = NSSize(width: 0, height: -4)
            addSubview(glass)
            self.glass = glass
            contentHost = glass.contentView
        } else {
            installBackdrop(backdrop)
            inspectorWell.wantsLayer = true
            inspectorWell.layer?.cornerCurve = .continuous
            inspectorWell.layer?.cornerRadius = PanelMetrics.nestedSurfaceRadius
            addSubview(inspectorWell, positioned: .above, relativeTo: backdrop)
            contentHost = self
        }

        buildFindRow()
        buildReplaceRow()

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = presentation == .inspector ? 8 : 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(findRow)
        rows.addArrangedSubview(replaceRow)
        replaceRow.isHidden = true
        contentHost.addSubview(rows)

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: contentHost.leadingAnchor, constant: PanelMetrics.inset),
            rows.trailingAnchor.constraint(equalTo: contentHost.trailingAnchor, constant: -PanelMetrics.inset),
            rows.topAnchor.constraint(equalTo: contentHost.topAnchor, constant: presentation == .inspector ? 10 : 7),
            findRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
            replaceRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
        ])

        // The toggles all mean "recompute the query", so they share one handler
        // rather than four near-identical ones.
        for toggle in [regexToggle, caseToggle, wordToggle, scopeToggle] {
            let action = ButtonAction { [weak self] in self?.emitQuery() }
            actions.append(action)
            toggle.target = action
            toggle.action = #selector(ButtonAction.fire(_:))
        }
        let optionsAction = ButtonAction { [weak self] in self?.showOptionsMenu() }
        self.optionsAction = optionsAction
        optionsButton.target = optionsAction
        optionsButton.action = #selector(ButtonAction.fire(_:))
        scopeToggle.isEnabled = false

        applyStyle()
        applyValidity()
        updateControlEnablement()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")

        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        glass?.frame = bounds
        if presentation == .inspector {
            let rowFrame = convert(findRow.bounds, from: findRow)
            inspectorWell.frame = rowFrame.insetBy(dx: -2, dy: -3)
        }
    }

    private func buildFindRow() {
        searchField.placeholderString = "Find…"
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.font = PanelFont.system(13.5)
        searchField.controlSize = .small
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.backgroundColor = .clear
        searchField.cell?.isBezeled = false
        (searchField.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        searchField.focusRingType = .none
        searchField.setAccessibilityLabel("Find")
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        leadingGlyph.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        leadingGlyph.imageScaling = .scaleProportionallyDown
        leadingGlyph.setAccessibilityElement(false)
        leadingGlyph.widthAnchor.constraint(equalToConstant: 22).isActive = true

        warningImage.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Invalid regular expression"
        )
        warningImage.toolTip = "Invalid regular expression"
        warningImage.isHidden = true
        // Layer-backed so the invalid-pattern glyph can pop in rather than
        // appear (`setWarningVisible`).
        warningImage.wantsLayer = true

        statusLabel.font = PanelFont.secondary
        statusLabel.alignment = .right
        // Layer-backed so a changing count can crossfade (`setStatusLabelText`).
        statusLabel.wantsLayer = true
        // Starts hidden: no count is pinned until a session reports one, and
        // a hidden stack member leaves no gap in the tray.
        statusLabel.isHidden = true
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        // A settled slot for the count so "1 of 1" and "12 of 12" never nudge
        // the surrounding buttons (§9.4).
        statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true

        let previous = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.findBar(self, didRequestAdvance: false)
        }
        let next = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.findBar(self, didRequestAdvance: true)
        }
        actions.append(contentsOf: [previous, next])

        let previousButton = PanelButton.symbol(
            "chevron.up", label: "Previous match", action: previous,
            pointSize: 14, weight: .regular
        )
        let nextButton = PanelButton.symbol(
            "chevron.down", label: "Next match", action: next,
            pointSize: 14, weight: .regular
        )
        self.previousButton = previousButton
        self.nextButton = nextButton
        findRow.translatesAutoresizingMaskIntoConstraints = false
        findRow.wantsLayer = true
        findRow.setHuggingPriority(.defaultLow, for: .horizontal)

        // One row for both presentations: the field stretches; the count and
        // the walk chevrons sit as one tray split off by a hairline, so the
        // row reads as a single control; options (and, for the floating bar,
        // the close key) trail after (§9.4).  The inspector used to stack a
        // second navigation row under the field — a whole row of chrome for
        // three small glyphs.
        findRow.orientation = .horizontal
        findRow.spacing = 6
        findRow.alignment = .centerY
        trailerDivider.wantsLayer = true
        trailerDivider.layer?.cornerRadius = 1
        trailerDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        trailerDivider.identifier = NSUserInterfaceItemIdentifier("find-divider")
        trailerDivider.heightAnchor.constraint(equalToConstant: 18).isActive = true

        optionsDivider.wantsLayer = true
        optionsDivider.layer?.cornerRadius = 1
        optionsDivider.identifier = NSUserInterfaceItemIdentifier("find-divider")
        optionsDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        optionsDivider.heightAnchor.constraint(equalToConstant: 18).isActive = true

        var rowViews: [NSView] = [
            leadingGlyph, searchField, warningImage, statusLabel,
            trailerDivider, previousButton, nextButton,
            optionsDivider, optionsButton,
        ]
        if presentation == .bar {
            let close = ButtonAction { [weak self] in
                guard let self else { return }
                self.delegate?.findBarDidRequestClose(self)
            }
            actions.append(close)
            let closeButton = PanelButton.symbol(
                "xmark", label: "Close find bar", action: close,
                pointSize: 14, weight: .regular
            )
            self.closeButton = closeButton
            rowViews.append(closeButton)
        }
        for view in rowViews {
            findRow.addArrangedSubview(view)
        }
    }

    func makeOptionsMenuForTesting() -> NSMenu {
        let menu = NSMenu(title: "Find Options")
        menu.addItem(optionItem(
            title: "Regular Expression",
            action: #selector(toggleRegexOption(_:)),
            state: regexToggle.state,
            enabled: true
        ))
        menu.addItem(optionItem(
            title: "Match Case",
            action: #selector(toggleCaseOption(_:)),
            state: caseToggle.state,
            enabled: true
        ))
        menu.addItem(optionItem(
            title: "Whole Word",
            action: #selector(toggleWordOption(_:)),
            state: wordToggle.state,
            enabled: true
        ))
        menu.addItem(.separator())
        menu.addItem(optionItem(
            title: "In Selection",
            action: #selector(toggleScopeOption(_:)),
            state: scopeToggle.state,
            enabled: selectionScope != nil
        ))
        return menu
    }

    private func optionItem(
        title: String,
        action: Selector,
        state: NSControl.StateValue,
        enabled: Bool
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = state
        item.isEnabled = enabled
        return item
    }

    private func showOptionsMenu() {
        let menu = makeOptionsMenuForTesting()
        menu.popUp(
            positioning: nil,
            at: NSPoint(x: optionsButton.bounds.minX, y: optionsButton.bounds.maxY + 2),
            in: optionsButton
        )
    }

    @objc private func toggleRegexOption(_ sender: NSMenuItem) { toggle(regexToggle) }
    @objc private func toggleCaseOption(_ sender: NSMenuItem) { toggle(caseToggle) }
    @objc private func toggleWordOption(_ sender: NSMenuItem) { toggle(wordToggle) }
    @objc private func toggleScopeOption(_ sender: NSMenuItem) {
        guard selectionScope != nil else { return }
        toggle(scopeToggle)
    }

    private func toggle(_ control: NSButton) {
        control.state = control.state == .on ? .off : .on
        emitQuery()
    }

    private func buildReplaceRow() {
        replaceField.placeholderString = "Replace"
        replaceField.font = PanelFont.row
        replaceField.controlSize = .small
        replaceField.focusRingType = .none
        replaceField.delegate = self
        replaceField.setAccessibilityLabel("Replace with")
        replaceField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let replace = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.findBar(self, didRequestReplace: self.replaceField.stringValue, all: false)
        }
        let replaceAll = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.findBar(self, didRequestReplace: self.replaceField.stringValue, all: true)
        }
        actions.append(contentsOf: [replace, replaceAll])

        let replaceButton = PanelButton.text("Replace", action: replace)
        let replaceAllButton = PanelButton.text("All", action: replaceAll)
        self.replaceButton = replaceButton
        self.replaceAllButton = replaceAllButton

        replaceRow.orientation = .horizontal
        replaceRow.spacing = 6
        replaceRow.alignment = .centerY
        replaceRow.translatesAutoresizingMaskIntoConstraints = false
        replaceRow.wantsLayer = true
        replaceRow.addArrangedSubview(replaceField)
        replaceRow.addArrangedSubview(replaceButton)
        replaceRow.addArrangedSubview(replaceAllButton)
    }

    // MARK: - API

    override var intrinsicContentSize: NSSize {
        switch presentation {
        case .bar:
            NSSize(
                width: NSView.noIntrinsicMetric,
                height: showsReplace ? FindBarDensity.replaceHeight : FindBarDensity.barHeight
            )
        case .inspector:
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }

    func focusSearchField(selectAll: Bool = true) {
        window?.makeFirstResponder(searchField)
        if selectAll {
            searchField.currentEditor()?.selectAll(nil)
        }
    }

    /// Keep labels and glyphs out of the material's topology change. The
    /// glass can stretch like one body; readable content arrives only once
    /// that body is close to its final width, avoiding the rubber-type look
    /// produced by scaling a populated search field from the toolbar lens.
    func prepareForLiquidEntrance() {
        entranceGeneration &+= 1
        rows.wantsLayer = true
        rows.layer?.removeAnimation(forKey: "find-content-arrival")
        rows.alphaValue = 0
        rows.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -2))
    }

    func playLiquidEntranceContent() {
        let generation = entranceGeneration
        guard !styleSheet.reduceMotion, window != nil, let layer = rows.layer else {
            rows.alphaValue = 1
            rows.layer?.setAffineTransform(.identity)
            return
        }

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 0.72, 1]
        opacity.keyTimes = [0, 0.58, 1]
        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = [
            CATransform3DMakeTranslation(0, -2, 0),
            CATransform3DMakeTranslation(0, 0.5, 0),
            CATransform3DIdentity,
        ]
        transform.keyTimes = [0, 0.72, 1]
        let group = CAAnimationGroup()
        group.animations = [opacity, transform]
        group.duration = Motion.standard
        group.beginTime = CACurrentMediaTime() + Motion.floatingContentRevealLead
        group.fillMode = .backwards
        group.timingFunction = Motion.timing(.decelerate)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self, self.entranceGeneration == generation else { return }
            self.rows.layer?.removeAnimation(forKey: "find-content-arrival")
        }
        rows.alphaValue = 1
        layer.setAffineTransform(.identity)
        layer.add(group, forKey: "find-content-arrival")
        CATransaction.commit()
    }

    func cancelLiquidEntrance() {
        entranceGeneration &+= 1
        rows.layer?.removeAnimation(forKey: "find-content-arrival")
        rows.alphaValue = 1
        rows.layer?.setAffineTransform(.identity)
    }

    /// Used by "Use Selection for Find" (§7.2) — the host pushes text in and
    /// the bar behaves exactly as if it had been typed.
    func setQueryText(_ text: String) {
        searchField.stringValue = text
        updateControlEnablement()
        emitQuery()
    }

    /// Buttons that walk or rewrite matches only mean something while there is
    /// a query to walk.  An empty field parks them, and a settled "No matches"
    /// keeps them parked — a button that cannot act must say so with its state,
    /// not with a click that lands nowhere.  Editing the text re-arms them
    /// immediately, so the find-as-you-type debounce never locks the reader
    /// out of the walk.
    private func updateControlEnablement() {
        let canNavigate = !searchField.stringValue.isEmpty && statusText != "No matches"
        previousButton?.isEnabled = canNavigate
        nextButton?.isEnabled = canNavigate
        replaceButton?.isEnabled = canNavigate
        replaceAllButton?.isEnabled = canNavigate
    }

    var currentQuery: FindQuery {
        var query = FindQuery()
        query.text = searchField.stringValue
        query.isRegex = regexToggle.state == .on
        query.caseSensitive = caseToggle.state == .on
        query.wholeWord = wordToggle.state == .on
        query.scope = scopeToggle.state == .on ? selectionScope : nil
        return query
    }

    private func emitQuery() {
        delegate?.findBar(self, didChange: currentQuery)
    }

    // MARK: - Style

    private func applyStyle() {
        trailerDivider.layer?.backgroundColor = styleSheet.rule.cgColor
        optionsDivider.layer?.backgroundColor = styleSheet.rule.cgColor
        leadingGlyph.contentTintColor = styleSheet.accent
        searchField.placeholderAttributedString = NSAttributedString(
            string: "Find…",
            attributes: [
                .font: PanelFont.system(13.5),
                .foregroundColor: styleSheet.textSecondary,
            ]
        )
        inspectorWell.layer?.backgroundColor = styleSheet.surface
            .panelAlpha(0.85, increaseContrast: styleSheet.increaseContrast).cgColor
        inspectorWell.layer?.borderColor = styleSheet.rule
            .panelAlpha(0.9, increaseContrast: styleSheet.increaseContrast).cgColor
        inspectorWell.layer?.borderWidth = PanelMetrics.hairline
        // Chrome glyphs share the quiet text tint; AppKit's default is a
        // full-strength white that shouts over a dark themed surface.
        for button in [optionsButton, previousButton, nextButton, closeButton].compactMap({ $0 }) {
            button.contentTintColor = styleSheet.textSecondary
        }
        // The focus ring echoes the theme's accent — the same "here" as the
        // pinned match count below.
        replaceField.ringColor = styleSheet.accent
        applyStatusColor()
        warningImage.contentTintColor = styleSheet.changeColor(.deleted)
        applyValidity()
        needsDisplay = true
    }

    /// The count echoes the theme's accent once a match is pinned (reads as
    /// the same "here" as the current-hit highlight); a failure stays in the
    /// delete tone; a bare total stays secondary. Replace confirmations read as
    /// success, so they share the accent (§9.4).
    private func applyStatusColor() {
        switch statusText {
        case "No matches":
            statusLabel.textColor = styleSheet.changeColor(.deleted)
        case let t where t.contains(" of ") || t.hasPrefix("Replaced"):
            statusLabel.textColor = styleSheet.accent
        default:
            statusLabel.textColor = styleSheet.textSecondary
        }
    }

    /// Subtle by design: an invalid pattern while you are still typing one is
    /// the normal case, not a failure state.  The glyph's entrance is a small
    /// springy pop rather than a hard appear, and it fades out just as
    /// quietly; the row glides to make room for it.
    private func applyValidity() {
        let show = !isQueryValid
        if show == warningImage.isHidden { setWarningVisible(show) }
        searchField.textColor = isQueryValid ? styleSheet.text : styleSheet.changeColor(.deleted)
    }

    private func setWarningVisible(_ visible: Bool) {
        let live = window != nil && !styleSheet.reduceMotion
        if visible {
            warningImage.layer?.removeAllAnimations()
            warningImage.isHidden = false
            guard live else { return }
            warningImage.alphaValue = 0
            warningImage.layer?.setAffineTransform(CGAffineTransform(scaleX: 0.6, y: 0.6))
            Motion.run(reduceMotion: false, duration: Motion.standard, curve: .snap) { _ in
                self.warningImage.animator().alphaValue = 1
                self.warningImage.layer?.setAffineTransform(.identity)
                self.layoutSubtreeIfNeeded()
            }
        } else {
            guard live else {
                warningImage.isHidden = true
                return
            }
            Motion.run(reduceMotion: false, duration: Motion.quick) { _ in
                self.warningImage.animator().alphaValue = 0
            } completion: { [weak self] in
                guard let self, self.isQueryValid else { return }
                self.warningImage.layer?.removeAllAnimations()
                self.warningImage.isHidden = true
                self.warningImage.alphaValue = 1
                self.warningImage.layer?.setAffineTransform(.identity)
            }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard presentation == .inspector else { return }
        styleSheet.rule.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: PanelMetrics.hairline).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    var dividerCountForTesting: Int {
        findRow.arrangedSubviews.count {
            $0.identifier?.rawValue == "find-divider"
        }
    }

    var hasCloseButtonForTesting: Bool { closeButton != nil }
    var leadingGlyphIsAccessibleForTesting: Bool { leadingGlyph.isAccessibilityElement() }
    var searchFieldIsBezeledForTesting: Bool { searchField.isBezeled }
}

// MARK: - Field editing

extension FindBarView: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        updateControlEnablement()
        emitQuery()
    }

    /// With the system ring retired, the fields repaint their own ring as the
    /// field editor comes and goes.
    func controlTextDidBeginEditing(_ notification: Notification) {
        (notification.object as? NSControl)?.needsDisplay = true
        if (notification.object as? NSSearchField) === searchField {
            glass?.showsFocus = true
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        (notification.object as? NSControl)?.needsDisplay = true
        if (notification.object as? NSSearchField) === searchField {
            glass?.showsFocus = false
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if control === replaceField {
                delegate?.findBar(self, didRequestReplace: replaceField.stringValue, all: false)
            } else {
                // ⏎ advances, ⇧⏎ goes back — the platform's find-bar idiom.
                let backwards = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
                delegate?.findBar(self, didRequestAdvance: !backwards)
            }
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            delegate?.findBarDidRequestClose(self)
            return true
        default:
            return false
        }
    }
}
