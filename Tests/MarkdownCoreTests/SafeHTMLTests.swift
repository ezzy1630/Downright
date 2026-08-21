import Foundation
import Testing
@testable import MarkdownCore

@Suite("Safe presentational HTML")
struct SafeHTMLTests {
    @Test func commonReadmeHTMLIsSourceAddressedAndSafe() throws {
        let source = #"<p align="center"><strong>Downright</strong><br><a href="https://example.com">Home</a></p>"#
        let parsed = MarkdownParser.parse(source)
        let html = try #require(parsed.root.children.first?.safeHTML)
        #expect(html.isSafe)
        #expect(html.annotations.contains { if case .paragraph(align: .center) = $0.kind { true } else { false } })
        #expect(html.annotations.contains { if case .strong = $0.kind { true } else { false } })
        #expect(html.annotations.contains { if case .lineBreak = $0.kind { true } else { false } })
        #expect(html.annotations.contains { if case .link(destination: "https://example.com", title: nil) = $0.kind { true } else { false } })
        #expect(html.tagRanges.allSatisfy { $0.location >= 0 && $0.upperBound <= (source as NSString).length })
    }

    @Test func detailsTablesAndLocalImagesStayInTheSubset() throws {
        let source = """
        <details open><summary>More</summary><table><tr><th align="right">A</th><td>B</td></tr></table></details>
        <img src="Docs/demo.png" alt="Demo">
        """
        let parsed = MarkdownParser.parse(source)
        let documents = parsed.root.children.compactMap(\.safeHTML)
        #expect(!documents.isEmpty)
        #expect(documents.allSatisfy { $0.isSafe })
        #expect(documents.flatMap(\.annotations).contains { if case .details(open: true) = $0.kind { true } else { false } })
        #expect(documents.flatMap(\.annotations).contains { if case .tableCell(header: true, align: .right) = $0.kind { true } else { false } })
        #expect(documents.flatMap(\.annotations).contains { if case .image(source: "Docs/demo.png", alt: "Demo") = $0.kind { true } else { false } })
    }

    @Test func unsafeOrUnknownHTMLRemainsLiteralAndInert() throws {
        for source in [
            #"<script>alert(1)</script>"#,
            #"<p onclick="steal()">Text</p>"#,
            #"<a href="javascript:alert(1)">Run</a>"#,
            #"<iframe src="https://example.com"></iframe>"#,
        ] {
            let parsed = MarkdownParser.parse(source)
            let html = try #require(parsed.root.children.first?.safeHTML)
            #expect(!html.isSafe)
            #expect(html.annotations.isEmpty)
            #expect(parsed.text == source)
        }
    }

    @Test func unbalancedDetailsWithoutARealDocumentBoundaryStayLiteral() throws {
        for source in ["<details>", "</details>"] {
            let parsed = MarkdownParser.parse(source)
            let html = try #require(parsed.root.children.first?.safeHTML)
            #expect(!html.isSafe)
            #expect(html.annotations.isEmpty)
            #expect(parsed.text == source)
        }
    }

    /// The cross-block accommodation must answer for *parsed tags*, not raw
    /// substrings: a mention of the element inside a code span, or in prose,
    /// must not license hiding a stray literal tag in another block.
    @Test func detailsMentionsInCodeSpansAndProseDoNotSatisfyTheCrossBlockCheck() throws {
        for opener in ["`<details>`", "the <details> element is a container"] {
            let source = """
            \(opener)

            </details>
            """
            let parsed = MarkdownParser.parse(source)
            let documents = parsed.root.children.compactMap(\.safeHTML)
            let closing = try #require(documents.last)
            #expect(!closing.isSafe, "a stray closer with only a textual mention before it stays literal")
            #expect(closing.annotations.isEmpty)
            #expect(parsed.text == source)
        }

        for closer in ["`</details>`", "write </details> to close"] {
            let source = """
            <details open>

            \(closer)
            """
            let parsed = MarkdownParser.parse(source)
            let documents = parsed.root.children.compactMap(\.safeHTML)
            let opening = try #require(documents.first)
            #expect(!opening.isSafe, "an opener whose only partner is textual mention stays literal")
            #expect(opening.annotations.isEmpty)
        }
    }

    /// The genuine README shape — an opening block, a blank line, the body,
    /// another blank line, the closing block — keeps its cross-block pairing.
    @Test func splitDetailsAcrossBlankLinesStillPairsUp() throws {
        let source = """
        <details open>
        <summary>More</summary>

        Body text across the boundary.

        </details>
        """
        let parsed = MarkdownParser.parse(source)
        let documents = parsed.root.children.compactMap(\.safeHTML)
        let annotations = documents.flatMap(\.annotations)
        #expect(annotations.contains { if case .details = $0.kind { true } else { false } })
        #expect(annotations.contains { if case .detailsClosing = $0.kind { true } else { false } })
    }

    @Test func remoteImagesStayVisibleButInertInsideSafeParents() throws {
        let source = #"<p align="center"><img src="https://tracker.example/pixel.png" alt="remote"></p>"#
        let parsed = MarkdownParser.parse(source)
        let html = try #require(parsed.root.children.first?.safeHTML)
        #expect(html.isSafe)
        #expect(html.annotations.contains { if case .inert = $0.kind { true } else { false } })
    }

    @Test func githubProfileContinuesToDescribeRawHTMLAsTargetCompatibility() {
        let parsed = MarkdownParser.parse("<strong>Text</strong>")
        let github = MarkdownCompatibility.diagnose(parsed, for: .gitHub)
        let noHTML = MarkdownCompatibility.diagnose(
            parsed,
            for: .custom(name: "No raw HTML", capabilities: [])
        )
        #expect(!github.diagnostics.contains { $0.capability == .rawHTML })
        #expect(noHTML.diagnostics.contains { $0.capability == .rawHTML })
    }

    @Test func downrightReadmeCorpusClassifiesSafeAndRemoteRiskHTML() throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let readme = try String(contentsOf: repository.appendingPathComponent("README.md"), encoding: .utf8)
        let parsed = MarkdownParser.parse(readme)
        var documents: [SafeHTMLDocument] = []
        parsed.root.walk { block in
            if let html = block.safeHTML { documents.append(html) }
        }
        #expect(!documents.isEmpty)
        #expect(documents.contains { html in
            html.annotations.contains { if case .inert = $0.kind { true } else { false } }
        })
        #expect(parsed.text == readme)
    }
}
