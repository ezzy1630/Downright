import AppKit
import MarkdownCore
import MarkdownRender

/// The small, safe front matter editor.  It edits only flat scalar fields.
/// Nested YAML, comments, anchors, and block scalars stay in Source mode.
@MainActor
protocol FrontMatterEditorDelegate: AnyObject {
    func frontMatterEditor(
        _ editor: FrontMatterEditorView,
        didRequest operation: FrontMatterEditOperation
    )
    func frontMatterEditorWantsSourceMode(_ editor: FrontMatterEditorView)
}

@MainActor
final class FrontMatterEditorView: NSView, PanelSurface {
    weak var delegate: FrontMatterEditorDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    var document: ParsedDocument = .empty {
        didSet { reload() }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    var renderedFieldCount: Int { rows.count }
    var showsSourceModePrompt: Bool { !sourceButton.isHidden }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: Command.frontMatterEditor.panelTitle)
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let fieldStack = NSStackView()
    /// Flipped so the field list starts at the top of the scroller rather than
    /// its bottom, which is what an unflipped document view would do.
    private let fieldHost = FrontMatterFieldHost()
    private lazy var fieldScroll = PanelList.makeScrollView(documentView: fieldHost)
    private let emptyState = PanelEmptyStateView()
    private let addKeyField = NSTextField()
    private let addValueField = NSTextField()
    private let addTypePopup = NSPopUpButton()
    private let addButton: NSButton
    private let sourceButton: NSButton
    private var addAction: ButtonAction?
    private var sourceAction: ButtonAction?
    private var rows: [FrontMatterFieldRow] = []
    /// Notices are not errors.  A fallback ("Nested YAML needs Source Focus")
    /// is a warning about what this editor will not touch; a rejected value is
    /// a danger.  They must not share the accent with a selected task (§11.3).
    private var statusIsWarning = true

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        addButton = PanelButton.text("Add field", action: ButtonAction { })
        sourceButton = PanelButton.text("Open Source Focus", action: ButtonAction { })
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        buildHeader()
        buildFields()
        buildAddForm()
        applyStyle()
        reload()

        setAccessibilityRole(.group)
        setAccessibilityLabel("Front matter editor")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildHeader() {
        titleLabel.font = PanelFont.title
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        detailLabel.font = PanelFont.secondary
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(detailLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
        ])
    }

    /// The field list scrolls; the add form and the Source Focus button are a
    /// pinned footer.  Pinning the stack itself let a ten-field block push both
    /// of them off the bottom of the panel with no way to reach either.
    private func buildFields() {
        fieldStack.orientation = .vertical
        fieldStack.alignment = .leading
        fieldStack.spacing = 7
        fieldStack.translatesAutoresizingMaskIntoConstraints = false
        // The document view is constrained, not autoresized: its height comes
        // from the field list so the scroller knows when there is more.
        fieldHost.translatesAutoresizingMaskIntoConstraints = false
        fieldHost.addSubview(fieldStack)

        addSubview(fieldScroll)
        emptyState.install(in: self, over: fieldScroll)

        statusLabel.font = PanelFont.secondary
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            fieldStack.leadingAnchor.constraint(equalTo: fieldHost.leadingAnchor),
            fieldStack.trailingAnchor.constraint(equalTo: fieldHost.trailingAnchor),
            fieldStack.topAnchor.constraint(equalTo: fieldHost.topAnchor),
            fieldStack.bottomAnchor.constraint(equalTo: fieldHost.bottomAnchor),
            fieldHost.widthAnchor.constraint(equalTo: fieldScroll.contentView.widthAnchor),
            fieldScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            fieldScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            fieldScroll.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: fieldScroll.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: fieldScroll.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: fieldScroll.bottomAnchor, constant: 10),
        ])
    }

    private func buildAddForm() {
        addKeyField.placeholderString = "Field name"
        addKeyField.font = PanelFont.row
        addKeyField.setAccessibilityLabel("New field name")
        addKeyField.translatesAutoresizingMaskIntoConstraints = false

        addValueField.placeholderString = "Value"
        addValueField.font = PanelFont.row
        addValueField.setAccessibilityLabel("New field value")
        addValueField.translatesAutoresizingMaskIntoConstraints = false

        addTypePopup.addItems(withTitles: FrontMatterFieldRow.kindTitles)
        addTypePopup.selectItem(at: 0)
        addTypePopup.font = PanelFont.secondary
        addTypePopup.setAccessibilityLabel("New field type")
        addTypePopup.translatesAutoresizingMaskIntoConstraints = false

        let action = ButtonAction { [weak self] in self?.addField() }
        addAction = action
        addButton.target = action
        addButton.action = #selector(ButtonAction.fire(_:))
        addButton.setAccessibilityLabel("Add front matter field")

        let source = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.frontMatterEditorWantsSourceMode(self)
        }
        sourceAction = source
        sourceButton.target = source
        sourceButton.action = #selector(ButtonAction.fire(_:))
        sourceButton.setAccessibilityLabel("Open Source Focus to edit front matter")

        // Two short lines rather than one long one: a single row of name,
        // value, type, and button needs about 313pt and the inspector can be
        // narrower than that, so the row used to run off the panel.
        let nameRow = NSStackView(views: [addKeyField, addTypePopup])
        let valueRow = NSStackView(views: [addValueField, addButton])
        for row in [nameRow, valueRow] {
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 5
            row.distribution = .fill
        }
        for filler in [addKeyField, addValueField] {
            filler.setContentHuggingPriority(.defaultLow, for: .horizontal)
            filler.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        for fixed: NSView in [addTypePopup, addButton] {
            fixed.setContentHuggingPriority(.required, for: .horizontal)
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        let form = NSStackView(views: [nameRow, valueRow])
        form.orientation = .vertical
        form.alignment = .leading
        form.distribution = .fill
        form.spacing = 5
        form.translatesAutoresizingMaskIntoConstraints = false
        addSubview(form)

        sourceButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sourceButton)

        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: fieldScroll.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: fieldScroll.trailingAnchor),
            form.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            nameRow.widthAnchor.constraint(equalTo: form.widthAnchor),
            valueRow.widthAnchor.constraint(equalTo: form.widthAnchor),
            addKeyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            addValueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            addTypePopup.widthAnchor.constraint(equalToConstant: 78),
            sourceButton.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            sourceButton.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 8),
            sourceButton.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
        ])
    }

    func reload() {
        rows.forEach {
            fieldStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        rows.removeAll(keepingCapacity: true)

        guard let front = document.frontMatter else {
            detailLabel.stringValue = "No front matter block"
            statusLabel.stringValue = ""
            sourceButton.isHidden = false
            addButton.isEnabled = false
            showEmptyState(
                symbol: "text.alignleft",
                title: "No front matter",
                subtitle: "Add a `---` YAML block at the top of\nthe document in Source Focus."
            )
            return
        }

        detailLabel.stringValue = front.fields.isEmpty
            ? "Empty YAML block"
            : "Flat fields · changes keep source formatting"
        let fallback = editabilityFallback(front: front)
        let canEdit = fallback == nil
        statusIsWarning = true
        statusLabel.stringValue = fallback.map(message(for:)) ?? ""
        sourceButton.isHidden = canEdit
        addButton.isEnabled = canEdit

        for field in front.fields {
            let row = FrontMatterFieldRow(field: field, styleSheet: styleSheet)
            row.onCommit = { [weak self, weak row] key, value in
                guard let self, let row else { return }
                self.delegate?.frontMatterEditor(self, didRequest: .set(key: key, value: value))
                row.clearError()
            }
            row.onRemove = { [weak self] key in
                guard let self else { return }
                self.delegate?.frontMatterEditor(self, didRequest: .remove(key: key))
            }
            row.isEnabled = canEdit
            rows.append(row)
            fieldStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: fieldStack.widthAnchor).isActive = true
        }

        if front.fields.isEmpty {
            showEmptyState(
                symbol: "text.alignleft",
                title: "Empty front matter",
                subtitle: "The YAML block has no fields yet.\nAdd one below."
            )
        } else {
            emptyState.isHidden = true
            fieldScroll.isHidden = false
        }
        applyStyle()
    }

    private func showEmptyState(symbol: String, title: String, subtitle: String) {
        emptyState.configure(symbol: symbol, title: title, subtitle: subtitle, styleSheet: styleSheet)
        emptyState.isHidden = false
        fieldScroll.isHidden = true
    }

    /// The editor asks the core writer to validate the full block.  This keeps
    /// the UI conservative: a complex block always gets a Source mode path.
    private func editabilityFallback(front: FrontMatter) -> FrontMatterSourceFallback? {
        guard let field = front.fields.first else { return nil }
        return FrontMatterEditing.set(document, key: field.key, value: .text(field.value)).fallback
    }

    private func message(for fallback: FrontMatterSourceFallback) -> String {
        switch fallback {
        case .nestedYAML: return "Nested YAML needs Source Focus."
        case .commentsNotSupported: return "Comments need Source Focus."
        case .anchorsOrAliasesNotSupported: return "YAML anchors need Source Focus."
        case .blockScalarNotSupported: return "Block text needs Source Focus."
        case .ambiguousField: return "Duplicate fields need Source Focus."
        default: return "This block needs Source Focus."
        }
    }

    private func addField() {
        let key = addKeyField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            addKeyField.becomeFirstResponder()
            return
        }
        let value = FrontMatterFieldRow.value(
            from: addValueField.stringValue, kindIndex: addTypePopup.indexOfSelectedItem
        )
        delegate?.frontMatterEditor(self, didRequest: .add(key: key, value: value))
        addKeyField.stringValue = ""
        addValueField.stringValue = ""
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.text
        detailLabel.textColor = styleSheet.textSecondary
        statusLabel.textColor = styleSheet.calloutColor(statusIsWarning ? .warning : .danger)
        addKeyField.textColor = styleSheet.text
        addValueField.textColor = styleSheet.text
        for row in rows { row.styleSheet = styleSheet }
    }
}

/// Flipped host for the scrolling field list.
private final class FrontMatterFieldHost: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
private final class FrontMatterFieldRow: NSView, NSTextFieldDelegate {
    static let kindTitles = ["Text", "Boolean", "Number", "List"]

    var styleSheet: StyleSheet { didSet { applyStyle() } }
    var isEnabled: Bool = true { didSet { setControlsEnabled() } }
    var onCommit: ((String, FrontMatterValue) -> Void)?
    var onRemove: ((String) -> Void)?

    private let field: FrontMatterField
    private let keyField: NSTextField
    private let valueField: NSTextField
    private let kindPopup = NSPopUpButton()
    private let dirtyDot = FrontMatterDirtyDot()
    private let removeButton: NSButton
    private let errorLabel = NSTextField(labelWithString: "")
    private var kindAction: ButtonAction?
    private var removeAction: ButtonAction?
    private var committedValue: String

    init(field: FrontMatterField, styleSheet: StyleSheet) {
        self.field = field
        self.styleSheet = styleSheet
        self.committedValue = field.value
        keyField = NSTextField(string: field.key)
        valueField = NSTextField(string: field.value)
        removeButton = PanelButton.symbol("trash", label: "Remove field", action: ButtonAction { })
        super.init(frame: .zero)

        keyField.isEditable = false
        keyField.isBordered = false
        keyField.drawsBackground = false
        keyField.font = PanelFont.rowEmphasised
        keyField.lineBreakMode = .byTruncatingTail
        keyField.setAccessibilityLabel("Field name: \(field.key)")
        valueField.font = PanelFont.row
        valueField.delegate = self
        valueField.setAccessibilityLabel("Value for \(field.key)")
        kindPopup.addItems(withTitles: Self.kindTitles)
        kindPopup.selectItem(at: Self.kindIndex(for: field.value))
        kindPopup.font = PanelFont.secondary
        kindPopup.setAccessibilityLabel("Type for \(field.key)")

        let kind = ButtonAction { [weak self] in self?.commit() }
        kindAction = kind
        kindPopup.target = kind
        kindPopup.action = #selector(ButtonAction.fire(_:))
        let remove = ButtonAction { [weak self] in
            guard let self else { return }
            self.onRemove?(self.field.key)
        }
        removeAction = remove
        removeButton.target = remove
        removeButton.action = #selector(ButtonAction.fire(_:))

        valueField.target = kind
        valueField.action = #selector(ButtonAction.fire(_:))

        let controls = NSStackView(views: [keyField, valueField, kindPopup, dirtyDot, removeButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 5
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        // The key can give up width before the value does; neither may push the
        // row past the panel.
        keyField.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        valueField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for fixed: NSView in [kindPopup, dirtyDot, removeButton] {
            fixed.setContentCompressionResistancePriority(.required, for: .horizontal)
            fixed.setContentHuggingPriority(.required, for: .horizontal)
        }

        errorLabel.font = PanelFont.secondary
        errorLabel.lineBreakMode = .byTruncatingTail
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            keyField.widthAnchor.constraint(greaterThanOrEqualToConstant: 54),
            valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 60),
            kindPopup.widthAnchor.constraint(equalToConstant: 74),
            dirtyDot.widthAnchor.constraint(equalToConstant: 8),
            removeButton.widthAnchor.constraint(equalToConstant: 22),
            errorLabel.leadingAnchor.constraint(equalTo: controls.leadingAnchor),
            errorLabel.trailingAnchor.constraint(equalTo: controls.trailingAnchor),
            errorLabel.topAnchor.constraint(equalTo: controls.bottomAnchor, constant: 2),
            errorLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Front matter field \(field.key)")
        applyStyle()
    }

    required init?(coder: NSCoder) { nil }

    // MARK: - Editing

    /// A typed value is visibly unsaved…
    func controlTextDidChange(_ notification: Notification) {
        dirtyDot.isDirty = valueField.stringValue != committedValue
    }

    /// …and clicking away or tabbing out saves it instead of dropping it.
    func controlTextDidEndEditing(_ notification: Notification) {
        guard valueField.stringValue != committedValue else { return }
        commit()
    }

    private func commit() {
        let value = Self.value(from: valueField.stringValue, kindIndex: kindPopup.indexOfSelectedItem)
        if case .number = value, Double(valueField.stringValue) == nil {
            errorLabel.stringValue = "Enter a number."
            dirtyDot.isDirty = true
            return
        }
        if case .boolean = value, !["true", "false"].contains(valueField.stringValue.lowercased()) {
            errorLabel.stringValue = "Enter true or false."
            dirtyDot.isDirty = true
            return
        }
        committedValue = valueField.stringValue
        dirtyDot.isDirty = false
        onCommit?(field.key, value)
    }

    func clearError() { errorLabel.stringValue = "" }

    private func applyStyle() {
        keyField.textColor = styleSheet.textSecondary
        valueField.textColor = styleSheet.text
        errorLabel.textColor = styleSheet.calloutColor(.danger)
        dirtyDot.color = styleSheet.calloutColor(.warning)
    }

    private func setControlsEnabled() {
        valueField.isEnabled = isEnabled
        kindPopup.isEnabled = isEnabled
        removeButton.isEnabled = isEnabled
    }

    static func kindIndex(for value: String) -> Int {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "true" || lower == "false" { return 1 }
        if Double(lower) != nil { return 2 }
        if lower.hasPrefix("[") && lower.hasSuffix("]") { return 3 }
        return 0
    }

    static func value(from raw: String, kindIndex: Int) -> FrontMatterValue {
        switch kindIndex {
        case 1: return .boolean(raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "true")
        case 2: return .number(Double(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case 3: return .list(parseList(raw))
        default: return .text(raw)
        }
    }

    /// A field whose value has been typed but not yet written to source shows a
    /// dot, not a button: the row saves itself when you leave it, and the dot
    /// is there so "unsaved" is visible while you are still in it (§11.3).
    private final class FrontMatterDirtyDot: NSView {
        var isDirty = false { didSet { needsDisplay = true } }
        var color: NSColor = .clear { didSet { needsDisplay = true } }

        override var intrinsicContentSize: NSSize { NSSize(width: 8, height: 8) }

        override func draw(_ dirtyRect: NSRect) {
            guard isDirty else { return }
            color.setFill()
            NSBezierPath(ovalIn: NSRect(x: bounds.midX - 3, y: bounds.midY - 3, width: 6, height: 6)).fill()
        }

        override func accessibilityLabel() -> String? { isDirty ? "Unsaved value" : nil }
    }

    private static func parseList(_ raw: String) -> [String] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("[") && text.hasSuffix("]") { text = String(text.dropFirst().dropLast()) }
        return text.split(separator: ",", omittingEmptySubsequences: false).map {
            let item = String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            if item.count >= 2, item.first == "\"", item.last == "\"" { return String(item.dropFirst().dropLast()) }
            return item
        }
    }
}
