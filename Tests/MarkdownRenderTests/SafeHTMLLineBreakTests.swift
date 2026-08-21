import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@Suite("Safe HTML line breaks")
@MainActor
struct SafeHTMLLineBreakTests {
    @Test("safe br tags render as breaks without changing source coordinates")
    func safeLineBreakPreservesSourceCoordinates() throws {
        let source = "<p>first<br>second</p>"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            storage: storage
        )
        let document = MarkdownParser.parse(source)
        view.update(document: document, dirty: .wholesale)

        let breakRange = (source as NSString).range(of: "<br>")
        let entry = try #require(
            view.currentDisplayMap.substitutions(in: breakRange).first
        )
        #expect(entry.sourceRange == breakRange)
        #expect(entry.displayLength == breakRange.length)
        #expect(entry.replacement?.string.first == "\n")
        #expect(entry.isHidden == false)
        #expect(entry.preservesSourceOffsets)
    }

    @Test("source mode leaves safe HTML tags literal")
    func sourceModeLeavesTagsLiteral() throws {
        let source = "<p>first<br>second</p>"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            storage: storage
        )
        view.mode = .source
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)

        let breakRange = (source as NSString).range(of: "<br>")
        #expect(view.currentDisplayMap.substitutions(in: breakRange).isEmpty)
    }

    @Test("scoped source focus reveals a safe br tag literally")
    func scopedSourceFocusRevealsTag() throws {
        let source = "<p>first<br>second</p>"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            storage: storage
        )
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)

        let breakRange = (source as NSString).range(of: "<br>")
        view.focusSource(in: breakRange)
        #expect(view.currentDisplayMap.substitutions(in: breakRange).isEmpty)
    }

    @Test("details preserves source offsets and shows its authored disclosure state")
    func detailsDisclosureSubstitution() throws {
        let source = "<details><summary>More</summary>Body</details>"
        let document = MarkdownParser.parse(source)
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            storage: storage
        )
        view.update(document: document, dirty: .wholesale)

        let details = try #require(document.root.children.first?.safeHTML?.annotations.first {
            if case .details = $0.kind { return true }
            return false
        })
        let substitution = try #require(
            view.currentDisplayMap.substitutions(in: details.tagRanges[0]).first
        )
        #expect(substitution.sourceRange == details.tagRanges[0])
        #expect(substitution.displayLength == details.tagRanges[0].length)
        #expect(substitution.replacement?.string.first == "▸")
        #expect(substitution.preservesSourceOffsets)
    }

    @Test("multiline details keeps all disclosure tags out of Document display")
    func multilineDetailsDisclosureSubstitution() throws {
        let source = """
        <details>
        <summary>More</summary>

        Body

        </details>
        """
        let document = MarkdownParser.parse(source)
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 640, height: 480), storage: storage)
        view.update(document: document, dirty: .wholesale)
        let tags = ["<details>", "<summary>", "</summary>", "</details>"]
        for tag in tags {
            let range = (source as NSString).range(of: tag)
            #expect(view.currentDisplayMap.substitutions(in: range).isEmpty == false, "missing substitution for \(tag)")
        }
    }

    @Test("HTML table rows receive source-preserving line breaks")
    func tableRowsDoNotConcatenate() throws {
        let source = "<table><tr><td>A</td><td>B</td></tr><tr><td>C</td><td>D</td></tr></table>"
        let document = MarkdownParser.parse(source)
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            storage: storage
        )
        view.update(document: document, dirty: .wholesale)

        let rows = document.root.children.first?.safeHTML?.annotations.filter {
            if case .tableRow = $0.kind { return true }
            return false
        } ?? []
        #expect(rows.count == 2)
        for row in rows {
            let closing = try #require(row.tagRanges.last)
            let substitution = try #require(
                view.currentDisplayMap.substitutions(in: closing).first
            )
            #expect(substitution.sourceRange == closing)
            #expect(substitution.replacement?.string.first == "\n")
            #expect(substitution.preservesSourceOffsets)
        }
    }
}
