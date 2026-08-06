import Foundation
import Testing
@testable import MarkdownCore

@Suite struct StructuralZoomTests {

    private let document = """
    # Title

    Opening sentence. Second sentence of the intro.

    ## Alpha

    Alpha's first sentence. Alpha's second sentence goes on for a while.

    ```swift
    let x = 1
    ```

    ### Alpha detail

    Detail prose here.

    | a | b |
    | --- | --- |
    | 1 | 2 |

    ## Beta

    Beta prose. More beta prose.

    - [ ] a task
    - [x] another task

    Closing prose sentence. Another closing sentence.

    * plain bullet
    * another plain bullet
    """

    private func visibleText(_ plan: ZoomPlan, in text: String) -> String {
        let ns = text as NSString
        return plan.visibleRanges.map { ns.substring(with: $0) }.joined()
    }

    private func assertWellFormed(_ plan: ZoomPlan, length: Int) {
        for (a, b) in zip(plan.visibleRanges, plan.visibleRanges.dropFirst()) {
            #expect(a.upperBound <= b.location, "visible ranges must be ascending and disjoint")
        }
        for range in plan.visibleRanges + plan.elidedRanges {
            #expect(range.location >= 0)
            #expect(range.upperBound <= length)
            #expect(range.length > 0)
        }
        // Together they must tile the document exactly once.
        let total = (plan.visibleRanges + plan.elidedRanges).reduce(0) { $0 + $1.length }
        #expect(total == length)
    }

    @Test func levelFiveIsTheIdentity() {
        let doc = MarkdownParser.parse(document)
        let plan = StructuralZoom.plan(doc, level: .everything)
        #expect(plan.isIdentity)
    }

    @Test func levelOneKeepsOnlyH1() {
        let doc = MarkdownParser.parse(document)
        let plan = StructuralZoom.plan(doc, level: .h1)
        assertWellFormed(plan, length: doc.length)
        let visible = visibleText(plan, in: document)
        #expect(visible.contains("# Title"))
        #expect(!visible.contains("## Alpha"))
        #expect(!visible.contains("Opening sentence"))
    }

    @Test func levelTwoAddsH2() {
        let doc = MarkdownParser.parse(document)
        let plan = StructuralZoom.plan(doc, level: .h2)
        assertWellFormed(plan, length: doc.length)
        let visible = visibleText(plan, in: document)
        #expect(visible.contains("## Alpha"))
        #expect(visible.contains("## Beta"))
        #expect(!visible.contains("### Alpha detail"))
    }

    @Test func levelThreeKeepsAllHeadings() {
        let doc = MarkdownParser.parse(document)
        let plan = StructuralZoom.plan(doc, level: .headings)
        assertWellFormed(plan, length: doc.length)
        let visible = visibleText(plan, in: document)
        for heading in doc.headings {
            #expect(visible.contains(heading.title), "missing \(heading.title)")
        }
        #expect(!visible.contains("Detail prose"))
    }

    /// §5.2: "every claim's headline plus all the concrete artifacts, and none
    /// of the connective padding."
    @Test func skeletonKeepsHeadingsFirstSentencesAndArtifacts() {
        let doc = MarkdownParser.parse(document)
        let plan = StructuralZoom.plan(doc, level: .skeleton)
        assertWellFormed(plan, length: doc.length)
        let visible = visibleText(plan, in: document)

        for heading in doc.headings { #expect(visible.contains(heading.title)) }
        #expect(visible.contains("let x = 1"))
        #expect(visible.contains("| 1 | 2 |"))
        #expect(visible.contains("- [ ] a task"))
        #expect(visible.contains("Alpha's first sentence."))
        // The connective padding goes: a plain bullet list is not an artifact,
        // and only a section's *first* sentence survives.
        #expect(!visible.contains("plain bullet"))
        #expect(!visible.contains("Closing prose sentence"))
    }

    @Test func skeletonKeepsTheLedeOfADocumentWithoutHeadings() {
        let text = "First sentence here. Second sentence. Third one too.\n\nAnother paragraph entirely.\n"
        let doc = MarkdownParser.parse(text)
        let plan = StructuralZoom.plan(doc, level: .skeleton)
        assertWellFormed(plan, length: doc.length)
        #expect(visibleText(plan, in: text).contains("First sentence here."))
    }

    @Test func frontMatterSurvivesEveryLevel() {
        let text = "---\ntitle: X\n---\n\n# H\n\nbody\n"
        let doc = MarkdownParser.parse(text)
        for level in [ZoomLevel.h1, .h2, .headings, .skeleton] {
            let plan = StructuralZoom.plan(doc, level: level)
            assertWellFormed(plan, length: doc.length)
            #expect(visibleText(plan, in: text).contains("title: X"), "level \(level.rawValue)")
        }
    }

    @Test func everyCorpusDocumentPlansCleanlyAtEveryLevel() {
        for entry in Corpus.all {
            let doc = MarkdownParser.parse(entry.text)
            for level in ZoomLevel.allCases {
                let plan = StructuralZoom.plan(doc, level: level)
                if level == .everything { continue }
                assertWellFormed(plan, length: doc.length)
            }
        }
    }
}

@Suite struct MetricsTests {

    @Test func countsWordsExcludingMarkersCodeAndFrontMatter() {
        let text = """
        ---
        title: Ignore these words entirely
        ---

        # One Two

        Three **four** five `six` seven.

        ```swift
        this code should not be counted at all here
        ```
        """
        let metrics = Metrics.metrics(for: text)
        // "One Two" + "Three four five six seven" = 7 words.
        #expect(metrics.words == 7)
        #expect(metrics.readMinutes == 7.0 / 238.0)
    }

    @Test func readTimeUses238WordsPerMinute() {
        let prose = (0..<238).map { "word\($0)" }.joined(separator: " ") + "\n"
        let metrics = Metrics.metrics(for: prose)
        #expect(metrics.words == 238)
        #expect(abs(metrics.readMinutes - 1.0) < 0.0001)
    }

    /// §9.6 regression: soft and hard line breaks inside a paragraph must count
    /// as word separators, not vanish and merge their lines into run-on words.
    @Test func hardWrappedParagraphsCountEveryWord() {
        let disposed = Metrics.metrics(for: "alpha beta\ngamma delta\n")
        #expect(disposed.words == 4)
        // A two-space hard break is still a single word gap.
        let spaces = Metrics.metrics(for: "one two  \nthree four\n")
        #expect(spaces.words == 4)
        let paragraph = MarkdownParser.parse("one two  \nthree four\n").root.children.first
        #expect(paragraph?.inlines.contains { if case .lineBreak = $0.kind { return true }; return false } == true)
    }

    @Test func hardWrapBreaksBecomeBreakSpans() {
        let source = "alpha beta\ngamma delta\n"
        let doc = MarkdownParser.parse(source)
        let paragraph = try! #require(doc.root.children.first)
        let kinds = paragraph.inlines.map(\.kind)
        #expect(kinds.contains { if case .softBreak = $0 { return true }; return false })
        #expect(kinds.contains(where: { if case .text = $0 { return true }; return false }))
    }

    @Test func explicitLineBreaksAreClassifiedLineBreakSpans() {
        let doc = MarkdownParser.parse("one  \ntwo\n")
        let paragraph = try! #require(doc.root.children.first)
        #expect(paragraph.inlines.contains { if case .lineBreak = $0.kind { return true }; return false })
    }

    /// §9.6 regression: swift-markdown anchors the continuation Text of a
    /// backslash hard break at the newline with a zero-length range (the line
    /// advance is lost), collapsing the rest of the line into one run-on word.
    /// `fillBreaks` must re-anchor it to the physical next line.
    @Test func backslashHardBreaksCountEveryWord() {
        let disposed = Metrics.metrics(for: "one two\\\nthree four\n")
        #expect(disposed.words == 4, "word count was \(disposed.words)")
        let doc = MarkdownParser.parse("one two\\\nthree four\n")
        let paragraph = try! #require(doc.root.children.first)
        let kinds = paragraph.inlines.map(\.kind)
        #expect(kinds.contains { if case .lineBreak = $0 { return true }; return false })
        let source = doc.text as NSString
        let three = paragraph.inlines.first {
            guard case .text = $0.kind else { return false }
            return source.substring(with: $0.range) == "three four"
        }
        #expect(three != nil)
    }

    @Test func emptyTextIsZero() {
        #expect(Metrics.metrics(for: "").words == 0)
        #expect(Metrics.metrics(for: "").readMinutes == 0)
    }

    /// §9.6: per-section read time is what tells you where the bulk of a
    /// document actually is, so a section must not count its subsections.
    @Test func sectionMetricsAreParallelAndExcludeSubsections() {
        let text = """
        # Top

        One two three.

        ## Sub

        Four five six seven eight.

        # Second

        Nine.
        """
        let doc = MarkdownParser.parse(text)
        let sections = Metrics.sectionMetrics(doc)
        #expect(sections.count == doc.headings.count)
        #expect(sections[0].words == 3)
        #expect(sections[1].words == 5)
        #expect(sections[2].words == 1)
    }

    @Test func headingWordCountsMatchSectionMetrics() {
        let doc = MarkdownParser.parse(Corpus.kitchenSink)
        let sections = Metrics.sectionMetrics(doc)
        #expect(doc.headings.map(\.wordCount) == sections.map(\.words))
    }

    @Test func firstSentenceUsesNLTokenizerNotNaivePeriods() {
        let text = "# H\n\nDr. Smith went to Washington. Then he left.\n"
        let doc = MarkdownParser.parse(text)
        let body = NSRange(location: doc.headings[0].range.upperBound,
                           length: doc.length - doc.headings[0].range.upperBound)
        let range = Metrics.firstSentenceRange(in: doc, within: body)
        #expect(range != nil)
        #expect(doc.substring(range!).trimmingCharacters(in: .whitespaces)
            == "Dr. Smith went to Washington.")
    }

    @Test func firstSentenceSkipsNonProseBlocks() {
        let text = "# H\n\n```swift\nlet x = 1\n```\n\nActual prose here. More.\n"
        let doc = MarkdownParser.parse(text)
        let body = NSRange(location: doc.headings[0].range.upperBound,
                           length: doc.length - doc.headings[0].range.upperBound)
        let range = Metrics.firstSentenceRange(in: doc, within: body)
        #expect(doc.substring(range ?? NSRange(location: 0, length: 0))
            .trimmingCharacters(in: .whitespaces) == "Actual prose here.")
    }

    @Test func metricsRunOnEveryCorpusDocument() {
        for entry in Corpus.all {
            let metrics = Metrics.metrics(for: entry.text)
            #expect(metrics.words >= 0)
            #expect(metrics.characters >= metrics.words)
        }
    }
}
