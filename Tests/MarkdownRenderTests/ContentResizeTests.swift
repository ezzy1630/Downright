import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

@Suite("Content resize")
@MainActor
struct ContentResizeTests {
    @Test("idle requests merge without losing structural urgency")
    func requestMerging() {
        #expect(ContentResizePolicy.merge(nil, with: .semantic) == .semantic)
        #expect(ContentResizePolicy.merge(.semantic, with: .lineCount) == .lineCount)
        #expect(ContentResizePolicy.merge(.lineCount, with: .scrollRepair) == .lineCount)
        #expect(ContentResizePolicy.merge(.semantic, with: .viewport) == .viewport)
        #expect(ContentResizePolicy.merge(.viewport, with: .immediate) == .immediate)
        #expect(ContentResizePolicy.idleDelay(for: .semantic) > 0)
        #expect(ContentResizePolicy.idleDelay(for: .lineCount) > 0)
        #expect(ContentResizePolicy.idleDelay(for: .viewport) == 0)
    }

    @Test("semantic updates wait for idle and wholesale updates stay immediate")
    func semanticUpdateIsDeferred() async throws {
        let initial = "# Heading\n\nA short paragraph."
        let storage = NSTextStorage(string: initial)
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400), storage: storage)
        view.update(document: MarkdownParser.parse(initial), dirty: .wholesale)
        #expect(view.pendingResizeRequestForTesting == nil)

        let changed = "# Heading\n\nA longer paragraph with one more word."
        storage.replaceCharacters(
            in: NSRange(location: 0, length: storage.length), with: changed)
        view.update(
            document: MarkdownParser.parse(changed),
            dirty: DirtySet(ranges: [NSRange(location: 0, length: (changed as NSString).length)],
                            isWholesale: false))
        #expect(view.pendingResizeRequestForTesting == .semantic)

        try await Task.sleep(for: .milliseconds(35))
        #expect(view.pendingResizeRequestForTesting == .semantic)
        try await Task.sleep(for: .milliseconds(120))
        #expect(view.pendingResizeRequestForTesting == nil)
    }

    @Test("line-count changes use the coalesced structural path")
    func lineCountUpdateIsDeferred() {
        let initial = "one line"
        let storage = NSTextStorage(string: initial)
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400), storage: storage)
        view.update(document: MarkdownParser.parse(initial), dirty: .wholesale)

        let changed = "one line\ntwo lines"
        storage.replaceCharacters(
            in: NSRange(location: 0, length: storage.length), with: changed)
        view.update(
            document: MarkdownParser.parse(changed),
            dirty: DirtySet(ranges: [NSRange(location: 0, length: (changed as NSString).length)],
                            isWholesale: false))
        #expect(view.pendingResizeRequestForTesting == .lineCount)
    }

    @Test("mode switches do not force layout in the property setter")
    func modeSwitchUsesDeferredViewportPath() {
        let source = "# Heading\n\nText"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 400), storage: storage)
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)

        view.mode = .source

        #expect(view.pendingResizeRequestForTesting == .viewport)
    }
}
    @Test("local typing keeps the viewport pixel-stable across parse commit")
    func localTypingDoesNotRescrollTheDocument() async throws {
        let paragraph = "A paragraph with enough words to form a stable line of document text."
        let text = (0..<80).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        container.layoutSubtreeIfNeeded()
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()

        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 700))
        container.scrollView.reflectScrolledClipView(clip)
        let editOffset = container.textView.topVisibleOffset + 8

        #expect(container.textView.performSourceEdit(
            range: NSRange(location: editOffset, length: 0),
            replacement: "x"
        ))
        let originAfterKeystroke = clip.bounds.origin
        let changed = storage.string
        container.textView.update(
            document: MarkdownParser.parse(changed),
            dirty: DirtySet(ranges: [NSRange(location: editOffset, length: 1)], isWholesale: false)
        )

        try await Task.sleep(for: .milliseconds(140))
        #expect(abs(clip.bounds.origin.y - originAfterKeystroke.y) < 0.5)
        #expect(abs(clip.bounds.origin.x - originAfterKeystroke.x) < 0.5)
    }
