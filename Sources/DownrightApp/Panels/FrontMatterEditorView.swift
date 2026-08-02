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

    var preferredWidth: CGFloat { 320 }

    var renderedFieldCount: Int { rows.count }
    var showsSourceModePrompt: Bool { !sourceButton.isHidden }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Front matter")
    private let detailLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let fieldStack = NSStackView()
    private let addKeyField = NSTextField()
    private let addValueField = NSTextField()
    private let addTypePopup = NSPopUpButton()
    private let addButton: NSButton
    private let sourceButton: NSButton
    private var addAction: ButtonAction?
    private var sourceAction: ButtonAction?
    private var rows: [FrontMatterFieldRow] = []

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        addButton = PanelButton.text("Add field", action: ButtonAction { })
        sourceButton = PanelButton.text("Open Source mode", action: ButtonAction { })
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

    private func buildFields() {
        fieldStack.orientation = .vertical
        fieldStack.alignment = .leading
        fieldStack.spacing = 7
        fieldStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(fieldStack)

        statusLabel.font = PanelFont.secondary
        statusLabel.maximumNumberOfLines = 3
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        NSLayoutConstraint.activate([
            fieldStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            fieldStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            fieldStack.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            statusLabel.leadingAnchor.constraint(equalTo: fieldStack.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: fieldStack.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: fieldStack.bottomAnchor, constant: 10),
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
        sourceButton.setAccessibilityLabel("Open Source mode to edit front matter")

        let form = NSStackView(views: [addKeyField, addValueField, addTypePopup, addButton])
        form.orientation = .horizontal
        form.alignment = .centerY
        form.spacing = 5
        form.translatesAutoresizingMaskIntoConstraints = false
        addSubview(form)

        sourceButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sourceButton)

        NSLayoutConstraint.activate([
            form.leadingAnchor.constraint(equalTo: fieldStack.leadingAnchor),
            form.trailingAnchor.constraint(equalTo: fieldStack.trailingAnchor),
            form.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            addKeyField.widthAnchor.constraint(equalToConstant: 82),
            addValueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 72),
            addTypePopup.widthAnchor.constraint(equalToConstant: 72),
            sourceButton.leadingAnchor.constraint(equalTo: form.leadingAnchor),
            sourceButton.topAnchor.constraint(equalTo: form.bottomAnchor, constant: 8),
            sourceButton.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
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
            statusLabel.stringValue = "Add a YAML block in Source mode."
            sourceButton.isHidden = false
            addButton.isEnabled = false
            return
        }

        detailLabel.stringValue = front.fields.isEmpty
            ? "Empty YAML block"
            : "Flat fields · changes keep source formatting"
        let fallback = editabilityFallback(front: front)
        let canEdit = fallback == nil
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
        }
    }

    /// The editor asks the core writer to validate the full block.  This keeps
    /// the UI conservative: a complex block always gets a Source mode path.
    private func editabilityFallback(front: FrontMatter) -> FrontMatterSourceFallback? {
        guard let field = front.fields.first else { return nil }
        return FrontMatterEditing.set(document, key: field.key, value: .text(field.value)).fallback
    }

    private func message(for fallback: FrontMatterSourceFallback) -> String {
        switch fallback {
        case .nestedYAML: return "Nested YAML needs Source mode."
        case .commentsNotSupported: return "Comments need Source mode."
        case .anchorsOrAliasesNotSupported: return "YAML anchors need Source mode."
        case .blockScalarNotSupported: return "Block text needs Source mode."
        case .ambiguousField: return "Duplicate fields need Source mode."
        default: return "This block needs Source mode."
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
        statusLabel.textColor = styleSheet.accent
        addKeyField.textColor = styleSheet.text
        addValueField.textColor = styleSheet.text
        for row in rows { row.styleSheet = styleSheet }
    }
}

@MainActor
private final class FrontMatterFieldRow: NSView {
    static let kindTitles = ["Text", "Boolean", "Number", "List"]

    var styleSheet: StyleSheet { didSet { applyStyle() } }
    var isEnabled: Bool = true { didSet { setControlsEnabled() } }
    var onCommit: ((String, FrontMatterValue) -> Void)?
    var onRemove: ((String) -> Void)?

    private let field: FrontMatterField
    private let keyField: NSTextField
    private let valueField: NSTextField
    private let kindPopup = NSPopUpButton()
    private let saveButton: NSButton
    private let removeButton: NSButton
    private let errorLabel = NSTextField(labelWithString: "")
    private var saveAction: ButtonAction?
    private var removeAction: ButtonAction?

    init(field: FrontMatterField, styleSheet: StyleSheet) {
        self.field = field
        self.styleSheet = styleSheet
        keyField = NSTextField(string: field.key)
        valueField = NSTextField(string: field.value)
        saveButton = PanelButton.symbol("checkmark", label: "Save field", action: ButtonAction { })
        removeButton = PanelButton.symbol("trash", label: "Remove field", action: ButtonAction { })
        super.init(frame: .zero)

        keyField.isEditable = false
        keyField.font = PanelFont.rowEmphasised
        keyField.setAccessibilityLabel("Field name: \(field.key)")
        valueField.font = PanelFont.row
        valueField.setAccessibilityLabel("Value for \(field.key)")
        kindPopup.addItems(withTitles: Self.kindTitles)
        kindPopup.selectItem(at: Self.kindIndex(for: field.value))
        kindPopup.font = PanelFont.secondary
        kindPopup.setAccessibilityLabel("Type for \(field.key)")

        let save = ButtonAction { [weak self] in self?.commit() }
        saveAction = save
        saveButton.target = save
        saveButton.action = #selector(ButtonAction.fire(_:))
        let remove = ButtonAction { [weak self] in
            guard let self else { return }
            self.onRemove?(self.field.key)
        }
        removeAction = remove
        removeButton.target = remove
        removeButton.action = #selector(ButtonAction.fire(_:))

        valueField.target = save
        valueField.action = #selector(ButtonAction.fire(_:))

        let controls = NSStackView(views: [keyField, valueField, kindPopup, saveButton, removeButton])
        controls.orientation = .horizontal
        controls.alignment = .centerY
        controls.spacing = 5
        controls.translatesAutoresizingMaskIntoConstraints = false
        addSubview(controls)

        errorLabel.font = PanelFont.secondary
        errorLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(errorLabel)

        NSLayoutConstraint.activate([
            controls.leadingAnchor.constraint(equalTo: leadingAnchor),
            controls.trailingAnchor.constraint(equalTo: trailingAnchor),
            controls.topAnchor.constraint(equalTo: topAnchor),
            keyField.widthAnchor.constraint(equalToConstant: 78),
            kindPopup.widthAnchor.constraint(equalToConstant: 70),
            saveButton.widthAnchor.constraint(equalToConstant: 22),
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

    private func commit() {
        let value = Self.value(from: valueField.stringValue, kindIndex: kindPopup.indexOfSelectedItem)
        if case .number = value, Double(valueField.stringValue) == nil {
            errorLabel.stringValue = "Enter a number."
            return
        }
        if case .boolean = value, !["true", "false"].contains(valueField.stringValue.lowercased()) {
            errorLabel.stringValue = "Enter true or false."
            return
        }
        onCommit?(field.key, value)
    }

    func clearError() { errorLabel.stringValue = "" }

    private func applyStyle() {
        keyField.textColor = styleSheet.textSecondary
        valueField.textColor = styleSheet.text
        errorLabel.textColor = styleSheet.accent
    }

    private func setControlsEnabled() {
        valueField.isEnabled = isEnabled
        kindPopup.isEnabled = isEnabled
        saveButton.isEnabled = isEnabled
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
