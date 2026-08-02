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
            filterButton.state = showsIncompleteOnly ? .on : .off
            reload()
        }
    }

    var progress: (done: Int, total: Int) {
        (done: tasks.reduce(0) { $0 + ($1.isChecked ? 1 : 0) }, total: tasks.count)
    }

    var preferredWidth: CGFloat { PanelMetrics.listWidth }

    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Tasks")
    private let countLabel = NSTextField(labelWithString: "")
    private let ring: TaskProgressRing
    private let filterButton = NSButton()
    private var filterAction: ButtonAction?
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
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
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
        addSubview(countLabel)

        ring.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ring)

        let action = ButtonAction { [weak self] in
            guard let self else { return }
            self.showsIncompleteOnly = self.filterButton.state == .on
        }
        filterAction = action
        filterButton.setButtonType(.switch)
        filterButton.title = "Incomplete only"
        filterButton.font = PanelFont.secondary
        filterButton.target = action
        filterButton.action = #selector(ButtonAction.fire(_:))
        filterButton.setAccessibilityLabel("Show incomplete tasks only")
        filterButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(filterButton)

        NSLayoutConstraint.activate([
            ring.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            ring.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            ring.widthAnchor.constraint(equalToConstant: 18),
            ring.heightAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: ring.trailingAnchor, constant: 6),
            titleLabel.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            countLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            countLabel.centerYAnchor.constraint(equalTo: ring.centerYAnchor),
            countLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 6),
            filterButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            filterButton.topAnchor.constraint(equalTo: ring.bottomAnchor, constant: 4),
        ])
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = 24
        table.setAccessibilityLabel("Task list")

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: filterButton.bottomAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Reload

    func reload() {
        rebuildRows()
        let counts = progress
        ring.progress = counts
        countLabel.stringValue = counts.total > 0 ? "\(counts.done) of \(counts.total)" : "None"
        table.reloadData()
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
        filterButton.contentTintColor = styleSheet.textSecondary
        table.reloadData()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

// MARK: - Table

extension TaskPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return PanelMetrics.rowHeight }
        if case .group = rows[row] { return PanelMetrics.groupRowHeight }
        return PanelMetrics.rowHeight
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
            cell.configure(text: title.uppercased(), color: styleSheet.textFaint)
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
            cell.configure(task: tasks[index], styleSheet: styleSheet)
            return cell
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = table.selectedRow
        guard row >= 0, row < rows.count, case .task(let index) = rows[row], index < tasks.count else { return }
        delegate?.taskPanel(self, didSelectTaskAt: tasks[index].contentRange.location)
    }
}

// MARK: - Row

private final class TaskRowView: NSView {
    var onToggle: ((Int) -> Void)?

    private let checkbox = NSButton()
    private let label = NSTextField(labelWithString: "")
    private var toggleAction: ButtonAction?
    private var checkboxLeading: NSLayoutConstraint!
    private var markOffset = 0

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)

        label.font = PanelFont.row
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        checkboxLeading = checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset)
        NSLayoutConstraint.activate([
            checkboxLeading,
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 2),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(task: TaskItem, styleSheet: StyleSheet) {
        markOffset = task.markRange.location
        checkboxLeading.constant = PanelMetrics.inset + CGFloat(min(task.indentLevel, 5)) * 12
        checkbox.state = task.isChecked ? .on : .off
        checkbox.setAccessibilityLabel(task.isChecked ? "Completed: \(task.text)" : "Incomplete: \(task.text)")

        let action = ButtonAction { [weak self] in
            guard let self else { return }
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
        setAccessibilityLabel(text)
    }
}
