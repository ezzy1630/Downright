import AppKit
import MarkdownCore
import Testing

@testable import MarkdownRender

/// Two constructs from a Reddit report, reconstructed rather than copied.
///
/// A table cell cannot hold a newline, so display math in a cell is written
/// `$$ <br> … <br> $$`. cmark splits each `<br>` into inline HTML before the
/// math pass, which scans one text span at a time, so neither `$$` sees its
/// partner and the cell shows raw LaTeX.
///
/// `\underbrace{…}_{label}` is not in SwiftMath, so the whole formula falls
/// back to the "could not be typeset" box; `\longrightarrow` beside it is
/// supported and is the control.
@Suite
@MainActor
struct ReportedMathConstructTests {
    private static let style = StyleSheet(theme: .fallback,
                                          appearance: NSAppearance(named: .aqua) ?? .currentDrawing())

    // MARK: - `$$ <br> … <br> $$` in a table cell

    @Test(arguments: [#"$$ <br> 30^\circ <br> $$"#, #"$$<br>+5\,J<br>$$"#, #"$$ <br/> \Delta x <br /> $$"#])
    func breakPaddedDisplayMathInACellIsTypeset(cellSource: String) throws {
        let source = "| Angle | Note |\n|---|---|\n| \(cellSource) | text |\n"
        let (cell, storage) = try firstBodyCell(source)
        let latex = mathLatex(in: cell, storage: storage)
        let body = cellSource
            .replacingOccurrences(of: "$$", with: "")
            .replacingOccurrences(of: "<br />", with: "")
            .replacingOccurrences(of: "<br/>", with: "")
            .replacingOccurrences(of: "<br>", with: "")
            .trimmingCharacters(in: .whitespaces)
        #expect(latex.map { $0.trimmingCharacters(in: .whitespaces) } == [body],
                "The cell's math is \(latex), not one formula \(body.debugDescription)")

        let presented = TableCellPresentation.attributedContent(for: cell, in: storage, styleSheet: Self.style)
        #expect(attachmentCount(presented) == 1,
                "The cell presents \(presented.string.debugDescription) without one typeset formula")
        #expect(!presented.string.contains("<br") && !presented.string.contains("$$"),
                "Delimiters or breaks leak into \(presented.string.debugDescription)")
    }

    /// The `<br>` handling must not make HTML or currency into math.
    @Test(arguments: ["a <br> b", "$5 <br> $10", "$$ <br> a"])
    func breaksAloneStayOutOfMath(cellSource: String) throws {
        let (cell, storage) = try firstBodyCell("| A | B |\n|---|---|\n| \(cellSource) | text |\n")
        #expect(mathLatex(in: cell, storage: storage).isEmpty, "\(cellSource.debugDescription) became math")
    }

    // MARK: - `\underbrace`

    @Test func underbracedLineFromTheReportTypesets() throws {
        // Control: the arrow between the two braces is already supported.
        try #require(render(#"a\quad\longrightarrow\quad b"#) != nil, "Control: \\longrightarrow failed")
        let line = #"\underbrace{\mathrm dW=\vec F\cdot\mathrm d\vec r}_{\text{small step}}"#
            + #"\quad\longrightarrow\quad\underbrace{W=\int_A^B\vec F\cdot\mathrm d\vec r}_{\text{whole path}}"#
        #expect(render(line) != nil, "The reported \\underbrace line still falls back to source")
    }

    /// Typesetting must keep the brace and put the label under it, not drop
    /// either or turn the label into a trailing subscript.
    @Test func underbraceDrawsABraceWithItsLabelBelow() throws {
        let base = try #require(render("x+y"), "Control: base failed")
        let label = try #require(render(#"\text{label}"#), "Control: label failed")
        let braced = render(#"\underbrace{x+y}"#)
        let labelled = render(#"\underbrace{x+y}_{\text{label}}"#)
        #expect(braced.map { $0.size.height > base.size.height + 1 } == true,
                "No brace below the base: \(String(describing: braced?.size)) vs base \(base.size)")
        if let labelled {
            #expect(labelled.size.height >= base.size.height + label.size.height * 0.5,
                    "The label is not stacked below: \(labelled.size), base \(base.size), label \(label.size)")
            #expect(labelled.size.width < base.size.width + label.size.width * 0.75,
                    "The label sits beside the base: \(labelled.size), base \(base.size), label \(label.size)")
        } else {
            Issue.record("\\underbrace with a label falls back to source")
        }
    }

    // MARK: - Helpers

    private func render(_ latex: String) -> NSImage? {
        MathRenderer.image(latex: latex, display: true, pointSize: 18, color: Self.style.text)
    }

    private func firstBodyCell(_ source: String) throws -> (TableCell, NSAttributedString) {
        let document = MarkdownParser.parse(source)
        let block = try #require(document.root.children.first, "No block parsed")
        guard case .table(let table) = block.content else {
            throw TableFixtureError(source: source)
        }
        let cell = try #require(table.bodyRows.first?.cells.first, "No body cell")
        return (cell, NSAttributedString(string: source))
    }

    private func mathLatex(in cell: TableCell, storage: NSAttributedString) -> [String] {
        var out: [String] = []
        for span in cell.inlines {
            span.walk { inline in
                if case .inlineMath(let latex) = inline.kind {
                    out.append((storage.string as NSString).substring(with: latex))
                }
            }
        }
        return out
    }

    private func attachmentCount(_ text: NSAttributedString) -> Int {
        var count = 0
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length), options: []) { value, _, _ in
            if value is NSTextAttachment { count += 1 }
        }
        return count
    }

    private struct TableFixtureError: Error, CustomStringConvertible {
        let source: String
        var description: String { "Not parsed as a table: \(source.debugDescription)" }
    }
}
