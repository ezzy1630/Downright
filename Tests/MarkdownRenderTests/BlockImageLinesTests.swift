import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@MainActor
struct BlockImageLinesTests {
    @Test(arguments: ["\n", "\r\n", "  \n"])
    func adjacentImageLinesKeepIndependentFragmentsAndSource(separator: String) throws {
        let first = "![猫](first.png)", second = "![](second.png)"
        let source = first + separator + second + "\n"
        let document = MarkdownParser.parse(source)
        let storage = NSTextStorage(string: source)
        let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua)!)
        let engine = DecorationEngine(styleSheet: sheet)
        engine.policy = RenderMode.read.policy
        engine.decorate(storage, document: document, dirty: .wholesale)
        for image in [first, second] {
            let range = (source as NSString).range(of: image)
            let payload = try #require(storage.attribute(.drFragment, at: range.location, effectiveRange: nil) as? FragmentPayload)
            #expect(payload.kind == .image)
            #expect(payload.sourceRange == range)
        }
        #expect(InlineImageDisplay.items(in: document, includesRemoteHTML: false).isEmpty,
                "image-only lines must not enter the eager inline-image rebuild path")
        let plan = HardWrapReflow.plan(document: document, text: source as NSString,
            hiddenRanges: engine.hiddenRanges(document: document, caret: nil, selections: []), enabled: true)
        #expect(plan.ranges.isEmpty, "the image lines must remain separate TextKit paragraphs")
        #expect(storage.string == source)

        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        view.mode = .read
        view.update(document: document, dirty: .wholesale)
        view.prepareForDisplay()
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        for image in [first, second] {
            let offset = (source as NSString).range(of: image).location
            let location = try #require(content.location(content.documentRange.location, offsetBy: offset))
            #expect(manager.textLayoutFragment(for: location) is ImageFragment)
        }
        #expect(storage.string == source)
    }

    @Test(arguments: [
        "Before ![Picture](picture.png) after.\n",
        "[![Badge](badge.svg)](https://example.com)\n",
        "![One](one.png) ![Two](two.png)\n",
    ])
    func proseLinkedBadgesAndSameLineRowsStayInline(source: String) throws {
        let document = MarkdownParser.parse(source)
        let paragraph = try #require(document.root.children.first)
        #expect(BlockImageLines.images(in: paragraph, text: source as NSString).isEmpty)
        #expect(!InlineImageDisplay.items(in: document, includesRemoteHTML: false).isEmpty)
    }
}
