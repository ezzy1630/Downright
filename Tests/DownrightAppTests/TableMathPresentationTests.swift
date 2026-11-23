import AppKit
import NativeUITestSupport
import Testing

@testable import DownrightApp
@testable import MarkdownRender

/// Reddit report: math inside table cells drew as raw LaTeX. Prose typesets
/// `$…$` through the display map; a table row instead draws whatever
/// `TableCellPresentation` hands it, in both the column and stacked layouts.
@Suite(.serialized)
@MainActor
struct TableMathPresentationTests {
    @Test func inlineMathInTableCellIsTypesetLikeProse() async throws {
        let source = "Prose $\\frac{1}{2}$ typesets.\n\n| Quantity | Value |\n|---|---|\n| Half | $\\frac{1}{2}$ |\n\nAfter.\n"
        try await UIDriver.withDocument(source) { ui in
            let storage = try #require(ui.textView.textStorage)
            let proseMath = NSRange(location: try ui.range(of: "Prose ").upperBound, length: "$\\frac{1}{2}$".utf16.count)
            try #require(ui.textView.currentDisplayMap.substitutions(in: proseMath).contains {
                $0.replacement?.attribute(.attachment, at: 0, effectiveRange: nil) != nil
            }, "Control: prose math must typeset to an attachment in this environment")

            let row = try ui.range(of: "| Half |")
            let fragment = try #require(try layoutFragment(at: row.location, in: ui.textView) as? TableRowFragment,
                                        "The math row is not drawn as a table row")
            let data = try #require(fragment.payload.tableData)
            let cell = try #require(data.rows.first { NSLocationInRange(row.location, $0.range) }?.cells.last,
                                    "The parsed table has no math cell")
            let presented = TableCellPresentation.attributedContent(for: cell, in: storage)
            var hasAttachment = false
            presented.enumerateAttribute(.attachment, in: NSRange(location: 0, length: presented.length), options: []) { value, _, _ in
                if value != nil { hasAttachment = true }
            }
            ui.check(!presented.string.contains("\\frac"),
                     "The table cell presents raw LaTeX \(presented.string.debugDescription)")
            ui.check(hasAttachment,
                     "The table cell presents no typeset formula: \(presented.string.debugDescription)")
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
