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

    /// Typing at the very end of a document used to grow the document view by
    /// a viewport fraction on every semantic repair, then shrink it back on the
    /// next document-scope pass — clamping the clip view and dropping the whole
    /// page on each keystroke.  The repair must stay content-anchored so the
    /// frame settles and the caret never moves under the user.
    @Test("typing at the document's end does not grow the frame into empty space")
    func semanticRepairStaysContentAnchoredAtTheBottom() async throws {
        let text = "# Heading\n\nA short document.\n\nEnd."
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        container.layoutSubtreeIfNeeded()
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()
        let settledHeight = container.textView.frame.height

        // Pin the clip to the bottom, as AppKit does when the caret lands at
        // the end of the document.
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: max(0, settledHeight - clip.bounds.height)))
        container.scrollView.reflectScrolledClipView(clip)

        // Two keystroke parse commits while pinned to the bottom.
        for _ in 0..<2 {
            container.textView.update(
                document: MarkdownParser.parse(text),
                dirty: DirtySet(
                    ranges: [NSRange(location: (text as NSString).length - 1, length: 1)],
                    isWholesale: false))
            try await Task.sleep(for: .milliseconds(160))
        }
        #expect(container.textView.frame.height <= settledHeight + 0.5)
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

    /// A stale over-tall frame (from an earlier estimate or a shrunk document)
    /// must not shrink while the viewport is pinned to the bottom, or the clip
    /// clamps and the whole page drops.  Once the user scrolls away from the
    /// edge, the frame settles.
    @Test("frame shrink is deferred while the viewport sits at the bottom")
    func shrinkIsDeferredAtTheBottom() throws {
        let text = "# Heading\n\nShort."
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        container.layoutSubtreeIfNeeded()
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()
        let trueHeight = container.textView.frame.height

        // Over-tall frame with the viewport pinned to its bottom.
        container.textView.setFrameSize(
            NSSize(width: container.textView.frame.width, height: trueHeight + 400))
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: container.textView.frame.height - clip.bounds.height))
        container.scrollView.reflectScrolledClipView(clip)

        container.textView.resizeToFitContent()
        #expect(
            container.textView.frame.height > trueHeight + 200,
            "shrank while the viewport was pinned to the bottom"
        )

        // Scrolling away from the edge lets the frame settle.
        clip.scroll(to: .zero)
        container.scrollView.reflectScrolledClipView(clip)
        container.textView.resizeToFitContent()
        #expect(abs(container.textView.frame.height - trueHeight) < 1)
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
