import Foundation
import Testing
@testable import MarkdownCore

@Suite struct ASTDiffTests {

    @Test func firstParseIsWholesale() {
        let doc = MarkdownParser.parse("# A\n")
        #expect(ASTDiff.dirtySet(old: nil, new: doc).isWholesale)
    }

    @Test func identicalTextIsClean() {
        let text = Corpus.kitchenSink
        let a = MarkdownParser.parse(text)
        let b = MarkdownParser.parse(text)
        #expect(ASTDiff.dirtySet(old: a, new: b).isEmpty)
    }

    /// §3.5's whole premise: full reparse is affordable because only the
    /// changed blocks are re-decorated.  Editing one paragraph of a 200-block
    /// document must dirty exactly that paragraph.
    @Test func editingOneParagraphDirtiesOneBlock() {
        let original = Corpus.manyBlocks(count: 200)
        let edited = original.replacingOccurrences(
            of: "Paragraph number 101 with some words in it.",
            with: "Paragraph number 101 with different words in it."
        )
        #expect(original != edited)

        let old = MarkdownParser.parse(original)
        let new = MarkdownParser.parse(edited)
        let dirty = ASTDiff.dirtySet(old: old, new: new)

        #expect(!dirty.isWholesale)
        #expect(dirty.ranges.count == 1)
        #expect(new.substring(dirty.ranges[0]) == "Paragraph number 101 with different words in it.")
    }

    /// An insertion near the top must not dirty everything after it, which is
    /// what a positional walk would produce.
    @Test func insertionNearTheTopStaysLocal() {
        let original = Corpus.manyBlocks(count: 200)
        let edited = original.replacingOccurrences(
            of: "Paragraph number 1 with some words in it.\n",
            with: "Paragraph number 1 with some words in it.\n\nA brand new paragraph.\n"
        )
        let old = MarkdownParser.parse(original)
        let new = MarkdownParser.parse(edited)
        let dirty = ASTDiff.dirtySet(old: old, new: new)

        #expect(!dirty.isWholesale)
        #expect(dirty.ranges.count == 1)
        #expect(new.substring(dirty.ranges[0]) == "A brand new paragraph.")
    }

    @Test func editInsideAListItemDirtiesTheItemNotTheList() {
        let old = MarkdownParser.parse("# H\n\n- one\n- two\n- three\n")
        let new = MarkdownParser.parse("# H\n\n- one\n- TWO\n- three\n")
        let dirty = ASTDiff.dirtySet(old: old, new: new)
        #expect(!dirty.isWholesale)
        #expect(dirty.ranges.count == 1)
        #expect(new.substring(dirty.ranges[0]) == "TWO")
    }

    @Test func majorStructuralChangeGoesWholesale() {
        let old = MarkdownParser.parse(Corpus.manyBlocks(count: 40))
        let new = MarkdownParser.parse("# Completely different\n")
        #expect(ASTDiff.dirtySet(old: old, new: new).isWholesale)
    }

    @Test func dirtyRangesAreAscendingAndDisjoint() {
        let original = Corpus.manyBlocks(count: 60)
        let edited = original
            .replacingOccurrences(of: "Paragraph number 3 ", with: "Paragraph number three ")
            .replacingOccurrences(of: "Paragraph number 44 ", with: "Paragraph number forty-four ")
        let dirty = ASTDiff.dirtySet(
            old: MarkdownParser.parse(original), new: MarkdownParser.parse(edited)
        )
        #expect(dirty.ranges.count == 2)
        #expect(dirty.ranges[0].upperBound <= dirty.ranges[1].location)
    }

    @Test func subtreeHashIgnoresPositionButNotContent() {
        let a = MarkdownParser.parse("# A\n\nalpha\n\nbeta\n")
        let b = MarkdownParser.parse("# A\n\nbeta\n\nalpha\n")
        // Same two paragraphs, swapped: their hashes must still match, which is
        // what lets the LCS pair them up.
        let aHashes = Set(a.root.children.map(\.subtreeHash))
        let bHashes = Set(b.root.children.map(\.subtreeHash))
        #expect(aHashes == bHashes)

        let c = MarkdownParser.parse("# A\n\nalpha!\n\nbeta\n")
        #expect(Set(c.root.children.map(\.subtreeHash)) != aHashes)
    }
}

@Suite struct TextDiffTests {

    @Test func identicalTextHasNoHunks() {
        #expect(TextDiff.hunks(old: Corpus.kitchenSink, new: Corpus.kitchenSink).isEmpty)
    }

    @Test func pureInsertionIsAnInsertHunk() {
        let hunks = TextDiff.hunks(old: "a\nb\n", new: "a\nnew\nb\n")
        #expect(hunks.count == 1)
        #expect(hunks[0].kind == .inserted)
        #expect(("a\nnew\nb\n" as NSString).substring(with: hunks[0].newRange) == "new\n")
        #expect(hunks[0].oldRange.length == 0)
    }

    @Test func pureDeletionIsADeleteHunk() {
        let hunks = TextDiff.hunks(old: "a\ngone\nb\n", new: "a\nb\n")
        #expect(hunks.count == 1)
        #expect(hunks[0].kind == .deleted)
        #expect(("a\ngone\nb\n" as NSString).substring(with: hunks[0].oldRange) == "gone\n")
        #expect(hunks[0].newRange.length == 0)
    }

    /// §8.1: "Changed words inside a modified paragraph are highlighted in the
    /// rendered prose."  The ranges must land on the changed words of the *new*
    /// text and nothing else.
    @Test func modifiedHunksCarryWordRangesInTheNewText() {
        let old = "The quick brown fox jumps over the lazy dog.\n"
        let new = "The quick red fox leaps over the lazy dog.\n"
        let hunks = TextDiff.hunks(old: old, new: new)
        #expect(hunks.count == 1)
        #expect(hunks[0].kind == .modified)

        let ns = new as NSString
        let words = hunks[0].wordRanges.map { ns.substring(with: $0) }
        #expect(words == ["red", "leaps"])
        for range in hunks[0].wordRanges {
            #expect(range.location >= hunks[0].newRange.location)
            #expect(range.upperBound <= hunks[0].newRange.upperBound)
        }
    }

    @Test func adjacentChangedWordsMergeIntoOneHighlight() {
        let hunks = TextDiff.hunks(old: "one two three four\n", new: "one alpha beta four\n")
        #expect(hunks.count == 1)
        let words = hunks[0].wordRanges.map { ("one alpha beta four\n" as NSString).substring(with: $0) }
        #expect(words == ["alpha beta"])
    }

    @Test func multipleSeparatedEditsProduceSeparateHunks() {
        let old = (1...20).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let new = old
            .replacingOccurrences(of: "line 3", with: "line three")
            .replacingOccurrences(of: "line 17", with: "line seventeen")
        let hunks = TextDiff.hunks(old: old, new: new)
        #expect(hunks.count == 2)
        #expect(hunks.allSatisfy { $0.kind == .modified })
        #expect(hunks[0].newRange.upperBound <= hunks[1].newRange.location)
    }

    /// §12's keystroke budget: the diff has to be O(ND), not pathological, on
    /// a 5k-line document.
    @Test func handlesFiveThousandLinesQuickly() {
        let old = (0..<5000).map { "line number \($0) of the document" }.joined(separator: "\n") + "\n"
        let new = old.replacingOccurrences(
            of: "line number 2500 of the document",
            with: "line number 2500 of the rewritten document"
        )
        let start = Date()
        let hunks = TextDiff.hunks(old: old, new: new)
        let elapsed = Date().timeIntervalSince(start)
        #expect(hunks.count == 1)
        #expect(elapsed < 1.0, "5k-line diff took \(elapsed)s")
    }

    @Test func unrelatedDocumentsDegradeToOneHunkRatherThanHanging() {
        let old = (0..<3000).map { "alpha \($0)" }.joined(separator: "\n")
        let new = (0..<3000).map { "beta \($0)" }.joined(separator: "\n")
        let start = Date()
        let hunks = TextDiff.hunks(old: old, new: new)
        let elapsed = Date().timeIntervalSince(start)
        #expect(!hunks.isEmpty)
        #expect(elapsed < 2.0, "worst-case diff took \(elapsed)s")
    }
}

@Suite struct MyersTests {

    @Test func producesAMinimalScript() {
        let script = Myers.diff([1, 2, 3, 4], [1, 3, 4])
        #expect(script != nil)
        var deletes = 0, inserts = 0, equals = 0
        for step in script! {
            switch step {
            case .delete: deletes += 1
            case .insert: inserts += 1
            case .equal: equals += 1
            }
        }
        #expect(deletes == 1)
        #expect(inserts == 0)
        #expect(equals == 3)
    }

    @Test func handlesEmptyInputs() {
        #expect(Myers.diff([], [1, 2])?.count == 2)
        #expect(Myers.diff([1, 2], [])?.count == 2)
        #expect(Myers.diff([], [])?.isEmpty == true)
    }

    @Test func givesUpBeyondTheDistanceCap() {
        #expect(Myers.diff([1, 2, 3, 4], [5, 6, 7, 8], maxDistance: 2) == nil)
    }
}
