import AppKit
import Foundation
import Testing

@testable import MarkdownRender

// Regression cover for the launch hang.
//
// `MarkdownContentStorage` vends custom TextKit 2 element ranges so grouped
// prose can wrap against the document measure.  The load-bearing invariant is
// that those ranges *tile* `[0, length)`: first starts at 0, each starts where
// the previous ended, and the last ends at the document length.  TextKit
// resumes enumeration from the location the storage returns, so a set that
// covers nothing — a paragraph index built before the text landed produced a
// single `{0, 0}` range for a 5041-character document — or that leaves a gap
// makes `enumerateTextElements` hand back the location it was given.
// `NSTextLayoutManager.ensureLayoutForBounds` then asks for the same location
// forever, and the app hangs on opening any document.
//
// `tiles`, `sourceRanges`, and `usesCustomLayout` are private, so these tests
// assert the invariant where it is observable and where it actually bites: the
// element ranges TextKit is handed, walked the way the layout manager walks
// them.

@Suite("Content storage tiling")
@MainActor
struct ContentStorageTilingTests {

    // MARK: - Documents

    /// Hard-wrapped prose: several source lines per visual paragraph, a blank
    /// line, then a second block.  No trailing newline, so every physical
    /// paragraph is non-empty.
    private static let wrapped = """
        Alpha beta gamma delta
        epsilon zeta eta theta
        iota kappa lambda

        A second block that stands on its own.
        """

    // MARK: - (a) A stale index must not enable custom layout

    /// The exact shape that hung: a paragraph index that knows nothing about
    /// the text in the storage.  Covering nothing is not "cover it all with one
    /// empty element" — it must fall back to `super`, which still tiles.
    @Test("an empty paragraph index leaves layout to super instead of vending {0, 0}")
    func emptyParagraphIndexDoesNotTakeOverLayout() {
        let text = Self.wrapped
        let (content, storage) = Self.makeStorage(text)
        content.configure(paragraphIndex: .empty, reflowRanges: [], displayMap: .identity)

        let ranges = Self.walkElements(content, length: storage.length)
        Self.expectTiles(ranges, length: storage.length)
        // A single degenerate element is the failure being guarded against; the
        // fallback reproduces the physical paragraphs one for one.
        #expect(ranges.count == Self.physicalElementCount(of: text))
        #expect(ranges.count > 1)
    }

    /// The same failure with a plausible-looking index: one built from an
    /// earlier, shorter revision of the document.  It covers a prefix, which
    /// leaves the tail uncovered, so it is refused too.
    @Test("a paragraph index from a shorter revision is refused")
    func staleShorterParagraphIndexIsRefused() {
        let text = Self.wrapped
        let (content, storage) = Self.makeStorage(text)
        let stale = ParagraphIndex(text: "Alpha beta gamma delta\n" as NSString)
        #expect(stale.length < storage.length)
        content.configure(paragraphIndex: stale, reflowRanges: [], displayMap: .identity)

        let ranges = Self.walkElements(content, length: storage.length)
        Self.expectTiles(ranges, length: storage.length)
        #expect(ranges.count == Self.physicalElementCount(of: text))
    }

    // MARK: - (b) The plain case

    @Test("a correct index with no reflow tiles as one element per physical paragraph")
    func physicalParagraphsTile() {
        let text = Self.wrapped
        let (content, storage) = Self.makeStorage(text)
        let index = ParagraphIndex(text: text as NSString)
        content.configure(paragraphIndex: index, reflowRanges: [], displayMap: .identity)

        let ranges = Self.walkElements(content, length: storage.length)
        Self.expectTiles(ranges, length: storage.length)
        let physical = (0..<index.starts.count).map { index.range(at: $0) }
        #expect(ranges == physical)
    }

    // MARK: - (c) Reflow groups that straddle a paragraph boundary

    /// A hard-wrap group is free to begin and end inside a physical paragraph.
    /// Skipping the straddled paragraphs — rather than clipping them to the
    /// group's bounds — left holes on both sides, the tiling check failed, and
    /// hard-wrap reflow silently stopped working for the whole document.
    @Test("a reflow group straddling paragraph boundaries still tiles")
    func straddlingReflowGroupTiles() {
        let text = Self.wrapped as NSString
        let (content, storage) = Self.makeStorage(text as String)
        let index = ParagraphIndex(text: text)

        // Start inside the first source line and end inside the third: both
        // ends fall strictly inside a physical paragraph.
        let start = text.range(of: "beta").location
        let end = text.range(of: "kappa").upperBound
        let group = NSRange(location: start, length: end - start)
        #expect(index.paragraphRange(containing: group.location).location < group.location)
        #expect(index.paragraphRange(containing: group.upperBound - 1).upperBound > group.upperBound)

        content.configure(paragraphIndex: index, reflowRanges: [group], displayMap: .identity)

        let ranges = Self.walkElements(content, length: storage.length)
        Self.expectTiles(ranges, length: storage.length)
        // The group is vended whole: that is the point of custom layout, and it
        // proves the tiling check accepted these ranges rather than falling
        // back to one element per physical line.
        #expect(ranges.contains(group))
    }

    // MARK: - (d) Trailing newline / zero-length final paragraph

    /// A terminator at the very end leaves an empty final paragraph, which is
    /// real to TextKit.  The ranges must still tile, and the walk must still
    /// reach the end of the document rather than stalling on the empty tail.
    @Test("a trailing newline leaves a zero-length final paragraph that still tiles")
    func trailingNewlineTiles() {
        let text = (Self.wrapped + "\n") as NSString
        let index = ParagraphIndex(text: text)
        #expect(index.range(at: index.starts.count - 1).length == 0)

        let (plain, plainStorage) = Self.makeStorage(text as String)
        plain.configure(paragraphIndex: index, reflowRanges: [], displayMap: .identity)
        Self.expectTiles(Self.walkElements(plain, length: plainStorage.length), length: plainStorage.length)

        // The same document with a reflow group, so custom layout is provably
        // the code path under test and not a silent fallback to `super`.
        let start = text.range(of: "Alpha").location
        let end = text.range(of: "lambda").upperBound
        let group = NSRange(location: start, length: end - start)
        let (grouped, groupedStorage) = Self.makeStorage(text as String)
        grouped.configure(paragraphIndex: index, reflowRanges: [group], displayMap: .identity)
        let ranges = Self.walkElements(grouped, length: groupedStorage.length)
        Self.expectTiles(ranges, length: groupedStorage.length)
        #expect(ranges.contains(group))
    }

    // MARK: - Harness

    private static func makeStorage(_ text: String) -> (MarkdownContentStorage, NSTextStorage) {
        let textStorage = NSTextStorage(string: text)
        let content = MarkdownContentStorage()
        content.textStorage = textStorage
        return (content, textStorage)
    }

    /// Element count a stock `NSTextContentStorage` produces for `text`, walked
    /// identically — the baseline the fallback path has to match.
    private static func physicalElementCount(of text: String) -> Int {
        let content = NSTextContentStorage()
        let storage = NSTextStorage(string: text)
        content.textStorage = storage
        return walkElements(content, length: storage.length).count
    }

    /// Walks the storage the way `NSTextLayoutManager` fills a viewport: ask
    /// for one element, stop, then resume from the location the storage handed
    /// back.  A location that fails to advance is the hang, so it is recorded
    /// as a failure instead of being looped on.
    private static func walkElements(
        _ content: NSTextContentStorage,
        length: Int
    ) -> [NSRange] {
        let origin = content.documentRange.location
        var ranges: [NSRange] = []
        var offset = 0
        var steps = 0

        while offset < length {
            steps += 1
            guard steps <= length + 8 else {
                Issue.record("enumeration never reached the end of the document")
                break
            }
            guard let from = content.location(origin, offsetBy: offset) else {
                Issue.record("no text location at offset \(offset)")
                break
            }

            var delivered: NSRange?
            let resume = content.enumerateTextElements(from: from) { element in
                if let range = element.elementRange {
                    delivered = NSRange(
                        location: content.offset(from: origin, to: range.location),
                        length: content.offset(from: range.location, to: range.endLocation)
                    )
                }
                return false  // one element per call, exactly like viewport layout
            }

            guard let range = delivered else {
                Issue.record("no element delivered from offset \(offset)")
                break
            }
            ranges.append(range)

            guard let resume else {
                Issue.record("no resume location returned from offset \(offset)")
                break
            }
            let next = content.offset(from: origin, to: resume)
            guard next > offset else {
                Issue.record("enumeration did not advance past offset \(offset) — this is the launch hang")
                break
            }
            offset = next
        }
        return ranges
    }

    /// `ranges` partition `[0, length)`: no gap, no overlap, no short tail.
    private static func expectTiles(
        _ ranges: [NSRange],
        length: Int,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(!ranges.isEmpty, "no element ranges at all", sourceLocation: sourceLocation)
        var cursor = 0
        for range in ranges {
            #expect(
                range.location == cursor,
                "element \(NSStringFromRange(range)) does not start at \(cursor)",
                sourceLocation: sourceLocation
            )
            cursor = range.upperBound
        }
        #expect(cursor == length, "elements end at \(cursor), document is \(length)", sourceLocation: sourceLocation)
    }
}
