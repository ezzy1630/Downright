import AppKit
import NativeUITestSupport
import Testing

@testable import DownrightApp
@testable import MarkdownRender

/// Reddit report: math inside table cells drew as raw LaTeX. Prose typesets
/// `$…$` through the display map; a table row instead draws whatever
/// `TableCellPresentation` hands it, in both the column and stacked layouts,
/// and sizes its columns and rows from the same content.
@Suite(.serialized)
@MainActor
struct TableMathPresentationTests {
    /// A label too long for any column forces the stacked layout.
    static let stackingLabel = String(repeating: "Supercalifragilisticexpialidocious", count: 5)

    @Test(arguments: [false, true])
    func inlineMathInTableCellIsTypesetLikeProse(stacked: Bool) async throws {
        let label = stacked ? Self.stackingLabel : "Half"
        let source = "Prose $\\frac{1}{2}$ typesets.\n\n| Quantity | Value |\n|---|---|\n| \(label) | $\\frac{1}{2}$ |\n\nAfter.\n"
        try await UIDriver.withDocument(source) { ui in
            let storage = try #require(ui.textView.textStorage)
            let proseMath = NSRange(location: try ui.range(of: "Prose ").upperBound, length: "$\\frac{1}{2}$".utf16.count)
            try #require(ui.textView.currentDisplayMap.substitutions(in: proseMath).contains {
                $0.replacement?.attribute(.attachment, at: 0, effectiveRange: nil) != nil
            }, "Control: prose math must typeset to an attachment in this environment")

            let row = try ui.range(of: "| \(label) |")
            let fragment = try #require(try layoutFragment(at: row.location, in: ui.textView) as? TableRowFragment,
                                        "The math row is not drawn as a table row")
            let data = try #require(fragment.payload.tableData)
            let cell = try #require(data.rows.first { NSLocationInRange(row.location, $0.range) }?.cells.last,
                                    "The parsed table has no math cell")
            let context = ui.textView.fragmentContext
            let width = Int((fragment.contentWidth * 4).rounded())
            let layout = try #require(context.tableLayouts
                .filter { $0.key.location == fragment.payload.sourceRange.location && $0.key.width == width }
                .max { $0.key.textRevision < $1.key.textRevision }?.value,
                "The row was laid out without its table geometry")
            try #require(layout.isStacked == stacked,
                         "Fixture expects stacked \(stacked), but the table laid out stacked \(layout.isStacked)")

            // What both row draw paths render: the cell content with the live style sheet.
            let presented = TableCellPresentation.attributedContent(for: cell, in: storage, styleSheet: context.styleSheet)
            var formula: NSTextAttachment?
            presented.enumerateAttribute(.attachment, in: NSRange(location: 0, length: presented.length), options: []) { value, _, _ in
                if let value = value as? NSTextAttachment { formula = value }
            }
            ui.check(!presented.string.contains("\\frac"),
                     "The table cell presents raw LaTeX \(presented.string.debugDescription)")
            ui.check(formula != nil,
                     "The table cell presents no typeset formula: \(presented.string.debugDescription)")

            if let formula {
                // The drawn cell rect is the row minus its top padding; the
                // formula has to fit inside it rather than clip.
                let rowHeight = fragment.layoutFragmentFrame.height
                ui.check(rowHeight >= formula.bounds.height + RenderMetrics.tableRowPadding,
                         "A \(rowHeight)pt row clips a \(formula.bounds.height)pt formula")
                if !stacked {
                    let latex = NSAttributedString(string: "\\frac{1}{2}",
                                                   attributes: [.font: context.styleSheet.bodyFont()]).size().width
                    ui.check(layout.columnWidths[1] < latex,
                             "The math column is \(layout.columnWidths[1])pt, sized for \(latex)pt of LaTeX, not the formula")
                }
            }
            ui.check(Data(ui.source.utf8) == Data(source.utf8) && !ui.isDirty,
                     "Presenting table math changed source or dirty state")
        }
    }

    private func layoutFragment(at sourceOffset: Int, in textView: MarkdownTextView) throws -> NSTextLayoutFragment {
        let layout = try #require(textView.textLayoutManager)
        let storage = try #require(layout.textContentManager)
        let offset = textView.currentDisplayMap.textKitOffset(forSource: sourceOffset)
        let location = try #require(storage.location(storage.documentRange.location, offsetBy: offset))
        layout.ensureLayout(for: NSTextRange(location: location))
        return try #require(layout.textLayoutFragment(for: location))
    }
}
