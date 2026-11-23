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

    @Test(arguments: [#"$$ <br> 30^\circ <br> $$"#, #"$$<br>+5\,J<br>$$"#, #"$$ <br/> \Delta x <br /> $$"#,
                      #"$$<BR>x^2<BR>$$"#])
    func breakPaddedDisplayMathInACellIsTypeset(cellSource: String) throws {
        let source = "| Angle | Note |\n|---|---|\n| \(cellSource) | text |\n"
        let (cell, storage) = try firstBodyCell(source)
        let latex = mathLatex(in: cell, storage: storage)
        let body = cellSource
            .replacingOccurrences(of: "$$", with: "")
            .replacingOccurrences(of: "<br />", with: "")
            .replacingOccurrences(of: "<br/>", with: "")
            .replacingOccurrences(of: "<br>", with: "")
            .replacingOccurrences(of: "<BR>", with: "")
            .trimmingCharacters(in: .whitespaces)
        #expect(latex.map { $0.trimmingCharacters(in: .whitespaces) } == [body],
                "The cell's math is \(latex), not one formula \(body.debugDescription)")
        // Source offsets stay exact: the formula spans the cell's own bytes.
        let text = storage.string as NSString
        #expect(cell.inlines.count == 1 && cell.inlines.first.map { text.substring(with: $0.range) } == cellSource,
                "The formula does not cover exactly \(cellSource.debugDescription)")

        let presented = TableCellPresentation.attributedContent(for: cell, in: storage, styleSheet: Self.style)
        #expect(attachmentCount(presented) == 1,
                "The cell presents \(presented.string.debugDescription) without one typeset formula")
        #expect(!presented.string.contains("<br") && !presented.string.contains("$$"),
                "Delimiters or breaks leak into \(presented.string.debugDescription)")
    }

    /// The `<br>` handling must not make other HTML, code or currency into math.
    @Test(arguments: ["a <br> b", "$5 <br> $10", "$$ <br> a", "$$ <br> `x` <br> $$", "$$ <b> x </b> $$"])
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
        #expect(braced.map { $0.size.width >= base.size.width - 0.5 } == true,
                "The braced argument is narrower than the argument: \(String(describing: braced?.size)) vs \(base.size)")
        if let labelled {
            #expect(labelled.size.height >= base.size.height + label.size.height * 0.5,
                    "The label is not stacked below: \(labelled.size), base \(base.size), label \(label.size)")
            #expect(labelled.size.width < base.size.width + label.size.width * 0.75,
                    "The label sits beside the base: \(labelled.size), base \(base.size), label \(label.size)")
        } else {
            Issue.record("\\underbrace with a label falls back to source")
        }
        // A label narrower than the brace sits centred under it, inside its width.
        if let short = render(#"\underbrace{x+y}_{n}"#), let braced {
            #expect(abs(short.size.width - braced.size.width) < 1,
                    "A short label widened the formula: \(short.size) vs \(braced.size)")
        } else {
            Issue.record("\\underbrace with a short label falls back to source")
        }
    }

    /// Past the widest brace variant (4 em) the brace is assembled from the
    /// font's pieces, so its ink still spans the whole argument.
    @Test func wideUnderbraceSpansItsArgument() throws {
        let argument = "a+b+c+d+e+f+g+h+i+j+k+l"
        let base = try #require(render(argument), "Control: base failed")
        try #require(base.size.width > 4 * 18 * 1.2, "The fixture must be wider than the widest variant: \(base.size)")
        let braced = try #require(render("\\underbrace{\(argument)}"), "A wide \\underbrace falls back to source")
        let band = Int((braced.size.height - base.size.height).rounded(.down))
        try #require(band > 2, "No room below the argument for a brace: \(braced.size) vs \(base.size)")
        let coverage = try inkedColumnFraction(of: braced, bottomRows: band)
        #expect(coverage >= 0.9,
                "The brace covers \(Int(coverage * 100))% of a \(Int(braced.size.width))pt argument")
    }

    /// Malformed input keeps the existing source fallback; an empty argument
    /// is not malformed and still draws its brace and label.
    @Test func unbalancedUnderbraceStillFallsBack() {
        #expect(render(#"\underbrace{x+y"#) == nil)
        #expect(render(#"\underbrace{}_{n}"#) != nil, "An empty \\underbrace argument failed to typeset")
    }

    // MARK: - Helpers

    private func render(_ latex: String) -> NSImage? {
        MathRenderer.image(latex: latex, display: true, pointSize: 18, color: Self.style.text)
    }

    /// Fraction of pixel columns with ink in the bottom `rows` of `image` at 1x.
    private func inkedColumnFraction(of image: NSImage, bottomRows rows: Int) throws -> Double {
        let width = Int(image.size.width.rounded(.up)), height = Int(image.size.height.rounded(.up))
        let context = try #require(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        let pixels = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        // Bitmap memory starts at the top row.
        var inked = 0
        for column in 0..<width {
            for row in max(0, height - rows)..<height where pixels[row * context.bytesPerRow + column * 4 + 3] > 0 {
                inked += 1
                break
            }
        }
        return Double(inked) / Double(max(1, width))
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
