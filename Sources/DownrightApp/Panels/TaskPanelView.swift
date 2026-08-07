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
///
/// Everything in the panel hangs off one left rail (`TaskRowMetrics`): the
/// percent figure, the section names, and the checkbox column all begin at the
/// same x, and task text begins at the second column that the boxes open.  A
/// worklist that lines up is the difference between a plan and a form.
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

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    var visibleTaskCountForTesting: Int {
        rows.reduce(into: 0) { count, row in
            if case .task = row { count += 1 }
        }
    }

    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let percentLabel = NSTextField(labelWithString: "")
    private let captionLabel = NSTextField(labelWithString: "")
    private let progressBar: PanelProgressBar
    private let filterControl: PanelSegmentedControl
    private let emptyState = PanelEmptyStateView()
    private let table = PanelList.makeTableView(identifier: "tasks")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)

    private enum Row {
        case group(String)
        /// Index into `tasks`.
        case task(Int)
    }

    private var rows: [Row] = []
    /// Which row carried the selection last, so a selection change can rebuild
    /// two rows instead of the whole list.
    private var lastSelectedRow: Int?
    /// Table width the current row heights were measured at.
    private var measuredWidth: CGFloat = 0
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
        super.init(frame: .zero)

        // The panel is a card inside the inspector: a flat themed surface (the
        // vibrancy backdrop resolved to almost the page colour).  The rule that
        // separates it from the host's switcher belongs to the host, which
        // draws one for every panel rather than each panel drawing its own.
        backdrop.usesSurfaceFill = true
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
        // The inspector host owns the section title and the close affordance,
        // so the panel's own header is just the worklist strip: progress, count,
        // and the filter.  One header per surface, never two (§11.4).
        //
        // Reading order top to bottom: the figure and the filter on one line,
        // then the bar that draws the same figure, then the list.  The bar used
        // to sit *above* the numbers and hard against the host's own rule,
        // where it read as a stray accent line belonging to neither surface.
        percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        percentLabel.translatesAutoresizingMaskIntoConstraints = false
        percentLabel.setAccessibilityRole(.staticText)
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(percentLabel)

        captionLabel.font = PanelFont.secondary
        captionLabel.alignment = .left
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.setAccessibilityRole(.staticText)
        captionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(captionLabel)

        progressBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(progressBar)

        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterControl.onChange = { [weak self] index in
            self?.showsIncompleteOnly = index == 1
        }
        filterControl.setAccessibilityLabel("Task filter")
        filterControl.toolTip = "Show all tasks or only open tasks"
        filterControl.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(filterControl)

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        addSubview(emptyState)

        NSLayoutConstraint.activate([
            filterControl.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -TaskRowMetrics.contentInset
            ),
            filterControl.topAnchor.constraint(
                equalTo: topAnchor, constant: TaskRowMetrics.headerTopPadding
            ),
            filterControl.heightAnchor.constraint(equalToConstant: TaskRowMetrics.filterHeight),

            percentLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: TaskRowMetrics.contentInset
            ),
            percentLabel.centerYAnchor.constraint(equalTo: filterControl.centerYAnchor),
            captionLabel.leadingAnchor.constraint(equalTo: percentLabel.trailingAnchor, constant: 7),
            captionLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: filterControl.leadingAnchor, constant: -10
            ),
            captionLabel.firstBaselineAnchor.constraint(equalTo: percentLabel.firstBaselineAnchor),

            // The bar sits on the same rail as everything else and under the
            // figure it restates, so the header reads as one block instead of
            // a line, a gap, and a row.
            progressBar.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: TaskRowMetrics.contentInset
            ),
            progressBar.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -TaskRowMetrics.contentInset
            ),
            progressBar.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 9),
            progressBar.heightAnchor.constraint(equalToConstant: TaskRowMetrics.progressBarHeight),
        ])
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.rowHeight = TaskRowMetrics.minimumHeight
        table.autoresizesSubviews = true
        table.setAccessibilityLabel("Task list")
        table.onActivate = { [weak self] in self?.activateSelection() }
        // "The row jumps the document to the task" — which it did only on a
        // double-click, while the chevron that appears on hover promised it on
        // one.  The checkbox handles its own clicks, so a click that reaches
        // the table is a click on the row and never a toggle.
        table.target = self
        table.action = #selector(rowClicked(_:))
        // Space ticks the selected task and Return jumps to it: the two things
        // the row does, both reachable without the pointer (§11.4).
        table.onKeyDown = { [weak self] key in
            guard let self else { return false }
            switch key {
            case "escape":
                self.onClose?()
                return true
            case "space":
                return self.toggleSelection()
            default:
                return false
            }
        }

        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: progressBar.bottomAnchor, constant: 12),
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
        measuredWidth = table.bounds.width
        table.reloadData()
        animateReload(previousCount: previousCount)

        let hasRows = !rows.isEmpty
        scroll.isHidden = !hasRows
        let emptyStateWasHidden = emptyState.isHidden
        emptyState.isHidden = hasRows
        // Configuring costs a symbol lookup and a string layout; a panel with
        // rows reloads on every keystroke that touches a task and has nothing
        // to say about being empty.
        if !hasRows { configureEmptyState() }
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
        PanelAnimation.run(reduceMotion: styleSheet.reduceMotion, duration: Motion.standard) { _ in
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

    /// Rows land top-down, so a plan reveals itself the way a hand unrolls it
    /// rather than arriving as one flat wash.  Only the rows currently on
    /// screen animate; scrolling later just shows settled rows.
    ///
    /// The stagger *compresses* instead of clipping.  The old one added a
    /// fixed 0.028s per row and capped the total at 0.30s, so on any list
    /// longer than twelve rows every remaining row shared one delay and
    /// flashed in as a batch, with the last landing at 0.50s — a duration the
    /// motion system does not have.  Spreading the same budget across however
    /// many rows there are keeps every row distinct and puts the last one down
    /// at exactly `Motion.deliberate` after the panel opens.
    private func staggerVisibleRows() {
        guard !styleSheet.reduceMotion, window != nil, table.numberOfRows > 0 else { return }
        let visible = table.rows(in: table.visibleRect)
        // Before the split view has settled, the visible rect can be empty
        // even though rows exist — animate the whole list rather than skip.
        let rowRange: Range<Int>
        if visible.length > 0 {
            rowRange = visible.location..<(visible.location + visible.length)
        } else {
            rowRange = 0..<table.numberOfRows
        }
        let span = max(1, rowRange.count - 1)
        let start = CACurrentMediaTime()
        for row in rowRange {
            guard row >= 0, row < rows.count else { continue }
            guard let view = table.view(atColumn: 0, row: row, makeIfNecessary: true) else { continue }
            let delay = Motion.quick * Double(row - rowRange.lowerBound) / Double(span)
            animateRowEntrance(view, at: start + delay)
        }
    }

    /// One entrance for every row, group headers included.  A header that pops
    /// while its tasks rise is two entrances in one list, and a scale on a text
    /// row costs a re-render for movement nobody asked for (§11.4).
    private func animateRowEntrance(_ view: NSView, at beginTime: CFTimeInterval) {
        view.wantsLayer = true
        view.alphaValue = 1
        view.layer?.transform = CATransform3DIdentity

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = 5
        rise.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [fade, rise]
        group.duration = Motion.standard
        group.timingFunction = Motion.timing(.decelerate)
        // fillMode .backwards shows the from-value during the delay, so no
        // row can flash at its final position before its turn.
        group.beginTime = beginTime
        group.fillMode = .backwards
        view.layer?.add(group, forKey: "row-entrance")
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
        captionLabel.textColor = styleSheet.textFaint
        table.reloadData()
    }

    @objc private func rowClicked(_ sender: Any?) {
        let row = table.clickedRow
        guard row >= 0, row < rows.count,
              case .task(let index) = rows[row], index < tasks.count else { return }
        delegate?.taskPanel(self, didSelectTaskAt: tasks[index].contentRange.location)
    }

    private func activateSelection() {
        let row = table.selectedRow
        guard row >= 0, row < rows.count, case .task(let index) = rows[row], index < tasks.count else { return }
        delegate?.taskPanel(self, didSelectTaskAt: tasks[index].contentRange.location)
    }

    /// Ticks the selected task through the row's own checkbox, so the keyboard
    /// gets the same haptic, ripple, and drawn check the pointer does.
    @discardableResult
    private func toggleSelection() -> Bool {
        let row = table.selectedRow
        guard row >= 0, row < rows.count, case .task = rows[row] else { return false }
        guard let cell = table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskRowView else { return false }
        cell.toggleFromKeyboard()
        return true
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
        // wait one turn, then give the table real geometry before asking which
        // rows are visible.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil, !self.styleSheet.reduceMotion else { return }
            self.scroll.layoutSubtreeIfNeeded()
            self.table.layoutSubtreeIfNeeded()
            self.staggerVisibleRows()
        }
    }

    override func layout() {
        super.layout()
        remeasureRowsIfWidthChanged()
        // Fallback for a panel populated while detached whose async entrance
        // fired before the inspector gave the table its width: the next layout
        // pass with real geometry runs the stagger instead of losing it.
        guard entranceScheduled, window != nil, table.numberOfRows > 0, bounds.width > 1 else { return }
        entranceScheduled = false
        staggerVisibleRows()
    }

    /// A wrapped row's height depends on the width it wraps at, and AppKit asks
    /// for heights once and caches them.  The first ask happens before the
    /// inspector has given the table its width, so without this a long task
    /// keeps the two-line height it was measured at when the panel was 90pt
    /// wide — which is what made one-line rows sit at uneven distances.
    private func remeasureRowsIfWidthChanged() {
        let width = table.bounds.width
        guard width > 1, abs(width - measuredWidth) > 0.5, table.numberOfRows > 0 else { return }
        measuredWidth = width
        table.noteHeightOfRows(withIndexesChanged: IndexSet(integersIn: 0..<table.numberOfRows))
    }

    override func cancelOperation(_ sender: Any?) { onClose?() }
}

// MARK: - Table

extension TaskPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard row < rows.count else { return TaskRowMetrics.minimumHeight }
        if case .group = rows[row] { return TaskRowMetrics.groupHeight }
        guard case .task(let index) = rows[row], index < tasks.count else {
            return TaskRowMetrics.minimumHeight
        }
        // Long labels wrap inside a fixed-width label column; the row grows
        // with them so a wrapped line can never collide with the row below (§8.5).
        return Self.estimatedRowHeight(for: tasks[index], panelWidth: tableView.bounds.width)
    }

    /// Measured from the very constants `TaskRowView` constrains itself with,
    /// including the indent, so a deeply nested long task is measured at the
    /// width it will actually wrap at instead of a wider guess.
    static func estimatedRowHeight(for task: TaskItem, panelWidth: CGFloat) -> CGFloat {
        let font = PanelFont.row
        let text = task.text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty, panelWidth > 0 else { return TaskRowMetrics.minimumHeight }

        let leading = TaskRowMetrics.leading(indentLevel: task.indentLevel)
        let available = max(
            TaskRowMetrics.minimumLabelWidth,
            panelWidth - leading - TaskRowMetrics.trailingChrome
        )
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        let lines = max(1, min(TaskRowMetrics.maximumLines, Int(ceil(width / available))))
        let lineHeight = font.ascender - font.descender + 2
        return max(
            TaskRowMetrics.minimumHeight,
            TaskRowMetrics.verticalPadding * 2 + CGFloat(lines) * lineHeight
        )
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
            // Section names sit on the panel's one left rail, with the percent
            // figure above them and the checkboxes below.
            cell.leadingInset = TaskRowMetrics.contentInset
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

    /// Only the two rows whose selection actually changed are rebuilt.  A full
    /// `reloadData` on every arrow key rebuilds every visible cell view, throws
    /// away their hover state, and grows with the length of the plan.
    func tableViewSelectionDidChange(_ notification: Notification) {
        var affected = IndexSet()
        if let previous = lastSelectedRow, previous < table.numberOfRows { affected.insert(previous) }
        if table.selectedRow >= 0 { affected.insert(table.selectedRow) }
        lastSelectedRow = table.selectedRow >= 0 ? table.selectedRow : nil
        guard !affected.isEmpty else { return }
        table.reloadData(forRowIndexes: affected, columnIndexes: IndexSet(integer: 0))
    }
}

// MARK: - Row

/// The one place the panel's geometry is written down.  `TaskRowView`
/// constrains itself from these, the header lays out from them, and
/// `estimatedRowHeight` measures from them, so the height a row is given and
/// the width its label wraps at cannot drift apart (§8.5).
enum TaskRowMetrics {
    /// One left rail for the whole panel: the percent figure, the section
    /// headers, and the checkboxes all start here — and it is the *host's*
    /// rail, so the section switcher above the panel starts on it too.  Two
    /// points of disagreement between chrome and content is the kind of thing
    /// nobody can name and everybody sees.
    static let contentInset = PanelMetrics.inset
    static let checkboxInset = contentInset
    static let boxSide = PanelCheckbox.Geometry.panelSide
    /// A child's box begins exactly where its parent's box ended, so nesting
    /// is one box-width per level — readable at four levels inside 336pt.
    static let indentStep = boxSide
    static let maximumIndent = 4
    /// Checkbox → label gap, label → chevron gap, chevron, chevron → edge.
    static let labelGap: CGFloat = 9
    static let glyphGap: CGFloat = 6
    static let glyphWidth: CGFloat = 8
    static let glyphInset: CGFloat = 10
    /// Air above and below a single line of task text.  12 made a one-line row
    /// 41pt tall — a settings form, not a worklist.
    static let verticalPadding: CGFloat = 7
    static let minimumHeight: CGFloat = 30
    /// Section headers carry their air above the label, which is where the
    /// break between two groups belongs.
    static let groupHeight: CGFloat = 26
    static let minimumLabelWidth: CGFloat = 90
    static let maximumLines = 3

    static let headerTopPadding: CGFloat = 11
    /// Tall enough to round its own ends and to read as a bar rather than as a
    /// rule that happens to be orange.
    static let progressBarHeight: CGFloat = 5
    /// The chrome height for a segmented control, not a squeezed one: the
    /// filter used to be pinned to 22 against a control designed at 26, which
    /// cramped the thumb and clipped the air around both labels.
    static let filterHeight = PanelSegmentedControl.controlHeight

    static func leading(indentLevel: Int) -> CGFloat {
        checkboxInset
            + CGFloat(min(indentLevel, maximumIndent)) * indentStep
            + boxSide
            + labelGap
    }

    static var trailingChrome: CGFloat { glyphGap + glyphWidth + glyphInset }

    /// Top of the checkbox, placed so its centre lands on the first line's
    /// x-height centre — `baseline - xHeight / 2`, the same rule the document
    /// renderer uses for the ornament column.
    static var firstLineBoxTop: CGFloat {
        let font = PanelFont.row
        let opticalCentre = verticalPadding + font.ascender - font.xHeight / 2
        return (opticalCentre - boxSide / 2).rounded()
    }

    /// Centre of the box one level shallower — where a nesting rail hangs from.
    static func railX(forIndentLevel level: Int) -> CGFloat {
        checkboxInset + CGFloat(level - 1) * indentStep + boxSide / 2
    }
}

private final class TaskRowView: NSView {
    var onToggle: ((Int) -> Void)?

    private let checkbox = PanelCheckbox()
    private let label = NSTextField(labelWithString: "")
    private let jumpGlyph = NSImageView()
    /// The row's own surface, drawn in the same rect the selection uses so
    /// hover, press, and selection are one shape at three strengths.
    private let surfaceLayer = CALayer()
    private var checkboxLeading: NSLayoutConstraint!
    private var markOffset = 0
    private var indentLevel = 0
    private var trackingArea: NSTrackingArea?
    private var styleSheet: StyleSheet = .current
    private var isHovered = false { didSet { updateSurface(animated: true) } }
    private var isPressed = false { didSet { updateSurface(animated: true) } }
    private var isSelected = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        wantsLayer = true
        surfaceLayer.cornerRadius = PanelMetrics.rowSurfaceRadius
        surfaceLayer.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(surfaceLayer)

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.onToggle = { [weak self] in
            guard let self else { return }
            self.pulseRowGlow()
            self.onToggle?(self.markOffset)
        }
        checkbox.onPressChange = { [weak self] pressed in
            self?.isPressed = pressed
        }
        addSubview(checkbox)

        label.font = PanelFont.row
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = TaskRowMetrics.maximumLines
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

        checkboxLeading = checkbox.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: TaskRowMetrics.checkboxInset
        )
        NSLayoutConstraint.activate([
            checkboxLeading,
            // The box centres on the first line's x-height, not on the row —
            // the rule `ListOrnamentFragment` uses to place the document's own
            // checkbox — so a wrapped task keeps its box beside the words it
            // belongs to instead of drifting to the middle of the block.
            checkbox.topAnchor.constraint(
                equalTo: topAnchor, constant: TaskRowMetrics.firstLineBoxTop
            ),
            checkbox.widthAnchor.constraint(equalToConstant: TaskRowMetrics.boxSide),
            checkbox.heightAnchor.constraint(equalToConstant: TaskRowMetrics.boxSide),
            label.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: TaskRowMetrics.labelGap),
            label.trailingAnchor.constraint(equalTo: jumpGlyph.leadingAnchor, constant: -TaskRowMetrics.glyphGap),
            label.topAnchor.constraint(equalTo: topAnchor, constant: TaskRowMetrics.verticalPadding),
            jumpGlyph.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -TaskRowMetrics.glyphInset),
            jumpGlyph.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
            jumpGlyph.widthAnchor.constraint(equalToConstant: TaskRowMetrics.glyphWidth),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.frame = PanelMetrics.rowSurface(in: bounds)
        CATransaction.commit()
    }

    func configure(task: TaskItem, groupTitle: String, isSelected: Bool, styleSheet: StyleSheet) {
        markOffset = task.markRange.location
        indentLevel = min(task.indentLevel, TaskRowMetrics.maximumIndent)
        self.styleSheet = styleSheet
        self.isSelected = isSelected
        checkboxLeading.constant = TaskRowMetrics.checkboxInset
            + CGFloat(indentLevel) * TaskRowMetrics.indentStep
        // A task that still had to be clipped says the rest on hover rather
        // than losing it (§8.5).
        toolTip = task.text.trimmingCharacters(in: .whitespaces)

        checkbox.setStyleSheet(styleSheet)
        checkbox.setChecked(task.isChecked, animated: false)
        checkbox.setAccessibilityLabel(task.isChecked ? "Mark incomplete: \(task.text)" : "Mark complete: \(task.text)")
        checkbox.setAccessibilityValue(task.isChecked ? "Completed" : "Incomplete")

        jumpGlyph.contentTintColor = styleSheet.textFaint

        // Byte-for-byte the treatment `DecorationEngine` gives a ticked task in
        // the page — secondary text, faint strike — so the same task does not
        // read as two different states in two places (§8.5).
        let text = task.text.trimmingCharacters(in: .whitespaces)
        if task.isChecked {
            label.attributedStringValue = NSAttributedString(string: text, attributes: [
                .font: PanelFont.row,
                .foregroundColor: styleSheet.textSecondary,
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
        // Reuse: a row handed back to the pool must not keep a half-run
        // entrance animation from a previous life.
        isPressed = false
        layer?.transform = CATransform3DIdentity
        layer?.removeAnimation(forKey: "row-entrance")
        alphaValue = 1
        needsDisplay = true
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

    /// The panel's Space key comes through here so pointer and keyboard share
    /// one toggle path, exactly as the checkbox's own comment claims.
    func toggleFromKeyboard() { checkbox.performToggle() }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // One faint rail per ancestor level, hanging from the centre of the
        // box it belongs to.  Rows abut, so consecutive children draw a single
        // unbroken line and a two-level plan reads as a hierarchy rather than
        // as an accidentally indented list.
        guard indentLevel > 0 else { return }
        let contrast = styleSheet.increaseContrast
        styleSheet.text.panelAlpha(contrast ? 0.16 : 0.09, increaseContrast: contrast).setFill()
        for level in 1...indentLevel {
            // A one-point rule centred on the box's centre line.
            let x = TaskRowMetrics.railX(forIndentLevel: level) - 0.5
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    /// Hover, press, and the completion glow are the same rectangle at three
    /// strengths, so the row never changes shape as it changes state.
    private func surfaceColor() -> NSColor {
        // Hover and press are the selection colour at a fraction of its
        // strength, so the three states are one ramp rather than three tints.
        let contrast = styleSheet.increaseContrast
        if isPressed { return styleSheet.selection.withAlphaComponent(contrast ? 0.9 : 0.65) }
        if isHovered { return styleSheet.selection.withAlphaComponent(contrast ? 0.7 : 0.45) }
        return .clear
    }

    private func updateSurface(animated: Bool) {
        let color = surfaceColor().cgColor
        guard animated, !styleSheet.reduceMotion, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surfaceLayer.removeAnimation(forKey: "surface")
            surfaceLayer.backgroundColor = color
            CATransaction.commit()
            updateGlyph(animated: false)
            return
        }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = surfaceLayer.presentation()?.backgroundColor ?? surfaceLayer.backgroundColor
        fade.toValue = color
        fade.duration = Motion.quick
        fade.timingFunction = Motion.timing(.easeOut)
        surfaceLayer.add(fade, forKey: "surface")
        surfaceLayer.backgroundColor = color
        updateGlyph(animated: true)
    }

    private func updateGlyph(animated: Bool) {
        let target: CGFloat = isHovered || isSelected ? 1 : 0
        guard animated, !styleSheet.reduceMotion else {
            jumpGlyph.alphaValue = target
            return
        }
        guard jumpGlyph.alphaValue != target else { return }
        Motion.run(reduceMotion: styleSheet.reduceMotion, duration: Motion.quick) { _ in
            jumpGlyph.animator().alphaValue = target
        }
    }

    /// The row answers a completed task with one brief accent wash in the
    /// checkbox's own colour, which settles back to whatever the row was
    /// already showing.  A glow, not a flash, so ticking six tasks in a row
    /// reads as a pulse train rather than a strobe.
    private func pulseRowGlow() {
        guard !styleSheet.reduceMotion, window != nil else { return }
        let contrast = styleSheet.increaseContrast
        let glow = styleSheet.accent.panelAlpha(contrast ? 0.18 : 0.12, increaseContrast: contrast)
        let settle = surfaceColor()
        let wash = CAKeyframeAnimation(keyPath: "backgroundColor")
        wash.values = [glow.cgColor, glow.cgColor, settle.cgColor]
        wash.keyTimes = [0, 0.25, 1]
        wash.duration = Motion.deliberate
        wash.timingFunctions = [Motion.timing(.easeOut), Motion.timing(.easeOut)]
        surfaceLayer.add(wash, forKey: "surface")
        surfaceLayer.backgroundColor = settle.cgColor
    }
}
