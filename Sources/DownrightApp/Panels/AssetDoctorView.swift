import AppKit
import MarkdownRender

@MainActor
protocol AssetDoctorViewDelegate: AnyObject {
    func assetDoctorView(_ view: AssetDoctorView, didSelect diagnostic: AssetDiagnostic)
    func assetDoctorView(_ view: AssetDoctorView, didReveal diagnostic: AssetDiagnostic)
    func assetDoctorView(_ view: AssetDoctorView, didRequestProposal kind: AssetProposalKind, for diagnostic: AssetDiagnostic)
    func assetDoctorView(_ view: AssetDoctorView, didApply proposal: AssetSourceProposal)
}

/// A local, source-first report for image references.
///
/// The view does not resolve URLs, read files, or contact the network.  The
/// host supplies the diagnostics and owns every edit.  This keeps the panel
/// safe to open while a document is dirty and makes every source change pass
/// through the document's normal undo path.
@MainActor
final class AssetDoctorView: NSView, PanelSurface {
    weak var delegate: AssetDoctorViewDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    var diagnostics: [AssetDiagnostic] = [] {
        didSet { reload() }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: Command.assetDoctor.panelTitle)
    private let statusLabel = NSTextField(labelWithString: "")
    private let emptyState = PanelEmptyStateView()
    private let table = PanelList.makeTableView(identifier: "assetDoctor")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    private enum Row {
        case group(code: AssetDiagnosticCode, severity: AssetDiagnosticSeverity, count: Int)
        case diagnostic(Int)
    }

    private var rows: [Row] = []

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)

        installBackdrop(backdrop)

        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        statusLabel.font = PanelFont.secondary
        statusLabel.alignment = .right
        statusLabel.lineBreakMode = .byTruncatingTail
        // The header must give way before it runs off a narrow inspector.
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.defaultLow + 1, for: .horizontal)
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Asset diagnostics")
        addSubview(scroll)
        emptyState.install(in: self, over: scroll)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            statusLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            statusLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Asset Doctor")
        applyStyle()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reload() {
        rebuildRows()
        table.reloadData()
        updateStatus()
        updateEmptyState()
    }

    /// "No issues" in a corner over an empty list is not an answer.  Every
    /// image resolving is a *result*, and the panel should say so (§11.4).
    private func updateEmptyState() {
        guard rows.isEmpty else {
            emptyState.isHidden = true
            scroll.isHidden = false
            return
        }
        emptyState.configure(
            symbol: "photo.on.rectangle",
            title: "Every image resolves",
            subtitle: "No missing files, unsafe destinations,\nor absolute paths in this document.",
            styleSheet: styleSheet
        )
        emptyState.isHidden = false
        scroll.isHidden = true
    }

    private func rebuildRows() {
        rows.removeAll(keepingCapacity: true)
        let grouped = Dictionary(grouping: diagnostics.indices) { diagnostics[$0].code }
        let codes = grouped.keys.sorted { $0.rawValue < $1.rawValue }
        for code in codes {
            guard let indices = grouped[code], !indices.isEmpty else { continue }
            let severity = indices.map { diagnostics[$0].severity }.max(by: severityOrder) ?? .info
            rows.append(.group(code: code, severity: severity, count: indices.count))
            rows.append(contentsOf: indices.map(Row.diagnostic))
        }
    }

    private func severityOrder(_ lhs: AssetDiagnosticSeverity, _ rhs: AssetDiagnosticSeverity) -> Bool {
        severityRank(lhs) < severityRank(rhs)
    }

    private func severityRank(_ severity: AssetDiagnosticSeverity) -> Int {
        switch severity {
        case .info: 0
        case .warning: 1
        case .error: 2
        }
    }

    private func updateStatus() {
        if diagnostics.isEmpty {
            statusLabel.stringValue = "No issues"
        } else {
            let errors = diagnostics.filter { $0.severity == .error }.count
            let warnings = diagnostics.filter { $0.severity == .warning }.count
            let parts = [
                errors > 0 ? "\(errors) error\(errors == 1 ? "" : "s")" : nil,
                warnings > 0 ? "\(warnings) warning\(warnings == 1 ? "" : "s")" : nil,
            ].compactMap { $0 }
            statusLabel.stringValue = parts.isEmpty ? "\(diagnostics.count) info" : parts.joined(separator: " · ")
        }
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        statusLabel.textColor = styleSheet.textFaint
        table.reloadData()
        updateEmptyState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        activateSelection()
    }

    private func activateSelection() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard let index = diagnosticIndex(for: row) else { return }
        delegate?.assetDoctorView(self, didSelect: diagnostics[index])
    }

    private func diagnosticIndex(for row: Int) -> Int? {
        guard row >= 0, row < rows.count else { return nil }
        if case .diagnostic(let index) = rows[row], index < diagnostics.count { return index }
        return nil
    }

    fileprivate func requestProposal(_ kind: AssetProposalKind, row: Int) {
        guard let index = diagnosticIndex(for: row) else { return }
        delegate?.assetDoctorView(self, didRequestProposal: kind, for: diagnostics[index])
    }

    fileprivate func reveal(row: Int) {
        guard let index = diagnosticIndex(for: row) else { return }
        delegate?.assetDoctorView(self, didReveal: diagnostics[index])
    }

    /// Used by a host after it validates a replacement.  The panel does not
    /// mutate source text itself; this method only forwards the proposal so a
    /// caller can test the same one-edit path as the buttons.
    func apply(_ proposal: AssetSourceProposal) {
        delegate?.assetDoctorView(self, didApply: proposal)
    }
}

extension AssetDoctorView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return PanelMetrics.detailRowHeight }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return PanelMetrics.detailRowHeight
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
        case .group(let code, let severity, let count):
            let identifier = NSUserInterfaceItemIdentifier("assetDoctorGroup")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PanelGroupRowView
                ?? PanelGroupRowView(identifier: identifier)
            cell.configure(text: "\(label(for: code).uppercased())  ·  \(count)", color: color(for: severity))
            return cell
        case .diagnostic(let index):
            guard index < diagnostics.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("assetDoctorRow")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? AssetDiagnosticRowView
                ?? AssetDiagnosticRowView(identifier: identifier)
            cell.configure(
                diagnostic: diagnostics[index], styleSheet: styleSheet,
                onSelect: { [weak self] in
                    guard let self, index < self.diagnostics.count else { return }
                    self.delegate?.assetDoctorView(self, didSelect: self.diagnostics[index])
                },
                onReveal: { [weak self] in self?.reveal(row: row) },
                onRelink: { [weak self] in self?.requestProposal(.relink, row: row) },
                onRename: { [weak self] in self?.requestProposal(.rename, row: row) }
            )
            return cell
        }
    }

    private func label(for code: AssetDiagnosticCode) -> String {
        switch code {
        case .missing: "Missing assets"
        case .outsideWorkspace: "Outside workspace"
        case .absolutePath: "Absolute paths"
        case .duplicate: "Duplicate assets"
        case .unsupportedFormat: "Unsupported formats"
        case .largeFile: "Large files"
        case .missingAlt: "Missing alt text"
        case .unsafe: "Unsafe destinations"
        case .malformed: "Malformed destinations"
        }
    }

    private func color(for severity: AssetDiagnosticSeverity) -> NSColor {
        switch severity {
        case .error: styleSheet.calloutColor(.danger)
        case .warning: styleSheet.calloutColor(.warning)
        case .info: styleSheet.textFaint
        }
    }
}

/// One asset finding.
///
/// The row's four actions live in a menu rather than four bordered buttons.
/// Four bezels per row in a list of twenty is the loudest thing in a low-chrome
/// app, and at 54pt they clipped anyway.  The menu is on the row's context
/// menu (pointer) and behind one quiet glyph that appears on hover, so every
/// action still has a pointer path and a keyboard path (§11.3).
private final class AssetDiagnosticRowView: NSView {
    private var reduceMotion = false
    private let severityLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(labelWithString: "")
    private let lineLabel = NSTextField(labelWithString: "")
    private let actionsButton: NSButton
    private var actionsAction: ButtonAction?
    private var trackingArea: NSTrackingArea?
    private var handlers: Handlers?

    private struct Handlers {
        let select: () -> Void
        let reveal: () -> Void
        let relink: () -> Void
        let rename: () -> Void
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        actionsButton = PanelButton.symbol("ellipsis.circle", label: "Asset actions", action: ButtonAction {})
        super.init(frame: .zero)
        self.identifier = identifier

        severityLabel.font = NSFont.systemFont(ofSize: 11, weight: .bold)
        severityLabel.alignment = .center
        severityLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(severityLabel)

        messageLabel.font = PanelFont.row
        messageLabel.maximumNumberOfLines = 2
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(messageLabel)

        lineLabel.font = PanelFont.secondary
        lineLabel.alignment = .right
        lineLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        lineLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lineLabel)

        let action = ButtonAction { [weak self] in self?.showActionsMenu() }
        actionsAction = action
        actionsButton.target = action
        actionsButton.action = #selector(ButtonAction.fire(_:))
        actionsButton.alphaValue = 0
        addSubview(actionsButton)

        NSLayoutConstraint.activate([
            severityLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            severityLabel.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            severityLabel.widthAnchor.constraint(equalToConstant: 16),
            messageLabel.leadingAnchor.constraint(equalTo: severityLabel.trailingAnchor, constant: 4),
            messageLabel.trailingAnchor.constraint(lessThanOrEqualTo: lineLabel.leadingAnchor, constant: -4),
            messageLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            messageLabel.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -5),
            lineLabel.trailingAnchor.constraint(equalTo: actionsButton.leadingAnchor, constant: -2),
            lineLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            lineLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 38),
            actionsButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            actionsButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionsButton.widthAnchor.constraint(equalToConstant: 24),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(
        diagnostic: AssetDiagnostic,
        styleSheet: StyleSheet,
        onSelect: @escaping () -> Void,
        onReveal: @escaping () -> Void,
        onRelink: @escaping () -> Void,
        onRename: @escaping () -> Void
    ) {
        reduceMotion = styleSheet.reduceMotion
        severityLabel.stringValue = diagnostic.severity == .error ? "!" : "•"
        severityLabel.textColor = switch diagnostic.severity {
        case .error: styleSheet.calloutColor(.danger)
        case .warning: styleSheet.calloutColor(.warning)
        case .info: styleSheet.textFaint
        }
        messageLabel.stringValue = diagnostic.message
        messageLabel.textColor = styleSheet.textSecondary
        lineLabel.stringValue = "Line \(diagnostic.reference.line)"
        lineLabel.textColor = styleSheet.textFaint
        actionsButton.contentTintColor = styleSheet.textFaint

        handlers = Handlers(select: onSelect, reveal: onReveal, relink: onRelink, rename: onRename)
        menu = makeActionsMenu()

        let destination = diagnostic.reference.source
        let severity = diagnostic.severity.rawValue.capitalized
        setAccessibilityLabel("\(severity), line \(diagnostic.reference.line): \(diagnostic.message). Asset \(destination)")
        toolTip = destination
    }

    private func makeActionsMenu() -> NSMenu {
        let menu = NSMenu()
        for (title, key) in [("Select in Document", "select"), ("Reveal in Finder", "reveal"),
                             ("Relink…", "relink"), ("Rename…", "rename")] {
            let item = NSMenuItem(title: title, action: #selector(performAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            menu.addItem(item)
        }
        return menu
    }

    @objc private func performAction(_ sender: NSMenuItem) {
        guard let handlers, let key = sender.representedObject as? String else { return }
        switch key {
        case "select": handlers.select()
        case "reveal": handlers.reveal()
        case "relink": handlers.relink()
        case "rename": handlers.rename()
        default: break
        }
    }

    private func showActionsMenu() {
        guard let menu else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: actionsButton.frame.minX, y: actionsButton.frame.maxY), in: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea(&trackingArea, options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect])
    }

    override func mouseEntered(with event: NSEvent) { setActionsVisible(true) }
    override func mouseExited(with event: NSEvent) { setActionsVisible(false) }

    private func setActionsVisible(_ visible: Bool) {
        PanelAnimation.run(
            reduceMotion: reduceMotion,
            duration: Motion.quick
        ) { _ in
            self.actionsButton.animator().alphaValue = visible ? 1 : 0
        }
    }
}
