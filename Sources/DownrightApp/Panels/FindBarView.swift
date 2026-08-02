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
            statusLabel.stringValue = statusText
            statusLabel.setAccessibilityLabel(statusText.isEmpty ? "No search" : statusText)
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
    private let regexToggle: NSButton
    private let caseToggle: NSButton
    private let wordToggle: NSButton
    private let scopeToggle: NSButton
    private let findRow = NSStackView()
    private let replaceRow = NSStackView()
    private let rows = NSStackView()
    private var actions: [ButtonAction] = []
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
        scopeToggle.isEnabled = false

        applyStyle()
        applyValidity()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Find")
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
            findRow.orientation = .horizontal
            findRow.spacing = 6
            findRow.alignment = .centerY
            for view in [searchField, warningImage, statusLabel, regexToggle, caseToggle,
                         wordToggle, scopeToggle, previousButton, nextButton,
                         PanelButton.symbol("xmark", label: "Close find bar", action: close)] {
                findRow.addArrangedSubview(view)
            }

        case .inspector:
            let searchLine = NSStackView(views: [searchField, warningImage])
            searchLine.orientation = .horizontal
            searchLine.spacing = 6
            searchLine.alignment = .centerY

            let options = NSStackView(views: [regexToggle, caseToggle, wordToggle, scopeToggle])
            options.orientation = .horizontal
            options.spacing = 6
            options.alignment = .centerY

            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let navigation = NSStackView(views: [statusLabel, spacer, previousButton, nextButton])
            navigation.orientation = .horizontal
            navigation.spacing = 6
            navigation.alignment = .centerY

            findRow.orientation = .vertical
            findRow.spacing = 8
            findRow.alignment = .leading
            for view in [searchLine, options, navigation] {
                findRow.addArrangedSubview(view)
                view.widthAnchor.constraint(equalTo: findRow.widthAnchor).isActive = true
            }
        }
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
        statusLabel.textColor = styleSheet.textSecondary
        warningImage.contentTintColor = styleSheet.changeColor(.deleted)
        applyValidity()
        needsDisplay = true
    }

    /// Subtle by design: an invalid pattern while you are still typing one is
    /// the normal case, not a failure state.
    private func applyValidity() {
        warningImage.isHidden = isQueryValid
        searchField.textColor = isQueryValid ? styleSheet.text : styleSheet.changeColor(.deleted)
    }

    override func draw(_ dirtyRect: NSRect) {
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
