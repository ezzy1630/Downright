import Foundation
import Testing
@testable import MarkdownCore

// Properties the render and app layers rely on but that no single feature test
// would otherwise pin down.

@Suite struct ContractTests {

    @Test func parseOptionsDisableTheirPasses() {
        let text = "---\na: b\n---\n\n$x$ and [[W]] and src/a.ts and\n\n```mermaid\ngraph TD;\n```\n"
        let off = ParseOptions(
            detectFrontMatter: false, detectMath: false, detectCallouts: false,
            detectWikilinks: false, detectPathTokens: false, detectMermaid: false
        )
        let doc = MarkdownParser.parse(text, options: off)
        #expect(doc.frontMatter == nil)
        #expect(doc.pathTokens.isEmpty)
        var kinds: [String] = []
        doc.root.walk { block in
            if case .mermaid = block.content { kinds.append("mermaid") }
            if case .mathBlock = block.content { kinds.append("math") }
            for span in block.inlines {
                span.walk { inline in
                    if case .inlineMath = inline.kind { kinds.append("inlineMath") }
                    if case .wikilink = inline.kind { kinds.append("wikilink") }
                }
            }
        }
        #expect(kinds.isEmpty, "disabled passes still ran: \(kinds)")
    }

    @Test func extensionPassLimitSkipsOptionalPasses() {
        let text = "Math $x^2$ and src/a.ts here.\n"
        let limited = MarkdownParser.parse(text, options: ParseOptions(extensionPassLimit: 4))
        #expect(limited.pathTokens.isEmpty)
        // The block structure is still parsed; only the extension passes stop.
        #expect(limited.root.children.count == 1)
    }

    @Test func pathTokensAreInDocumentOrder() {
        let doc = MarkdownParser.parse(Corpus.kitchenSink)
        for (a, b) in zip(doc.pathTokens, doc.pathTokens.dropFirst()) {
            #expect(a.range.location < b.range.location)
        }
    }

    @Test func lineStartsAgreeWithTheDocumentHelpers() {
        for entry in Corpus.all {
            let doc = MarkdownParser.parse(entry.text)
            guard doc.length > 0 else { continue }
            for (index, start) in doc.lineStarts.enumerated() {
                #expect(doc.line(at: start) == index + 1, "\(entry.name) line \(index)")
                let range = doc.range(ofLine: index + 1)
                #expect(range.location == start)
                #expect(!doc.substring(range).contains("\n"))
            }
        }
    }

    @Test func blockLookupFindsTheDeepestBlock() {
        let doc = MarkdownParser.parse("# H\n\n- item **bold**\n")
        let offset = (doc.text as NSString).range(of: "bold").location
        let block = doc.root.block(at: offset)
        #expect(block != nil)
        if case .paragraph = block!.content {} else { Issue.record("expected the paragraph inside the item") }
    }

    @Test func subtreeHashesAreAssignedEverywhere() {
        let doc = MarkdownParser.parse(Corpus.kitchenSink)
        doc.root.walk { #expect($0.subtreeHash != 0) }
    }

    @Test func identitiesAreUniqueAmongSiblings() {
        let doc = MarkdownParser.parse(Corpus.kitchenSink)
        func check(_ children: [MDBlock]) {
            var seen = Set<BlockIdentity>()
            for child in children {
                #expect(seen.insert(child.identity).inserted, "duplicate identity \(child.identity)")
                check(child.children)
            }
        }
        check(doc.root.children)
    }

    /// §12: cold launch to first rendered pixel under 250ms for a 100KB file,
    /// of which parsing is only a slice.  This is a regression guard, not a
    /// benchmark — it catches accidental quadratic behaviour.
    @Test func parsesAHundredKilobytesQuickly() {
        let unit = Corpus.kitchenSink + "\n\n"
        var text = ""
        while text.utf8.count < 100_000 { text += unit }

        let start = Date()
        let doc = MarkdownParser.parse(text)
        let elapsed = Date().timeIntervalSince(start)
        #expect(doc.length > 0)
        #expect(elapsed < 1.0, "100KB parse took \(elapsed)s")
    }

    @Test func parsingIsDeterministic() {
        let a = MarkdownParser.parse(Corpus.kitchenSink)
        let b = MarkdownParser.parse(Corpus.kitchenSink)
        #expect(a.root.subtreeHash == b.root.subtreeHash)
        #expect(a.headings.map(\.slug) == b.headings.map(\.slug))
    }

    @Test func degenerateInputsDoNotCrash() {
        for text in ["", "\n", "\n\n\n", " ", "\t", "#", "```", "|", "> ", "- ", "[", "$", "\u{FEFF}"] {
            let doc = MarkdownParser.parse(text)
            #expect(doc.length == (text as NSString).length)
            _ = TidyDocument.plan(doc)
            _ = StructuralZoom.plan(doc, level: .skeleton)
            _ = Metrics.metrics(for: text)
            _ = Restructure.tableOfContents(doc, maxLevel: 6)
            _ = ListEditing.continuation(doc, at: 0)
            _ = ASTDiff.dirtySet(old: nil, new: doc)
        }
    }
}
