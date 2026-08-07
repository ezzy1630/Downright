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
    private let searchField = NSSearchField()
    private let replaceField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let warningImage = NSImageView()
    private let trailerDivider = NSView()
    private let regexToggle: NSButton
    private let caseToggle: NSButton
    private let wordToggle: NSButton
    private let scopeToggle: NSButton
    private let optionsButton: NSButton
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

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        buildFindRow()
        buildReplaceRow()

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = presentation == .inspector ? 10 : 6
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
        findRow.translatesAutoresizingMaskIntoConstraints = false
        findRow.setHuggingPriority(.defaultLow, for: .horizontal)

        switch presentation {
        case .bar:
            let close = ButtonAction { [weak self] in
                guard let self else { return }
                self.delegate?.findBarDidRequestClose(self)
            }
            actions.append(close)
            // The field stretches to fill the pill; the bar's own fixed width
            // (FindBarDensity.barWidth) gives it a settled, centred extent.
            findRow.orientation = .horizontal
            findRow.spacing = 6
            findRow.alignment = .centerY
            // The count and chevrons sit as one tray on the field's trailing
            // edge (split by a hairline) so the pill reads as a single control,
            // with options and the close key trailing after (§9.4).
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
            for view in [searchField, warningImage, trailerDivider, trailer, optionsButton,
                         PanelButton.symbol("xmark", label: "Close find bar", action: close)] {
                findRow.addArrangedSubview(view)
            }

        case .inspector:
            let searchLine = NSStackView(views: [searchField, warningImage])
            searchLine.orientation = .horizontal
            searchLine.spacing = 6
            searchLine.alignment = .centerY

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let navigation = NSStackView(views: [statusLabel, spacer, optionsButton, previousButton, nextButton])
            navigation.orientation = .horizontal
            navigation.spacing = 6
            navigation.alignment = .centerY

            findRow.orientation = .vertical
            findRow.spacing = 8
            findRow.alignment = .leading
            for view in [searchLine, navigation] {
                findRow.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: findRow.widthAnchor).isActive = true
            }
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
