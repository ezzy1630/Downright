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
final class TaskPanelView: NSView, PanelSurface {
    weak var delegate: TaskPanelDelegate?
    var onClose: (() -> Void)?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            ring.styleSheet = styleSheet
            applyStyle()
        }
    }

    var tasks: [TaskItem] = [] { didSet { reload() } }
    var headings: [HeadingNode] = [] { didSet { reload() } }

    var showsIncompleteOnly: Bool = false {
        didSet {
            guard showsIncompleteOnly != oldValue else { return }
            filterButton.selectedSegment = showsIncompleteOnly ? 1 : 0
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
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let ring: TaskProgressRing
    private let filterButton = NSSegmentedControl(
        labels: ["All", "Open"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let closeButton: NSButton
    private var filterAction: ButtonAction?
    private var closeAction: ButtonAction?
    private let table = PanelList.makeTableView(identifier: "tasks")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    private enum Row {
        case group(String)
        /// Index into `tasks`.
        case task(Int)
    }

    private var rows: [Row] = []

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        self.ring = TaskProgressRing(styleSheet: styleSheet)
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

        countLabel.font = PanelFont.secondary
        countLabel.alignment = .right
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        countLabel.setAccessibilityRole(.staticText)
        addSubview(countLabel)

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

        emptyLabel.font = PanelFont.row
        emptyLabel.alignment = .center
        emptyLabel.textColor = styleSheet.textSecondary
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        addSubview(emptyLabel)

        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)

        let action = ButtonAction { [weak self] in
            guard let self else { return }
            self.showsIncompleteOnly = self.filterButton.selectedSegment == 1
        }
        filterAction = action
        filterButton.controlSize = .small
        filterButton.font = PanelFont.secondary
        filterButton.selectedSegment = 0
        filterButton.target = action
        filterButton.action = #selector(ButtonAction.fire(_:))
        filterButton.toolTip = "Show all tasks or only open tasks"
        filterButton.setAccessibilityLabel("Task filter")
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 15),
            ring.leadingAnchor.constraint(equalTo: titleLabel.trailingAnchor, constant: 8),
            ring.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            ring.widthAnchor.constraint(equalToConstant: 20),
            ring.heightAnchor.constraint(equalToConstant: 20),
            titleLabel.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            countLabel.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -8),
            countLabel.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: ring.trailingAnchor, constant: 8),
            filterButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            filterButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 10),
            filterButton.heightAnchor.constraint(equalToConstant: 24),
            filterButton.widthAnchor.constraint(equalToConstant: 112),
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
            scroll.topAnchor.constraint(equalTo: filterButton.bottomAnchor, constant: 10),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            emptyLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: - Reload

    func reload() {
        rebuildRows()
        let counts = progress
        ring.progress = counts
        let open = counts.total - counts.done
        countLabel.stringValue = counts.total > 0 ? "\(open) open · \(counts.done) done" : "No tasks"
        countLabel.setAccessibilityLabel(countLabel.stringValue == "No tasks"
            ? "No tasks"
            : "\(counts.done) of \(counts.total) tasks completed")
        let previousCount = table.numberOfRows
        table.reloadData()
        animateReload(previousCount: previousCount)
        let hasRows = !rows.isEmpty
        scroll.isHidden = !hasRows
        emptyLabel.isHidden = hasRows
        emptyLabel.stringValue = tasks.isEmpty
            ? "No tasks yet\nAdd - [ ] in the document to start a worklist."
            : "Everything is complete\nChoose All to review finished work."
        emptyLabel.setAccessibilityLabel(emptyLabel.stringValue)
        setAccessibilityValue(tasks.isEmpty ? "No tasks" : (hasRows ? countLabel.stringValue : "No incomplete tasks"))
    }

    private func animateReload(previousCount: Int) {
        guard !styleSheet.reduceMotion, previousCount != table.numberOfRows, table.numberOfRows > 0 else { return }
        table.alphaValue = 0
        table.wantsLayer = true
        table.layer?.transform = CATransform3DMakeTranslation(0, 5, 0)
        PanelAnimation.run(reduceMotion: false, duration: Motion.standard) { _ in
            self.table.animator().alphaValue = 1
            self.table.animator().layer?.transform = CATransform3DIdentity
        }
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

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        countLabel.textColor = styleSheet.textFaint
        emptyLabel.textColor = styleSheet.textSecondary
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

    override func cancelOperation(_ sender: Any?) { onClose?() }
}

// MARK: - Table

extension TaskPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return PanelMetrics.rowHeight }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return 42
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

    private let checkbox = NSButton()
    private let label = NSTextField(labelWithString: "")
    private var toggleAction: ButtonAction?
    private var checkboxLeading: NSLayoutConstraint!
    private var markOffset = 0
    private var trackingArea: NSTrackingArea?
    private var hoverColor: NSColor = .clear
    private var isHovered = false { didSet { updateSurface(animated: true) } }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.focusRingType = .default
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)

        label.font = PanelFont.row
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 2
        label.cell?.wraps = true
        label.cell?.isScrollable = false
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        checkboxLeading = checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset)
        NSLayoutConstraint.activate([
            checkboxLeading,
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkbox.widthAnchor.constraint(equalToConstant: 20),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        wantsLayer = true
        layer?.cornerRadius = 7
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(task: TaskItem, groupTitle: String, styleSheet: StyleSheet) {
        markOffset = task.markRange.location
        hoverColor = styleSheet.selection.panelAlpha(
            styleSheet.increaseContrast ? 0.28 : 0.14,
            increaseContrast: styleSheet.increaseContrast
        )
        checkboxLeading.constant = 12 + CGFloat(min(task.indentLevel, 4)) * 11
        checkbox.state = task.isChecked ? .on : .off
        checkbox.setAccessibilityLabel(task.isChecked ? "Mark incomplete: \(task.text)" : "Mark complete: \(task.text)")
        checkbox.setAccessibilityValue(task.isChecked ? "Completed" : "Incomplete")

        let action = ButtonAction { [weak self] in
            guard let self else { return }
            self.animateToggle()
            self.onToggle?(self.markOffset)
        }
        toggleAction = action
        checkbox.target = action
        checkbox.action = #selector(ButtonAction.fire(_:))

        // Struck-through and dimmed when done: the completed half of an agent
        // plan should recede rather than compete with what is left.
        let text = task.text.trimmingCharacters(in: .whitespaces)
        if task.isChecked {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: PanelFont.row,
                .foregroundColor: styleSheet.textFaint,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: styleSheet.textFaint,
            ])
        } else {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: PanelFont.row,
                .foregroundColor: styleSheet.text,
            ])
        }
        setAccessibilityRole(.row)
        setAccessibilityLabel("\(task.isChecked ? "Completed" : "Incomplete") task: \(text), in \(groupTitle)")
        updateSurface(animated: false)
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

    private func updateSurface(animated: Bool) {
        let color = isHovered ? hoverColor : .clear
        let changes = { self.layer?.backgroundColor = color.cgColor }
        guard animated else { changes(); return }
        PanelAnimation.run(
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            duration: Motion.quick
        ) { _ in changes() }
    }

    private func animateToggle() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let initial = checkbox.layer?.transform ?? CATransform3DIdentity
        checkbox.wantsLayer = true
        checkbox.layer?.transform = CATransform3DMakeScale(0.78, 0.78, 1)
        PanelAnimation.run(reduceMotion: false, duration: Motion.standard) { _ in
            self.checkbox.animator().layer?.transform = initial
        }
    }
}
