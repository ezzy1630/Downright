import Foundation
import Testing
@testable import MarkdownCore

@Suite struct FrontMatterEditingTests {
    @Test func setPreservesQuoteAndBoundaryWhitespace() throws {
        let source = "---\ntitle:  \"Old\"  \ncount: 2\n---\nBody\n"
        let result = FrontMatterEditing.set(MarkdownParser.parse(source), key: "title", value: .text("New"))
        let proposal = try #require(result.proposal)
        #expect(proposal.applying(to: source) == "---\ntitle:  \"New\"  \ncount: 2\n---\nBody\n")
    }

    @Test func typedValuesRoundTripWithoutChangingOtherFields() throws {
        let source = "---\ntitle: Demo\n---\n"
        let document = MarkdownParser.parse(source)
        let bool = try #require(FrontMatterEditing.set(document, key: "enabled", value: .boolean(true)).proposal)
        let list = try #require(FrontMatterEditing.add(MarkdownParser.parse(bool.applying(to: source) ?? source), key: "tags", value: .list(["one", "two"])).proposal)
        let output = try #require(list.applying(to: bool.applying(to: source) ?? source))
        #expect(output == "---\ntitle: Demo\nenabled: true\ntags: [one, two]\n---\n")
    }

    @Test func addAndRemoveKeepCRLF() throws {
        let source = "---\r\ntitle: Demo\r\n---\r\n"
        let added = try #require(FrontMatterEditing.add(MarkdownParser.parse(source), key: "draft", value: .boolean(false)).proposal)
        let withField = try #require(added.applying(to: source))
        #expect(withField == "---\r\ntitle: Demo\r\ndraft: false\r\n---\r\n")
        let removed = try #require(FrontMatterEditing.remove(MarkdownParser.parse(withField), key: "title").proposal)
        #expect(removed.applying(to: withField) == "---\r\ndraft: false\r\n---\r\n")
    }

    @Test func complexYamlFallsBackToSource() {
        let nested = FrontMatterEditing.set(
            MarkdownParser.parse("---\ntags:\n  - one\n---\n"), key: "tags", value: .list(["two"])
        )
        #expect(nested.proposal == nil)
        #expect(nested.fallback == .nestedYAML)

        let comment = FrontMatterEditing.set(
            MarkdownParser.parse("---\n# note\ntitle: Demo\n---\n"), key: "title", value: .text("x")
        )
        #expect(comment.fallback == .commentsNotSupported)
    }

    @Test func staleProposalDoesNotApply() throws {
        let source = "---\ntitle: Demo\n---\n"
        let proposal = try #require(FrontMatterEditing.set(MarkdownParser.parse(source), key: "title", value: .text("New")).proposal)
        #expect(proposal.applying(to: source.replacingOccurrences(of: "Demo", with: "Other")) == nil)
    }

    @Test func emptyFieldCanBeSetWithoutAddingADuplicate() throws {
        let source = "---\ntitle: \n---\n"
        let proposal = try #require(FrontMatterEditing.set(MarkdownParser.parse(source), key: "title", value: .text("Demo")).proposal)
        #expect(proposal.applying(to: source) == "---\ntitle: Demo\n---\n")
    }

    @Test func specialTextUsesSafeYamlQuotes() throws {
        let source = "---\ntitle: Demo\n---\n"
        let proposal = try #require(FrontMatterEditing.set(MarkdownParser.parse(source), key: "title", value: .text("true: \"quoted\" # note")).proposal)
        #expect(proposal.applying(to: source) == "---\ntitle: \"true: \\\"quoted\\\" # note\"\n---\n")
    }

    @Test func listItemsUseTypeSafeQuotes() throws {
        let source = "---\ntags: [one, two]\n---\n"
        let proposal = try #require(FrontMatterEditing.set(MarkdownParser.parse(source), key: "tags", value: .list(["true", "a: b", "plain"])).proposal)
        #expect(proposal.applying(to: source) == "---\ntags: [\"true\", \"a: b\", plain]\n---\n")
    }

    @Test func duplicateAndInvalidKeysFallBack() {
        let duplicate = FrontMatterEditing.set(MarkdownParser.parse("---\ntitle: A\ntitle: B\n---\n"), key: "title", value: .text("C"))
        #expect(duplicate.fallback == .ambiguousField)
        let invalid = FrontMatterEditing.add(MarkdownParser.parse("---\ntitle: A\n---\n"), key: "bad:key", value: .text("x"))
        #expect(invalid.fallback == .unsupportedValue)
    }

    @Test func malformedAnchoredAndBlockScalarYamlFallsBack() {
        let malformed = FrontMatterEditing.set(MarkdownParser.parse("---\ntitle: A\n"), key: "title", value: .text("B"))
        #expect(malformed.fallback == .malformedFence)
        let anchor = FrontMatterEditing.set(MarkdownParser.parse("---\ntitle: &base A\n---\n"), key: "title", value: .text("B"))
        #expect(anchor.fallback == .anchorsOrAliasesNotSupported)
        let block = FrontMatterEditing.set(MarkdownParser.parse("---\ndescription: |\n---\n"), key: "description", value: .text("B"))
        #expect(block.fallback == .blockScalarNotSupported)
    }

    @Test func rendersNumberWithoutPointZero() throws {
        let source = "---\ncount: 1\n---\n"
        let proposal = try #require(FrontMatterEditing.set(MarkdownParser.parse(source), key: "count", value: .number(42.0)).proposal)
        #expect(proposal.applying(to: source) == "---\ncount: 42\n---\n")
    }
}
