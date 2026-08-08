import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

/// Nested lists are the shape agent-written markdown arrives in, and two
/// defects made them read wrong in opposite directions.
///
/// **Every ornament past the first level was invisible.** The parser leaves a
/// block's container indentation out of its range, so a nested item's range
/// starts at its own marker while the enclosing item still spans the leading
/// columns.  `FragmentProvider` resolved a paragraph's payload by reading the
/// attribute at the paragraph's *first character* — which on an indented line
/// belongs to the parent.  `ListOrnamentFragment` then saw a payload whose
/// block began on an earlier line, concluded it was a continuation paragraph,
/// and drew nothing.  Bullets, ordered numbers, and checkboxes all disappeared
/// from depth two down, at every nesting level, in every list.
///
/// **A completed parent crossed out its whole subtree.** The strikethrough was
/// applied to the item's `contentRange`, which spans its nested children, so an
/// open sub-task rendered struck through and dimmed — stating the opposite of
/// its actual state.
///
/// Both are asserted structurally rather than by pixel: an ornament that
/// resolves to its own block is one that draws, and `isFirstParagraphOfBlock`
/// is the exact predicate `drawObject` gates on.
@Suite("List ornaments and task completion")
@MainActor
struct ListOrnamentTests {

    private static func makeContainer(_ text: String) -> MarkdownContainerView {
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 1000, height: 900)
        container.layoutSubtreeIfNeeded()
        container.textView.mode = .read
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.textView.resizeToFitContent()
        return container
    }

    private static func ornaments(in container: MarkdownContainerView) -> [ListOrnamentFragment] {
        guard let layout = container.textView.textLayoutManager else { return [] }
        layout.ensureLayout(for: layout.documentRange)
        var result: [ListOrnamentFragment] = []
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location,
                                            options: [.ensuresLayout]) { fragment in
            if let ornament = fragment as? ListOrnamentFragment { result.append(ornament) }
            return true
        }
        return result
    }

    /// The ornaments that actually put a mark on screen: `drawObject` returns
    /// immediately unless the fragment owns the block's first paragraph.
    private static func drawnOrnaments(in container: MarkdownContainerView) -> [ListOrnamentFragment] {
        ornaments(in: container).filter(\.isFirstParagraphOfBlock)
    }

    // MARK: - Every level draws

    @Test("A bullet is drawn at every nesting depth")
    func nestedBulletsDraw() {
        let container = Self.makeContainer("""
        - level one
          - level two
            - level three
        """)
        let drawn = Self.drawnOrnaments(in: container)
        #expect(drawn.count == 3)
        // Each ornament must resolve to its *own* item, so the three payloads
        // are distinct blocks rather than three views of the outermost one.
        #expect(Set(drawn.map { $0.payload.sourceRange.location }).count == 3)
        #expect(drawn.allSatisfy { $0.payload.detail.hasPrefix("unordered:") })
    }

    @Test("A nested checkbox is drawn and carries its own state")
    func nestedCheckboxesDraw() {
        let container = Self.makeContainer("""
        - [x] checked parent
          - [ ] nested open
          - [x] nested done
        """)
        let details = Self.drawnOrnaments(in: container).map(\.payload.detail)
        #expect(details == ["task:checked", "task:unchecked", "task:checked"])
    }

    @Test("Ordered numbering is drawn when nested")
    func nestedOrderedDraws() {
        let container = Self.makeContainer("""
        1. first
           1. nested first
           2. nested second
        """)
        let details = Self.drawnOrnaments(in: container).map(\.payload.detail)
        #expect(details == ["ordered:1", "ordered:1", "ordered:2"])
    }

    @Test("A plain bullet nested under a task is drawn")
    func bulletUnderTaskDraws() {
        let container = Self.makeContainer("""
        - [ ] task parent
          - plain nested bullet
        """)
        let details = Self.drawnOrnaments(in: container).map(\.payload.detail)
        #expect(details == ["task:unchecked", "unordered:2"])
    }

    @Test("A list nested inside a blockquote still draws")
    func bulletInsideBlockQuoteDraws() {
        let container = Self.makeContainer("""
        > - quoted one
        >   - quoted two
        """)
        #expect(Self.drawnOrnaments(in: container).count == 2)
    }

    /// The counterpart guard: a continuation paragraph belongs to the item but
    /// begins no block of its own, so it must *not* acquire a second bullet.
    @Test("A continuation paragraph does not draw a second ornament")
    func continuationParagraphDrawsNothing() {
        let container = Self.makeContainer("""
        - item with two paragraphs

          the second paragraph

        - next item
        """)
        #expect(Self.drawnOrnaments(in: container).count == 2)
    }

    // MARK: - Completion styling stops at the item

    private static func isStruckThrough(_ container: MarkdownContainerView, _ needle: String) -> Bool {
        let storage = container.textView.textStorage!
        let range = (storage.string as NSString).range(of: needle)
        guard range.location != NSNotFound else {
            Issue.record("'\(needle)' is not in the document")
            return false
        }
        return storage.attribute(.strikethroughStyle, at: range.location, effectiveRange: nil) != nil
    }

    @Test("A completed task strikes its own text")
    func completedTaskIsStruck() {
        let container = Self.makeContainer("- [x] this one is done")
        #expect(Self.isStruckThrough(container, "this one is done"))
    }

    @Test("A completed parent does not strike an open sub-task")
    func completionDoesNotBleedIntoSubtree() {
        let container = Self.makeContainer("""
        - [x] checked parent
          - [ ] nested open
          - [x] nested done
        """)
        #expect(Self.isStruckThrough(container, "checked parent"))
        // The defect: this read `true`, so an open task looked finished.
        #expect(!Self.isStruckThrough(container, "nested open"))
        // A nested *completed* task is still struck — by its own checkbox.
        #expect(Self.isStruckThrough(container, "nested done"))
    }

    @Test("An open parent leaves its subtree alone")
    func openParentDoesNotStrikeSubtree() {
        let container = Self.makeContainer("""
        - [ ] open parent
          - [ ] nested open
          - [x] nested done
        """)
        #expect(!Self.isStruckThrough(container, "open parent"))
        #expect(!Self.isStruckThrough(container, "nested open"))
        #expect(Self.isStruckThrough(container, "nested done"))
    }

    @Test("A completed item's own second paragraph is struck with it")
    func completionCoversTheItemsOwnBlocks() {
        let container = Self.makeContainer("""
        - [x] done item

          still the same item

        - [ ] other
        """)
        #expect(Self.isStruckThrough(container, "done item"))
        #expect(Self.isStruckThrough(container, "still the same item"))
        #expect(!Self.isStruckThrough(container, "other"))
    }
}
