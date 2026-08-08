import Foundation

// MARK: - Task worklist
//
// The Tasks panel does not want the raw `tasks` array: it wants tasks grouped
// under the heading they belong to, split into open and done, with progress
// numbers, a one-line status summary, and a clipboard-ready report.  All of
// that is a pure function of `doc.tasks` and `doc.headings`, so it lives here
// as a value type the panel can diff and cache instead of recomputing ad hoc.
//
// The derivation is one pass over the tasks to bucket them into sections —
// `doc.tasks` is already in document order, so appending preserves order
// everywhere — followed by a handful of counts and the two string renders.

/// A document's tasks, organised for the Tasks panel.
public struct TaskWorklist: Sendable, Equatable {

    /// A task flattened to what the panel renders: source offsets for
    /// navigation, text and state for display, and `taskIndex` back into
    /// `doc.tasks` so an edit can find the original.
    public struct Entry: Sendable, Equatable {
        /// Index into the source `[TaskItem]`.
        public var taskIndex: Int
        /// `markRange.location` — the offset `Restructure.toggleTask` wants.
        public var markOffset: Int
        /// `contentRange.location`.
        public var contentOffset: Int
        public var text: String
        public var isChecked: Bool
        public var indentLevel: Int

        public init(
            taskIndex: Int, markOffset: Int, contentOffset: Int, text: String,
            isChecked: Bool, indentLevel: Int
        ) {
            self.taskIndex = taskIndex
            self.markOffset = markOffset
            self.contentOffset = contentOffset
            self.text = text
            self.isChecked = isChecked
            self.indentLevel = indentLevel
        }
    }

    /// The tasks that share a `headingIndex`.  A section exists only when at
    /// least one task falls under it — a heading without tasks never appears,
    /// and neither does "Document" when every task has a heading.
    public struct Section: Sendable, Equatable {
        public var headingIndex: Int?
        /// The heading's title, or "Document" when `headingIndex` is nil.
        public var title: String
        /// Every task in the section, in document order.
        public var entries: [Entry]
        /// The unchecked tasks, stable in document order — shown first.
        public var openEntries: [Entry]
        /// The checked tasks, stable in document order.
        public var doneEntries: [Entry]
        public var openCount: Int
        public var doneCount: Int

        public init(
            headingIndex: Int?, title: String, entries: [Entry],
            openEntries: [Entry], doneEntries: [Entry], openCount: Int, doneCount: Int
        ) {
            self.headingIndex = headingIndex
            self.title = title
            self.entries = entries
            self.openEntries = openEntries
            self.doneEntries = doneEntries
            self.openCount = openCount
            self.doneCount = doneCount
        }
    }


    /// One section's contribution to the panel's progress bar: `weight` sizes
    /// the segment relative to the whole document, `completion` fills it.
    public struct Segment: Sendable, Equatable {
        public var sectionIndex: Int
        public var title: String
        public var taskCount: Int
        public var doneCount: Int
        /// `taskCount / totalCount`, or 0 when the worklist is empty.
        public var weight: Double
        /// `doneCount / taskCount`, or 0 when the section has no tasks.
        public var completion: Double

        public init(
            sectionIndex: Int, title: String, taskCount: Int, doneCount: Int,
            weight: Double, completion: Double
        ) {
            self.sectionIndex = sectionIndex
            self.title = title
            self.taskCount = taskCount
            self.doneCount = doneCount
            self.weight = weight
            self.completion = completion
        }
    }

    /// Sections in the order their first task appears in the document.
    public var sections: [Section]
    public var totalCount: Int
    public var doneCount: Int
    /// The first open entry in document order — what "next" refers to.
    public var upNext: (sectionIndex: Int, entry: Entry)?
    public var segments: [Segment]
    /// One line for the status bar; empty when there are no tasks.
    public var statusLine: String
    /// Just the counts, for the panel's caption.  The Up Next card already
    /// names the next task, so repeating its title here would say one thing
    /// twice — the caption stays a pure meter.
    public var countLine: String
    /// Clipboard-ready Markdown summary; empty when there are no tasks.
    public var statusReport: String

    // Tuples have `==` operators but cannot *conform* to Equatable (SE-0283
    // is accepted yet unimplemented), so `upNext` blocks synthesis and the
    // conformance is written out by hand.
    public static func == (lhs: TaskWorklist, rhs: TaskWorklist) -> Bool {
        guard lhs.sections == rhs.sections,
              lhs.totalCount == rhs.totalCount,
              lhs.doneCount == rhs.doneCount,
              lhs.segments == rhs.segments,
              lhs.statusLine == rhs.statusLine,
              lhs.countLine == rhs.countLine,
              lhs.statusReport == rhs.statusReport
        else { return false }
        switch (lhs.upNext, rhs.upNext) {
        case (nil, nil):
            return true
        case let (lhs?, rhs?):
            return lhs.sectionIndex == rhs.sectionIndex && lhs.entry == rhs.entry
        default:
            return false
        }
    }

    /// `headingIndex` is *expected* to index into `headings` (both come from the
    /// same `ParsedDocument`), but the panel rebuilds on every keystroke and can
    /// meet a task array captured a parse earlier than the headings it is paired
    /// with.  Rather than trust the index and trap on the mismatch, an
    /// out-of-range heading degrades to the "Document" section — a task is never
    /// worth a crash.
    public init(tasks: [TaskItem], headings: [HeadingNode]) {
        var sections: [Section] = []
        var bucket: [Int?: Int] = [:]
        var upNext: (sectionIndex: Int, entry: Entry)?
        var doneCount = 0

        for (taskIndex, task) in tasks.enumerated() {
            let entry = Entry(
                taskIndex: taskIndex,
                markOffset: task.markRange.location,
                contentOffset: task.contentRange.location,
                text: task.text,
                isChecked: task.isChecked,
                indentLevel: task.indentLevel
            )
            // Validate against the live `headings` array, not the task's word.
            let headingIndex = task.headingIndex.flatMap {
                headings.indices.contains($0) ? $0 : nil
            }
            let sectionIndex: Int
            if let existing = bucket[headingIndex] {
                sectionIndex = existing
            } else {
                sectionIndex = sections.count
                bucket[headingIndex] = sectionIndex
                sections.append(Section(
                    headingIndex: headingIndex,
                    title: headingIndex.map { headings[$0].title } ?? "Document",
                    entries: [], openEntries: [], doneEntries: [],
                    openCount: 0, doneCount: 0
                ))
            }
            sections[sectionIndex].entries.append(entry)
            if task.isChecked {
                sections[sectionIndex].doneEntries.append(entry)
                sections[sectionIndex].doneCount += 1
                doneCount += 1
            } else {
                sections[sectionIndex].openEntries.append(entry)
                sections[sectionIndex].openCount += 1
                // The first open task met is the first in document order.
                if upNext == nil { upNext = (sectionIndex, entry) }
            }
        }

        self.sections = sections
        self.totalCount = tasks.count
        self.doneCount = doneCount
        self.upNext = upNext
        self.segments = sections.enumerated().map { index, section in
            let taskCount = section.entries.count
            return Segment(
                sectionIndex: index,
                title: section.title,
                taskCount: taskCount,
                doneCount: section.doneCount,
                weight: tasks.isEmpty ? 0 : Double(taskCount) / Double(tasks.count),
                completion: taskCount == 0 ? 0 : Double(section.doneCount) / Double(taskCount)
            )
        }

        if tasks.isEmpty {
            self.statusLine = ""
            self.countLine = ""
            self.statusReport = ""
        } else if doneCount == tasks.count {
            let summary = tasks.count == 1 ? "1 task done" : "All \(tasks.count) tasks done"
            self.statusLine = summary
            self.countLine = summary
            var report = "**\(summary)**"
            TaskWorklist.appendSections(to: &report, sections)
            self.statusReport = report
        } else {
            // doneCount < totalCount means an open task exists, so upNext is set.
            let next = upNext?.entry.text ?? ""
            // U+00B7 middle dot for the one-liner, U+2014 em dash for Markdown.
            self.statusLine = "\(doneCount) of \(tasks.count) done · next: \(next)"
            self.countLine = "\(doneCount) of \(tasks.count) done"
            var report = "**\(doneCount) of \(tasks.count) done** — next: \(next)"
            TaskWorklist.appendSections(to: &report, sections)
            self.statusReport = report
        }
    }

    /// Renders every section below the report's first line: a blank line, the
    /// `##` heading with its done/total counts, then each task in document
    /// order as a GFM checkbox indented two spaces per `indentLevel`.
    private static func appendSections(to report: inout String, _ sections: [Section]) {
        for section in sections {
            report += "\n\n## \(section.title) (\(section.doneCount)/\(section.entries.count))"
            for entry in section.entries {
                report += "\n"
                if entry.indentLevel > 0 {
                    report += String(repeating: "  ", count: entry.indentLevel)
                }
                report += entry.isChecked ? "- [x] " : "- [ ] "
                report += entry.text
            }
        }
    }
}
