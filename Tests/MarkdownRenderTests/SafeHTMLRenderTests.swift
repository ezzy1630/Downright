import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@Suite("Native safe HTML rendering")
struct SafeHTMLRenderTests {
    private func engine(_ mode: RenderMode) -> DecorationEngine {
        let sheet = StyleSheet(
            theme: .fallback,
            appearance: NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()
        )
        let engine = DecorationEngine(styleSheet: sheet)
        engine.policy = mode.policy
        return engine
    }

    @Test func safeTagsCollapseButSourceAndSemanticAttributesRemain() throws {
        let source = #"<p align="center"><strong>Gold</strong> <a href="https://example.com">standard</a></p>"#
        let document = MarkdownParser.parse(source)
        let storage = NSTextStorage(string: source)
        let renderer = engine(.live)
        renderer.decorate(storage, document: document, dirty: .wholesale)

        #expect(storage.string == source)
        let hidden = renderer.hiddenRanges(document: document, caret: nil, selections: [])
        let html = try #require(document.root.children.first?.safeHTML)
        #expect(Set(hidden) == Set(html.tagRanges))

        let gold = (source as NSString).range(of: "Gold")
        let standard = (source as NSString).range(of: "standard")
        let bold = try #require(storage.attribute(.font, at: gold.location, effectiveRange: nil) as? NSFont)
        #expect(bold.fontDescriptor.symbolicTraits.contains(.bold))
        #expect(storage.attribute(.drLink, at: standard.location, effectiveRange: nil) as? String == "https://example.com")
        let paragraph = try #require(storage.attribute(.paragraphStyle, at: gold.location, effectiveRange: nil) as? NSParagraphStyle)
        #expect(paragraph.alignment == .center)
    }

    @Test func caretRevealsSafeTagsForEditingAndSourceModeAlwaysShowsThem() throws {
        let source = "<strong>Text</strong>"
        let document = MarkdownParser.parse(source)
        let live = engine(.live)
        #expect(!live.hiddenRanges(document: document, caret: nil, selections: []).isEmpty)
        #expect(live.hiddenRanges(document: document, caret: 9, selections: []).isEmpty)
        #expect(engine(.source).hiddenRanges(document: document, caret: nil, selections: []).isEmpty)
    }

    @Test func unsafeHTMLReceivesNoLinkFragmentOrHiddenRanges() {
        let source = #"<a href="javascript:alert(1)">Run</a>"#
        let document = MarkdownParser.parse(source)
        let storage = NSTextStorage(string: source)
        let renderer = engine(.live)
        renderer.decorate(storage, document: document, dirty: .wholesale)
        #expect(renderer.hiddenRanges(document: document, caret: nil, selections: []).isEmpty)
        #expect(storage.attribute(.drLink, at: 0, effectiveRange: nil) == nil)
        #expect(storage.string == source)
    }

    @Test func localHTMLImageUsesNativeFragmentWithoutRemoteLoading() throws {
        let source = #"<img src="Docs/demo.png" alt="Demo">"#
        let document = MarkdownParser.parse(source)
        let storage = NSTextStorage(string: source)
        engine(.live).decorate(storage, document: document, dirty: .wholesale)
        let payload = try #require(storage.attribute(.drFragment, at: 0, effectiveRange: nil) as? FragmentPayload)
        #expect(payload.kind == .image)
        #expect(payload.detail == "Docs/demo.png")
        #expect(storage.string == source)
    }

    @Test func detailsAndTableAnnotationsReceiveNativeReadingChrome() throws {
        let source = "<details open><summary>More</summary>Body</details>\n<table><tr><td>A</td><td>B</td></tr></table>"
        let document = MarkdownParser.parse(source)
        let storage = NSTextStorage(string: source)
        engine(.live).decorate(storage, document: document, dirty: .wholesale)

        let details = try #require(document.root.children.first?.safeHTML)
        let summary = try #require(details.annotations.first {
            if case .summary = $0.kind { return true }
            return false
        })
        #expect(storage.attribute(.backgroundColor, at: summary.contentRange.location, effectiveRange: nil) != nil)

        let table = try #require(document.root.children.compactMap(\.safeHTML).first {
            $0.annotations.contains {
                if case .tableCell = $0.kind { return true }
                return false
            }
        })
        let cells = table.annotations.filter {
            if case .tableCell = $0.kind { return true }
            return false
        }
        #expect(cells.count == 2)
        for cell in cells {
            let last = cell.contentRange.upperBound - 1
            #expect((storage.attribute(.kern, at: last, effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0 > 0)
            #expect(storage.attribute(.backgroundColor, at: last, effectiveRange: nil) != nil)
        }
        #expect(storage.string == source)
    }
}
