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

    @Test func sharedPaneExpandsFoldedCueWithoutLeavingHiddenAttributes() throws {
        let text = "# Section\n\nFirst body.\n\nMore body.\n\n# Next\n\nLast body.\n"
        let storage = NSTextStorage(string: text)
        let sheet = MarkdownTextView.fallbackStyleSheet()
        let source = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage, styleSheet: sheet)
        source.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        source.foldedHeadingSlugs = ["section"]
        let shared = MarkdownTextView(frame: source.frame, storage: storage, styleSheet: sheet, sharingPresentationOf: source)
        let offset = (text as NSString).range(of: "First body").location
        #expect((storage.attribute(.drElided, at: offset, effectiveRange: nil) as? NSNumber)?.boolValue == true)
        shared.expandElision(at: offset)
        #expect(shared.fragmentContext.elision.isIdentity)
        #expect((storage.attribute(.drElided, at: offset, effectiveRange: nil) as? NSNumber)?.boolValue != true)
    }

    @Test func sharedPaneOwnsAccessibleRenderedObjects() {
        let text = "---\ntitle: Demo\n---\n\n| A | B |\n|---|---|\n| C | D |\n\n$$\nx^2\n$$\n"
        let storage = NSTextStorage(string: text)
        let source = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        source.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        let shared = MarkdownTextView(frame: source.frame, storage: storage, styleSheet: source.styleSheet, sharingPresentationOf: source)
        let children = (shared.accessibilityChildren() ?? []).compactMap { $0 as? NSAccessibilityElement }
        #expect(children.compactMap { $0.accessibilityLabel() } == ["Edit document metadata", "Markdown table", "Display math"])
        #expect(children.allSatisfy { ($0.accessibilityParent() as? MarkdownTextView) === shared })
    }

    @Test func narrowPaneFitsCodeWithoutChangingFocusModeVisibility() {
        let pane = MarkdownContainerView(storage: NSTextStorage(string: "```swift\nlet value = 1\n```\n"))
        let map = DensityGutterView()
        pane.leadingAccessory = map
        pane.textView.update(document: MarkdownParser.parse(pane.textView.textStorage!.string), dirty: .wholesale)
        pane.frame = NSRect(x: 0, y: 0, width: 260, height: 400)
        pane.layoutSubtreeIfNeeded()
        let textLeft = pane.scrollView.frame.minX + pane.scrollView.contentInsets.left + pane.textView.textContainerOrigin.x
        #expect(textLeft + pane.textView.textContainer!.size.width <= pane.scrollView.frame.maxX)
        #expect(map.frame.width == 0)
        #expect(map.clipsToBounds)
        map.isHidden = true
        pane.frame.size.width = 700
        pane.needsLayout = true
        pane.layoutSubtreeIfNeeded()
        #expect(map.isHidden)
        #expect(!map.clipsToBounds)
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
        #expect(attachedElementCounts.allSatisfy { $0 > 0 })
        #expect(attachedElementCounts[0] == attachedElementCounts[1])
    }
}
