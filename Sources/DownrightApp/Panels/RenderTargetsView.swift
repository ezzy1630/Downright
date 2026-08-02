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
        didSet { reloadPreview() }
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

    var preferredWidth: CGFloat { 360 }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Render targets")
    private let countLabel = NSTextField(labelWithString: "")
    private let targetControl = NSPopUpButton()
    private let previewLabel = NSTextField(labelWithString: "")
    private let preview = NSTextView()
    private let table = PanelList.makeTableView(identifier: "renderTargets")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private let applyButton: NSButton
    private let sourceButton: NSButton
    private var applyAction: ButtonAction?
    private var sourceAction: ButtonAction?
    private var rows: [Row] = []
    private var selectedIndex: Int?

    private enum Row {
        case group(MarkdownCapability, Int)
        case diagnostic(Int)
    }

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        applyButton = PanelButton.text("Apply safe fixes", action: ButtonAction { })
        sourceButton = PanelButton.text("Open Source mode", action: ButtonAction { })
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

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
        preview.font = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
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
        sourceButton.setAccessibilityLabel("Open Source mode")
        let actions = NSStackView(views: [applyButton, sourceButton])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 5
        actions.translatesAutoresizingMaskIntoConstraints = false
        addSubview(actions)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
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
            preview.heightAnchor.constraint(equalToConstant: 74),
            actions.leadingAnchor.constraint(equalTo: previewLabel.leadingAnchor),
            actions.trailingAnchor.constraint(lessThanOrEqualTo: previewLabel.trailingAnchor),
            actions.topAnchor.constraint(equalTo: preview.bottomAnchor, constant: 7),
            actions.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
        ])

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
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard sender.indexOfSelectedItem >= 0, sender.indexOfSelectedItem < profiles.count else { return }
        selectedProfile = profiles[sender.indexOfSelectedItem]
    }

    private func reload() {
        rows.removeAll(keepingCapacity: true)
        let grouped = Dictionary(grouping: report.diagnostics.indices, by: { report.diagnostics[$0].capability })
        for capability in MarkdownCapability.allCases {
            guard let indices = grouped[capability], !indices.isEmpty else { continue }
            rows.append(.group(capability, indices.count))
            rows.append(contentsOf: indices.map(Row.diagnostic))
        }
        countLabel.stringValue = report.diagnostics.isEmpty ? "Compatible" : "(report.diagnostics.count) issue\(report.diagnostics.count == 1 ? "" : "s")"
        countLabel.setAccessibilityLabel(countLabel.stringValue)
        table.reloadData()
        table.deselectAll(nil)
        selectedIndex = nil
        reloadPreview()
        applyButton.isEnabled = report.diagnostics.contains { $0.proposal != nil }
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
        reloadPreview()
        delegate?.renderTargetsView(self, didSelect: report.diagnostics[index])
    }

    private func applySafeFixes() {
        let length = (sourceText as NSString).length
        let edits = report.diagnostics.compactMap { diagnostic -> TextEdit? in
            guard let proposal = diagnostic.proposal,
                  proposal.range.location >= 0, proposal.range.upperBound <= length else { return nil }
            return TextEdit(range: proposal.range, replacement: proposal.replacement, summary: proposal.summary)
        }
        guard !edits.isEmpty else { return }
        delegate?.renderTargetsView(self, didApply: nonOverlapping(edits))
    }

    private func nonOverlapping(_ edits: [TextEdit]) -> [TextEdit] {
        var lastStart = Int.max
        return edits.sorted { $0.range.location > $1.range.location }.filter {
            guard $0.range.upperBound <= lastStart else { return false }
            lastStart = $0.range.location
            return true
        }
    }

    private func reloadPreview() {
        guard let selectedIndex, selectedIndex < report.diagnostics.count,
              let proposal = report.diagnostics[selectedIndex].proposal else {
            previewLabel.stringValue = "Select a finding to preview a safe source change."
            preview.string = ""
            return
        }
        guard proposal.range.location >= 0,
              proposal.range.upperBound <= (sourceText as NSString).length else { return }
        let before = (sourceText as NSString).substring(with: proposal.range)
        previewLabel.stringValue = "Preview · \(proposal.summary)"
        preview.string = "− \(before)\n+ \(proposal.replacement)"
        preview.setAccessibilityLabel("Source change preview: replace \(before) with \(proposal.replacement)")
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        countLabel.textColor = styleSheet.textFaint
        previewLabel.textColor = styleSheet.textFaint
        preview.backgroundColor = styleSheet.background
        preview.textColor = styleSheet.text
        table.reloadData()
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
        guard row < rows.count else { return 48 }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return 58
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
            cell.configure(diagnostic: report.diagnostics[index], styleSheet: styleSheet)
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

    func configure(diagnostic: CompatibilityDiagnostic, styleSheet: StyleSheet) {
        titleLabel.stringValue = diagnostic.title
        detailLabel.stringValue = diagnostic.explanation
        rangeLabel.stringValue = "Source range \(diagnostic.range.location)–\(diagnostic.range.upperBound)"
        titleLabel.textColor = styleSheet.calloutColor(.warning)
        detailLabel.textColor = styleSheet.textSecondary
        rangeLabel.textColor = styleSheet.textFaint
        setAccessibilityLabel("\(diagnostic.title). \(diagnostic.explanation). \(rangeLabel.stringValue)")
    }
}
