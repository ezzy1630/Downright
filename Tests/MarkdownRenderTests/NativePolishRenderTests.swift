import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@MainActor
@Suite(.serialized)
struct NativePolishRenderTests {
    @Test func dropCaretRemainsVisibleAboveOpaqueTextBackground() throws {
        let text = "MMMMMMMM next line.\n"
        let storage = NSTextStorage(string: text)
        let pane = MarkdownContainerView(storage: storage)
        pane.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
        pane.textView.mode = .source
        pane.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        pane.layoutSubtreeIfNeeded()
        storage.addAttribute(.backgroundColor, value: NSColor.red,
                             range: NSRange(location: 0, length: storage.length))
        let content = try #require(pane.textView.textContentStorage as? MarkdownContentStorage)
        content.configure(paragraphIndex: ParagraphIndex(text: text as NSString),
                          reflowRanges: [], displayMap: .identity)
        pane.textView.invalidateAllFragments()
        pane.textView.prepareForDisplay()
        pane.textView.dropInsertionOffset = 1
        let caret = try #require(pane.textView.rect(forOffset: 1))
        let location = pane.convert(NSPoint(x: caret.minX, y: caret.midY), from: pane.textView)
        let bitmap = try #require(pane.bitmapImageRepForCachingDisplay(in: pane.bounds))
        pane.cacheDisplay(in: pane.bounds, to: bitmap)
        let accent = try #require(pane.textView.styleSheet.accent.usingColorSpace(.deviceRGB))
        var accentVisible = false
        let scaleX = CGFloat(bitmap.pixelsWide) / pane.bounds.width
        let scaleY = CGFloat(bitmap.pixelsHigh) / pane.bounds.height
        for y in Int((location.y - 2) * scaleY)...Int((location.y + 2) * scaleY) {
            for x in Int((location.x - 1) * scaleX)...Int((location.x + 1) * scaleX) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let distance = abs(color.redComponent - accent.redComponent)
                    + abs(color.greenComponent - accent.greenComponent)
                    + abs(color.blueComponent - accent.blueComponent)
                if distance < 0.15 { accentVisible = true }
            }
        }
        #expect(accentVisible)
        #expect(storage.string == text)
    }

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
            // A newly attached empty-sized scroller has no visible elements.
            // Measure actual viewport preparation, rather than constructor
            // cache side effects, with all bounds and positivity checks intact.
            pane.frame = NSRect(x: 0, y: 0, width: 700, height: 400)
            pane.layoutSubtreeIfNeeded()
            pane.textView.prepareForDisplay()
            #expect(pane.textView.textContainerOrigin == NSPoint(x: RenderMetrics.revealSlack, y: RenderMetrics.verticalInset))
            attachedElementCounts.append(pane.textView.cachedLayoutElementCountForTesting)
            #expect(storage.string == text)
        }
        // Attachment may warm a viewport, but doubling document length must
        // not grow that work. Avoid assuming AppKit's viewport overscan size.
        #expect(attachedElementCounts.allSatisfy { $0 > 0 })
        #expect(attachedElementCounts[0] == attachedElementCounts[1])
    }
    @Test func largeDocumentOriginMatchesNativeGeometry() {
        let text = String(repeating: "שלום café **bold**\n\n", count: 2_100)
        let storage = NSTextStorage(string: text)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        for inset in [NSSize(width: 44, height: 36), NSSize(width: 20, height: 10)] {
            view.textContainerInset = inset
            #expect(view.textContainerOrigin == view.nativeTextContainerOriginForTesting)
        }
    }

}
