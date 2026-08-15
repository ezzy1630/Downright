import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol DocumentHealthViewDelegate: AnyObject {
    func documentHealthView(_ view: DocumentHealthView, didSelect diagnostic: DocumentHealthDiagnostic)
    func documentHealthView(_ view: DocumentHealthView, didApply fixes: [TextEdit])
    func documentHealthViewWantsSourceMode(_ view: DocumentHealthView)
}

/// A source-first health report.  The panel owns only presentation state.
/// The document controller owns parsing, selection, and edits.
@MainActor
final class DocumentHealthView: NSView, PanelSurface {
    weak var delegate: DocumentHealthViewDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    var sourceText: String = "" {
        didSet {
            guard sourceText != oldValue else { return }
            lineIndex = SourceLineIndex(text: sourceText)
            table.reloadData()
            reloadPreview()
        }
    }

    var diagnostics: [DocumentHealthDiagnostic] = [] {
        didSet { reload() }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: Command.documentHealth.panelTitle)
    private let countLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")
    private let preview = NSTextView()
    private let emptyState = PanelEmptyStateView()
    private let table = PanelList.makeTableView(identifier: "documentHealth")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private let applyButton: NSButton
    private let ignoreButton: NSButton
    private let sourceButton: NSButton
    private var applyAction: ButtonAction?
    private var ignoreAction: ButtonAction?
    private var sourceAction: ButtonAction?
    private var ignoredIDs: Set<String> = []
    private var rows: [Row] = []
    private var selectedIndex: Int?
    /// Selection is remembered by finding id, not row: the host reparses on
    /// every keystroke and a row number does not survive that.
    private var selectedDiagnosticID: String?
    private var lineIndex = SourceLineIndex(text: "")
    /// What the last action did, shown where the preview normally is.  Cleared
    /// by the first reload that is not the one the action itself caused.
    private var actionStatus: String?
    private var isApplyingFixes = false
    private var previewConstraints: [NSLayoutConstraint] = []

    private enum Row {
        case group(DocumentHealthCategory, DocumentHealthSeverity, Int)
        case diagnostic(Int)
    }

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        applyButton = PanelButton.text("Apply safe fixes", action: ButtonAction { })
        ignoreButton = PanelButton.text("Ignore", action: ButtonAction { })
        sourceButton = PanelButton.text("Open Source Focus", action: ButtonAction { })
        super.init(frame: .zero)

        installBackdrop(backdrop)

        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        countLabel.font = PanelFont.secondary
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(countLabel)

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Document health findings")
        addSubview(scroll)

        previewLabel.font = PanelFont.secondary
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewLabel)
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = PanelFont.monospaced(10)
        preview.drawsBackground = true
        preview.textContainerInset = NSSize(width: 6, height: 5)
        preview.setAccessibilityLabel("Source change preview")
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)

        let apply = ButtonAction { [weak self] in self?.applySafeFixes() }
        applyAction = apply
        applyButton.target = apply
        applyButton.action = #selector(ButtonAction.fire(_:))
        applyButton.setAccessibilityLabel("Apply all safe health fixes")

        let ignore = ButtonAction { [weak self] in self?.ignoreSelection() }
        ignoreAction = ignore
        ignoreButton.target = ignore
        ignoreButton.action = #selector(ButtonAction.fire(_:))
        ignoreButton.setAccessibilityLabel("Ignore selected health finding")

        let source = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.documentHealthViewWantsSourceMode(self)
        }
        sourceAction = source
        sourceButton.target = source
        sourceButton.action = #selector(ButtonAction.fire(_:))
        sourceButton.setAccessibilityLabel("Open Source Focus")

        // Two short rows rather than one 305pt row: the inspector can be
        // narrower than three buttons side by side, and a control that runs off
        // the panel is worse than one that wraps.
        let primaryRow = NSStackView(views: [applyButton, ignoreButton])
        primaryRow.orientation = .horizontal
        primaryRow.alignment = .centerY
        primaryRow.spacing = 5
        for button in [applyButton, ignoreButton, sourceButton] {
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }

        let actions = NSStackView(views: [primaryRow, sourceButton])
        actions.orientation = .vertical
        actions.alignment = .leading
        actions.spacing = 5
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)
        emptyState.install(in: self, over: scroll)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: PanelMetrics.headerTopPadding),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            countLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            previewLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            previewLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: previewLabel.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewLabel.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 4),
            actions.leadingAnchor.constraint(equalTo: previewLabel.leadingAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: previewLabel.trailingAnchor),
            actions.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 7),
            actions.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])

        // The diff box only exists while there is a change to show in it.
        previewConstraints = [preview.heightAnchor.constraint(equalToConstant: 74)]
        NSLayoutConstraint.activate(previewConstraints)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Document health")
        applyStyle()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func resetIgnoredFindings() {
        ignoredIDs.removeAll()
        reload()
    }

    func selectFindingForTesting(at row: Int) {
        guard row >= 0, row < rows.count, case .diagnostic = rows[row] else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectedIndex = diagnosticIndex(for: row)
        reloadPreview()
    }

    func applySafeFixesForTesting() { applySafeFixes() }

    func ignoreSelectionForTesting() { ignoreSelection() }

    private var visibleDiagnostics: [Int] {
        diagnostics.indices.filter { !ignoredIDs.contains(diagnostics[$0].id) }
    }

    private func reload() {
        if !isApplyingFixes { actionStatus = nil }
        rows.removeAll(keepingCapacity: true)
        let grouped = Dictionary(grouping: visibleDiagnostics) { diagnostics[$0].category }
        for category in DocumentHealthCategory.allCases {
            guard let indices = grouped[category], !indices.isEmpty else { continue }
            let severity = indices.map { diagnostics[$0].severity }.max(by: severityOrder) ?? .info
            rows.append(.group(category, severity, indices.count))
            rows.append(contentsOf: indices.map(Row.diagnostic))
        }
        countLabel.stringValue = visibleDiagnostics.isEmpty
            ? "No issues"
            : "\(visibleDiagnostics.count) finding\(visibleDiagnostics.count == 1 ? "" : "s")"
        countLabel.setAccessibilityLabel(countLabel.stringValue)
        table.reloadData()
        restoreSelection()
        updateEmptyState()
        reloadPreview()
        updateActionState()
    }

    /// Reselect the same finding after a reparse rather than dropping the
    /// user's selection — and its preview — on every keystroke.
    private func restoreSelection() {
        guard let selectedDiagnosticID,
              let index = diagnostics.firstIndex(where: { $0.id == selectedDiagnosticID }),
              !ignoredIDs.contains(selectedDiagnosticID),
              let row = rows.firstIndex(where: {
                  if case .diagnostic(let candidate) = $0 { return candidate == index }
                  return false
              })
        else {
            table.deselectAll(nil)
            selectedIndex = nil
            self.selectedDiagnosticID = nil
            return
        }
        selectedIndex = index
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func updateEmptyState() {
        guard rows.isEmpty else {
            emptyState.isHidden = true
            scroll.isHidden = false
            return
        }
        emptyState.configure(
            symbol: "checkmark.seal",
            title: "No findings",
            subtitle: diagnostics.isEmpty
                ? "Headings, links, and structure all\nlook right from here."
                : "Every finding in this document\nhas been ignored.",
            styleSheet: styleSheet
        )
        emptyState.isHidden = false
        scroll.isHidden = true
    }

    private func severityOrder(_ lhs: DocumentHealthSeverity, _ rhs: DocumentHealthSeverity) -> Bool {
        rank(lhs) < rank(rhs)
    }

    private func rank(_ severity: DocumentHealthSeverity) -> Int {
        switch severity { case .info: 0; case .warning: 1; case .error: 2 }
    }

    private func diagnosticIndex(for row: Int) -> Int? {
        guard row >= 0, row < rows.count else { return nil }
        guard case .diagnostic(let index) = rows[row], index < diagnostics.count else { return nil }
        return index
    }

    private func activateSelection() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let index = diagnosticIndex(for: row) else { return }
        selectedIndex = index
        selectedDiagnosticID = diagnostics[index].id
        actionStatus = nil
        reloadPreview()
        updateActionState()
        delegate?.documentHealthView(self, didSelect: diagnostics[index])
    }

    /// Every fix this button would apply, in the order they will be written.
    private var safeFixes: [TextEdit] {
        let length = (sourceText as NSString).length
        let fixes = visibleDiagnostics.compactMap { index -> TextEdit? in
            guard let fix = diagnostics[index].fix,
                  fix.range.location >= 0, fix.range.upperBound <= length else { return nil }
            return fix
        }
        return nonOverlapping(fixes)
    }

    private func applySafeFixes() {
        let fixes = safeFixes
        guard !fixes.isEmpty else { return }
        // Say what happened.  Rows vanishing is not feedback (§11.4).
        actionStatus = "Applied \(fixes.count) safe fix\(fixes.count == 1 ? "" : "es")."
        isApplyingFixes = true
        defer { isApplyingFixes = false }
        delegate?.documentHealthView(self, didApply: fixes)
        reloadPreview()
    }

    private func nonOverlapping(_ edits: [TextEdit]) -> [TextEdit] {
        var lastStart = Int.max
        return edits.sorted { $0.range.location > $1.range.location }.filter {
            guard $0.range.upperBound <= lastStart else { return false }
            lastStart = $0.range.location
            return true
        }
    }

    private func ignoreSelection() {
        guard let selectedIndex, selectedIndex < diagnostics.count else { return }
        let ignored = diagnostics[selectedIndex]
        ignoredIDs.insert(ignored.id)
        selectedDiagnosticID = nil
        actionStatus = "Ignored “\(ignored.message)”."
        isApplyingFixes = true
        defer { isApplyingFixes = false }
        reload()
    }

    /// Shows the diff box only when there is a diff.  Offering to "select a
    /// finding" over an empty list is an instruction the panel cannot honour.
    private func reloadPreview() {
        if let actionStatus {
            previewLabel.stringValue = actionStatus
            setPreviewVisible(false)
            return
        }
        guard !rows.isEmpty else {
            previewLabel.stringValue = ""
            setPreviewVisible(false)
            return
        }
        guard let selectedIndex, selectedIndex < diagnostics.count,
              let fix = diagnostics[selectedIndex].fix,
              fix.range.location >= 0,
              fix.range.upperBound <= (sourceText as NSString).length else {
            previewLabel.stringValue = "Select a finding to preview a safe source change."
            setPreviewVisible(false)
            return
        }
        let before = (sourceText as NSString).substring(with: fix.range)
        previewLabel.stringValue = "Preview · \(fix.summary)"
        preview.string = "− \(before)\n+ \(fix.replacement)"
        preview.setAccessibilityLabel("Source change preview: replace \(before) with \(fix.replacement)")
        setPreviewVisible(true)
    }

    private func setPreviewVisible(_ visible: Bool) {
        guard preview.isHidden == visible else { return }
        preview.isHidden = !visible
        if !visible { preview.string = "" }
        for constraint in previewConstraints { constraint.constant = visible ? 74 : 0 }
    }

    private func updateActionState() {
        let count = safeFixes.count
        // The button says how much it will do before it does it (§11.4).
        applyButton.title = count == 1 ? "Apply 1 Safe Fix" : "Apply \(count) Safe Fixes"
        applyButton.isEnabled = count > 0
        applyButton.setAccessibilityLabel(applyButton.title)
        ignoreButton.isEnabled = selectedIndex != nil
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        countLabel.textColor = styleSheet.textFaint
        previewLabel.textColor = styleSheet.textFaint
        preview.backgroundColor = styleSheet.background
        preview.textColor = styleSheet.text
        table.reloadData()
        updateEmptyState()
    }

    @objc private func rowClicked(_ sender: Any?) { activateSelection() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

extension DocumentHealthView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return PanelMetrics.wideRowHeight }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return PanelMetrics.wideRowHeight
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PanelList.selectionRow(in: tableView, owner: self, styleSheet: styleSheet)
    }

    func tableView(_ tableView: NSTableView, isGroupRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .group = rows[row] { return true }
        return false
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard row < rows.count else { return false }
        if case .group = rows[row] { return false }
        return true
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }
        switch rows[row] {
        case .group(let category, let severity, let count):
            let id = NSUserInterfaceItemIdentifier("documentHealthGroup")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? PanelGroupRowView
                ?? PanelGroupRowView(identifier: id)
            cell.configure(text: "\(category.rawValue.uppercased())  ·  \(count)", color: color(for: severity))
            return cell
        case .diagnostic(let index):
            guard index < diagnostics.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("documentHealthRow")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? HealthDiagnosticRowView
                ?? HealthDiagnosticRowView(identifier: id)
            cell.configure(
                diagnostic: diagnostics[index],
                lineCaption: lineIndex.caption(for: diagnostics[index].range),
                styleSheet: styleSheet
            )
            return cell
        }
    }

    private func color(for severity: DocumentHealthSeverity) -> NSColor {
        switch severity { case .error: styleSheet.calloutColor(.danger); case .warning: styleSheet.calloutColor(.warning); case .info: styleSheet.textFaint }
    }
}

private final class HealthDiagnosticRowView: NSView {
    private let messageLabel = NSTextField(labelWithString: "")
    private let reasonLabel = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        for label in [messageLabel, reasonLabel, rangeLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        messageLabel.font = PanelFont.rowEmphasised
        reasonLabel.font = PanelFont.secondary
        rangeLabel.font = PanelFont.secondary
        NSLayoutConstraint.activate([
            messageLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            messageLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            reasonLabel.leadingAnchor.constraint(equalTo: messageLabel.leadingAnchor),
            reasonLabel.trailingAnchor.constraint(equalTo: messageLabel.trailingAnchor),
            reasonLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 2),
            rangeLabel.leadingAnchor.constraint(equalTo: messageLabel.leadingAnchor),
            rangeLabel.trailingAnchor.constraint(equalTo: messageLabel.trailingAnchor),
            rangeLabel.topAnchor.constraint(equalTo: reasonLabel.bottomAnchor, constant: 2),
        ])
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(diagnostic: DocumentHealthDiagnostic, lineCaption: String, styleSheet: StyleSheet) {
        messageLabel.stringValue = "\(diagnostic.severity.rawValue.capitalized): \(diagnostic.message)"
        reasonLabel.stringValue = diagnostic.explanation
        // A reader locates a finding by line.  VoiceOver keeps the exact source
        // range, which is the one place the byte offsets are still useful.
        rangeLabel.stringValue = lineCaption
        messageLabel.textColor = color(for: diagnostic.severity, styleSheet: styleSheet)
        reasonLabel.textColor = styleSheet.textSecondary
        rangeLabel.textColor = styleSheet.textFaint
        toolTip = "\(diagnostic.message)\n\(diagnostic.explanation)"
        let range = "Source range \(diagnostic.range.location)–\(diagnostic.range.upperBound)"
        setAccessibilityLabel("\(messageLabel.stringValue). \(reasonLabel.stringValue). \(lineCaption). \(range)")
    }

    private func color(for severity: DocumentHealthSeverity, styleSheet: StyleSheet) -> NSColor {
        switch severity { case .error: styleSheet.calloutColor(.danger); case .warning: styleSheet.calloutColor(.warning); case .info: styleSheet.textSecondary }
    }
}
