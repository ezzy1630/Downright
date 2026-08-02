import Foundation
import Testing
@testable import MarkdownCore

@Suite struct DocumentHealthTests {
    @Test func reportsStableIDsAndUTF16Ranges() {
        let text = "# Title\n\n#### Café\n"
        let first = DocumentHealth.analyze(text)
        let second = DocumentHealth.analyze(text)
        #expect(first.map(\.id) == second.map(\.id))
        let skipped = first.first { $0.id == "heading.skipped-level" }
        #expect(skipped?.range == NSRange(location: 9, length: 9))
        #expect(skipped?.fix?.replacement == "## ")
        #expect(skipped?.fix?.range.location == 9)
    }

    @Test func ignoresCodeAndFrontMatter() {
        let text = "---\ntitle: the the\n---\n\n# Title\n\n```\n# Fake\n[bad](javascript:alert(1))\n```\n"
        let findings = DocumentHealth.analyze(text)
        #expect(!findings.contains { $0.range.location < 25 && $0.id == "prose.repeated-word" })
        #expect(!findings.contains { $0.id == "url.unsafe-scheme" })
    }

    @Test func findsReferencesFootnotesAndImages() {
        let text = "[x][missing]\n\n[^a]: one\n[^a]: two\n\n![](missing.png)\n"
        let findings = DocumentHealth.analyze(text, resolver: DocumentHealthResolver { _ in false })
        #expect(findings.contains { $0.id == "reference.undefined" })
        #expect(findings.contains { $0.id == "footnote.duplicate" })
        #expect(findings.contains { $0.id == "image.missing-alt" })
        #expect(findings.contains { $0.id == "asset.missing" })
    }

    @Test func doesNotFlagExternalLinksAsMissingAssets() {
        let findings = DocumentHealth.analyze("[site](https://example.com)\n", resolver: DocumentHealthResolver { _ in false })
        #expect(!findings.contains { $0.id == "link.missing" })
        #expect(!findings.contains { $0.id == "url.unsafe-scheme" })
    }
    @Test func catchesUnclosedFenceAndIgnoresItsContents() {
        let text = "# Title\n\n```swift\nlet x = 1\n\n![diagram](/tmp/diagram.png)\n"
        let findings = DocumentHealth.analyze(text)
        #expect(findings.contains { $0.id == "fence.unclosed" })
        #expect(!findings.contains { $0.id == "asset.absolute-path" })
    }

    @Test func catchesAbsolutePathOutsideCode() {
        let findings = DocumentHealth.analyze("![diagram](/assets/diagram.png)\n")
        #expect(findings.contains { $0.id == "asset.absolute-path" })
    }

    @Test func catchesUnsafeURLAndDuplicateAnchor() {
        let findings = DocumentHealth.analyze("# Same\n\n# Same\n\n[run](javascript:alert(1))\n")
        #expect(findings.contains { $0.id == "heading.duplicate-anchor" })
        #expect(findings.contains { $0.id == "url.unsafe-scheme" })
    }

    @Test func resolverOnlyChecksLocalTargets() {
        let findings = DocumentHealth.analyze("[missing](docs/missing.md)\n", resolver: DocumentHealthResolver { _ in false })
        #expect(findings.contains { $0.id == "link.missing" })
    }

    @Test func reportsDenseParagraphAndInvalidTableRow() {
        let text = "| A | B |\n| --- | --- |\n| only |\n\n" + String(repeating: "word ", count: 130) + "\n"
        let findings = DocumentHealth.analyze(text)
        #expect(findings.contains { $0.id == "table.invalid-row" })
        #expect(findings.contains { $0.id == "paragraph.dense" })
    }
}
