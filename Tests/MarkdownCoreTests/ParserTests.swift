import Foundation
import Testing
@testable import MarkdownCore

@Suite struct SourcePositionTests {

    /// swift-markdown's column is documented as a byte offset; the render layer
    /// hands ranges straight to `NSTextStorage`, so this is pinned down rather
    /// than assumed.
    @Test func columnsAreUTF8BytesConvertedToUTF16() {
        let text = "héllo *wörld*\n日本語 text\n"
        let map = SourceMap(text)
        // "héllo " is 6 characters but 7 UTF-8 bytes; cmark reports column 8
        // for the `*` that follows it, which is UTF-16 offset 6.
        #expect(map.offset(line: 1, column: 8) == 6)
        #expect(map.offset(line: 1, column: 1) == 0)
        // Line 2 starts after "héllo *wörld*\n" = 14 UTF-16 units.
        #expect(map.offset(line: 2, column: 1) == 14)
        // "日本語" is 9 UTF-8 bytes, 3 UTF-16 units.
        #expect(map.offset(line: 2, column: 10) == 17)
    }

    @Test func tabsCountAsOneByte() {
        let map = SourceMap("\tindented\n")
        #expect(map.offset(line: 1, column: 2) == 1)
        #expect(map.offset(line: 1, column: 10) == 9)
    }

    @Test func lineIndexHandlesEveryTerminator() {
        let map = SourceMap("a\r\nb\rc\nd")
        #expect(map.lineCount == 4)
        #expect(map.string(ofLine: 0) == "a")
        #expect(map.string(ofLine: 1) == "b")
        #expect(map.string(ofLine: 2) == "c")
        #expect(map.string(ofLine: 3) == "d")
    }

    @Test func trailingNewlineProducesAVirtualFinalLine() {
        let map = SourceMap("a\n")
        #expect(map.lineCount == 2)
        #expect(map.contentRange(ofLine: 1).length == 0)
    }
}

@Suite struct ParserTests {

    /// Every block's range must be in bounds and its content range inside it.
    /// This is the invariant the decorator relies on for every fragment it
    /// builds, so it is checked over the whole corpus.
    @Test func rangesAreWellFormedAcrossTheCorpus() {
        for entry in Corpus.all {
            let doc = MarkdownParser.parse(entry.text)
            doc.root.walk { block in
                #expect(block.range.location >= 0, "\(entry.name)")
                #expect(block.range.upperBound <= doc.length, "\(entry.name): \(block.content)")
                #expect(block.contentRange.location >= block.range.location, "\(entry.name): \(block.content)")
                #expect(block.contentRange.upperBound <= block.range.upperBound, "\(entry.name): \(block.content)")
                if let marker = block.markerRange {
                    #expect(marker.location >= block.range.location, "\(entry.name): \(block.content)")
                    #expect(marker.upperBound <= block.range.upperBound, "\(entry.name): \(block.content)")
                }
                if let trailing = block.trailingMarkerRange {
                    #expect(trailing.upperBound <= block.range.upperBound, "\(entry.name): \(block.content)")
                }
                for span in block.inlines {
                    span.walk { inline in
                        #expect(inline.range.upperBound <= doc.length, "\(entry.name)")
                        #expect(inline.contentRange.location >= inline.range.location, "\(entry.name)")
                        #expect(inline.contentRange.upperBound <= inline.range.upperBound, "\(entry.name)")
                    }
                }
                // The decorator walks siblings in order and assumes it never
                // has to back up or resolve an overlap.
                for (a, b) in zip(block.inlines, block.inlines.dropFirst()) {
                    #expect(a.range.upperBound <= b.range.location, "\(entry.name): overlapping inline spans")
                }
                for (a, b) in zip(block.children, block.children.dropFirst()) {
                    #expect(a.range.upperBound <= b.range.location, "\(entry.name): overlapping child blocks")
                }
            }
        }
    }

    @Test func substringRoundTripsThroughBlockRanges() {
        let doc = MarkdownParser.parse(Corpus.kitchenSink)
        // Each block's range must actually name its own source text.
        let heading = doc.root.children.first { $0.headingLevel == 1 }
        #expect(heading != nil)
        #expect(doc.substring(heading!.range) == "# Release Plan")
        #expect(doc.substring(heading!.markerRange!) == "# ")
        #expect(doc.substring(heading!.contentRange) == "Release Plan")
    }

    /// §6.1a: the gutter renders the leading marker, so `markerRange` must be
    /// exactly the marker plus its trailing space.
    @Test func markerRangesCoverTheLeadingBlockMarker() {
        let text = "## Heading\n\n> quoted\n\n- bullet\n\n1. numbered\n\n- [ ] task\n"
        let doc = MarkdownParser.parse(text)
        var markers: [String] = []
        doc.root.walk { block in
            guard let marker = block.markerRange else { return }
            switch block.content {
            case .heading, .blockQuote, .listItem: markers.append(doc.substring(marker))
            default: break
            }
        }
        #expect(markers == ["## ", "> ", "- ", "1. ", "- [ ] "])
    }

    @Test func setextHeadingsCarryTheirUnderlineAsTrailingMarker() {
        let doc = MarkdownParser.parse("Title\n=====\n\nBody.\n")
        let heading = doc.root.children.first!
        #expect(heading.headingLevel == 1)
        #expect(heading.markerRange == nil)
        #expect(doc.substring(heading.trailingMarkerRange!) == "=====")
        #expect(doc.substring(heading.contentRange) == "Title")
    }

    @Test func closingHashesBecomeATrailingMarker() {
        let doc = MarkdownParser.parse("## Heading ##\n")
        let heading = doc.root.children.first!
        #expect(doc.substring(heading.range) == "## Heading ##")
        #expect(doc.substring(heading.markerRange!) == "## ")
        #expect(doc.substring(heading.trailingMarkerRange!) == " ##")
    }

    @Test func fencedCodeSplitsIntoFenceContentFence() {
        let doc = MarkdownParser.parse("```swift\nlet x = 1\n```\n")
        let block = doc.root.children.first!
        guard case .codeBlock(let language, let isFenced, let content) = block.content else {
            Issue.record("expected a code block, got \(block.content)")
            return
        }
        #expect(language == "swift")
        #expect(isFenced)
        #expect(doc.substring(content) == "let x = 1\n")
        #expect(doc.substring(block.markerRange!) == "```swift\n")
        #expect(doc.substring(block.trailingMarkerRange!) == "```")
    }

    /// CommonMark: a closing fence "may be followed only by spaces or tabs,
    /// which are ignored".  The recovery used to reject a closer carrying
    /// trailing whitespace, swallow it into the content, and render it inside
    /// the block (and copy it, and feed it to math/Mermaid sources).
    @Test func closingFenceMayCarryTrailingWhitespace() {
        let doc = MarkdownParser.parse("```swift\nlet x = 1\n``` \n")
        let block = doc.root.children.first!
        guard case .codeBlock(_, let isFenced, let content) = block.content else {
            Issue.record("expected a code block, got \(block.content)")
            return
        }
        #expect(isFenced)
        #expect(doc.substring(content) == "let x = 1\n")
        #expect(doc.substring(block.trailingMarkerRange!) == "``` ")
    }

    /// CommonMark: "The closing code fence must be at least as long as the
    /// opening fence."  Inside an unclosed four-backtick block a three-backtick
    /// line is *content*; the recovery used to treat it as the closer and hide
    /// it as chrome.
    @Test func shortFenceLineInsideLongerUnclosedFenceIsContent() {
        let doc = MarkdownParser.parse("````\ncode\n```\nmore\n")
        let block = doc.root.children.first!
        guard case .codeBlock(_, let isFenced, let content) = block.content else {
            Issue.record("expected a code block, got \(block.content)")
            return
        }
        #expect(isFenced)
        #expect(doc.substring(content) == "code\n```\nmore")
        #expect(block.trailingMarkerRange == nil)
    }

    @Test func indentedCodeIsNotFenced() {
        let doc = MarkdownParser.parse("    indented\n    more\n")
        guard case .codeBlock(_, let isFenced, _) = doc.root.children.first!.content else {
            Issue.record("expected a code block")
            return
        }
        #expect(!isFenced)
    }

    /// A fence nested inside a blockquote has `> ` prefixes on every line; the
    /// raw line starts with `>`, so plain whitespace trimming would miss the
    /// fence entirely and drop its marker ranges.
    @Test func quotedFencedCodeKeepsItsMarkers() {
        let doc = MarkdownParser.parse("> ```swift\n> let x = 1\n> ```\n")
        let quote = doc.root.children.first!
        let block = quote.children.first!
        guard case .codeBlock(let language, let isFenced, let content) = block.content else {
            Issue.record("expected a code block inside the quote, got \(block.content)")
            return
        }
        #expect(language == "swift")
        #expect(isFenced)
        // The opening marker is the fence's own characters (the block's range
        // starts at the backtick); the closing marker runs from the line start,
        // so it keeps the `> ` prefix — same convention as a list-nested
        // fence keeping its indent.
        #expect(doc.substring(block.markerRange!) == "```swift\n")
        #expect(doc.substring(block.trailingMarkerRange!) == "> ```")
        #expect(doc.substring(content) == "> let x = 1\n")
    }

    @Test func deeplyNestedQuotedFenceStillResolves() {
        let doc = MarkdownParser.parse("> > ```\n> > code\n> > ```\n")
        let outer = doc.root.children.first!
        let inner = outer.children.first!
        let block = inner.children.first!
        guard case .codeBlock(_, let isFenced, _) = block.content else {
            Issue.record("expected a code block, got \(block.content)")
            return
        }
        #expect(isFenced)
        #expect(doc.substring(block.trailingMarkerRange!) == "> > ```")
    }

    @Test func tasksAreCollectedWithSingleCharacterMarkRanges() {
        let doc = MarkdownParser.parse("## Work\n\n- [ ] alpha\n- [x] beta\n  - [ ] nested\n")
        #expect(doc.tasks.count == 3)
        #expect(doc.tasks.map(\.isChecked) == [false, true, false])
        for task in doc.tasks {
            #expect(task.markRange.length == 1)
            #expect(["x", " "].contains(doc.substring(task.markRange).lowercased()))
        }
        // A task's label ends at its own line terminator: the parent never
        // swallows its nested children's text (§8.5).
        #expect(doc.tasks.map(\.text) == ["alpha", "beta", "nested"])
        #expect(doc.tasks.allSatisfy { $0.headingIndex == 0 })
        #expect(doc.tasks[2].indentLevel == 1)
    }

    @Test func outlineLinksParentsAndSections() {
        let doc = MarkdownParser.parse("# A\n\ntext\n\n## B\n\nmore\n\n### C\n\ndeep\n\n## D\n\nend\n")
        #expect(doc.headings.map(\.title) == ["A", "B", "C", "D"])
        #expect(doc.headings.map(\.level) == [1, 2, 3, 2])
        #expect(doc.headings.map(\.parentIndex) == [nil, 0, 1, 0])
        #expect(doc.headings[0].childIndices == [1, 3])
        // B's section covers B, C and their bodies but stops at D.
        #expect(doc.substring(doc.headings[1].sectionRange) == "## B\n\nmore\n\n### C\n\ndeep\n\n")
        #expect(doc.headings.map(\.slug) == ["a", "b", "c", "d"])
    }

    @Test func duplicateHeadingsGetDistinctSlugs() {
        let doc = MarkdownParser.parse("# Setup\n\n## Setup\n\n## Setup\n")
        #expect(doc.headings.map(\.slug) == ["setup", "setup-1", "setup-2"])
    }

    @Test func linkReferenceDefinitionsAreRecovered() {
        let doc = MarkdownParser.parse("[ref]: https://example.com \"Title\"\n\nSee [ref].\n")
        #expect(doc.linkReferences["ref"]?.destination == "https://example.com")
        #expect(doc.linkReferences["ref"]?.title == "Title")
    }

    @Test func footnoteDefinitionsAndReferencesSurvive() {
        let doc = MarkdownParser.parse("Body text.[^1]\n\n[^1]: The note.\n")
        #expect(doc.footnotes["1"] != nil)
        var referenced = false
        doc.root.walk { block in
            for span in block.inlines {
                span.walk { inline in
                    if case .footnoteReference(let id) = inline.kind, id == "1" { referenced = true }
                }
            }
        }
        #expect(referenced)
    }

    /// Regression: a line inside an outer fence that starts with a shorter
    /// fence run plus an info string (`\`\`\`ruby` inside `\`\`\`\`) is content,
    /// not a closer.  The source scanner used to close on it and then read a
    /// footnote-looking line *inside* the fence as a real definition.
    @Test func fencedExampleCodeWithInfoStringsHidesFootnoteLookingLines() {
        let doc = MarkdownParser.parse(
            "````markdown\n```ruby\n[^inner]: not a definition\n```\n````\n"
        )
        #expect(doc.footnotes["inner"] == nil)
        #expect(doc.root.children.count == 1, "the whole construct is one code block")
    }

    /// Regression: when a footnote definition's body parses as a bare URL,
    /// cmark consumes the definition line and gives the indented continuation
    /// to a code block.  The synthesized footnote block used to cover both
    /// lines and overlap that sibling — top-level children never overlap.
    @Test func synthesizedFootnoteBlockDoesNotOverlapItsSibling() {
        let doc = MarkdownParser.parse("[^a]: first\n    continued\n")
        // The definition itself is still recognized…
        #expect(doc.footnotes["a"] != nil)
        // …and no two top-level blocks claim the same bytes.
        let children = doc.root.children
        for (index, block) in children.enumerated() {
            if index + 1 < children.count {
                #expect(block.range.upperBound <= children[index + 1].range.location)
            }
        }
    }

    @Test func tablesCarryRowsCellsAndAlignments() {
        let doc = MarkdownParser.parse("| a | b | c |\n|:--|:-:|--:|\n| 1 | 2 | 3 |\n")
        guard case .table(let table) = doc.root.children.first!.content else {
            Issue.record("expected a table")
            return
        }
        #expect(table.alignments == [.left, .center, .right])
        #expect(table.rows.count == 2)
        #expect(table.headerRow != nil)
        #expect(table.columnCount == 3)
        #expect(doc.substring(table.delimiterRange) == "|:--|:-:|--:|")
        #expect(doc.substring(table.rows[0].cells[1].contentRange) == "b")
    }

    @Test func blockQuoteDepthIsTracked() {
        let doc = MarkdownParser.parse("> outer\n>\n> > inner\n")
        var depths: [Int] = []
        doc.root.walk { block in
            if case .paragraph = block.content { depths.append(block.quoteDepth) }
        }
        #expect(depths.contains(1))
        #expect(depths.contains(2))
    }

    @Test func emptyDocumentIsSafe() {
        let doc = MarkdownParser.parse("")
        #expect(doc.length == 0)
        #expect(doc.headings.isEmpty)
        #expect(doc.root.children.isEmpty)
    }

    @Test func smartPunctuationIsNeverApplied() {
        // §3.1 and §6.4: the bytes are the truth and quotes stay straight.
        let text = "He said \"hello\" -- really.\n"
        let doc = MarkdownParser.parse(text)
        #expect(doc.text == text)
        let paragraph = doc.root.children.first!
        #expect(doc.substring(paragraph.contentRange).contains("\"hello\""))
        #expect(doc.substring(paragraph.contentRange).contains("--"))
    }

    @Test func inlineMarkersAreExactlyTheDelimiters() {
        let doc = MarkdownParser.parse("a **bold** and _em_ and ~~x~~ and `c` here\n")
        var pairs: [String] = []
        for span in doc.root.children[0].inlines {
            span.walk { inline in
                guard inline.kind.revealsMarkers else { return }
                for marker in inline.markerRanges { pairs.append(doc.substring(marker)) }
            }
        }
        #expect(pairs == ["**", "**", "_", "_", "~~", "~~", "`", "`"])
    }
}
