import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

@Suite("Content resize")
@MainActor
struct ContentResizeTests {
    @Test("paragraph-preserving edits let the caret wrap without scrolling")
    func typingCanWrapWithoutMovingTheViewport() async throws {
        let text = (0..<80).map {
            "## Section \($0)\n\nParagraph \($0) " + String(repeating: "some words wrap here. ", count: 12)
        }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let pane = MarkdownContainerView(storage: storage)
        pane.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        pane.layoutSubtreeIfNeeded()
        let view = pane.textView
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        view.resizeToFitContent()
        let caret = (text as NSString).range(of: "Paragraph 40").location + 60
        view.setSourceSelectedRanges([NSRange(location: caret, length: 0)])
        view.scroll(toOffset: caret, position: .center, animated: false)
        let clip = pane.scrollView.contentView
        let beforeY = clip.bounds.minY
        let beforeCaretY = try #require(view.rect(forOffset: caret)).minY - beforeY
        let replacement = String(repeating: "more words to wrap. ", count: 6)
        #expect(view.performSourceEdit(range: NSRange(location: caret, length: 0), replacement: replacement))
        view.update(document: MarkdownParser.parse(storage.string), dirty: DirtySet(
            ranges: [NSRange(location: caret, length: (replacement as NSString).length)], isWholesale: false))
        try await Task.sleep(for: .milliseconds(150))
        let afterCaretY = try #require(view.rect(forOffset: view.sourceSelectedRange.location)).minY - clip.bounds.minY
        #expect(afterCaretY > beforeCaretY + view.styleSheet.lineHeight)
        #expect(abs(clip.bounds.minY - beforeY) < 0.5)
    }

    @Test("laid-out reading anchors round-trip without moving the camera",
          arguments: [(13.5, 80), (16, 80), (17.25, 80), (18, 80), (19.5, 80), (22, 80), (16, 1_600)])
    func laidOutAnchorDoesNotMoveCamera(bodySize: Double, sectionCount: Int) throws {
        var theme = MarkdownTextView.fallbackStyleSheet().theme
        theme.typography.bodySize = CGFloat(bodySize)
        let appearance = try #require(NSAppearance(named: .aqua))
        let style = StyleSheet(theme: theme, appearance: appearance)
        let text = (0..<sectionCount).map {
            "## Section \($0)\n\nParagraph \($0) "
                + String(repeating: "Some **formatted** words wrap onto another line. ", count: 12)
        }.joined(separator: "\n\n")
        let pane = MarkdownContainerView(storage: NSTextStorage(string: text), styleSheet: style)
        pane.frame = NSRect(x: 0, y: 0, width: 900, height: 640)
        pane.layoutSubtreeIfNeeded()
        let view = pane.textView
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        view.resizeToFitContent()
        let target = (text as NSString).range(of: "Paragraph \(sectionCount / 2)").location + 180
        view.scroll(toOffset: target, position: .top, animated: false)
        view.prepareForDisplay()
        let clip = pane.scrollView.contentView
        let before = clip.bounds.minY
        for _ in 0..<5 {
            let anchor = try #require(view.laidOutViewportAnchor())
            view.restoreViewport(to: anchor)
            #expect(abs(clip.bounds.minY - before) < 0.5,
                    "capturing and restoring an unchanged line drifted the camera")
        }
    }

    @Test("display repairs a native frame narrower than its text container")
    func displayRestoresContainerWidthAfterNativeShrink() throws {
        let text = "A paragraph with enough source text and a [link](https://example.com/longer/path) to use the full column.\n"
        let pane = MarkdownContainerView(storage: NSTextStorage(string: text))
        pane.frame = NSRect(x: 0, y: 0, width: 1_020, height: 700)
        pane.layoutSubtreeIfNeeded()
        let view = pane.textView
        view.mode = .source
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        view.minSize = .zero
        view.setFrameSize(NSSize(width: 200, height: view.frame.height))
        view.prepareForDisplay()
        let required = try #require(view.textContainer).size.width + 2 * view.textContainerInset.width
        #expect(view.frame.width >= required)
        #expect(view.string == text)
    }

    @discardableResult
    private func pumpMainQueue(
        until condition: () -> Bool,
        timeout: Duration = .seconds(1)
    ) async -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !condition() && clock.now < deadline {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            if !condition() {
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        return condition()
    }

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

        #expect(await pumpMainQueue { view.pendingResizeRequestForTesting == nil })
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
            #expect(await pumpMainQueue {
                container.textView.pendingResizeRequestForTesting == nil
            })
        }
        #expect(container.textView.frame.height <= settledHeight + 0.5)
    }

    @Test("local typing keeps visible content stable across parse commit")
    func localTypingKeepsVisibleContentStable() async throws {
        let paragraph = "A paragraph with enough words to form a stable line of document text."
        let text = (0..<80).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        container.layoutSubtreeIfNeeded()
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()
        #expect(container.textView.cachedLayoutElementCountForTesting > 0)

        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 700))
        container.scrollView.reflectScrolledClipView(clip)
        let anchor = container.textView.topVisibleOffset
        var editOffset = anchor + 8

        func anchorScreenY() throws -> CGFloat {
            try #require(container.textView.rect(forOffset: anchor)).minY - clip.bounds.origin.y
        }

        let screenYBeforeEdit = try anchorScreenY()

        for character in "stable typing" {
            #expect(container.textView.performSourceEdit(
                range: NSRange(location: editOffset, length: 0),
                replacement: String(character)
            ))
            #expect(
                container.textView.cachedLayoutElementCountForTesting > 0,
                "typing discarded every resolved layout element"
            )
            #expect(abs(try anchorScreenY() - screenYBeforeEdit) < 0.5)
            let changed = storage.string
            container.textView.update(
                document: MarkdownParser.parse(changed),
                dirty: DirtySet(
                    ranges: [NSRange(location: editOffset, length: 1)],
                    isWholesale: false
                )
            )
            #expect(abs(try anchorScreenY() - screenYBeforeEdit) < 0.5)
            editOffset += 1
        }

        #expect(await pumpMainQueue {
            container.textView.pendingResizeRequestForTesting == nil
        })
        #expect(abs(try anchorScreenY() - screenYBeforeEdit) < 0.5)
    }

    @Test("typing does not move an unchanged visible line between parse commits")
    func typingHasNoIntermediateCameraMovement() async throws {
        let text = (0..<80).map {
            "## Section \($0)\n\nA short paragraph \($0) with room to type."
        }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 420),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.close() }
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        view.resizeToFitContent()
        let source = text as NSString
        let paragraph = source.range(of: "paragraph 40").location
        var caret = source.range(of: "room to type.", options: [],
            range: NSRange(location: paragraph, length: source.length - paragraph)).location
        view.setSourceSelectedRanges([NSRange(location: caret, length: 0)])
        view.scroll(toOffset: caret, position: .center, animated: false)
        try await Task.sleep(for: .milliseconds(150))
        let clip = container.scrollView.contentView
        let initialY = clip.bounds.minY
        var observedY: [CGFloat] = []
        let observer = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification, object: clip, queue: .main
        ) { _ in
            MainActor.assumeIsolated { observedY.append(clip.bounds.minY) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        for character in "steady" {
            #expect(view.performSourceEdit(range: NSRange(location: caret, length: 0), replacement: String(character)))
            view.update(document: MarkdownParser.parse(storage.string),
                        dirty: DirtySet(ranges: [NSRange(location: caret, length: 1)], isWholesale: false))
            caret += 1
            try await Task.sleep(for: .milliseconds(30))
        }
        try await Task.sleep(for: .milliseconds(150))
        #expect(abs(clip.bounds.minY - initialY) < 0.5)
        #expect(observedY.allSatisfy { abs($0 - initialY) < 0.5 },
                "typing exposed intermediate camera positions: \(observedY)")
    }

    @Test("repeated typing leaves one ordered layout fragment per source element")
    func repeatedTypingDoesNotStackStaleFragments() throws {
        let paragraph = "A paragraph with enough words to form several stable lines of rendered text."
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
        var editOffset = container.textView.topVisibleOffset + 8

        for character in "stacked fragments" {
            let expectedInvalidationStart = container.textView
                .paragraphRange(containing: editOffset).location
            #expect(container.textView.performSourceEdit(
                range: NSRange(location: editOffset, length: 0),
                replacement: String(character)
            ))
            let invalidated = try #require(
                container.textView.lastFragmentInvalidationRangeForTesting
            )
            #expect(invalidated.location == expectedInvalidationStart)
            #expect(invalidated.upperBound == storage.length)
            let changed = storage.string
            container.textView.update(
                document: MarkdownParser.parse(changed),
                dirty: DirtySet(
                    ranges: [NSRange(location: editOffset, length: 1)],
                    isWholesale: false
                )
            )
            editOffset += 1
        }

        let layout = try #require(container.textView.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var previousMaxY = -CGFloat.greatestFiniteMagnitude
        var sourceOffsets: [Int] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location) { fragment in
            let offset = layout.offset(
                from: layout.documentRange.location,
                to: fragment.rangeInElement.location
            )
            sourceOffsets.append(offset)
            #expect(
                fragment.layoutFragmentFrame.minY + 0.5 >= previousMaxY,
                "layout fragments overlap or move backwards at source offset \(offset)"
            )
            previousMaxY = fragment.layoutFragmentFrame.maxY
            return true
        }
        #expect(sourceOffsets == sourceOffsets.sorted())
        #expect(Set(sourceOffsets).count == sourceOffsets.count)
    }

    /// The other half of the same promise, on the path a local edit does *not*
    /// take: an external change, a debounced second parse, a theme swap.  Those
    /// restore the reading position from a source anchor, and the restore used
    /// to scroll that anchor to `.top` — parking its line at the container
    /// inset regardless of where the reader had it.  Every commit therefore
    /// shoved the page by the leftover fraction of a line plus the inset, which
    /// is what "the camera teleports while I type" looks like from the outside.
    ///
    /// A mid-line viewport is the case that catches it: land the clip somewhere
    /// that is deliberately *not* a line boundary and require it to stay there.
    @Test("a reparse that is not a local edit leaves the viewport exactly where it was")
    func nonLocalReparseKeepsThePixelViewport() async throws {
        let paragraph = "A paragraph with enough words to form a stable line of document text."
        let text = (0..<80).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        container.layoutSubtreeIfNeeded()
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()

        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 703))
        container.scrollView.reflectScrolledClipView(clip)

        // What the reader can see is where the anchor line sits *on screen*,
        // not what the clip origin reads.  Resolving lazy layout legitimately
        // moves a line in document coordinates; the promise is that the clip
        // follows it so the glyphs under the reader's eye do not move.
        let anchor = container.textView.topVisibleOffset
        func screenY() throws -> CGFloat {
            try #require(container.textView.rect(forOffset: anchor)).minY - clip.bounds.origin.y
        }
        let before = try screenY()

        // No `performSourceEdit` first, so `shouldFollowCaretAfterLocalEdit` is
        // false and the commit goes down the anchor-restoring branch.
        container.textView.update(
            document: MarkdownParser.parse(text),
            dirty: DirtySet(ranges: [NSRange(location: 40, length: 1)], isWholesale: false)
        )
        #expect(abs(try screenY() - before) < 0.5, "the commit moved the page")

        #expect(await pumpMainQueue {
            container.textView.pendingResizeRequestForTesting == nil
        })
        #expect(abs(try screenY() - before) < 0.5, "the deferred resize moved the page")
    }

    @Test("a shared-storage edit keeps the source camera through TextKit repair")
    func sharedStorageEditKeepsThePixelViewport() async throws {
        let paragraph = "A paragraph with enough words to form a stable line of document text."
        let text = (0..<80).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        container.layoutSubtreeIfNeeded()
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()

        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 703))
        container.scrollView.reflectScrolledClipView(clip)
        let anchor = container.textView.topVisibleOffset
        let editOffset = min(storage.length, anchor + 4)
        let before = try #require(container.textView.rect(forOffset: anchor)).minY
            - clip.bounds.origin.y
        let edit = TextEdit(
            range: NSRange(location: editOffset, length: 0),
            replacement: "x",
            summary: "External edit"
        )

        container.textView.prepareForExternalDocumentEdits([edit])
        storage.replaceCharacters(in: edit.range, with: edit.replacement)
        container.textView.update(
            document: MarkdownParser.parse(storage.string),
            dirty: DirtySet(
                ranges: [NSRange(location: editOffset, length: 1)],
                isWholesale: false
            )
        )
        #expect(
            abs(try #require(container.textView.rect(forOffset: anchor)).minY
                - clip.bounds.origin.y - before) < 0.5,
            "the shared-storage edit moved the page"
        )

        #expect(await pumpMainQueue {
            container.textView.pendingResizeRequestForTesting == nil
        })
        #expect(
            abs(try #require(container.textView.rect(forOffset: anchor)).minY
                - clip.bounds.origin.y - before) < 0.5,
            "the deferred shared-storage repair moved the page"
        )
    }

    @Test("a rendered local edit survives AppKit's deferred caret scroll")
    func localEditKeepsThePixelViewportAfterCaretRepair() async throws {
        let paragraph = "A paragraph with enough words to form a stable line of document text."
        let text = (0..<80).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        container.layoutSubtreeIfNeeded()
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()

        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 703))
        container.scrollView.reflectScrolledClipView(clip)
        let anchor = container.textView.topVisibleOffset
        let before = try #require(container.textView.rect(forOffset: anchor)).minY
            - clip.bounds.origin.y

        let editOffset = min(storage.length, anchor + 4)
        #expect(container.textView.performSourceEdit(
            range: NSRange(location: editOffset, length: 0), replacement: "x"
        ))
        container.textView.update(
            document: MarkdownParser.parse(storage.string),
            dirty: DirtySet(ranges: [NSRange(location: editOffset, length: 1)], isWholesale: false)
        )

        // Simulate NSTextView's late make-caret-visible correction.
        clip.scroll(to: .zero)
        container.scrollView.reflectScrolledClipView(clip)
        #expect(await pumpMainQueue {
            guard let rect = container.textView.rect(forOffset: anchor) else { return false }
            return abs(rect.minY - clip.bounds.origin.y - before) < 0.5
        })

        let after = try #require(container.textView.rect(forOffset: anchor)).minY
            - clip.bounds.origin.y
        #expect(abs(after - before) < 0.5, "the deferred caret repair moved the page")
    }

    @Test("a newer deletion supersedes a queued parse camera repair")
    func deletionSupersedesQueuedCameraRepair() async throws {
        let text = (0..<80).map {
            "## Section \($0)\n\nParagraph \($0) with **formatted** words."
        }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        view.resizeToFitContent()
        let target = (text as NSString).range(of: "Paragraph 40").location
        view.scroll(toOffset: target, position: .top, animated: false)
        #expect(view.performSourceEdit(range: NSRange(location: target + 12, length: 0), replacement: "x"))
        view.update(
            document: MarkdownParser.parse(storage.string),
            dirty: DirtySet(ranges: [NSRange(location: target, length: 20)], isWholesale: false))

        // A second key can arrive before the first commit's deferred repairs.
        // Delete a selection ending at the top visible paragraph while the
        // next parse is still pending.
        let anchor = view.captureViewportAnchor()
        let deletion = NSRange(location: anchor.offset - 80, length: 80)
        #expect(view.performSourceEdit(range: deletion, replacement: ""))
        let currentOffset = anchor.offset - 80
        let clip = container.scrollView.contentView
        let screenY = try #require(view.rect(forOffset: currentOffset)).minY - clip.bounds.minY
        try await Task.sleep(for: .milliseconds(150))
        let settledY = try #require(view.rect(forOffset: currentOffset)).minY - clip.bounds.minY
        #expect(abs(settledY - screenY) < 0.5, "an older parse repair overrode the newer edit's camera")
    }

    @Test("undo camera repair survives AppKit's deferred caret scroll")
    func undoCameraRepairRunsAfterTheCommand() async {
        let text = (0..<80).map { "## Section \($0)\n\nParagraph \($0)" }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        container.layoutSubtreeIfNeeded()
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()

        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 703))
        container.scrollView.reflectScrolledClipView(clip)
        container.textView.preserveViewportAcrossUndoRedo()

        storage.replaceCharacters(in: NSRange(location: 16, length: 1), with: "x")
        container.textView.update(
            document: MarkdownParser.parse(storage.string),
            dirty: DirtySet(ranges: [NSRange(location: 16, length: 1)], isWholesale: false)
        )

        // NSTextView can make the restored selection visible after storage
        // observers have returned. The queued repair and the later semantic
        // height pass must both preserve the command-boundary pixel camera.
        clip.scroll(to: .zero)
        container.scrollView.reflectScrolledClipView(clip)
        #expect(await pumpMainQueue { abs(clip.bounds.origin.y - 703) < 0.5 })

        #expect(abs(clip.bounds.origin.y - 703) < 0.5)
        #expect(await pumpMainQueue { abs(clip.bounds.origin.y - 703) < 0.5 })
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

    @Test("document replacement discards the previous camera and queued resize repairs", arguments: [1, 2_500])
    func documentReplacementResetsQueuedCameraRepairs(replacementParagraphCount: Int) async {
        let originalParagraphCount = replacementParagraphCount == 1 ? 100 : 5_000
        let text = (0..<originalParagraphCount).map { "Paragraph \($0) has enough text to keep the document tall." }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        view.resizeToFitContent()
        let clip = container.scrollView.contentView
        let oldHeight = view.frame.height
        clip.scroll(to: NSPoint(x: 0, y: view.frame.height - clip.bounds.height))
        container.scrollView.reflectScrolledClipView(clip)
        #expect(clip.bounds.minY > 400)
        view.mode = .source
        view.preserveViewportOnNextDocumentUpdate()
        #expect(view.pendingResizeRequestForTesting != nil)

        let replacement = (0..<replacementParagraphCount).map { "New paragraph \($0)." }.joined(separator: "\n\n")
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: replacement)
        view.update(document: MarkdownParser.parse(replacement), dirty: .wholesale, preservingSelection: false)
        view.prepareForDisplay()
        #expect(view.frame.height < oldHeight - clip.bounds.height)
        #expect(view.cachedLayoutElementCountForTesting > 0)
        #expect(view.cachedLayoutElementCountForTesting < 1_000)
        #expect(abs(clip.bounds.minY) < 0.5)
        #expect(view.pendingResizeRequestForTesting == nil)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(abs(clip.bounds.minY) < 0.5)
        #expect(storage.string == replacement)
    }

    @Test("chrome repairs cannot restore a previous document's camera", arguments: [false, true], [false, true])
    func retainedChromeRepairDoesNotCrossDocuments(targeted: Bool, invokedBeforeReplacement: Bool) async {
        let text = (0..<100).map { "Original paragraph \($0)." }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 700))
        container.scrollView.reflectScrolledClipView(clip)
        let repair = targeted ? view.makeViewportRepair(at: view.topVisibleOffset) : view.makeViewportRepair()
        if invokedBeforeReplacement { repair() }

        let replacement = text.replacingOccurrences(of: "Original", with: "Replacement")
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: replacement)
        view.update(document: MarkdownParser.parse(replacement), dirty: .wholesale, preservingSelection: false)
        view.scroll(toOffset: 0, position: .top, animated: false)
        #expect(abs(clip.bounds.minY) < 0.5)
        if !invokedBeforeReplacement { repair() }
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(abs(clip.bounds.minY) < 0.5)
    }

    @Test("already-visible navigation keeps the queued camera repair")
    func visibleNavigationPreservesQueuedRepair() async throws {
        let text = (0..<100).map { "Paragraph \($0) keeps the document tall." }.joined(separator: "\n\n")
        let container = MarkdownContainerView(storage: NSTextStorage(string: text))
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 900))
        container.scrollView.reflectScrolledClipView(clip)
        let anchor = view.captureViewportAnchor()
        view.mode = .source
        #expect(view.pendingResizeRequestForTesting == .viewport)
        view.scroll(toOffset: anchor.offset, position: .visible, animated: false)
        // AppKit can make a late caret correction before the queued repair.
        clip.scroll(to: .zero)
        #expect(await pumpMainQueue { view.pendingResizeRequestForTesting == nil })
        let rect = try #require(view.rect(forOffset: anchor.offset))
        #expect(abs(clip.bounds.minY - rect.minY - anchor.gap) < 1)
    }

    @Test("queued reflow repair retires an animation's stale pixel target")
    func reflowRepairRetiresScrollSpring() async {
        let text = (0..<100).map { "Paragraph \($0) keeps the document tall." }.joined(separator: "\n\n")
        let container = MarkdownContainerView(storage: NSTextStorage(string: text))
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 400)
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 900))
        container.scrollView.reflectScrolledClipView(clip)
        // Drive the production spring directly: this source test has no
        // on-screen window or display link and must not create one.
        view.startAnimatedScroll(to: 1_800, in: clip)
        view.mode = .source
        #expect(await pumpMainQueue { view.pendingResizeRequestForTesting == nil })
        let repairedY = clip.bounds.minY
        _ = view.documentMotionTick(dt: 1)
        view.documentMotionApply()
        #expect(abs(clip.bounds.minY - repairedY) < 1)
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

    @Test("Document and Source mode keep a deep reading position")
    func modeSwitchPreservesDeepViewportAnchor() async throws {
        let paragraph = "A paragraph with enough words to keep the source and rendered views tall."
        let source = (0..<70).map {
            "## Section \($0)\n\n\(paragraph)"
        }.joined(separator: "\n\n")
        let storage = NSTextStorage(string: source)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 420)
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        view.resizeToFitContent()

        let clip = container.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 900))
        container.scrollView.reflectScrolledClipView(clip)
        let anchor = view.topVisibleOffset
        let before = try #require(view.rect(forOffset: anchor)).minY - clip.bounds.origin.y

        view.mode = .source
        #expect(await pumpMainQueue {
            guard let rect = view.rect(forOffset: anchor) else { return false }
            return abs(rect.minY - clip.bounds.origin.y - before) < 1
        })
        let sourceAfter = try #require(view.rect(forOffset: anchor)).minY - clip.bounds.origin.y
        #expect(abs(sourceAfter - before) < 1, "Source mode moved the reading position")

        view.mode = .live
        #expect(await pumpMainQueue {
            guard let rect = view.rect(forOffset: anchor) else { return false }
            return abs(rect.minY - clip.bounds.origin.y - before) < 2
        })
        let documentAfter = try #require(view.rect(forOffset: anchor)).minY - clip.bounds.origin.y
        // The rendered heading font and the source mono font have a small
        // baseline difference; the source anchor must remain in the same
        // reading band, not land at a new page position.
        #expect(abs(documentAfter - before) < 2, "Document mode moved the reading position")
    }
}
