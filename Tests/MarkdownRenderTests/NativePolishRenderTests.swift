import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@MainActor
@Suite(.serialized)
struct NativePolishRenderTests {
    @Test func sharedPanePreservesFragmentPresentationState() {
        let text = "- first line\n  second line\n\n```swift\nlet value = 1\n```\n\n## Hidden section\n\n| A | B |\n|---|---|\n| C | D |\n"
        let storage = NSTextStorage(string: text)
        let sheet = MarkdownTextView.fallbackStyleSheet()
        let source = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage, styleSheet: sheet)
        source.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        source.foldedHeadingSlugs = ["hidden-section"]
        source.setCodeBlockCollapsed(true, at: (text as NSString).range(of: "```swift").location)
        source.focusSource(in: (text as NSString).range(of: "| A | B |"))
        let shared = MarkdownTextView(frame: source.frame, storage: storage, styleSheet: sheet, sharingPresentationOf: source)
        let continuation = (text as NSString).range(of: "second line").location
        #expect(shared.fragmentContext.paragraphIndex.index(containing: continuation)
                != shared.fragmentContext.paragraphIndex.index(containing: 0))
        #expect(shared.fragmentContext.sourceFocusRange == source.fragmentContext.sourceFocusRange)
        #expect(shared.fragmentContext.elision.elidedRanges == source.fragmentContext.elision.elidedRanges)
        #expect(shared.fragmentContext.cueElision.elidedRanges == source.fragmentContext.cueElision.elidedRanges)
        #expect(shared.fragmentContext.collapseOverrides == source.fragmentContext.collapseOverrides)
        #expect(storage.string == text)
    }

    @Test func attachingSharedPaneKeepsDocumentLayoutLazy() throws {
        var attachedElementCounts: [Int] = []
        for paragraphCount in [2_000, 4_000] {
            let text = (0..<paragraphCount).map { "Paragraph \($0) with **emphasis**." }.joined(separator: "\n\n")
            let storage = NSTextStorage(string: text)
            let sheet = MarkdownTextView.fallbackStyleSheet()
            let source = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage, styleSheet: sheet)
            source.update(document: MarkdownParser.parse(text), dirty: .wholesale)
            let pane = MarkdownContainerView(storage: storage, styleSheet: sheet, sharingPresentationOf: source)
            attachedElementCounts.append(pane.textView.cachedLayoutElementCountForTesting)
            #expect(pane.textView.textContainerOrigin == NSPoint(x: RenderMetrics.revealSlack, y: RenderMetrics.verticalInset))
            #expect(storage.string == text)
        }
        // Attachment may warm a viewport, but doubling document length must
        // not grow that work. Avoid assuming AppKit's viewport overscan size.
        #expect(attachedElementCounts[0] == attachedElementCounts[1])
    }
}
