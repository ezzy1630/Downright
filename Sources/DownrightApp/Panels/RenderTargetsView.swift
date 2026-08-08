import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol RenderTargetsViewDelegate: AnyObject {
    func renderTargetsView(_ view: RenderTargetsView, didSelect profile: RenderTargetProfile)
    func renderTargetsView(_ view: RenderTargetsView, didSelect diagnostic: CompatibilityDiagnostic)
    func renderTargetsView(_ view: RenderTargetsView, didApply fixes: [TextEdit])
    func renderTargetsViewWantsSourceMode(_ view: RenderTargetsView)
}

/// A renderer compatibility report.  Profiles are data, so the host can add
/// custom targets without changing this panel or the core analyzer.
@MainActor
final class RenderTargetsView: NSView, PanelSurface {
    weak var delegate: RenderTargetsViewDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    var profiles: [RenderTargetProfile] = RenderTargetProfile.builtIns {
        didSet { rebuildTargetControl() }
    }

    var document: ParsedDocument = .empty {
        didSet { recomputeReport() }
    }

    var sourceText: String = "" {
        didSet {
            guard sourceText != oldValue else { return }
            lineIndex = SourceLineIndex(text: sourceText)
            table.reloadData()
            reloadPreview()
        }
    }

    var selectedProfile: RenderTargetProfile = .gitHub {
        didSet {
            guard selectedProfile != oldValue else { return }
            syncTargetControl()
            recomputeReport()
            delegate?.renderTargetsView(self, didSelect: selectedProfile)
        }
    }

    var report: CompatibilityReport = CompatibilityReport(profile: .gitHub, diagnostics: []) {
        didSet { reload() }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: Command.renderTargets.panelTitle)
    private let countLabel = NSTextField(labelWithString: "")
    private let targetControl = NSPopUpButton()
    private let previewLabel = NSTextField(labelWithString: "")
    private let preview = NSTextView()
    private let emptyState = PanelEmptyStateView()
    private let table = PanelList.makeTableView(identifier: "renderTargets")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private let applyButton: NSButton
    private let sourceButton: NSButton
    private var applyAction: ButtonAction?
    private var sourceAction: ButtonAction?
    private var rows: [Row] = []
    private var selectedIndex: Int?
    /// Selection survives a reparse by diagnostic id rather than row number.
    private var selectedDiagnosticID: String?
    private var lineIndex = SourceLineIndex(text: "")
    /// What the last action did, shown where the preview normally is.
    private var actionStatus: String?
    private var isApplyingFixes = false
    private var previewConstraints: [NSLayoutConstraint] = []

    private enum Row {
        case group(MarkdownCapability, Int)
        case diagnostic(Int)
    }

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        applyButton = PanelButton.text("Apply safe fixes", action: ButtonAction { })
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

        targetControl.font = PanelFont.secondary
        targetControl.target = self
        targetControl.action = #selector(targetChanged(_:))
        targetControl.setAccessibilityLabel("Render target")
        targetControl.translatesAutoresizingMaskIntoConstraints = false
        addSubview(targetControl)

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Render target findings")
        addSubview(scroll)

        previewLabel.font = PanelFont.secondary
        previewLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(previewLabel)
        preview.isEditable = false
        preview.isSelectable = true
        preview.isRichText = false
        preview.font = PanelFont.monospaced(10)
        preview.textContainerInset = NSSize(width: 6, height: 5)
        preview.setAccessibilityLabel("Render target source change preview")
        preview.translatesAutoresizingMaskIntoConstraints = false
        addSubview(preview)

        let apply = ButtonAction { [weak self] in self?.applySafeFixes() }
        applyAction = apply
        applyButton.target = apply
        applyButton.action = #selector(ButtonAction.fire(_:))
        applyButton.setAccessibilityLabel("Apply all safe render target fixes")
        let source = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.renderTargetsViewWantsSourceMode(self)
        }
        sourceAction = source
        sourceButton.target = source
        sourceButton.action = #selector(ButtonAction.fire(_:))
        sourceButton.setAccessibilityLabel("Open Source Focus")
        for button in [applyButton, sourceButton] {
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        let actions = NSStackView(views: [applyButton, sourceButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
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
            targetControl.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            targetControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            targetControl.widthAnchor.constraint(equalToConstant: 176),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: targetControl.bottomAnchor, constant: 6),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 160),
            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: countLabel.trailingAnchor),
            previewLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: 8),
            preview.leadingAnchor.constraint(equalTo: previewLabel.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: previewLabel.trailingAnchor),
            preview.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 4),
            actions.leadingAnchor.constraint(equalTo: previewLabel.leadingAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: previewLabel.trailingAnchor),
            actions.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 7),
            actions.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])

        // The diff box only exists while there is a diff to put in it.
        previewConstraints = [preview.heightAnchor.constraint(equalToConstant: 74)]
        NSLayoutConstraint.activate(previewConstraints)

        setAccessibilityRole(.group)
        setAccessibilityLabel("Render targets")
        rebuildTargetControl()
        applyStyle()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func selectFindingForTesting(at row: Int) {
        guard row >= 0, row < rows.count, case .diagnostic = rows[row] else { return }
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        selectedIndex = diagnosticIndex(for: row)
        reloadPreview()
    }

    func applySafeFixesForTesting() { applySafeFixes() }

    private func recomputeReport() {
        guard document.length > 0 || !document.text.isEmpty else { return }
        report = MarkdownCompatibility.diagnose(document, for: selectedProfile)
    }

    private func rebuildTargetControl() {
        targetControl.removeAllItems()
        targetControl.addItems(withTitles: profiles.map(\.name))
        syncTargetControl()
    }

    private func syncTargetControl() {
        guard let index = profiles.firstIndex(of: selectedProfile) else { return }
        targetControl.selectItem(at: index)
        themeTargetControl()
    }

    private func themeTargetControl() {
        targetControl.contentTintColor = styleSheet.text
        guard let title = targetControl.selectedItem?.title else { return }
        targetControl.attributedTitle = NSAttributedString(
            string: title,
            attributes: [.foregroundColor: styleSheet.text, .font: targetControl.font ?? PanelFont.row]
        )
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < profiles.count else { return }
        selectedProfile = profiles[sender.indexOfSelectedItem]
    }

    private func reload() {
        if !isApplyingFixes { actionStatus = nil }
        rows.removeAll(keepingCapacity: true)
        let grouped = Dictionary(grouping: report.diagnostics.indices, by: { report.diagnostics[$0].capability })
        for capability in MarkdownCapability.allCases {
            guard let indices = grouped[capability], !indices.isEmpty else { continue }
            rows.append(.group(capability, indices.count))
            rows.append(contentsOf: indices.map(Row.diagnostic))
        }
        countLabel.stringValue = report.diagnostics.isEmpty
            ? "Compatible"
            : "\(report.diagnostics.count) issue\(report.diagnostics.count == 1 ? "" : "s")"
        countLabel.setAccessibilityLabel(countLabel.stringValue)
        table.reloadData()
        restoreSelection()
        updateEmptyState()
        reloadPreview()
        updateActionState()
    }

    /// Reselect the same finding after a reparse instead of clearing the
    /// selection — and the preview — on every keystroke in the document.
    private func restoreSelection() {
        guard let selectedDiagnosticID,
              let index = report.diagnostics.firstIndex(where: { $0.id == selectedDiagnosticID }),
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
            title: "Compatible with \(selectedProfile.name)",
            subtitle: "Everything in this document renders\non the selected target.",
            styleSheet: styleSheet
        )
        emptyState.isHidden = false
        scroll.isHidden = true
    }

    private func updateActionState() {
        let count = safeEdits.count
        applyButton.title = count == 1 ? "Apply 1 Safe Fix" : "Apply \(count) Safe Fixes"
        applyButton.isEnabled = count > 0
        applyButton.setAccessibilityLabel(applyButton.title)
    }

    private func diagnosticIndex(for row: Int) -> Int? {
        guard row >= 0, row < rows.count else { return nil }
        guard case .diagnostic(let index) = rows[row], index < report.diagnostics.count else { return nil }
        return index
    }

    private func activateSelection() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let index = diagnosticIndex(for: row) else { return }
        selectedIndex = index
        selectedDiagnosticID = report.diagnostics[index].id
        actionStatus = nil
        reloadPreview()
        delegate?.renderTargetsView(self, didSelect: report.diagnostics[index])
    }

    /// Every edit the apply button would write, in the order it will write them.
    private var safeEdits: [TextEdit] {
        let length = (sourceText as NSString).length
        let edits = report.diagnostics.compactMap { diagnostic -> TextEdit? in
            guard let proposal = diagnostic.proposal,
                  proposal.range.location >= 0, proposal.range.upperBound <= length else { return nil }
            return TextEdit(range: proposal.range, replacement: proposal.replacement, summary: proposal.summary)
        }
        return nonOverlapping(edits)
    }

    private func applySafeFixes() {
        let edits = safeEdits
        guard !edits.isEmpty else { return }
        actionStatus = "Applied \(edits.count) safe fix\(edits.count == 1 ? "" : "es")."
        isApplyingFixes = true
        delegate?.renderTargetsView(self, didApply: edits)
        isApplyingFixes = false
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

    /// Shows the diff box only when there is a diff.  Asking the reader to
    /// "select a finding" over an empty list is an instruction with no target.
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
        guard let selectedIndex, selectedIndex < report.diagnostics.count,
              let proposal = report.diagnostics[selectedIndex].proposal,
              proposal.range.location >= 0,
              proposal.range.upperBound <= (sourceText as NSString).length else {
            previewLabel.stringValue = "Select a finding to preview a safe source change."
            setPreviewVisible(false)
            return
        }
        let before = (sourceText as NSString).substring(with: proposal.range)
        previewLabel.stringValue = "Preview · \(proposal.summary)"
        preview.string = "− \(before)\n+ \(proposal.replacement)"
        preview.setAccessibilityLabel("Source change preview: replace \(before) with \(proposal.replacement)")
        setPreviewVisible(true)
    }

    private func setPreviewVisible(_ visible: Bool) {
        guard preview.isHidden == visible else { return }
        preview.isHidden = !visible
        if !visible { preview.string = "" }
        for constraint in previewConstraints { constraint.constant = visible ? 74 : 0 }
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        countLabel.textColor = styleSheet.textFaint
        previewLabel.textColor = styleSheet.textFaint
        preview.backgroundColor = styleSheet.background
        preview.textColor = styleSheet.text
        themeTargetControl()
        table.reloadData()
        updateEmptyState()
    }

    @objc private func rowClicked(_ sender: Any?) { activateSelection() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

extension RenderTargetsView: NSTableViewDataSource, NSTableViewDelegate {
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
        case .group(let capability, let count):
            let id = NSUserInterfaceItemIdentifier("renderTargetsGroup")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? PanelGroupRowView
                ?? PanelGroupRowView(identifier: id)
            cell.configure(text: "\(capability.displayName.uppercased())  ·  \(count)", color: styleSheet.calloutColor(.warning))
            return cell
        case .diagnostic(let index):
            guard index < report.diagnostics.count else { return nil }
            let id = NSUserInterfaceItemIdentifier("renderTargetsRow")
            let cell = tableView.makeView(withIdentifier: id, owner: self) as? CompatibilityDiagnosticRowView
                ?? CompatibilityDiagnosticRowView(identifier: id)
            cell.configure(
                diagnostic: report.diagnostics[index],
                lineCaption: lineIndex.caption(for: report.diagnostics[index].range),
                styleSheet: styleSheet
            )
            return cell
        }
    }
}

private final class CompatibilityDiagnosticRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let rangeLabel = NSTextField(labelWithString: "")

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        for label in [titleLabel, detailLabel, rangeLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.lineBreakMode = .byTruncatingTail
            addSubview(label)
        }
        titleLabel.font = PanelFont.rowEmphasised
        detailLabel.font = PanelFont.secondary
        rangeLabel.font = PanelFont.secondary
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            rangeLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            rangeLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            rangeLabel.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 2),
        ])
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(diagnostic: CompatibilityDiagnostic, lineCaption: String, styleSheet: StyleSheet) {
        titleLabel.stringValue = diagnostic.title
        detailLabel.stringValue = diagnostic.explanation
        // Line for the reader; the exact range stays on the accessibility
        // label, where a precise source position is still worth having.
        rangeLabel.stringValue = lineCaption
        titleLabel.textColor = styleSheet.calloutColor(.warning)
        detailLabel.textColor = styleSheet.textSecondary
        rangeLabel.textColor = styleSheet.textFaint
        toolTip = "\(diagnostic.title)\n\(diagnostic.explanation)"
        let range = "Source range \(diagnostic.range.location)–\(diagnostic.range.upperBound)"
        setAccessibilityLabel("\(diagnostic.title). \(diagnostic.explanation). \(lineCaption). \(range)")
    }
}
