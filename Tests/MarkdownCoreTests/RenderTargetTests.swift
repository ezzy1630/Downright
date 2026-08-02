import Foundation
import Testing
@testable import MarkdownCore

@Suite struct RenderTargetTests {

    @Test func builtInProfilesHaveIntentionalDifferences() {
        #expect(BuiltInRenderTarget.allCases.count == 9)
        #expect(BuiltInRenderTarget.allCases.map(\.displayName) == [
            "Downright", "CommonMark", "GitHub", "Obsidian", "Pandoc",
            "MultiMarkdown", "Jekyll", "Hugo", "Quarto",
        ])
        #expect(RenderTargetProfile.builtIns.compactMap(\.builtIn).count == 9)
        #expect(RenderTargetProfile.downright.capabilities == .all)
        #expect(!RenderTargetProfile.commonMark.capabilities.contains(.tables))
        #expect(RenderTargetProfile.gitHub.capabilities.contains(.tables))
        #expect(RenderTargetProfile.obsidian.capabilities.contains(.wikilinks))
        #expect(!RenderTargetProfile.gitHub.capabilities.contains(.wikilinks))
    }

    @Test func everyCapabilityIsDetectedFromParsedRanges() {
        let source = """
        ---
        title: Demo
        ---

        # Heading {#demo}

        | A | B |
        |---|---|
        | 1 | 2 |

        - [ ] task
        ~~strike~~ and $x^2$ and [[Notes]].

        [^one] and <span>HTML</span>

        [^one]: Footnote

        > [!NOTE] Alert

        ```mermaid
        graph TD
        ```
        """
        let document = MarkdownParser.parse(source)
        let report = MarkdownCompatibility.diagnose(document, for: .commonMark)
        let found = Set(report.diagnostics.map(\.capability))
        let expected = MarkdownCapabilities.all.subtracting(.rawHTML).capabilities
        #expect(expected.allSatisfy(found.contains))
        #expect(report.diagnostics.allSatisfy { !$0.explanation.isEmpty })
    }

    @Test func diagnosticsUseExactExtensionRangesAndStableOrder() {
        let source = "---\ntitle: Demo\n---\n\n# Heading {#demo}\n\n> [!NOTE] Heads up\n> Body\n\nSee [[Notes]] and ~~old~~.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
        let document = MarkdownParser.parse(source)
        let report = MarkdownCompatibility.diagnose(document, for: .commonMark)
        let snippets = report.diagnostics.map { document.substring($0.range) }

        #expect(snippets == ["---\ntitle: Demo\n---\n", "{#demo}", "> [!NOTE] Heads up", "[[Notes]]", "~~old~~", "| A | B |\n|---|---|\n| 1 | 2 |"])
        #expect(report.diagnostics.map(\.range.location) == report.diagnostics.map(\.range.location).sorted())
        #expect(report.diagnostics.allSatisfy { !$0.explanation.isEmpty })
    }

    @Test func wikilinkProposalIsByteLocalAndReversible() throws {
        let source = "See [[Design Notes|the notes]].\n"
        let document = MarkdownParser.parse(source)
        let report = MarkdownCompatibility.diagnose(document, for: .gitHub)
        let proposal = try #require(report.diagnostics.first?.proposal)
        let transformed = try #require(proposal.applying(to: source))
        #expect(transformed == "See [the notes](<Design Notes>).\n")
        #expect(proposal.reversing(in: transformed) == source)
        #expect(proposal.reversing(in: "other text") == nil)
    }

    @Test func customProfileRoundTripsThroughCodable() throws {
        let profile = RenderTargetProfile(name: "Docs", capabilities: [.tables, .math, .rawHTML])
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(RenderTargetProfile.self, from: data)
        #expect(decoded == profile)
        #expect(decoded.builtIn == nil)
    }

    @Test func reportAndProposalCodableRoundTrip() throws {
        let source = "é [[Design Notes]]\n"
        let document = MarkdownParser.parse(source)
        let report = MarkdownCompatibility.diagnose(document, for: .gitHub)
        let diagnostic = try #require(report.diagnostics.first)
        #expect(diagnostic.capability == .wikilinks)
        #expect(diagnostic.range.location == 2)
        #expect(document.substring(diagnostic.range) == "[[Design Notes]]")

        let data = try JSONEncoder().encode(report)
        let decoded = try JSONDecoder().decode(CompatibilityReport.self, from: data)
        #expect(decoded == report)
        #expect(decoded.diagnostics.first?.proposal?.replacement == "[Design Notes](<Design Notes>)")
    }

    @Test func duplicateFindingsAreDeterministicAndRangeOrdered() {
        let source = "~~one~~ and [[A]] and ~~two~~ and [[B]]\n"
        let document = MarkdownParser.parse(source)
        let first = MarkdownCompatibility.diagnose(document, for: .commonMark)
        let second = MarkdownCompatibility.diagnose(document, for: .commonMark)
        #expect(first == second)
        #expect(first.diagnostics.map(\.range.location) == [0, 12, 22, 34])
        #expect(first.diagnostics.map(\.capability) == [.strikethrough, .wikilinks, .strikethrough, .wikilinks])
    }

    @Test func sideBySideComparisonExposesCapabilityDelta() {
        let source = MarkdownParser.parse("# H\n\n- [ ] task\n")
        let result = MarkdownCompatibility.compare(source, from: .downright, to: .commonMark)
        #expect(result.source.name == "Downright")
        #expect(result.target.name == "CommonMark")
        #expect(result.onlyInSource.contains(.taskLists))
        #expect(result.report.diagnostics.contains { $0.capability == .taskLists })
    }
}
