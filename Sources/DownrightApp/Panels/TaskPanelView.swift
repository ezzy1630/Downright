import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol TaskPanelDelegate: AnyObject {
    /// `markOffset` is the location of the single character between the
    /// brackets, so the host's write is a one-character replacement (§8.5).
    func taskPanel(_ panel: TaskPanelView, didToggleTaskAt markOffset: Int)
    func taskPanel(_ panel: TaskPanelView, didSelectTaskAt contentOffset: Int)
}

/// Task panel (§8.5).
///
/// "Agent plans are `- [ ]` all the way down."  Grouping by nearest heading is
/// what turns a flat list of forty checkboxes back into the plan it came from;
/// the incomplete filter is what turns the plan into a worklist.
///
/// Toggling and selecting are deliberately separate targets: the checkbox
/// writes to the file immediately, the row jumps the document to the task.  One
/// control doing both would make every navigation a mutation.
///
/// The header reads like a worklist rather than a control strip: a progress
/// bar that glides, a whole-percent figure, a quiet "done of total" caption,
/// and a thumbed All/Open filter — so the shape of the plan is visible before
/// the first checkbox is read.
final class TaskPanelView: NSView, PanelSurface {
    weak var delegate: TaskPanelDelegate?
    var onClose: (() -> Void)?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            progressBar.styleSheet = styleSheet
            filterControl.styleSheet = styleSheet
            applyStyle()
        }
    }

    var tasks: [TaskItem] = [] { didSet { reload() } }
    var headings: [HeadingNode] = [] { didSet { reload() } }

    var showsIncompleteOnly: Bool = false {
        didSet {
            guard showsIncompleteOnly != oldValue else { return }
            filterControl.setSelectedIndex(showsIncompleteOnly ? 1 : 0, animated: false)
            reload()
        }
    }

    var progress: (done: Int, total: Int) {
        (done: tasks.reduce(0) { $0 + ($1.isChecked ? 1 : 0) }, total: tasks.count)
    }

    var preferredWidth: CGFloat { 336 }

    var visibleTaskCountForTesting: Int {
        rows.reduce(into: 0) { count, row in
            if case .task = row { count += 1 }
        }
    }

    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Tasks")
    private let percentLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private let progressBar: PanelProgressBar
    private let filterControl: PanelSegmentedControl
    private let closeButton: NSButton
    private let emptyState = TaskEmptyStateView()
    private var closeAction: ButtonAction?
    private let table = PanelList.makeTableView(identifier: "tasks")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    private enum Row {
        case group(String)
        /// Index into `tasks`.
        case task(Int)
    }

    private var rows: [Row] = []
    /// Set when a reload populated the table before the panel reached a window
    /// (the host hands it `tasks` while it is still detached); the entrance
    /// then runs on first layout instead of being skipped.
    private var entranceScheduled = false

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        self.progressBar = PanelProgressBar(styleSheet: styleSheet)
        self.filterControl = PanelSegmentedControl(items: ["All", "Open"], styleSheet: styleSheet)
        self.closeButton = NSButton()
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        backdrop.wantsLayer = true
        backdrop.layer?.cornerRadius = 10
        backdrop.layer?.masksToBounds = true
        addSubview(backdrop)

        buildHeader()
        buildTable()
        applyStyle()
        reload()

        setAccessibilityRole(.group)
        setAccessibilityLabel("Tasks")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildHeader() {
        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .semibold)
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.setAccessibilityRole(.staticText)
        addSubview(percentLabel)

        captionLabel.font = PanelFont.secondary
        captionLabel.alignment = .right
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.setAccessibilityRole(.staticText)
        captionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(captionLabel)

        let close = ButtonAction { [weak self] in self?.onClose?() }
        closeAction = close
        closeButton.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close tasks")
        closeButton.imagePosition = .imageOnly
        closeButton.isBordered = false
        closeButton.bezelStyle = .accessoryBarAction
        closeButton.focusRingType = .default
        closeButton.target = close
        closeButton.action = #selector(ButtonAction.fire(_:))
        closeButton.toolTip = "Close Tasks"
        closeButton.setAccessibilityLabel("Close Tasks")
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(closeButton)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)

        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterControl.onChange = { [weak self] index in
            self?.showsIncompleteOnly = index == 1
        }
        filterControl.setAccessibilityLabel("Task filter")
        filterControl.toolTip = "Show all tasks or only open tasks"
        addSubview(filterControl)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        addSubview(emptyState)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            progressBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            progressBar.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            progressBar.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 16),
            progressBar.heightAnchor.constraint(equalToConstant: 4),

            percentLabel.leadingAnchor.constraint(equalTo: progressBar.leadingAnchor),
            percentLabel.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 7),
            captionLabel.leadingAnchor.constraint(greaterThanOrEqualTo: percentLabel.trailingAnchor, constant: 8),
            captionLabel.trailingAnchor.constraint(equalTo: progressBar.trailingAnchor),
            captionLabel.centerYAnchor.constraint(equalTo: percentLabel.centerYAnchor),

            filterControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            filterControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            filterControl.topAnchor.constraint(equalTo: percentLabel.bottomAnchor, constant: 13),
            filterControl.heightAnchor.constraint(equalToConstant: PanelSegmentedControl.controlHeight),
        ])
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 42
        table.autoresizesSubviews = true
        table.setAccessibilityLabel("Task list")
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.onKeyDown = { [weak self] key in
            guard key == "escape" else { return false }
            self?.onClose?()
            return true
        }

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            emptyState.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: - Reload

    func reload() {
        rebuildRows()
        let counts = progress
        let total = counts.total
        let done = counts.done
        let fraction = total > 0 ? min(1, max(0, CGFloat(done) / CGFloat(total))) : 0

        progressBar.fraction = fraction
        percentLabel.stringValue = total > 0 ? "\(Int((fraction * 100).rounded()))%" : "0%"
        percentLabel.textColor = total > 0 && done == total
            ? styleSheet.accent
            : styleSheet.text
        captionLabel.stringValue = total > 0 ? "\(done) of \(total) complete" : "No tasks"
        let accessibleCaption = total > 0
            ? "\(done) of \(total) tasks complete"
            : "No tasks"
        percentLabel.setAccessibilityLabel(accessibleCaption)
        captionLabel.setAccessibilityLabel(accessibleCaption)

        let previousCount = table.numberOfRows
        table.reloadData()
        animateReload(previousCount: previousCount)

        let hasRows = !rows.isEmpty
        scroll.isHidden = !hasRows
        let emptyStateWasHidden = emptyState.isHidden
        emptyState.isHidden = hasRows
        configureEmptyState()
        if emptyStateWasHidden, !emptyState.isHidden {
            animateEmptyStateAppearance()
        }

        setAccessibilityValue(tasks.isEmpty ? "No tasks" : (hasRows ? accessibleCaption : "No incomplete tasks"))
    }

    private func animateEmptyStateAppearance() {
        guard !styleSheet.reduceMotion else { return }
        emptyState.alphaValue = 0
        emptyState.wantsLayer = true
        emptyState.layer?.transform = CATransform3DMakeTranslation(0, 5, 0)
        PanelAnimation.run(reduceMotion: false, duration: Motion.standard) { _ in
            self.emptyState.animator().alphaValue = 1
            self.emptyState.animator().layer?.transform = CATransform3DIdentity
        }
    }

    private func animateReload(previousCount: Int) {
        let rowsChanged = previousCount != table.numberOfRows
        // Only reduce-motion or an empty table disarms the stage.  A later
        // same-count reload must not: the host sets `tasks` then `headings`
        // before the panel ever reaches a window, and a reload in between
        // would otherwise cancel the entrance the first populate armed.
        if styleSheet.reduceMotion || table.numberOfRows == 0 {
            entranceScheduled = false
            return
        }
        if window == nil {
            entranceScheduled = true
            return
        }
        if rowsChanged {
            staggerVisibleRows()
        }
    }

    /// Rows land in document order: group headers pop into place first, then
    /// the tasks beneath them rise one after another.  A plan reveals itself
    /// top-down, like a hand unrolling it, instead of arriving as one flat
    /// wash.  Only the rows currently on screen animate; scrolling later just
    /// shows settled rows.
    private func staggerVisibleRows() {
        guard !styleSheet.reduceMotion, window != nil, table.numberOfRows > 0 else { return }
        let visible = table.rows(in: table.visibleRect)
        guard visible.length > 0 else { return }
        var sequence = 0
        for row in visible.location..<(visible.location + visible.length) {
            guard row >= 0, row < rows.count else { continue }
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            if case .group = rows[row] {
                animateHeaderLanding(view)
            } else {
                let delay = min(Double(sequence) * 0.028, 0.30)
                animateRowEntrance(view, delay: delay)
                sequence += 1
            }
        }
    }

    private func animateRowEntrance(_ view: NSView, delay: TimeInterval) {
        view.wantsLayer = true
        view.alphaValue = 1
        view.layer?.transform = CATransform3DIdentity

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 6
        rise.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = Motion.standard
        group.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1)
        // fillMode .backwards shows the from-value during the delay, so no
        // row can flash at its final position before its turn.
        group.beginTime = CACurrentMediaTime() + delay
        group.fillMode = .backwards
        view.layer?.add(group, forKey: "row-entrance")
    }

    private func animateHeaderLanding(_ view: NSView) {
        view.wantsLayer = true
        view.layer?.transform = CATransform3DIdentity
        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values = [0.96, 1.02, 1.0]
        pop.keyTimes = [0, 0.6, 1]
        pop.duration = Motion.deliberate
        pop.timingFunctions = [
            CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1),
            CAMediaTimingFunction(name: .easeOut),
        ]
        pop.beginTime = CACurrentMediaTime() + 0.04
        pop.fillMode = .backwards
        view.layer?.add(pop, forKey: "header-pop")
    }

    /// Tasks arrive in document order, so grouping is a single pass: a new
    /// group starts wherever the nearest heading changes.
    private func rebuildRows() {
        rows.removeAll(keepingCapacity: true)
        var started = false
        var currentHeading: Int?

        for (index, task) in tasks.enumerated() {
            if showsIncompleteOnly && task.isChecked { continue }
            if !started || currentHeading != task.headingIndex {
                rows.append(.group(groupTitle(for: task.headingIndex)))
                currentHeading = task.headingIndex
                started = true
            }
            rows.append(.task(index))
        }
    }

    private func groupTitle(for headingIndex: Int?) -> String {
        guard let headingIndex, headingIndex >= 0, headingIndex < headings.count else { return "Document" }
        let title = headings[headingIndex].title
        return title.isEmpty ? "Untitled" : title
    }

    private func configureEmptyState() {
        if tasks.isEmpty {
            emptyState.configure(
                symbol: "checklist",
                title: "No tasks yet",
                subtitle: "Add `- [ ]` anywhere in the document\nto start a worklist.",
                styleSheet: styleSheet
            )
        } else {
            emptyState.configure(
                symbol: "checkmark.circle",
                title: "All caught up",
                subtitle: "Nothing left to do.\nSwitch to All to review finished work.",
                styleSheet: styleSheet
            )
        }
        emptyState.setAccessibilityLabel("\(emptyState.title): \(emptyState.subtitle)")
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        captionLabel.textColor = styleSheet.textFaint
        table.reloadData()
    }

    private func activateSelection() {
        let row = table.selectedRow
        guard row >= 0, row < rows.count, case .task(let index) = rows[row], index < tasks.count else { return }
        delegate?.taskPanel(self, didSelectTaskAt: tasks[index].contentRange.location)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, entranceScheduled else { return }
        entranceScheduled = false
        // The host finishes constraining the panel after this call returns, so
        // wait one turn before asking which rows are visible.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.styleSheet.reduceMotion else { return }
            self.staggerVisibleRows()
        }
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}

// MARK: - Table

extension TaskPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return PanelMetrics.rowHeight }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        guard case .task(let index) = rows[row], index < tasks.count else { return PanelMetrics.rowHeight }
        // Long labels wrap inside a fixed-width label column; the row grows
        // with them so a wrapped line can never collide with the row below (§8.5).
        return Self.estimatedRowHeight(for: tasks[index], panelWidth: tableView.bounds.width)
    }

    private static func estimatedRowHeight(for task: TaskItem, panelWidth: CGFloat) -> CGFloat {
        let font = PanelFont.row
        let available = max(120, panelWidth - PanelMetrics.inset - 20 - 8 - 8 - 6 - 14)
        let text = task.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return PanelMetrics.rowHeight }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let lines = max(1, min(3, Int(ceil(width / available))))
        let lineHeight = font.ascender - font.descender + 2
        // 12pt vertical padding above and below the wrapped block.
        return max(PanelMetrics.rowHeight, 12 + CGFloat(lines) * lineHeight + 12)
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("taskRowBackground")
        if let view = tableView.makeView(withIdentifier: identifier, owner: self) as? PanelSelectionRowView {
            view.styleSheet = styleSheet
            return view
        }
        let view = PanelSelectionRowView()
        view.identifier = identifier
        view.styleSheet = styleSheet
        return view
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < rows.count else { return nil }

        switch rows[row] {
        case .group(let title):
            let identifier = NSUserInterfaceItemIdentifier("taskGroup")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? PanelGroupRowView
                ?? PanelGroupRowView(identifier: identifier)
            cell.configure(text: title, color: styleSheet.textFaint)
            return cell

        case .task(let index):
            guard index < tasks.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("taskRow")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TaskRowView
                ?? TaskRowView(identifier: identifier)
            cell.onToggle = { [weak self] markOffset in
                guard let self else { return }
                self.delegate?.taskPanel(self, didToggleTaskAt: markOffset)
            }
            cell.configure(
                task: tasks[index],
                groupTitle: groupTitle(for: tasks[index].headingIndex),
                isSelected: table.selectedRow == row,
                styleSheet: styleSheet
            )
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) { table.reloadData() }
}

// MARK: - Row

private final class TaskRowView: NSView {
    var onToggle: ((Int) -> Void)?

    private let checkbox = TaskCheckboxButton()
    private let label = NSTextField(labelWithString: "")
    private let jumpGlyph = NSImageView()
    private var checkboxLeading: NSLayoutConstraint!
    private var markOffset = 0
    private var indentLevel = 0
    private var trackingArea: NSTrackingArea?
    private var hoverColor: NSColor = .clear
    private var styleSheet: StyleSheet = .current
    private var isHovered = false { didSet { updateSurface(animated: true) } }
    private var isSelected = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.onToggle = { [weak self] in
            guard let self else { return }
            self.animateLabelPulse()
            self.pulseRowGlow()
            self.onToggle?(self.markOffset)
        }
        checkbox.onPressChange = { [weak self] pressed in
            self?.setRowPressed(pressed)
        }
        addSubview(checkbox)

        label.font = PanelFont.row
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 3
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        jumpGlyph.image = NSImage(
            systemSymbolName: "chevron.right",
            accessibilityDescription: "Jump to task"
        )
        jumpGlyph.contentTintColor = .clear
        jumpGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        jumpGlyph.translatesAutoresizingMaskIntoConstraints = false
        jumpGlyph.alphaValue = 0
        addSubview(jumpGlyph)

        checkboxLeading = checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset)
        NSLayoutConstraint.activate([
            checkboxLeading,
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: RenderMetrics.taskBoxSide),
            checkbox.heightAnchor.constraint(equalToConstant: RenderMetrics.taskBoxSide),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: jumpGlyph.leadingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            jumpGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            jumpGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            jumpGlyph.widthAnchor.constraint(equalToConstant: 8),
        ])

        wantsLayer = true
        layer?.cornerRadius = 7
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(task: TaskItem, groupTitle: String, isSelected: Bool, styleSheet: StyleSheet) {
        markOffset = task.markRange.location
        indentLevel = min(task.indentLevel, 4)
        self.styleSheet = styleSheet
        self.isSelected = isSelected
        hoverColor = styleSheet.selection.panelAlpha(
            styleSheet.increaseContrast ? 0.28 : 0.14,
            increaseContrast: styleSheet.increaseContrast
        )
        checkboxLeading.constant = 12 + CGFloat(indentLevel) * 11

        checkbox.setStyleSheet(styleSheet)
        checkbox.setChecked(task.isChecked, animated: false)
        checkbox.setAccessibilityLabel(task.isChecked ? "Mark incomplete: \(task.text)" : "Mark complete: \(task.text)")
        checkbox.setAccessibilityValue(task.isChecked ? "Completed" : "Incomplete")

        jumpGlyph.contentTintColor = styleSheet.textFaint

        // Struck-through and eased back when done, but still legible: one
        // completion cue (the tick) plus a restrained strike, never three
        // heavy reductions stacked on top of each other (§8.5).
        let text = task.text.trimmingCharacters(in: .whitespaces)
        if task.isChecked {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: PanelFont.row,
                .foregroundColor: styleSheet.textSecondary,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: styleSheet.textFaint.withAlphaComponent(0.55),
            ])
        } else {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: PanelFont.row,
                .foregroundColor: styleSheet.text,
            ])
        }
        setAccessibilityRole(.row)
        setAccessibilityLabel("\(task.isChecked ? "Completed" : "Incomplete") task: \(text), in \(groupTitle)")
        // Reuse: a row handed back to the pool must not keep its squeeze or a
        // half-run entrance animation from a previous life.
        layer?.transform = CATransform3DIdentity
        layer?.removeAnimation(forKey: "row-entrance")
        layer?.removeAnimation(forKey: "header-pop")
        alphaValue = 1
        updateSurface(animated: false)
        updateGlyph(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // A faint vertical guide that continues the nesting implied by the
        // checkbox indentation, so a two-level plan reads as a hierarchy and
        // not as an accidentally indented list.
        guard indentLevel > 0 else { return }
        let x = 12 + CGFloat(indentLevel) * 11 - 6.5
        let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
        styleSheet.text.panelAlpha(contrast ? 0.16 : 0.10, increaseContrast: contrast).setFill()
        NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
    }

    private func updateSurface(animated: Bool) {
        let color = isHovered ? hoverColor : .clear
        let changes = { self.layer?.backgroundColor = color.cgColor }
        guard animated else { changes(); return }
        PanelAnimation.run(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            duration: Motion.quick
        ) { _ in changes() }
        updateGlyph(animated: animated)
    }

    private func updateGlyph(animated: Bool) {
        let target: CGFloat = isHovered || isSelected ? 1 : 0
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            jumpGlyph.alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.quick
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            jumpGlyph.animator().alphaValue = target
        }
    }

    private func animateLabelPulse() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let original = label.layer?.transform ?? CATransform3DIdentity
        label.wantsLayer = true
        label.layer?.transform = CATransform3DMakeScale(0.96, 0.96, 1)
        Motion.run(reduceMotion: false, duration: Motion.deliberate, curve: .spring) { _ in
            self.label.animator().layer?.transform = original
        }
    }

    /// The checkbox presses the whole row, not just itself: the same
    /// toolbar press policy, scaled to the row's calm.  Pointer and keyboard
    /// both arrive here through the checkbox's single press channel.
    private func setRowPressed(_ pressed: Bool) {
        // A click landing while a staggered entrance is still running must
        // take over the transform immediately, or the entrance's presentation
        // value would swallow the press for its remaining duration.
        layer?.removeAnimation(forKey: "row-entrance")
        layer?.removeAnimation(forKey: "header-pop")
        let scale = pressed ? ToolbarChromePolicy.pressedScale : 1
        let target = CATransform3DMakeScale(scale, scale, 1)
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduce, window != nil else {
            layer?.transform = target
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer?.presentation()?.transform ?? layer?.transform
        animation.toValue = target
        animation.duration = pressed
            ? ToolbarChromePolicy.pressInDuration
            : ToolbarChromePolicy.pressOutDuration
        animation.timingFunction = ToolbarChromePolicy.timingFunction()
        layer?.add(animation, forKey: "row-press")
        layer?.transform = target
    }

    /// The whole row answers a completed task with a brief accent wash — the
    /// same colour as the checkbox fill, at panel alpha — that settles back to
    /// the row's own hover surface.  A soft glow, not a flash, so rapid
    /// ticking reads as a pulse train rather than a strobe.
    private func pulseRowGlow() {
        let contrast = styleSheet.increaseContrast
        let glow = styleSheet.accent.panelAlpha(
            contrast ? 0.16 : 0.10,
            increaseContrast: contrast
        )
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard !reduce, window != nil else { return }
        layer?.backgroundColor = glow.cgColor
        let settle = isHovered ? hoverColor : .clear
        PanelAnimation.run(reduceMotion: false, duration: Motion.deliberate) { _ in
            self.layer?.backgroundColor = settle.cgColor
        }
    }
}

// MARK: - Checkbox

/// The checkbox is drawn, not templated: a neutral border that warms on hover,
/// an accent fill that pops in, and a checkmark that draws itself.  A stock
/// `.switch` button cannot spring its fill or stroke its check, and that
/// animation is the whole reason ticking a task here feels like completing it.
private final class TaskCheckboxButton: NSView {
    var onToggle: (() -> Void)?
    /// Lets the owning row compress with the checkbox so the press reads as
    /// one physical surface rather than a stamp on top of a still row.
    var onPressChange: ((Bool) -> Void)?

    private var styleSheet: StyleSheet = .current
    private let borderLayer = CAShapeLayer()
    private let fillLayer = CAShapeLayer()
    private let sheenLayer = CAShapeLayer()
    private let checkLayer = CAShapeLayer()
    private let rippleLayer = CAShapeLayer()
    private var isChecked = false
    private var isHovering = false
    private var isPressed = false

    override var intrinsicContentSize: NSSize {
        NSSize(width: RenderMetrics.taskBoxSide, height: RenderMetrics.taskBoxSide)
    }

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        for layer in [fillLayer, borderLayer, sheenLayer, rippleLayer, checkLayer] {
            layer.fillColor = NSColor.clear.cgColor
            layer.actions = ["position": NSNull(), "bounds": NSNull()]
            self.layer?.addSublayer(layer)
        }
        rippleLayer.lineWidth = 1.6
        rippleLayer.opacity = 0
        // The eyebrow highlight: a bright inner stroke along the top and left
        // edges of the fill, so a checked box reads as a raised chip catching
        // light rather than a flat accent square.  StrokeStart/End wrap around
        // the closed rounded-rect path so the visible arc is the top edge
        // (0…0.30) plus the left edge (0.72…1).
        sheenLayer.lineWidth = 1.1
        sheenLayer.lineCap = .round
        sheenLayer.strokeStart = 0.72
        sheenLayer.strokeEnd = 0.30
        sheenLayer.opacity = 0
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func setStyleSheet(_ styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        applyVisual(animated: false)
    }

    func setChecked(_ checked: Bool, animated: Bool) {
        guard checked != isChecked else { return }
        isChecked = checked
        applyVisual(animated: animated)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius: CGFloat = 5
        borderLayer.frame = bounds
        borderLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        fillLayer.frame = bounds
        fillLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        checkLayer.frame = bounds
        checkLayer.path = Self.checkPath(in: bounds.insetBy(dx: 3.5, dy: 3.5))
        checkLayer.lineWidth = 1.8
        checkLayer.lineCap = .round
        checkLayer.lineJoin = .round
        checkLayer.strokeStart = 0
        sheenLayer.frame = bounds
        sheenLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        rippleLayer.frame = bounds
        rippleLayer.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        rippleLayer.strokeColor = styleSheet.accent.cgColor
        CATransaction.commit()
    }

    private static func checkPath(in rect: NSRect) -> CGPath {
        // Drawn in the checkbox's unflipped coordinates, matching the renderer:
        // the vertex sits at the bottom — upper-left start, bottom vertex, and
        // the long arm finishing mid-right on the far side.
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX + 1.2, y: rect.maxY - 1.2))
        path.line(to: NSPoint(x: rect.midX - 0.5, y: rect.minY + 1.4))
        path.line(to: NSPoint(x: rect.maxX - 0.6, y: rect.midY + 0.6))
        return path.cgPath
    }

    private func applyVisual(animated: Bool) {
        let contrast = styleSheet.increaseContrast
        let accent = styleSheet.accent
        let neutral = styleSheet.text.panelAlpha(contrast ? 0.5 : 0.30, increaseContrast: contrast)

        let targetBorder = isChecked ? accent : (isHovering ? accent.withAlphaComponent(0.8) : neutral)
        let targetFillAlpha: CGFloat = isChecked ? 1 : (isHovering ? 0.10 : 0)
        let checkEnd: CGFloat = isChecked ? 1 : 0

        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard animated, !reduce, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            borderLayer.strokeColor = targetBorder.cgColor
            borderLayer.lineWidth = isChecked ? 1.6 : 1.4
            fillLayer.opacity = Float(targetFillAlpha)
            fillLayer.backgroundColor = accent.cgColor
            fillLayer.cornerRadius = 5
            sheenLayer.strokeColor = styleSheet.background.withAlphaComponent(0.30).cgColor
            sheenLayer.opacity = Float(isChecked ? 1 : 0)
            checkLayer.strokeColor = styleSheet.background.cgColor
            checkLayer.strokeEnd = checkEnd
            checkLayer.opacity = Float(checkEnd)
            CATransaction.commit()
            return
        }

        sheenLayer.strokeColor = styleSheet.background.withAlphaComponent(0.30).cgColor
        if isChecked {
            // The sheen waits for the fill to nearly settle, then arrives on
            // top of it — keyTimes hold opacity at 0 for the delay so the
            // layer cannot flash at full opacity before the animation runs.
            let sheenFade = CAKeyframeAnimation(keyPath: "opacity")
            sheenFade.values = [0, 0, 1]
            sheenFade.keyTimes = [0, 0.45, 1]
            sheenFade.duration = Motion.standard + Motion.quick
            sheenFade.timingFunctions = [
                CAMediaTimingFunction(name: .linear),
                CAMediaTimingFunction(name: .easeOut),
            ]
            sheenLayer.removeAllAnimations()
            sheenLayer.add(sheenFade, forKey: "sheen-fade")
        } else {
            let sheenFade = CABasicAnimation(keyPath: "opacity")
            sheenFade.fromValue = 1
            sheenFade.toValue = 0
            sheenFade.duration = Motion.quick
            sheenLayer.removeAllAnimations()
            sheenLayer.add(sheenFade, forKey: "sheen-fade")
        }
        sheenLayer.opacity = Float(isChecked ? 1 : 0)

        // Border warms toward the accent.
        let border = CABasicAnimation(keyPath: "strokeColor")
        border.fromValue = borderLayer.strokeColor
        border.toValue = targetBorder.cgColor
        border.duration = Motion.quick
        borderLayer.strokeColor = targetBorder.cgColor
        borderLayer.add(border, forKey: "border")

        borderLayer.lineWidth = isChecked ? 1.6 : 1.4

        if isChecked {
            // The fill springs in beneath the check as the check draws.  The
            // keyframe carries a deliberate overshoot (0.62 → 1.07 → 1) so the
            // box lands with a soft bounce instead of stopping dead at full
            // size — a spring timing function alone cannot overshoot an
            // explicitly-clamped scale this tightly.
            let pop = CAKeyframeAnimation(keyPath: "transform.scale")
            pop.values = [0.62, 1.07, 1.0]
            pop.keyTimes = [0, 0.55, 1]
            pop.duration = Motion.deliberate
            pop.timingFunctions = [
                CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1),
                CAMediaTimingFunction(controlPoints: 0.45, 0, 0.55, 1),
            ]

            let fadeIn = CABasicAnimation(keyPath: "opacity")
            fadeIn.fromValue = 0
            fadeIn.toValue = 1
            fadeIn.duration = Motion.quick

            fillLayer.backgroundColor = accent.cgColor
            fillLayer.cornerRadius = 5
            fillLayer.removeAllAnimations()
            fillLayer.add(pop, forKey: "fill-pop")
            fillLayer.add(fadeIn, forKey: "fill-fade")
            fillLayer.opacity = 1

            checkLayer.strokeColor = styleSheet.background.cgColor
            let draw = CABasicAnimation(keyPath: "strokeEnd")
            draw.fromValue = 0
            draw.toValue = 1
            draw.duration = Motion.standard
            draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
            checkLayer.removeAllAnimations()
            checkLayer.add(draw, forKey: "check-draw")
            checkLayer.strokeEnd = 1
            checkLayer.opacity = 1
        } else {
            // The check withdraws, then the fill lets go.
            let retract = CABasicAnimation(keyPath: "strokeEnd")
            retract.fromValue = 1
            retract.toValue = 0
            retract.duration = Motion.quick
            checkLayer.removeAllAnimations()
            checkLayer.add(retract, forKey: "check-retract")
            checkLayer.strokeEnd = 0

            let fadeOut = CABasicAnimation(keyPath: "opacity")
            fadeOut.fromValue = 1
            fadeOut.toValue = 0
            fadeOut.duration = Motion.quick
            fillLayer.removeAllAnimations()
            fillLayer.add(fadeOut, forKey: "fill-fade-out")
            fillLayer.opacity = 0
        }
    }

    // MARK: - Interaction

    override func mouseDown(with event: NSEvent) {
        isPressed = true
        updatePress(animated: true)
        onPressChange?(true)
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside != isPressed else { return }
        isPressed = inside
        updatePress(animated: true)
        onPressChange?(isPressed)
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        isPressed = false
        updatePress(animated: true)
        onPressChange?(false)
        if inside {
            performToggle()
        }
    }

    /// One toggle path for pointer, keyboard, and VoiceOver so the feedback —
    /// haptic, ripple, and the drawn check — is identical however it was fired.
    private func performToggle() {
        isChecked.toggle()
        applyVisual(animated: true)
        if isChecked {
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            pulseRipple()
        }
        onToggle?()
    }

    /// A soft ring that expands from the box and fades, so a completed task is
    /// answered in place — the same pulse the document renderer draws around a
    /// checkbox the moment it is ticked (§7.1).
    private func pulseRipple() {
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        guard window != nil, !reduce else {
            rippleLayer.opacity = 0
            return
        }
        rippleLayer.removeAllAnimations()
        rippleLayer.opacity = 1
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.7
        scale.toValue = 1.5
        scale.duration = 0.42
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 0.9, 0.34, 1)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 0
        fade.duration = 0.42

        let group = CAAnimationGroup()
        group.animations = [scale, fade]
        group.duration = 0.42
        rippleLayer.add(group, forKey: "ripple")
        rippleLayer.opacity = 0
    }

    private func updatePress(animated: Bool) {
        let scale = isPressed ? 0.86 : 1
        let target = CATransform3DMakeScale(scale, scale, 1)
        guard animated, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            layer?.transform = target
            return
        }
        let animation = CABasicAnimation(keyPath: "transform")
        animation.fromValue = layer?.presentation()?.transform ?? layer?.transform
        animation.toValue = target
        animation.duration = isPressed ? 0.07 : Motion.standard
        animation.timingFunction = CAMediaTimingFunction(name: isPressed ? .easeOut : .easeInEaseOut)
        layer?.add(animation, forKey: "press")
        layer?.transform = target
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseEnteredAndExited],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isChecked else { return }
        isHovering = true
        applyVisual(animated: true)
    }

    override func mouseExited(with event: NSEvent) {
        guard isHovering else { return }
        isHovering = false
        applyVisual(animated: true)
    }

    override func accessibilityPerformPress() -> Bool {
        performToggle()
        return true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyVisual(animated: false)
    }
}

// MARK: - Empty state

/// A two-line empty state with a tinted symbol disc, used when the panel has
/// nothing to list.  It replaces the old flat text so "nothing to do" reads as
/// a state of the plan, not a gap in the UI.
private final class TaskEmptyStateView: NSView {
    private let discLayer = CALayer()
    private let symbolView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let subtitleLabel = NSTextField(wrappingLabelWithString: "")

    var title: String { titleLabel.stringValue }
    var subtitle: String { subtitleLabel.stringValue }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        symbolView.translatesAutoresizingMaskIntoConstraints = false
        symbolView.imageScaling = .scaleProportionallyDown
        symbolView.contentTintColor = .clear
        addSubview(symbolView)

        discLayer.opacity = 0
        layer?.addSublayer(discLayer)

        titleLabel.font = NSFont.systemFont(ofSize: 12.5, weight: .semibold)
        titleLabel.alignment = .center
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        subtitleLabel.font = PanelFont.secondary
        subtitleLabel.alignment = .center
        subtitleLabel.maximumNumberOfLines = 3
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitleLabel)

        NSLayoutConstraint.activate([
            symbolView.topAnchor.constraint(equalTo: topAnchor),
            symbolView.centerXAnchor.constraint(equalTo: centerXAnchor),
            symbolView.widthAnchor.constraint(equalToConstant: 40),
            symbolView.heightAnchor.constraint(equalToConstant: 40),
            titleLabel.topAnchor.constraint(equalTo: symbolView.bottomAnchor, constant: 10),
            titleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            subtitleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            subtitleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            subtitleLabel.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitleLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        discLayer.frame = symbolView.frame.insetBy(dx: -2, dy: -2)
        discLayer.cornerRadius = discLayer.bounds.width / 2
        CATransaction.commit()
    }

    func configure(symbol: String, title: String, subtitle: String, styleSheet: StyleSheet) {
        let contrast = styleSheet.increaseContrast
        discLayer.backgroundColor = styleSheet.accent
            .panelAlpha(0.12, increaseContrast: contrast).cgColor
        discLayer.opacity = 1

        symbolView.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: title
        )?.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 18, weight: .medium))
        symbolView.contentTintColor = styleSheet.accent

        titleLabel.stringValue = title
        titleLabel.textColor = styleSheet.text
        subtitleLabel.stringValue = subtitle
        subtitleLabel.textColor = styleSheet.textFaint
        setAccessibilityRole(.group)
        setAccessibilityLabel("\(title): \(subtitle)")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
