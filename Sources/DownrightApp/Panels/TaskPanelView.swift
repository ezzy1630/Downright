import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol TaskPanelDelegate: AnyObject {
    /// `markOffset` is the location of the single character between the
    /// brackets, so the host's write is a one-character replacement (§8.5).
    func taskPanel(_ panel: TaskPanelView, didToggleTaskAt markOffset: Int)
    func taskPanel(_ panel: TaskPanelView, didSelectTaskAt contentOffset: Int)
    /// Quick-add: insert `- [ ] text` at the end of the section's task list.
    func taskPanel(_ panel: TaskPanelView, didRequestNewTask text: String, headingIndex: Int?)
    /// Drag reorder within one sibling group.  `targetIndex == nil` moves the
    /// task to the end of its group.
    func taskPanel(_ panel: TaskPanelView, didMoveTask taskIndex: Int, before targetIndex: Int?)
}
/// Task panel (§8.5) — the plan, live.
///
/// "Agent plans are `- [ ]` all the way down."  The panel answers the two
/// questions a reader actually has, in one glance: *how is the plan going*
/// (the section-map bar, one segment per heading, with the count riding at its
/// end) and *let me work it* (the list — open tasks first, tick, quick-add,
/// drag to reorder — every one of them a source edit through the delegate, so
/// the document remains the only source of truth).  *What do I do next* needs
/// no chrome of its own: the list is open-first, so the next task is simply
/// the first row, and Space ticks it before any row is selected.
///
/// The list is open-first: finished work collapses into a per-section
/// "N completed" pile instead of occupying the top of the panel as a wall of
/// struck-through rows, which is also why the old All/Open filter is gone —
/// the ordering carries the filter now.  Sections group by nearest heading, as
/// they always did, but a document with one anonymous section skips the header
/// row rather than spend it saying "Document".
///
/// Toggling and selecting stay separate targets: the checkbox writes to the
/// file immediately, Return (or the hover chevron) jumps the document to the
/// task.  A completion plays its moment — haptic, drawn check, strike sweep —
/// and only then slides the row into the pile, with an Undo pill underneath,
/// because a tick that writes immediately deserves an equally immediate way
/// back.
///
/// Everything in the panel hangs off one left rail (`TaskRowMetrics`): the
/// section bar, the section headers, and the checkbox column all begin at the
/// same x.  A worklist that lines up is the difference between a plan and a
/// form.
final class TaskPanelView: NSView, PanelSurface {
    weak var delegate: TaskPanelDelegate?
    var onClose: (() -> Void)?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            sectionBar.styleSheet = styleSheet
            undoPill.styleSheet = styleSheet
            applyStyle()
        }
    }

    var tasks: [TaskItem] = [] { didSet { reload() } }
    var headings: [HeadingNode] = [] { didSet { reload() } }

    var progress: (done: Int, total: Int) { (worklist.doneCount, worklist.totalCount) }
    /// A worklist is a narrow tool, not a working surface: the slim panel
    /// width, one tier below the detail panels.
    var preferredWidth: CGFloat { 300 }

    var visibleTaskCountForTesting: Int {
        rows.reduce(into: 0) { count, row in
            if case .task = row { count += 1 }
        }
    }
    var pileRowCountForTesting: Int {
        rows.reduce(into: 0) { count, row in
            if case .pile = row { count += 1 }
        }
    }
    var statusLineForTesting: String { worklist.statusLine }
    var captionForTesting: String { captionLabel.stringValue }
    var rowCountForTesting: Int { rows.count }
    func setCompletedPileExpandedForTesting(_ expanded: Bool, section: Int) {
        let key = sectionKey(for: section)
        if expanded { expandedPiles.insert(key) } else { expandedPiles.remove(key) }
        reload()
    }

    // MARK: - Views

    private let backdrop: PanelBackdrop
    private let sectionBar: TaskSectionBarView
    private let captionLabel = NSTextField(labelWithString: "")
    private let table = PanelList.makeTableView(identifier: "tasks")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private let emptyState = PanelEmptyStateView()
    private let undoPill = TaskUndoPillView()

    private enum Row: Equatable {
        /// Index into `worklist.sections`.
        case section(Int)
        /// Index into `tasks`.
        case task(Int)
        /// The "N completed" disclosure of a section.
        case pile(Int)
        /// Quick-add row of a section; -1 is the whole document (empty plan).
        case add(Int)
    }

    private var worklist = TaskWorklist(tasks: [], headings: [])
    private var rows: [Row] = []
    /// Which row carried the selection last, so a selection change can rebuild
    /// two rows instead of the whole list.
    private var lastSelectedRow: Int?
    /// Table width the current row heights were measured at.
    private var measuredWidth: CGFloat = 0
    private var heightCache: [Int: CGFloat] = [:]
    /// Collapse state, keyed by `sectionKey` so a reload does not reopen what
    /// the reader folded.
    private var collapsedSections: Set<Int> = []
    private var expandedPiles: Set<Int> = []
    /// Section whose add-row is editing; -1 is the whole document.
    private var editingAddSection: Int?
    /// The mark of a completion the panel just asked for.  The row stays put
    /// while the check draws and the strike sweeps; the rebuild that slides it
    /// into the pile waits out the moment.
    private var pendingCompletionMark: Int?
    private var deferredRebuild: DispatchWorkItem?
    private var undoMarkOffset: Int?
    /// Menu actions are target/action pairs; the menu holds no strong
    /// reference, so the panel does for the menu's lifetime.
    private var menuActions: [ButtonAction] = []

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        self.sectionBar = TaskSectionBarView(styleSheet: styleSheet)
        super.init(frame: .zero)

        // The panel is glass (§11.4): the material blends with the window so
        // the document ghosts through the column rather than stopping at a
        // matte slab, and a whisper of a themed veil keeps the rows legible
        // over a busy page.  The rule that separates it from the host's
        // header belongs to the host.
        // Tasks is a working sidebar, not a transient overlay. Give it a
        // stable surface so rows remain distinct from the document in every
        // wallpaper, transparency, and appearance combination.
        backdrop.usesSurfaceFill = true
        backdrop.blendsWithinWindow = true
        backdrop.veilAlpha = 0
        installBackdrop(backdrop)

        buildHeader()
        buildTable()
        buildUndoPill()
        installChrome()
        applyStyle()
        reload()

        setAccessibilityRole(.group)
        setAccessibilityLabel("Tasks")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildHeader() {
        // The inspector host owns the panel title and the close affordance, so
        // the panel's own header is one line: the section map with the tally
        // riding at its trailing end.  One header per surface, never two
        // (§11.4).  Counts read as figures, not words: monospaced digits keep
        // the tally from shimmying as it changes — a meter, not a sentence.
        captionLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: PanelFont.secondary.pointSize, weight: .regular
        )
        captionLabel.alignment = .right
        captionLabel.lineBreakMode = .byTruncatingTail
        captionLabel.translatesAutoresizingMaskIntoConstraints = false
        captionLabel.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        captionLabel.setAccessibilityRole(.staticText)

        sectionBar.onSelectSegment = { [weak self] index in self?.revealSection(index) }
    }

    private func buildTable() {
        table.dataSource = self
        table.delegate = self
        table.onActivate = { [weak self] in self?.jumpToSelection() }
        table.onKeyDown = { [weak self] key in self?.handleListKey(key) ?? false }
        table.onMenu = { [weak self] row in self?.menu(forTableRow: row) }
        table.registerForDraggedTypes([.string])
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        // A little air after the last row, so the plan never ends flush
        // against the glass.
        scroll.contentView.contentInsets = .init(top: 0, left: 0, bottom: 10, right: 0)
    }

    private func buildUndoPill() {
        undoPill.onUndo = { [weak self] in self?.undoCompletion() }
        undoPill.isHidden = true
    }

    private func installChrome() {
        sectionBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(sectionBar)
        addSubview(captionLabel)
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        undoPill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(undoPill)

        let rail = TaskRowMetrics.contentInset
        NSLayoutConstraint.activate([
            sectionBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rail),
            sectionBar.topAnchor.constraint(equalTo: topAnchor, constant: 12),

            captionLabel.leadingAnchor.constraint(equalTo: sectionBar.trailingAnchor, constant: 8),
            captionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -rail),
            captionLabel.centerYAnchor.constraint(equalTo: sectionBar.centerYAnchor),

            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: sectionBar.bottomAnchor, constant: 8),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),

            undoPill.centerXAnchor.constraint(equalTo: centerXAnchor),
            undoPill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
            undoPill.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 12),
            undoPill.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            undoPill.heightAnchor.constraint(equalToConstant: TaskUndoPillView.height),
        ])

        // Installed last so "nothing here yet" floats over the (empty) list in
        // the same place every panel puts it.
        emptyState.install(in: self, over: scroll)
    }

    // MARK: - Style

    private func applyStyle() {
        captionLabel.textColor = styleSheet.textFaint
        if !emptyState.isHidden { configureEmptyState() }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styleSheet = .current
    }

    // MARK: - Content

    func reload() {
        worklist = TaskWorklist(tasks: tasks, headings: headings)
        heightCache.removeAll()
        updateSummary()
        scheduleRowRebuild()
        updateAccessibility()
    }

    private func updateSummary() {
        sectionBar.segments = worklist.segments
        // The tally rides at the bar's trailing end.  Hovering a segment used
        // to swap this for the section's own count — the same message in the
        // same spot, so the header appeared to react while saying nothing new.
        // The meter holds still under the pointer now; a click still scrolls
        // to the section.
        captionLabel.stringValue = worklist.countLine
        updateEmptyState()
    }

    private func updateEmptyState() {
        let empty = worklist.totalCount == 0 && editingAddSection == nil
        emptyState.isHidden = !empty
        if empty { configureEmptyState() }
    }

    private func configureEmptyState() {
        emptyState.configure(
            symbol: "checklist",
            title: "No tasks yet",
            subtitle: "Press ⌘N to add the first task, or type “- [ ]” in the document.",
            styleSheet: styleSheet
        )
    }

    private func updateAccessibility() {
        setAccessibilityValue(worklist.statusLine.isEmpty ? "No tasks" : worklist.statusLine)
    }

    // MARK: - Rows

    private func sectionKey(for section: Int) -> Int {
        guard section >= 0, section < worklist.sections.count else { return -1 }
        return worklist.sections[section].headingIndex ?? -1
    }

    /// A section header earns its row only when there is something to tell
    /// apart.  One section — named or not — makes it a disclosure control for a
    /// group with no siblings, sitting under a panel title that already says
    /// "Tasks"; collapsing it does what the panel's own close button does.  A
    /// document whose only heading *is* "Tasks" showed the word twice, four
    /// points apart.
    private var showsSectionHeaders: Bool { worklist.sections.count > 1 }

    private func buildRows() -> [Row] {
        var result: [Row] = []
        for (index, section) in worklist.sections.enumerated() {
            if showsSectionHeaders { result.append(.section(index)) }
            let collapsed = showsSectionHeaders && collapsedSections.contains(sectionKey(for: index))
            if !collapsed {
                for entry in section.openEntries { result.append(.task(entry.taskIndex)) }
                if !section.doneEntries.isEmpty {
                    // The pile keeps finished work from becoming a wall of
                    // check marks above the work that is left.  A section with
                    // *nothing* left has no such wall to hold back, and piling
                    // it anyway left a header and a "3 completed" line standing
                    // in for a section whose contents the document was showing
                    // in full a few inches away — the panel looked empty where
                    // the page looked finished.
                    let hasOpenWork = !section.openEntries.isEmpty
                    let expanded = expandedPiles.contains(sectionKey(for: index))
                    if hasOpenWork { result.append(.pile(index)) }
                    if !hasOpenWork || expanded {
                        for entry in section.doneEntries { result.append(.task(entry.taskIndex)) }
                    }
                }
            }
        }
        // One add row for the whole panel, at its foot.
        //
        // There used to be one per section, so a three-section plan carried
        // three identical "+ Add task" affordances competing with the tasks
        // themselves — the panel's most repeated element was the one thing the
        // reader had not written.  Which section a new task joins was never
        // really chosen by *which* plus was clicked anyway:
        // `preferredAddSection` already resolves it from the selection and the
        // up-next task, and it does so at click time so a selection moved since
        // the last rebuild still counts.
        if !worklist.sections.isEmpty || editingAddSection != nil {
            result.append(.add(editingAddSection ?? preferredAddSection()))
        }
        return result
    }

    /// The completion moment holds the list still for a beat: the row the
    /// reader just ticked keeps its place while the check draws and the strike
    /// sweeps, then the rebuild slides it into the pile.  Header and tally
    /// update immediately — only the row geometry waits.
    private func scheduleRowRebuild() {
        deferredRebuild?.cancel()
        deferredRebuild = nil
        guard let mark = pendingCompletionMark, window != nil, !styleSheet.reduceMotion else {
            pendingCompletionMark = nil
            rebuildRows(animated: window != nil)
            return
        }
        // Only hold when the completion actually landed in the new parse.
        guard tasks.first(where: { $0.markRange.location == mark })?.isChecked == true else {
            pendingCompletionMark = nil
            rebuildRows(animated: window != nil)
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingCompletionMark = nil
            self.deferredRebuild = nil
            self.rebuildRows(animated: true)
        }
        deferredRebuild = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10, execute: work)
    }

    private func rebuildRows(animated: Bool) {
        let selectedTask = selectedTaskIndex()
        let newRows = buildRows()
        let old = rows
        rows = newRows

        let canAnimate = animated
            && window != nil
            && !styleSheet.reduceMotion
            && !old.isEmpty && !newRows.isEmpty
        guard canAnimate, newRows != old else {
            table.reloadData()
            restoreSelection(selectedTask)
            return
        }

        let diff = newRows.difference(from: old)
        // Removals address the old row model, insertions the new one — exactly
        // the coordinate spaces `beginUpdates` expects.
        var removals = IndexSet()
        var insertions = IndexSet()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removals.insert(offset)
            case .insert(let offset, _, _): insertions.insert(offset)
            }
        }
        table.beginUpdates()
        table.removeRows(at: removals, withAnimation: [.effectFade, .slideUp])
        table.insertRows(at: insertions, withAnimation: [.effectFade, .slideDown])
        table.endUpdates()
        // Survivors kept their row identity; their contents may still have
        // changed (a pile's count, a task the document edited in place).
        let survivors = IndexSet(newRows.indices.filter { !insertions.contains($0) })
        if !survivors.isEmpty {
            table.reloadData(forRowIndexes: survivors, columnIndexes: IndexSet(integer: 0))
        }
        restoreSelection(selectedTask)
    }

    private func restoreSelection(_ taskIndex: Int?) {
        guard let taskIndex, let row = rows.firstIndex(of: .task(taskIndex)) else {
            lastSelectedRow = nil
            return
        }
        if table.selectedRow != row {
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        lastSelectedRow = row
    }

    private func selectedTaskIndex() -> Int? {
        guard table.selectedRow >= 0, table.selectedRow < rows.count,
              case .task(let index) = rows[table.selectedRow]
        else { return nil }
        return index
    }

    // MARK: - Actions

    private func toggleTask(_ task: TaskItem) {
        let completing = !task.isChecked
        if completing {
            NSHapticFeedbackManager.defaultPerformer.perform(.generic, performanceTime: .now)
            pendingCompletionMark = task.markRange.location
            undoMarkOffset = task.markRange.location
            undoPill.present(title: task.text)
        } else {
            pendingCompletionMark = nil
        }
        delegate?.taskPanel(self, didToggleTaskAt: task.markRange.location)
    }

    private func undoCompletion() {
        guard let mark = undoMarkOffset,
              let task = tasks.first(where: { $0.markRange.location == mark }),
              task.isChecked
        else { return }
        // An un-tick is a plain toggle, not a completion: no pill, no hold.
        pendingCompletionMark = nil
        delegate?.taskPanel(self, didToggleTaskAt: mark)
    }

    @discardableResult
    private func toggleUpNext() -> Bool {
        guard let up = worklist.upNext, up.entry.taskIndex < tasks.count else { return false }
        toggleTask(tasks[up.entry.taskIndex])
        return true
    }

    @discardableResult
    private func jumpToUpNext() -> Bool {
        guard let up = worklist.upNext else { return false }
        delegate?.taskPanel(self, didSelectTaskAt: up.entry.contentOffset)
        return true
    }

    private func jumpToSelection() {
        guard let index = selectedTaskIndex(), index < tasks.count else { return }
        delegate?.taskPanel(self, didSelectTaskAt: tasks[index].contentRange.location)
    }

    /// A click on a section-map segment: unfold the section if the reader had
    /// folded it, then bring its header into view.
    private func revealSection(_ section: Int) {
        guard section < worklist.sections.count else { return }
        if collapsedSections.remove(sectionKey(for: section)) != nil {
            rebuildRows(animated: true)
        }
        if let row = rows.firstIndex(of: .section(section)) {
            table.scrollRowToVisible(row)
        }
    }

    // MARK: - Quick add

    /// ⌘N, or a click on a section's "Add task" row.  The field opens in the
    /// section the reader is looking at — the selected task's, then Up Next's,
    /// then the plan's last; an empty plan gets one document-scope row.
    private func beginNewTask(section requested: Int? = nil) {
        guard editingAddSection == nil else { return }
        let section = requested ?? preferredAddSection()
        if section >= 0 { collapsedSections.remove(sectionKey(for: section)) }
        editingAddSection = section
        rebuildRows(animated: false)
        updateEmptyState()
        focusAddField(section: section)
    }

    private func preferredAddSection() -> Int {
        if let index = selectedTaskIndex(),
           let section = worklist.sections.firstIndex(where: {
               $0.headingIndex == tasks[index].headingIndex
           }) {
            return section
        }
        if let up = worklist.upNext { return up.sectionIndex }
        return worklist.sections.isEmpty ? -1 : worklist.sections.count - 1
    }

    private func focusAddField(section: Int) {
        guard let row = rows.firstIndex(of: .add(section)) else { return }
        table.scrollRowToVisible(row)
        // The field exists once the row view is on screen; first-responder has
        // to wait a turn for the table to lay the row out.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let view = self.table.view(atColumn: 0, row: row, makeIfNecessary: true) as? TaskAddRowView
            if let view { self.window?.makeFirstResponder(view.textField) }
        }
    }

    private func commitNewTask(_ text: String) {
        let section = editingAddSection
        editingAddSection = nil
        // The reparse delivers the new row; this reload just closes the field,
        // which must also happen when the insert itself is refused.
        defer { reload() }
        guard let section, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let heading = section >= 0 && section < worklist.sections.count
            ? worklist.sections[section].headingIndex
            : nil
        delegate?.taskPanel(self, didRequestNewTask: text, headingIndex: heading)
    }

    private func cancelNewTask() {
        editingAddSection = nil
        reload()
    }

    // MARK: - Context menu

    private func menu(forTableRow row: Int) -> NSMenu? {
        guard rows.indices.contains(row) else { return nil }
        menuActions = []
        func item(_ title: String, _ handler: @escaping () -> Void) -> NSMenuItem {
            let action = ButtonAction(handler)
            menuActions.append(action)
            let menuItem = NSMenuItem(
                title: title, action: #selector(ButtonAction.fire(_:)), keyEquivalent: ""
            )
            menuItem.target = action
            return menuItem
        }
        switch rows[row] {
        case .task(let index) where index < tasks.count:
            let task = tasks[index]
            table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            let menu = NSMenu()
            menu.addItem(item("Jump to Source") { [weak self] in
                guard let self else { return }
                self.delegate?.taskPanel(self, didSelectTaskAt: task.contentRange.location)
            })
            menu.addItem(item(task.isChecked ? "Mark Incomplete" : "Mark Complete") { [weak self] in
                self?.toggleTask(task)
            })
            menu.addItem(.separator())
            menu.addItem(item("Copy Task Text") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.text, forType: .string)
            })
            menu.addItem(item("Copy Status Report") { [weak self] in self?.copyStatusReport() })
            return menu
        case .section:
            let menu = NSMenu()
            menu.addItem(item("Copy Status Report") { [weak self] in self?.copyStatusReport() })
            return menu
        default:
            return nil
        }
    }

    /// The status report is Markdown, like everything else here: paste it into
    /// a standup and it is already formatted.
    private func copyStatusReport() {
        guard !worklist.statusReport.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(worklist.statusReport, forType: .string)
    }

    // MARK: - Keyboard

    /// The list's keys.  Space ticks the selected task — or Up Next when
    /// nothing is selected, so the panel is workable from the keyboard the
    /// moment it opens; Return jumps; ←/→ fold and unfold sections and piles.
    private func handleListKey(_ key: String) -> Bool {
        switch key {
        case "space":
            if let index = selectedTaskIndex(), index < tasks.count {
                toggleTask(tasks[index])
                return true
            }
            return toggleUpNext()
        case "return":
            if table.selectedRow < 0 { return jumpToUpNext() }
            return false  // a selected row's Return is the table's onActivate
        case "left", "right":
            return adjustDisclosure(expanding: key == "right")
        default:
            return false
        }
    }

    private func adjustDisclosure(expanding: Bool) -> Bool {
        let row = table.selectedRow
        guard rows.indices.contains(row) else { return false }
        switch rows[row] {
        case .section(let section):
            let key = sectionKey(for: section)
            if expanding { collapsedSections.remove(key) } else { collapsedSections.insert(key) }
            rebuildRows(animated: true)
            return true
        case .pile(let section):
            let key = sectionKey(for: section)
            if expanding { expandedPiles.insert(key) } else { expandedPiles.remove(key) }
            rebuildRows(animated: true)
            return true
        case .task(let index) where !expanding:
            // ← on a task walks the selection up to its section header.
            guard let section = worklist.sections.firstIndex(where: {
                $0.headingIndex == tasks[index].headingIndex
            }), let header = rows.firstIndex(of: .section(section)) else { return false }
            table.selectRowIndexes(IndexSet(integer: header), byExtendingSelection: false)
            return true
        default:
            return false
        }
    }

    /// ⌘N opens the quick-add field.  Caught here rather than in the list so it
    /// works whichever subview is first responder — an unhandled key bubbles
    /// up the responder chain and lands on the panel.
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == [.command], event.charactersIgnoringModifiers?.lowercased() == "n",
           editingAddSection == nil {
            beginNewTask()
            return
        }
        super.keyDown(with: event)
    }

    // MARK: - Drag reorder

    /// The group a drag may move inside: same heading, same indent, same
    /// parent — `Restructure.moveTask`'s sibling rule, mirrored so the panel
    /// never offers a gap the edit would refuse.
    private func siblingKey(of index: Int) -> String {
        guard index < tasks.count else { return "" }
        return "\(tasks[index].headingIndex ?? -1)#\(tasks[index].indentLevel)#\(parentTaskIndex(of: index) ?? -1)"
    }

    private func parentTaskIndex(of index: Int) -> Int? {
        guard index < tasks.count else { return nil }
        var candidate = index - 1
        while candidate >= 0 {
            if tasks[candidate].headingIndex == tasks[index].headingIndex,
               tasks[candidate].indentLevel < tasks[index].indentLevel {
                return candidate
            }
            candidate -= 1
        }
        return nil
    }

    private enum DropTarget {
        case before(Int)
        case endOfGroup
    }

    /// The task a gap-drop would precede, or `.endOfGroup` at the group's
    /// tail; nil when the gap is outside the dragged task's sibling group.
    private func dropBeforeTarget(gap: Int, source: Int) -> DropTarget? {
        let key = siblingKey(of: source)
        var above: Int?
        var row = gap - 1
        while row >= 0 {
            if case .task(let index) = rows[row] { above = index; break }
            if case .section = rows[row] { break }
            row -= 1
        }
        var below: Int?
        row = gap
        while row < rows.count {
            if case .task(let index) = rows[row] { below = index; break }
            if case .section = rows[row] { break }
            row += 1
        }
        // Dropping on the task's own slot is a no-op the edit would refuse.
        if above == source || below == source { return nil }
        if let below, siblingKey(of: below) == key { return .before(below) }
        if let above, siblingKey(of: above) == key { return .endOfGroup }
        return nil
    }

    private func taskHeight(for taskIndex: Int, width: CGFloat) -> CGFloat {
        if measuredWidth != width {
            measuredWidth = width
            heightCache.removeAll()
        }
        if let cached = heightCache[taskIndex] { return cached }
        let height = TaskRowView.fittingHeight(
            for: tasks[taskIndex], width: width, styleSheet: styleSheet
        )
        heightCache[taskIndex] = height
        return height
    }
}

// MARK: - Table

extension TaskPanelView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard rows.indices.contains(row) else { return nil }
        switch rows[row] {
        case .section(let section):
            let identifier = NSUserInterfaceItemIdentifier("taskSection")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TaskSectionRowView
                ?? TaskSectionRowView(identifier: identifier)
            let model = worklist.sections[section]
            cell.onToggle = { [weak self] in
                guard let self else { return }
                let key = self.sectionKey(for: section)
                if self.collapsedSections.contains(key) {
                    self.collapsedSections.remove(key)
                } else {
                    self.collapsedSections.insert(key)
                }
                self.rebuildRows(animated: true)
            }
            cell.configure(
                title: model.title,
                openCount: model.openCount,
                collapsed: collapsedSections.contains(sectionKey(for: section)),
                styleSheet: styleSheet
            )
            return cell

        case .pile(let section):
            let identifier = NSUserInterfaceItemIdentifier("taskPile")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TaskPileRowView
                ?? TaskPileRowView(identifier: identifier)
            let key = sectionKey(for: section)
            cell.onToggle = { [weak self] in
                guard let self else { return }
                if self.expandedPiles.contains(key) {
                    self.expandedPiles.remove(key)
                } else {
                    self.expandedPiles.insert(key)
                }
                self.rebuildRows(animated: true)
            }
            cell.configure(
                count: worklist.sections[section].doneCount,
                expanded: expandedPiles.contains(key),
                styleSheet: styleSheet
            )
            return cell
        case .add(let section):
            let identifier = NSUserInterfaceItemIdentifier("taskAdd")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TaskAddRowView
                ?? TaskAddRowView(identifier: identifier)
            // `nil`, not `section`: the row's own index is only what the last
            // rebuild resolved, and the selection it was derived from may have
            // moved since.  `beginNewTask` re-resolves it.
            cell.onBeginEdit = { [weak self] in self?.beginNewTask(section: nil) }
            cell.onCommit = { [weak self] text in self?.commitNewTask(text) }
            cell.onCancel = { [weak self] in self?.cancelNewTask() }
            cell.configure(editing: editingAddSection == section, styleSheet: styleSheet)
            return cell

        case .task(let index):
            guard index < tasks.count else { return nil }
            let identifier = NSUserInterfaceItemIdentifier("taskRow")
            let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? TaskRowView
                ?? TaskRowView(identifier: identifier)
            cell.onToggle = { [weak self] task in
                guard let self else { return }
                self.toggleTask(task)
            }
            cell.configure(
                task: tasks[index],
                sectionTitle: worklist.sections.first {
                    $0.headingIndex == tasks[index].headingIndex
                }?.title ?? "Document",
                isSelected: table.selectedRow == row,
                styleSheet: styleSheet
            )
            return cell
        }
    }

    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        guard rows.indices.contains(row) else { return TaskRowMetrics.minimumHeight }
        switch rows[row] {
        case .section: return TaskRowMetrics.groupHeight
        case .pile: return TaskRowMetrics.groupHeight
        case .add: return TaskRowMetrics.minimumHeight
        case .task(let index):
            guard index < tasks.count else { return TaskRowMetrics.minimumHeight }
            return taskHeight(for: index, width: tableView.bounds.width)
        }
    }

    /// Only task rows select; headers, piles, and the add row are controls.
    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .task = rows[row] { return true }
        return false
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

    // MARK: Drag reorder

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard rows.indices.contains(row), case .task(let index) = rows[row] else { return nil }
        let item = NSPasteboardItem()
        item.setString("\(index)", forType: .string)
        return item
    }

    func tableView(
        _ tableView: NSTableView, validateDrop info: NSDraggingInfo,
        proposedRow row: Int, proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        guard let source = Int(info.draggingPasteboard.string(forType: .string) ?? ""),
              source < tasks.count,
              dropBeforeTarget(gap: row, source: source) != nil
        else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }

    func tableView(
        _ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
        row: Int, dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let source = Int(info.draggingPasteboard.string(forType: .string) ?? ""),
              source < tasks.count,
              let target = dropBeforeTarget(gap: row, source: source)
        else { return false }
        switch target {
        case .before(let index):
            delegate?.taskPanel(self, didMoveTask: source, before: index)
        case .endOfGroup:
            delegate?.taskPanel(self, didMoveTask: source, before: nil)
        }
        return true
    }
}

// MARK: - Row geometry

/// The one place the panel's geometry is written down.  `TaskRowView`
/// constrains itself from these, the header lays out from them, and
/// `fittingHeight` measures from them, so the height a row is given and the
/// width its label wraps at cannot drift apart (§8.5).
enum TaskRowMetrics {
    /// One left rail for the whole panel: the section bar, the section
    /// headers, and the checkboxes all start here — and it is the *host's*
    /// rail, so the section switcher above the panel starts on it too.
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
    /// Air above and below a single line of task text.
    static let verticalPadding: CGFloat = 7
    static let minimumHeight: CGFloat = 30
    /// Section headers and pile rows carry their air above the label, which is
    /// where the break between two groups belongs.
    static let groupHeight: CGFloat = 26
    static let minimumLabelWidth: CGFloat = 90
    static let maximumLines = 3

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

// MARK: - Row surface

/// The chrome every task-panel row shares: the rounded surface drawn behind the
/// row and the pointer tracking that drives it.  Rows differ in what they draw
/// on top and in how they restyle on hover, never in the surface itself, so the
/// surface lives here once instead of four times.
private class TaskRowSurfaceView: NSView {
    /// The row's own surface, drawn in the same rect the selection uses so
    /// hover, press, and selection are one shape at three strengths.
    let surfaceLayer = CALayer()
    var isHovered = false { didSet { hoverDidChange() } }

    private var trackingArea: NSTrackingArea?

    /// Rows that cross-fade the surface themselves suppress the implicit
    /// `backgroundColor` animation so CoreAnimation cannot race their own.
    init(identifier: NSUserInterfaceItemIdentifier, ownsBackgroundFade: Bool = false) {
        super.init(frame: .zero)
        self.identifier = identifier

        wantsLayer = true
        surfaceLayer.cornerRadius = PanelMetrics.rowSurfaceRadius
        surfaceLayer.actions = ownsBackgroundFade
            ? ["position": NSNull(), "bounds": NSNull(), "backgroundColor": NSNull()]
            : ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(surfaceLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Subclasses restyle here; the base owns only the flag and the tracking.
    func hoverDidChange() {}

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.frame = PanelMetrics.rowSurface(in: bounds)
        CATransaction.commit()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea(&trackingArea, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect])
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

// MARK: - Task row

/// A worklist row: the document's checkbox at panel size, the task's text, and
/// a jump chevron on hover.  Completed tasks read quieter but carry no
/// permanent strikethrough — the strike is a *moment*, drawn across the label
/// in the instant of completion (`playCompletionMoment`), not a state the
/// reader has to see through for the rest of the plan's life.
private final class TaskRowView: TaskRowSurfaceView {
    var onToggle: ((TaskItem) -> Void)?

    private let checkbox = PanelCheckbox()
    private let label = NSTextField(labelWithString: "")
    private let jumpGlyph = NSImageView()
    /// The completion strike, drawn only while the moment plays.
    private let strikeLayer = CALayer()
    private var checkboxLeading: NSLayoutConstraint!
    private var task = TaskItem(
        isChecked: false, markRange: NSRange(location: 0, length: 1),
        contentRange: NSRange(location: 0, length: 0), text: "",
        headingIndex: nil, indentLevel: 0
    )
    private var indentLevel = 0
    private var styleSheet: StyleSheet = .current
    private var isPressed = false { didSet { updateSurface(animated: true) } }
    private var isSelected = false

    override func hoverDidChange() { updateSurface(animated: true) }

    /// The height the panel's `heightOfRow` reports, measured from the same
    /// metrics the live row constrains from.
    static func fittingHeight(for task: TaskItem, width: CGFloat, styleSheet: StyleSheet) -> CGFloat {
        let indent = min(task.indentLevel, TaskRowMetrics.maximumIndent)
        let textWidth = max(
            TaskRowMetrics.minimumLabelWidth,
            width - TaskRowMetrics.leading(indentLevel: indent) - TaskRowMetrics.trailingChrome
        )
        let rect = (task.text as NSString).boundingRect(
            with: NSSize(width: textWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: PanelFont.row]
        )
        let font = PanelFont.row
        let lineHeight = ceil(font.ascender - font.descender + font.leading)
        let capped = min(ceil(rect.height), lineHeight * CGFloat(TaskRowMetrics.maximumLines))
        return max(TaskRowMetrics.minimumHeight, TaskRowMetrics.verticalPadding * 2 + capped)
    }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(identifier: identifier, ownsBackgroundFade: true)

        strikeLayer.zPosition = 10
        strikeLayer.opacity = 0
        strikeLayer.actions = ["position": NSNull(), "bounds": NSNull()]
        layer?.addSublayer(strikeLayer)

        checkbox.translatesAutoresizingMaskIntoConstraints = false
        checkbox.onToggle = { [weak self] in
            guard let self else { return }
            if !self.task.isChecked { self.playCompletionMoment() }
            self.pulseRowGlow()
            self.onToggle?(self.task)
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
            // the rule the document's own checkbox follows — so a wrapped task
            // keeps its box beside the words it belongs to.
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

    func configure(task: TaskItem, sectionTitle: String, isSelected: Bool, styleSheet: StyleSheet) {
        self.task = task
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

        // Done reads as quieter text and a filled box; nothing is struck
        // through at rest.  The strike exists only as the completion moment.
        let text = task.text.trimmingCharacters(in: .whitespaces)
        label.attributedStringValue = NSAttributedString(string: text, attributes: [
            .font: PanelFont.row,
            .foregroundColor: task.isChecked ? styleSheet.textSecondary : styleSheet.text,
        ])
        setAccessibilityRole(.row)
        setAccessibilityLabel("\(task.isChecked ? "Completed" : "Incomplete") task: \(text), in \(sectionTitle)")
        // Reuse: a row handed back to the pool must not keep a half-run
        // completion sweep from a previous life.
        isPressed = false
        strikeLayer.removeAllAnimations()
        strikeLayer.opacity = 0
        layer?.transform = CATransform3DIdentity
        alphaValue = 1
        needsDisplay = true
        updateSurface(animated: false)
        updateGlyph(animated: false)
    }

    /// The completion moment: the strike draws itself across the first line
    /// while the label cools to its done colour.  The panel holds the row in
    /// place for the beat and then slides it into the completed pile.
    func playCompletionMoment() {
        guard !styleSheet.reduceMotion, window != nil else { return }
        layoutSubtreeIfNeeded()
        let font = PanelFont.row
        let labelFrame = label.frame
        let strikeY = labelFrame.minY + font.ascender - font.xHeight / 2
        strikeLayer.removeAllAnimations()
        strikeLayer.backgroundColor = styleSheet.textFaint.cgColor
        strikeLayer.opacity = 1
        strikeLayer.frame = NSRect(x: labelFrame.minX, y: strikeY, width: 0, height: 1)
        CATransaction.begin()
        CATransaction.setAnimationDuration(Motion.standard)
        CATransaction.setAnimationTimingFunction(Motion.timing(.decelerate))
        strikeLayer.frame = NSRect(x: labelFrame.minX, y: strikeY, width: labelFrame.width, height: 1)
        CATransaction.commit()
        label.textColor = styleSheet.textSecondary
    }

    /// The nesting rails: for a task two levels deep, the parent and grandparent
    /// boxes each leave a one-point rule centred on where their boxes sat, so
    /// children draw a single unbroken line and a two-level plan reads as a
    /// hierarchy rather than as an accidentally indented list.
    override func draw(_ dirtyRect: NSRect) {
        guard indentLevel > 0 else { return }
        let contrast = styleSheet.increaseContrast
        styleSheet.text.panelAlpha(contrast ? 0.16 : 0.09, increaseContrast: contrast).setFill()
        for level in 1...indentLevel {
            let x = TaskRowMetrics.railX(forIndentLevel: level) - 0.5
            NSRect(x: x, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    /// Hover, press, and the completion glow are the same rectangle at three
    /// strengths, so the row never changes shape as it changes state.
    private func surfaceColor() -> NSColor {
        let contrast = styleSheet.increaseContrast
        if isPressed { return styleSheet.selection.withAlphaComponent(contrast ? 0.95 : 0.75) }
        if isHovered { return styleSheet.selection.withAlphaComponent(contrast ? 0.8 : 0.55) }
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

// MARK: - Section header row

/// The worklist's disclosure glyph, pre-rendered pointing right and down.
///
/// The rows below used to keep one image and turn the *view* with
/// `frameCenterRotation`, but under Auto Layout the rotated frame became a
/// moving target for the constraint solver and the glyph drifted a half-row
/// off its title's baseline.  Swapping two pre-rendered images keeps every
/// frame upright and exact; the square canvases share a size, so the swap
/// never nudges the title either.
private enum TaskDisclosureGlyph {
    static let right = make(pointingDown: false)
    static let down = make(pointingDown: true)

    private static func make(pointingDown: Bool) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        guard let source = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return nil }
        guard pointingDown else { return source }
        let glyph = source.size
        // A square canvas, so the down glyph's extents match the right one's
        // slot and the turn never resizes anything.
        let side = max(glyph.width, glyph.height)
        let rotated = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            // AppKit's y-up space: a clockwise quarter-turn of the
            // right-chevron points it down.
            transform.rotate(byDegrees: -90)
            transform.translateX(by: -glyph.width / 2, yBy: -glyph.height / 2)
            transform.concat()
            source.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
            return true
        }
        // Drawn bitmaps aren't templates by default; the rows tint their
        // chevron through `contentTintColor`, which only templates honour.
        rotated.isTemplate = true
        return rotated
    }
}

/// A section's own row: disclosure chevron, the heading's title, and the one
/// number that matters about a section — how much of it is left.  Clicking
/// folds the section; ←/→ do the same from the keyboard.
private final class TaskSectionRowView: TaskRowSurfaceView {
    var onToggle: (() -> Void)?

    private let chevron = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private var styleSheet: StyleSheet = .current

    override func hoverDidChange() { updateSurface(animated: true) }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(identifier: identifier, ownsBackgroundFade: true)

        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        // The symbol draws at its configured point size, centred — never
        // scaled to fill the square, so the glyph stays pixel-crisp.
        chevron.imageScaling = .scaleNone
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        titleLabel.font = PanelFont.group
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        statusLabel.font = NSFont.monospacedDigitSystemFont(
            ofSize: PanelFont.secondary.pointSize, weight: .regular
        )
        statusLabel.alignment = .right
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(statusLabel)

        let rail = TaskRowMetrics.contentInset
        NSLayoutConstraint.activate([
            chevron.leadingAnchor.constraint(equalTo: leadingAnchor, constant: rail),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            // A fixed square slot: the glyph is always centred in the same
            // box, so swapping the right/down drawings never moves the title.
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),
            titleLabel.leadingAnchor.constraint(equalTo: chevron.trailingAnchor, constant: 4),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            statusLabel.leadingAnchor.constraint(
                greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8
            ),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -rail),
            statusLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(title: String, openCount: Int, collapsed: Bool, styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        chevron.setAccessibilityLabel(collapsed ? "Expand section" : "Collapse section")
        chevron.contentTintColor = styleSheet.textFaint
        setChevron(open: !collapsed, animated: window != nil)
        titleLabel.stringValue = title
        titleLabel.textColor = styleSheet.textSecondary
        // Both states speak in the same voice.  "All done" used to be drawn in
        // the accent while "3 left" sat in the faint tier, so one section's
        // status read as a button and its neighbour's read as a caption —
        // orange in this panel means *progress*, and the section bar and the
        // checkboxes already own it.  Status is status: one colour, whatever
        // it says.
        statusLabel.stringValue = openCount > 0 ? "\(openCount) left" : "All done"
        statusLabel.textColor = styleSheet.textFaint
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title) section, \(openCount) left, \(collapsed ? "collapsed" : "expanded")")
        updateSurface(animated: false)
    }

    /// The disclosure turn, told with the two pre-rendered glyphs and a quick
    /// crossfade — the gesture every Mac user learned in the Finder, without
    /// ever rotating a view Auto Layout is placing (see `TaskDisclosureGlyph`).
    private func setChevron(open: Bool, animated: Bool) {
        let image = open ? TaskDisclosureGlyph.down : TaskDisclosureGlyph.right
        guard chevron.image != image else { return }
        if animated, !styleSheet.reduceMotion, window != nil, let layer = chevron.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.quick
            fade.timingFunction = Motion.timing(.easeOut)
            layer.add(fade, forKey: "disclosure")
        }
        chevron.image = image
    }

    /// Claiming the press keeps the table's own tracking from swallowing the
    /// release, so the click pair always lands on the row.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?()
    }

    private func updateSurface(animated: Bool) {
        let contrast = styleSheet.increaseContrast
        let color = isHovered
            ? styleSheet.text.panelAlpha(contrast ? 0.1 : 0.06, increaseContrast: contrast).cgColor
            : CGColor.clear
        // Hover warms the words a step as well as the pill — the row answers
        // as one control, not as a tint under indifferent text.
        titleLabel.textColor = isHovered ? styleSheet.text : styleSheet.textSecondary
        chevron.contentTintColor = isHovered ? styleSheet.textSecondary : styleSheet.textFaint
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surfaceLayer.backgroundColor = color
        CATransaction.commit()
    }
}

// MARK: - Completed pile row

/// The "4 completed" row at a section's tail.  Finished work stays one click
/// away — reviewable, un-tickable — but it no longer occupies the top of the
/// panel by default.
private final class TaskPileRowView: TaskRowSurfaceView {
    var onToggle: (() -> Void)?

    private let chevron = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private var styleSheet: StyleSheet = .current

    override func hoverDidChange() { applyStyle(animated: true) }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(identifier: identifier, ownsBackgroundFade: true)

        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 8, weight: .bold)
        chevron.imageScaling = .scaleNone
        chevron.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chevron)

        label.font = PanelFont.secondary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)

        // Chevron centres on the checkbox column; the label starts on the text
        // column, so the pile reads as a property of the list, not a new list.
        NSLayoutConstraint.activate([
            chevron.centerXAnchor.constraint(
                equalTo: leadingAnchor,
                constant: TaskRowMetrics.checkboxInset + TaskRowMetrics.boxSide / 2
            ),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
            // The same fixed square slot the section row's chevron gets.
            chevron.widthAnchor.constraint(equalToConstant: 10),
            chevron.heightAnchor.constraint(equalToConstant: 10),
            label.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: TaskRowMetrics.leading(indentLevel: 0)
            ),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(count: Int, expanded: Bool, styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        chevron.setAccessibilityLabel(expanded ? "Hide completed tasks" : "Show completed tasks")
        setChevron(open: expanded, animated: window != nil)
        label.stringValue = count == 1 ? "1 completed" : "\(count) completed"
        setAccessibilityRole(.button)
        setAccessibilityLabel(expanded ? "Hide \(count) completed tasks" : "Show \(count) completed tasks")
        applyStyle(animated: false)
    }

    /// The same disclosure turn the section rows make — one gesture across the
    /// whole list, told with the shared pre-rendered glyphs.
    private func setChevron(open: Bool, animated: Bool) {
        let image = open ? TaskDisclosureGlyph.down : TaskDisclosureGlyph.right
        guard chevron.image != image else { return }
        if animated, !styleSheet.reduceMotion, window != nil, let layer = chevron.layer {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = Motion.quick
            fade.timingFunction = Motion.timing(.easeOut)
            layer.add(fade, forKey: "disclosure")
        }
        chevron.image = image
    }

    private func applyStyle(animated: Bool) {
        let contrast = styleSheet.increaseContrast
        let warm = isHovered
        label.textColor = warm ? styleSheet.textSecondary : styleSheet.textFaint
        chevron.contentTintColor = warm
            ? styleSheet.textSecondary
            : styleSheet.text.panelAlpha(contrast ? 0.5 : 0.35, increaseContrast: contrast)
        let surface = styleSheet.text.panelAlpha(warm ? 0.055 : 0, increaseContrast: contrast).cgColor
        guard animated, !styleSheet.reduceMotion, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surfaceLayer.removeAnimation(forKey: "surface")
            surfaceLayer.backgroundColor = surface
            CATransaction.commit()
            return
        }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = surfaceLayer.presentation()?.backgroundColor ?? surfaceLayer.backgroundColor
        fade.toValue = surface
        fade.duration = Motion.quick
        fade.timingFunction = Motion.timing(.easeOut)
        surfaceLayer.add(fade, forKey: "surface")
        surfaceLayer.backgroundColor = surface
    }

    /// Claiming the press keeps the table's own tracking from swallowing the
    /// release, so the click pair always lands on the row.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onToggle?()
    }
}

// MARK: - Quick-add row

/// The section's "+ Add task" row, and the reason the panel is two-way.  Idle
/// it is a quiet affordance on the text column; editing it is an inline field
/// that writes `- [ ] …` into the source through the delegate — Return
/// commits, Esc cancels, clicking away commits whatever is typed.
private final class TaskAddRowView: TaskRowSurfaceView, NSTextFieldDelegate {
    var onBeginEdit: (() -> Void)?
    var onCommit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let plusGlyph = NSImageView()
    private let hintLabel = NSTextField(labelWithString: "Add task")
    let textField = NSTextField()
    private var styleSheet: StyleSheet = .current
    private var editing = false
    /// Esc marks the edit so `controlTextDidEndEditing` does not commit it.
    private var cancelled = false

    override func hoverDidChange() { applyStyle(animated: window != nil) }

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(identifier: identifier, ownsBackgroundFade: true)

        plusGlyph.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "Add task")
        plusGlyph.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 10, weight: .medium)
        plusGlyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(plusGlyph)

        hintLabel.font = PanelFont.row
        hintLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(hintLabel)

        textField.font = PanelFont.row
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.lineBreakMode = .byTruncatingTail
        textField.placeholderString = "New task"
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false
        textField.isHidden = true
        addSubview(textField)

        NSLayoutConstraint.activate([
            plusGlyph.centerXAnchor.constraint(
                equalTo: leadingAnchor,
                constant: TaskRowMetrics.checkboxInset + TaskRowMetrics.boxSide / 2
            ),
            plusGlyph.centerYAnchor.constraint(equalTo: centerYAnchor),
            hintLabel.leadingAnchor.constraint(
                equalTo: leadingAnchor, constant: TaskRowMetrics.leading(indentLevel: 0)
            ),
            hintLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            textField.leadingAnchor.constraint(equalTo: hintLabel.leadingAnchor),
            textField.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -TaskRowMetrics.contentInset
            ),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(editing: Bool, styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.editing = editing
        cancelled = false
        hintLabel.isHidden = editing
        textField.isHidden = !editing
        if !editing { textField.stringValue = "" }
        setAccessibilityRole(editing ? nil : .button)
        setAccessibilityLabel(editing ? "New task title" : "Add task")
        applyStyle(animated: false)
    }

    private func applyStyle(animated: Bool) {
        let contrast = styleSheet.increaseContrast
        let warm = isHovered && !editing
        hintLabel.textColor = warm ? styleSheet.textSecondary : styleSheet.textFaint
        plusGlyph.contentTintColor = warm
            ? styleSheet.accent
            : styleSheet.text.panelAlpha(contrast ? 0.5 : 0.35, increaseContrast: contrast)
        textField.textColor = styleSheet.text
        let surface = styleSheet.text.panelAlpha(warm ? 0.055 : 0, increaseContrast: contrast).cgColor
        guard animated, !styleSheet.reduceMotion, window != nil else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            surfaceLayer.removeAnimation(forKey: "surface")
            surfaceLayer.backgroundColor = surface
            CATransaction.commit()
            return
        }
        let fade = CABasicAnimation(keyPath: "backgroundColor")
        fade.fromValue = surfaceLayer.presentation()?.backgroundColor ?? surfaceLayer.backgroundColor
        fade.toValue = surface
        fade.duration = Motion.quick
        fade.timingFunction = Motion.timing(.easeOut)
        surfaceLayer.add(fade, forKey: "surface")
        surfaceLayer.backgroundColor = surface
    }

    // MARK: - Editing

    func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        if command == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true
            onCancel?()
            return true
        }
        if command == #selector(NSResponder.insertNewline(_:)) {
            onCommit?(textField.stringValue)
            return true
        }
        return false
    }

    /// Clicking away commits whatever is typed — losing the title the reader
    /// just wrote because they clicked the document would be unforgivable.
    func controlTextDidEndEditing(_ obj: Notification) {
        guard editing, !cancelled else { return }
        onCommit?(textField.stringValue)
    }

    // MARK: - Pointer

    /// Claiming the press keeps the table's own tracking from swallowing the
    /// release, so the click pair always lands on the row.
    override func mouseDown(with event: NSEvent) {}

    override func mouseUp(with event: NSEvent) {
        guard !editing, bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onBeginEdit?()
    }
}

// MARK: - Undo pill

/// The transient "Completed '…' — Undo" pill.  Ticking a task writes the file
/// immediately, so the way back has to be just as immediate: a four-second
/// pill that rises from the panel's foot.  Hovering holds it open; Undo is the
/// same one-character write in reverse.
private final class TaskUndoPillView: NSView {
    static let height: CGFloat = 28

    var onUndo: (() -> Void)?
    var styleSheet: StyleSheet = .current {
        didSet { applyStyle() }
    }

    private let label = NSTextField(labelWithString: "")
    private let undoButton = NSButton()
    private var undoAction: ButtonAction?
    private var dismissTimer: Timer?
    private var trackingAreaRef: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = Self.height / 2
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 5
        layer?.shadowOffset = NSSize(width: 0, height: -1)

        label.font = PanelFont.secondary
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(label)

        let action = ButtonAction { [weak self] in
            self?.onUndo?()
            self?.dismiss(animated: true)
        }
        undoAction = action
        undoButton.target = action
        undoButton.action = #selector(ButtonAction.fire(_:))
        undoButton.isBordered = false
        undoButton.font = PanelFont.system(11.5, weight: .semibold)
        undoButton.translatesAutoresizingMaskIntoConstraints = false
        undoButton.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(undoButton)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            undoButton.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            undoButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            undoButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        let labelSize = label.intrinsicContentSize
        let buttonSize = undoButton.intrinsicContentSize
        return NSSize(
            width: 12 + min(labelSize.width, 210) + 8 + buttonSize.width + 10,
            height: Self.height
        )
    }

    /// What the pill believes it should be, tracked apart from `isHidden` so a
    /// re-present during a dismiss animation wins over the fade's completion.
    private var wantsVisible = false

    func present(title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        label.stringValue = "Completed ‘\(trimmed)’"
        invalidateIntrinsicContentSize()
        armDismiss(after: 4)
        wantsVisible = true
        guard isHidden else {
            // A second completion while the pill is out retells it and
            // cancels any fade already in flight.
            layer?.removeAnimation(forKey: "transform")
            alphaValue = 1
            return
        }
        isHidden = false
        guard !styleSheet.reduceMotion, window != nil else {
            alphaValue = 1
            return
        }
        alphaValue = 0
        layer?.transform = CATransform3DMakeTranslation(0, 6, 0)
        Motion.run(reduceMotion: false, duration: Motion.deliberate, curve: .decelerate) { _ in
            self.animator().alphaValue = 1
            self.layer?.transform = CATransform3DIdentity
        }
    }

    func dismiss(animated: Bool) {
        dismissTimer?.invalidate()
        dismissTimer = nil
        wantsVisible = false
        guard animated, !styleSheet.reduceMotion, window != nil else {
            isHidden = true
            return
        }
        Motion.run(reduceMotion: false, duration: Motion.standard, curve: .easeOut) { _ in
            self.animator().alphaValue = 0
        } completion: {
            // A re-present during the fade outranks the fade.
            guard !self.wantsVisible else { return }
            self.isHidden = true
            self.layer?.transform = CATransform3DIdentity
        }
    }

    private func armDismiss(after interval: TimeInterval) {
        dismissTimer?.invalidate()
        dismissTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.dismiss(animated: true)
        }
    }

    /// The pointer pauses the countdown — reading a pill should never be a
    /// race against it.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        refreshTrackingArea(&trackingAreaRef, options: [.mouseEnteredAndExited, .activeInKeyWindow])
    }

    override func mouseEntered(with event: NSEvent) {
        dismissTimer?.invalidate()
        dismissTimer = nil
    }

    override func mouseExited(with event: NSEvent) {
        armDismiss(after: 1.6)
    }

    private func applyStyle() {
        let contrast = styleSheet.increaseContrast
        layer?.backgroundColor = styleSheet.text
            .withAlphaComponent(contrast ? 0.98 : 0.92).cgColor
        label.textColor = styleSheet.background
        undoButton.contentTintColor = styleSheet.accent
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}
