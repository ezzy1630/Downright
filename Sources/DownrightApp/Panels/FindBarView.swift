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
    static let barWidth: CGFloat = 440
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
private final class FindBarSearchField: NSSearchField {
    var ringColor: NSColor = .controlAccentColor { didSet { needsDisplay = true } }
    private var keyObservers: [NSObjectProtocol] = []

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard FindFieldRing.isVisible(in: self) else { return }
        let ring = bounds.insetBy(dx: FindFieldRing.inset, dy: FindFieldRing.inset)
        FindFieldRing.stroke(in: self, cornerRadius: ring.height / 2, color: ringColor)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyObservers = FindFieldRing.reinstallKeyStatusRedraw(on: self, replacing: keyObservers)
    }

    deinit { keyObservers.forEach(NotificationCenter.default.removeObserver) }
}

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
            applyStyle()
        }
    }

    var showsReplace: Bool = false {
        didSet {
            guard showsReplace != oldValue else { return }
            replaceRow.isHidden = !showsReplace
            invalidateIntrinsicContentSize()
        }
    }

    var statusText: String = "" {
        didSet {
            guard statusText != oldValue else { return }
            statusLabel.stringValue = statusText
            // Collapse out of the tray when there is no count to report: a
            // hidden stack member takes no width, so the field stretches to
            // fill the row instead of leaving a measured gap of dead air.
            statusLabel.isHidden = statusText.isEmpty
            statusLabel.setAccessibilityLabel(statusText.isEmpty ? "No search" : statusText)
            applyStatusColor()
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
    private let searchField = FindBarSearchField()
    private let replaceField = FindBarReplaceField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let warningImage = NSImageView()
    private let trailerDivider = NSView()
    private let regexToggle: NSButton
    private let caseToggle: NSButton
    private let wordToggle: NSButton
    private let scopeToggle: NSButton
    private let optionsButton: NSButton
    /// Assigned in `buildFindRow()` so `applyStyle()` can keep every chrome
    /// glyph on the same quiet tint instead of AppKit's default white.
    private var previousButton: NSButton!
    private var nextButton: NSButton!
    private var closeButton: NSButton?
    private let findRow = NSStackView()
    private let replaceRow = NSStackView()
    private let rows = NSStackView()
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

        installBackdrop(backdrop)

        buildFindRow()
        buildReplaceRow()

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = presentation == .inspector ? 8 : 6
        rows.translatesAutoresizingMaskIntoConstraints = false
        rows.addArrangedSubview(findRow)
        rows.addArrangedSubview(replaceRow)
        replaceRow.isHidden = true
        addSubview(rows)

        NSLayoutConstraint.activate([
            rows.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            rows.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            rows.topAnchor.constraint(equalTo: topAnchor, constant: presentation == .inspector ? 8 : 6),
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
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")

        // The .bar form floats over the document as a card rather than a
        // full-width strip. Rounded corners let the material read as its own
        // surface; `masksToBounds` clips the vibrancy to the card, and the
        // layer border draws the polished outline on top of it. (A layer
        // shadow cannot survive `masksToBounds`, so the outline stays flat;
        // the pill's own height separates it from the page underneath.)
        if presentation == .bar {
            wantsLayer = true
            layer?.cornerRadius = PanelMetrics.cornerRadius
            layer?.masksToBounds = true
            layer?.borderWidth = 1
        } else {
            // Inspector content is animated by its layer-backed host. Keep the
            // find surface in that layer tree explicitly; without its own
            // backing layer AppKit exposes and focuses the controls but never
            // composites them above the nested material surface.
            wantsLayer = true
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildFindRow() {
        searchField.placeholderString = "Find"
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.font = PanelFont.row
        searchField.controlSize = .small
        // The system ring is retired in favour of the field's own thin stroke
        // (see FindFieldRing above).
        searchField.focusRingType = .none
        searchField.setAccessibilityLabel("Find")
        searchField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        warningImage.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: "Invalid regular expression"
        )
        warningImage.toolTip = "Invalid regular expression"
        warningImage.isHidden = true

        statusLabel.font = PanelFont.secondary
        statusLabel.alignment = .right
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

        let previousButton = PanelButton.symbol("chevron.up", label: "Previous match", action: previous)
        let nextButton = PanelButton.symbol("chevron.down", label: "Next match", action: next)
        self.previousButton = previousButton
        self.nextButton = nextButton
        findRow.translatesAutoresizingMaskIntoConstraints = false
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
        let trailer = NSStackView()
        trailer.orientation = .horizontal
        trailer.spacing = 2
        trailer.alignment = .centerY
        for view in [statusLabel, previousButton, nextButton] {
            trailer.addArrangedSubview(view)
        }
        trailerDivider.wantsLayer = true
        trailerDivider.layer?.cornerRadius = 1
        trailerDivider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        trailerDivider.heightAnchor.constraint(equalToConstant: 14).isActive = true

        var rowViews: [NSView] = [searchField, warningImage, trailerDivider, trailer, optionsButton]
        if presentation == .bar {
            let close = ButtonAction { [weak self] in
                guard let self else { return }
                self.delegate?.findBarDidRequestClose(self)
            }
            actions.append(close)
            let closeButton = PanelButton.symbol("xmark", label: "Close find bar", action: close)
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

        replaceRow.orientation = .horizontal
        replaceRow.spacing = 6
        replaceRow.alignment = .centerY
        replaceRow.translatesAutoresizingMaskIntoConstraints = false
        replaceRow.addArrangedSubview(replaceField)
        replaceRow.addArrangedSubview(PanelButton.text("Replace", action: replace))
        replaceRow.addArrangedSubview(PanelButton.text("All", action: replaceAll))
    }

    // MARK: - API

    override var intrinsicContentSize: NSSize {
        switch presentation {
        case .bar:
            NSSize(width: NSView.noIntrinsicMetric, height: showsReplace ? 66 : 34)
        case .inspector:
            NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
        }
    }

    func focusSearchField() {
        window?.makeFirstResponder(searchField)
        searchField.currentEditor()?.selectAll(nil)
    }

    /// Used by "Use Selection for Find" (§7.2) — the host pushes text in and
    /// the bar behaves exactly as if it had been typed.
    func setQueryText(_ text: String) {
        searchField.stringValue = text
        emitQuery()
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
        // Chrome glyphs share the quiet text tint; AppKit's default is a
        // full-strength white that shouts over a dark themed surface.
        for button in [optionsButton, previousButton, nextButton, closeButton].compactMap({ $0 }) {
            button.contentTintColor = styleSheet.textSecondary
        }
        // The focus ring echoes the theme's accent — the same "here" as the
        // pinned match count below.
        searchField.ringColor = styleSheet.accent
        replaceField.ringColor = styleSheet.accent
        // The bar's outline follows the theme so it stays legible in both
        // appearances (the inspector form has no border width, so this is a
        // no-op there).
        if presentation == .bar {
            layer?.borderColor = styleSheet.rule.cgColor
        }
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
    /// the normal case, not a failure state.
    private func applyValidity() {
        warningImage.isHidden = isQueryValid
        searchField.textColor = isQueryValid ? styleSheet.text : styleSheet.changeColor(.deleted)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard presentation == .inspector else { return }
        // A themed well under the field's native capsule.  Over the
        // inspector's glass the system bezel alone is nearly invisible, and a
        // field you cannot see is the first thing people report as broken.
        let fieldFrame = convert(searchField.bounds, from: searchField)
        if !fieldFrame.isEmpty {
            let well = fieldFrame.insetBy(dx: -1, dy: -1.5)
            let capsule = NSBezierPath(
                roundedRect: well, xRadius: well.height / 2, yRadius: well.height / 2
            )
            styleSheet.surface
                .panelAlpha(0.85, increaseContrast: styleSheet.increaseContrast).setFill()
            capsule.fill()
            styleSheet.rule
                .panelAlpha(0.9, increaseContrast: styleSheet.increaseContrast).setStroke()
            capsule.lineWidth = PanelMetrics.hairline
            capsule.stroke()
        }
        styleSheet.rule.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: PanelMetrics.hairline).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

// MARK: - Field editing

extension FindBarView: NSSearchFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSSearchField) === searchField else { return }
        emitQuery()
    }

    /// With the system ring retired, the fields repaint their own ring as the
    /// field editor comes and goes.
    func controlTextDidBeginEditing(_ notification: Notification) {
        (notification.object as? NSControl)?.needsDisplay = true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        (notification.object as? NSControl)?.needsDisplay = true
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
