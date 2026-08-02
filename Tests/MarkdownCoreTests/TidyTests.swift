import Foundation
import Testing
@testable import MarkdownCore

@Suite struct TidyTests {

    private func tidied(_ text: String, rules: Set<TidyRule> = Set(TidyRule.allCases)) -> String {
        TidyDocument.plan(MarkdownParser.parse(text), rules: rules).applied(to: text)
    }

    // MARK: Individual rules

    @Test func collapsesSkippedHeadingLevels() {
        let out = tidied("# Title\n\n## Two\n\n#### Four\n\n##### Five\n", rules: [.headingLevels])
        #expect(out == "# Title\n\n## Two\n\n### Four\n\n#### Five\n")
    }

    /// H1 is the document's title.  Re-levelling it changes what the document
    /// *is*, so it is never touched even when a jump would justify it.
    @Test func neverChangesH1() {
        #expect(tidied("### Deep\n\n# Title\n", rules: [.headingLevels]) == "### Deep\n\n# Title\n")
        #expect(tidied("# A\n\n# B\n", rules: [.headingLevels]) == "# A\n\n# B\n")
    }

    @Test func leavesADocumentThatStartsAtH2Alone() {
        #expect(tidied("## A\n\n### B\n", rules: [.headingLevels]) == "## A\n\n### B\n")
    }

    @Test func alignsTablePipesRespectingAlignmentMarkers() {
        let out = tidied("|Name|Count|Notes|\n|:-|-:|:-:|\n|a|1|x|\n|bbbb|22|yy|\n", rules: [.tablePipes])
        #expect(out == """
        | Name | Count | Notes |
        | :--- | ----: | :---: |
        | a    |     1 |   x   |
        | bbbb |    22 |  yy   |

        """)
    }

    @Test func collapsesBlankLineRuns() {
        #expect(tidied("a\n\n\n\n\nb\n", rules: [.blankLines]) == "a\n\nb\n")
        #expect(tidied("a\n\nb\n", rules: [.blankLines]) == "a\n\nb\n")
    }

    @Test func blankLinesInsideCodeFencesAreContent() {
        let text = "```\nx\n\n\n\ny\n```\n"
        #expect(tidied(text, rules: [.blankLines]) == text)
    }

    @Test func addsCodeFenceLanguagesOnlyWhenConfident() {
        #expect(tidied("```\ndef f(self):\n    import os\n```\n", rules: [.codeFenceLanguages])
            == "```python\ndef f(self):\n    import os\n```\n")
        let vague = "```\njust some words\n```\n"
        #expect(tidied(vague, rules: [.codeFenceLanguages]) == vague)
        let tagged = "```text\ndef f(self):\n    import os\n```\n"
        #expect(tidied(tagged, rules: [.codeFenceLanguages]) == tagged)
    }

    @Test func renumbersOrderedLists() {
        #expect(tidied("1. a\n1. b\n1. c\n", rules: [.orderedListNumbers]) == "1. a\n2. b\n3. c\n")
        // A list that deliberately starts at 3 keeps its start.
        #expect(tidied("3. a\n7. b\n", rules: [.orderedListNumbers]) == "3. a\n4. b\n")
    }

    @Test func normalisesListMarkers() {
        #expect(tidied("* a\n* b\n", rules: [.listMarkers]) == "- a\n- b\n")
        #expect(tidied("+ a\n+ b\n", rules: [.listMarkers]) == "- a\n- b\n")
    }

    @Test func trimsTrailingWhitespaceButKeepsHardBreaks() {
        // Exactly two spaces is a deliberate hard line break (§6.4).
        #expect(tidied("line one  \nline two\n", rules: [.trailingWhitespace]) == "line one  \nline two\n")
        #expect(tidied("line one   \nline two\t\n", rules: [.trailingWhitespace]) == "line one\nline two\n")
        #expect(tidied("   \nx\n", rules: [.trailingWhitespace]) == "\nx\n")
    }

    @Test func trailingWhitespaceInsideCodeIsPreserved() {
        let text = "```\nx   \n```\n"
        #expect(tidied(text, rules: [.trailingWhitespace]) == text)
    }

    // MARK: Invariants

    /// A rule that normalises to a form it would then re-normalise produces a
    /// document that never stops changing.  Idempotence is the guard.
    @Test func planIsIdempotentAcrossTheCorpus() {
        for entry in Corpus.all {
            let once = tidied(entry.text)
            let second = TidyDocument.plan(MarkdownParser.parse(once))
            #expect(second.isEmpty, "\(entry.name): second pass wanted \(second.map(\.summary))")
        }
    }

    @Test func eachRuleIsIndividuallyIdempotent() {
        for rule in TidyRule.allCases {
            for entry in Corpus.all {
                let once = tidied(entry.text, rules: [rule])
                let second = TidyDocument.plan(MarkdownParser.parse(once), rules: [rule])
                #expect(second.isEmpty, "\(rule.rawValue) on \(entry.name): \(second.map(\.summary))")
            }
        }
    }

    @Test func editsNeverOverlap() {
        for entry in Corpus.all {
            let edits = TidyDocument.plan(MarkdownParser.parse(entry.text))
            for (a, b) in zip(edits, edits.dropFirst()) {
                #expect(a.range.upperBound <= b.range.location, "\(entry.name): overlapping tidy edits")
            }
        }
    }

    @Test func everyEditIsLabelled() {
        let edits = TidyDocument.plan(MarkdownParser.parse(Corpus.oddSpacing))
        #expect(!edits.isEmpty)
        for edit in edits {
            #expect(!edit.summary.isEmpty)
            #expect(edit.rule != nil)
        }
    }

    @Test func aTidyDocumentGetsNoEdits() {
        let clean = "# Title\n\n## Section\n\nA paragraph.\n\n- one\n- two\n"
        #expect(TidyDocument.plan(MarkdownParser.parse(clean)).isEmpty)
    }

    @Test func selectedRulesOnlyProduceTheirOwnEdits() {
        let edits = TidyDocument.plan(MarkdownParser.parse(Corpus.kitchenSink), rules: [.blankLines])
        #expect(edits.allSatisfy { $0.rule == .blankLines })
    }

    /// The whole point of §9.1: the document is still the same document.
    @Test func tidyPreservesContent() {
        let out = tidied(Corpus.kitchenSink)
        let doc = MarkdownParser.parse(out)
        let original = MarkdownParser.parse(Corpus.kitchenSink)
        #expect(doc.headings.map(\.title) == original.headings.map(\.title))
        #expect(doc.tasks.count == original.tasks.count)
        #expect(doc.frontMatter?["title"] == original.frontMatter?["title"])
    }
}
