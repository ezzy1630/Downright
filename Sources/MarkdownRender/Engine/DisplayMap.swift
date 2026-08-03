import Foundation

// The single highest-risk piece of arithmetic in the app (§6.1).
//
// §3.1 forbids ever mutating characters, so hiding a marker cannot mean
// deleting it. It means handing TextKit 2 a *different attributed string* for
// the paragraph that contains it. The physical fallback uses
// `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)`,
// while grouped prose uses `MarkdownContentStorage` to vend source-length
// elements. Both keep the backing source untouched and coordinate-safe.
//
// Substitution creates two coordinate spaces that must never be confused:
//
//   * **Source offsets** — UTF-16 offsets into `NSTextStorage`.  The only
//     truth.  Every public API in this package speaks source offsets.
//
//   * **TextKit offsets** — what TextKit 2 reports back.  When the layout
//     manager resolves a point or a caret inside a substituted paragraph it
//     forms the location as
//     `contentManager.location(element.elementRange.location, offsetBy: i)`
//     where `i` indexes the *substituted* string.  So a TextKit offset is
//     "source offset of the paragraph start, plus the display index inside
//     it".  It is neither a source offset nor a document-wide display offset.
//
// Two consequences worth stating out loud, because both are easy to get wrong:
//
//   1. The TextKit space is **not contiguous**.  Paragraph `n`'s TextKit
//      offsets stop short of paragraph `n+1`'s start by exactly the number of
//      characters paragraph `n` lost.  Never do length arithmetic in the
//      TextKit space — convert both endpoints of a range independently.
//
//   2. The map is monotonic non-decreasing in both directions, which is what
//      keeps selection order and hit testing stable.

// MARK: - Paragraph index

/// Start offsets of every paragraph of the source text, where "paragraph"
/// means what `NSTextContentStorage` means by it: a run terminated by `\n`,
/// `\r`, `\r\n`, U+0085, U+2028, or U+2029, with the terminator belonging to
/// the paragraph it ends.
public struct ParagraphIndex: Sendable, Equatable {
    /// Ascending, always begins with 0.
    public let starts: [Int]
    /// UTF-16 length of the text this index was built from.
    public let length: Int

    public init(starts: [Int], length: Int) {
        self.starts = starts.isEmpty ? [0] : starts
        self.length = length
    }

    public static let empty = ParagraphIndex(starts: [0], length: 0)

    /// Single pass over the UTF-16 buffer.
    ///
    /// Rebuilt on every text change and never on a caret move, so it sits on
    /// the keystroke path (§12).  That is why it takes the contiguous-buffer
    /// fast path when `CFString` can hand one over, and falls back to chunked
    /// copies through raw pointers rather than bounds-checked subscripting.
    public init(text: NSString) {
        let n = text.length
        var starts: [Int] = [0]
        starts.reserveCapacity(n / 24 + 8)
        var pendingCR = false

        if n > 0, let contiguous = CFStringGetCharactersPtr(text as CFString) {
            ParagraphIndex.scan(UnsafeBufferPointer(start: contiguous, count: n),
                                base: 0, starts: &starts, pendingCR: &pendingCR)
        } else if n > 0 {
            let chunkSize = 8192
            var buffer = [unichar](repeating: 0, count: chunkSize)
            var base = 0
            while base < n {
                let count = Swift.min(chunkSize, n - base)
                buffer.withUnsafeMutableBufferPointer { raw in
                    guard let pointer = raw.baseAddress else { return }
                    text.getCharacters(pointer, range: NSRange(location: base, length: count))
                    ParagraphIndex.scan(UnsafeBufferPointer(start: pointer, count: count),
                                        base: base, starts: &starts, pendingCR: &pendingCR)
                }
                base += count
            }
        }
        if pendingCR { starts.append(n) }
        // A terminator at the very end leaves an empty final paragraph, which
        // is real to TextKit, so it is kept.
        self.init(starts: starts, length: n)
    }

    private static func scan(
        _ buffer: UnsafeBufferPointer<unichar>,
        base: Int,
        starts: inout [Int],
        pendingCR: inout Bool
    ) {
        guard let pointer = buffer.baseAddress else { return }
        var i = 0
        let count = buffer.count
        while i < count {
            let c = pointer[i]
            // The overwhelmingly common character is none of the terminators;
            // one comparison rejects the whole ASCII printable range.
            if c > 0x0D || c < 0x0A {
                if pendingCR { pendingCR = false; starts.append(base + i) }
                if c == 0x0085 || c == 0x2028 || c == 0x2029 { starts.append(base + i + 1) }
                i += 1
                continue
            }
            if pendingCR {
                pendingCR = false
                // `\r\n` is one terminator: the paragraph starts after the
                // `\n`, not between the two.
                if c == 0x0A { starts.append(base + i + 1); i += 1; continue }
                starts.append(base + i)
            }
            if c == 0x0D { pendingCR = true }
            else if c == 0x0A { starts.append(base + i + 1) }
            i += 1
        }
    }

    /// Index of the paragraph containing `offset`, clamped into range.
    public func index(containing offset: Int) -> Int {
        if offset <= 0 { return 0 }
        var lo = 0, hi = starts.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if starts[mid] <= offset { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    public func start(containing offset: Int) -> Int { starts[index(containing: offset)] }

    public func end(ofParagraphAt index: Int) -> Int {
        index + 1 < starts.count ? starts[index + 1] : length
    }

    public func range(at index: Int) -> NSRange {
        let s = starts[index]
        return NSRange(location: s, length: end(ofParagraphAt: index) - s)
    }

    /// Range of the paragraph containing `offset`.
    public func paragraphRange(containing offset: Int) -> NSRange {
        range(at: index(containing: offset))
    }
}

// MARK: - Range normalisation

public enum RangeSet {
    /// Ascending, non-overlapping, zero-length ranges dropped.  Every hidden
    /// and elided range list in this package passes through here so downstream
    /// code can assume the invariant instead of re-checking it.
    public static func normalized(_ ranges: [NSRange]) -> [NSRange] {
        guard ranges.count > 1 else { return ranges.filter { $0.length > 0 } }
        let sorted = ranges.filter { $0.length > 0 }.sorted {
            $0.location == $1.location ? $0.length < $1.length : $0.location < $1.location
        }
        var out: [NSRange] = []
        out.reserveCapacity(sorted.count)
        for r in sorted {
            if var last = out.last, r.location <= last.upperBound {
                if r.upperBound > last.upperBound {
                    last.length = r.upperBound - last.location
                    out[out.count - 1] = last
                }
            } else {
                out.append(r)
            }
        }
        return out
    }

    /// End of a paragraph's content, i.e. the paragraph range minus its
    /// terminator.
    public static func contentEnd(ofParagraph range: NSRange, text: NSString) -> Int {
        var e = Swift.min(range.upperBound, text.length)
        guard e > range.location else { return range.location }
        let last = text.character(at: e - 1)
        if last == 0x0A || last == 0x0D || last == 0x0085 || last == 0x2028 || last == 0x2029 {
            e -= 1
            if last == 0x0A, e > range.location, text.character(at: e - 1) == 0x0D { e -= 1 }
        }
        return e
    }

    /// Sub-ranges of `ranges` that intersect `window`, clipped to it.
    /// `ranges` must be normalised.
    public static func intersecting(_ ranges: [NSRange], _ window: NSRange) -> [NSRange] {
        var out: [NSRange] = []
        for r in ranges {
            if r.upperBound <= window.location { continue }
            if r.location >= window.upperBound { break }
            let lo = Swift.max(r.location, window.location)
            let hi = Swift.min(r.upperBound, window.upperBound)
            if hi > lo { out.append(NSRange(location: lo, length: hi - lo)) }
        }
        return out
    }

    /// True when a normalised `ranges` covers `offset`
    /// (`location <= offset < upperBound`).
    public static func covers(_ ranges: [NSRange], _ offset: Int) -> Bool {
        var lo = 0, hi = ranges.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            let r = ranges[mid]
            if offset < r.location { hi = mid - 1 }
            else if offset >= r.upperBound { lo = mid + 1 }
            else { return true }
        }
        return false
    }

    /// Projects cached source ranges across one edit while dropping every
    /// range in the edited paragraph span.
    ///
    /// A parse result arrives asynchronously. During that gap, keeping valid
    /// substitutions outside the edit prevents the entire document from
    /// flashing back to raw Markdown. The edited paragraphs deliberately use
    /// identity presentation until the parser supplies authoritative ranges.
    public static func projectedAcrossEdit(
        _ ranges: [NSRange],
        edit: NSRange,
        insertedLength: Int,
        oldParagraphs: ParagraphIndex,
        inputIsNormalized: Bool = false
    ) -> [NSRange] {
        let boundedLocation = Swift.max(0, Swift.min(edit.location, oldParagraphs.length))
        let boundedEnd = Swift.max(
            boundedLocation,
            Swift.min(edit.upperBound, oldParagraphs.length)
        )
        let first = oldParagraphs.index(containing: boundedLocation)
        let lastOffset = Swift.max(boundedLocation, boundedEnd - 1)
        let last = oldParagraphs.index(containing: lastOffset)
        let affected = NSUnionRange(oldParagraphs.range(at: first), oldParagraphs.range(at: last))
        let delta = insertedLength - edit.length

        let projected = ranges.compactMap { range in
            if range.upperBound <= affected.location { return range }
            if range.location >= affected.upperBound {
                return NSRange(location: range.location + delta, length: range.length)
            }
            return nil
        }
        return inputIsNormalized ? projected : normalized(projected)
    }
}

// MARK: - Substitutions

/// One source range replaced in the display string.
///
/// A zero display length is the ordinary hidden-marker representation (§6.1).
/// A positive length is an inline object — today inline math, which becomes a
/// single attachment character carrying the typeset image (§11.3), or a
/// same-length hard-wrap/hidden replacement used by grouped TextKit elements.
/// All are the same operation on the same map, which is why they cannot
/// disagree about caret arithmetic.
public struct DisplaySubstitution {
    public var sourceRange: NSRange
    public var displayLength: Int
    /// Attributed replacement; `nil` means "omit", and its length must equal
    /// `displayLength`.
    public var replacement: NSAttributedString?
    /// True when the source is semantically hidden, even if a grouped TextKit
    /// element has to carry a same-length replacement for coordinate safety.
    public var isHidden: Bool
    /// True only for a soft Markdown break replaced inside a grouped element.
    /// Physical paragraph fallback must retain that element's separator.
    public var isHardWrapReflow: Bool
    /// True when every display position in the replacement has the same
    /// source position. This is required for same-length zero-width content;
    /// inline objects still intentionally collapse to their leading edge.
    public var preservesSourceOffsets: Bool

    public init(
        sourceRange: NSRange,
        displayLength: Int,
        replacement: NSAttributedString? = nil,
        isHidden: Bool = false,
        isHardWrapReflow: Bool = false,
        preservesSourceOffsets: Bool = false
    ) {
        self.sourceRange = sourceRange
        self.displayLength = displayLength
        self.replacement = replacement
        self.isHidden = isHidden
        self.isHardWrapReflow = isHardWrapReflow
        self.preservesSourceOffsets = preservesSourceOffsets
    }

    public static func hide(_ range: NSRange) -> DisplaySubstitution {
        DisplaySubstitution(sourceRange: range, displayLength: 0, replacement: nil, isHidden: true)
    }

    public static func replace(_ range: NSRange, with string: NSAttributedString) -> DisplaySubstitution {
        DisplaySubstitution(sourceRange: range, displayLength: string.length, replacement: string)
    }

    /// Same-length hidden content used by grouped hard-wrap elements. It
    /// keeps the backing range and the attributed string in lockstep while
    /// retaining the semantic hidden-range bookkeeping used by editing and
    /// accessibility.
    public static func replaceHidden(_ range: NSRange, with string: NSAttributedString) -> DisplaySubstitution {
        DisplaySubstitution(
            sourceRange: range,
            displayLength: string.length,
            replacement: string,
            isHidden: true,
            preservesSourceOffsets: true
        )
    }

    /// Same-length display-only space used for an intra-block soft break.
    public static func replaceHardWrap(_ range: NSRange, with string: NSAttributedString) -> DisplaySubstitution {
        DisplaySubstitution(
            sourceRange: range,
            displayLength: string.length,
            replacement: string,
            isHardWrapReflow: true,
            preservesSourceOffsets: true
        )
    }
}

// MARK: - Display map

/// Source ⇄ TextKit offset conversion for a given set of substitutions.
///
/// Immutable and cheap to rebuild: the only mutable inputs are the paragraph
/// index (rebuilt on a text change) and the substitutions (rebuilt on a caret
/// move or a mode change).
public struct DisplayMap {
    public let paragraphs: ParagraphIndex
    /// Ascending, non-overlapping, never crossing a paragraph boundary and
    /// never covering a paragraph terminator.
    private let base: [DisplaySubstitution]
    /// Index into `base` of the first entry in each paragraph, so a conversion
    /// only ever touches its own paragraph's entries.
    private let firstInParagraph: [Int]
    /// One paragraph whose entries replace the base's (§6.1c).
    ///
    /// A caret move changes the substitutions of exactly one paragraph, and a
    /// 5k-line document carries tens of thousands of them.  Rebuilding the
    /// whole set to reveal two asterisks costs milliseconds the keystroke
    /// budget does not have (§12), so a reveal is expressed as an override on
    /// top of the document's collapsed map instead.
    private let overrideParagraph: Int?
    private let overrideEntries: [DisplaySubstitution]
    /// Hidden ranges from `base`, cached while the map is built. Edit
    /// projection must not materialize all effective substitutions when a
    /// transient paragraph override is active.
    private let normalizedBaseHiddenRanges: [NSRange]

    public static let identity = DisplayMap(paragraphs: .empty, substitutions: [])

    /// Sanitisation and the paragraph index are built in one merge pass over
    /// two already-ordered sequences.  A caret move rebuilds this map, so it is
    /// on the keystroke path (§12) and a per-entry binary search over a
    /// document with thousands of markers is a cost worth not paying.
    public init(paragraphs: ParagraphIndex, substitutions: [DisplaySubstitution]) {
        self.paragraphs = paragraphs

        let ordered = DisplayMap.ordered(substitutions)
        var kept: [DisplaySubstitution] = []
        kept.reserveCapacity(ordered.count)
        var first = [Int](repeating: 0, count: paragraphs.starts.count + 1)
        var seen = [Bool](repeating: false, count: paragraphs.starts.count + 1)
        var paragraph = 0
        var lastEnd = 0

        for sub in ordered {
            let range = sub.sourceRange
            guard range.length > 0,
                  range.location >= lastEnd,
                  range.upperBound <= paragraphs.length,
                  sub.displayLength >= 0,
                  (sub.replacement?.length ?? 0) == sub.displayLength else { continue }
            while paragraph + 1 < paragraphs.starts.count, paragraphs.starts[paragraph + 1] <= range.location {
                paragraph += 1
            }
            // A substitution crossing a paragraph terminator would leave the
            // element's range and its content permanently out of step — the one
            // failure mode that silently corrupts every later conversion — so
            // it is refused rather than clipped.
            guard range.upperBound <= paragraphs.end(ofParagraphAt: paragraph) else { continue }
            if !seen[paragraph] {
                seen[paragraph] = true
                first[paragraph] = kept.count
            }
            kept.append(sub)
            lastEnd = range.upperBound
        }
        self.base = kept
        self.normalizedBaseHiddenRanges = kept.compactMap { sub in
            sub.isHidden ? sub.sourceRange : nil
        }

        // Paragraphs with nothing of their own point at the next paragraph's
        // first entry, so `entries(inParagraphAt:)` is defined everywhere.
        var running = kept.count
        for p in stride(from: paragraphs.starts.count - 1, through: 0, by: -1) {
            if seen[p] { running = first[p] } else { first[p] = running }
        }
        first[paragraphs.starts.count] = kept.count
        self.firstInParagraph = first
        self.overrideParagraph = nil
        self.overrideEntries = []
    }

    private init(
        paragraphs: ParagraphIndex,
        base: [DisplaySubstitution],
        firstInParagraph: [Int],
        overrideParagraph: Int?,
        overrideEntries: [DisplaySubstitution],
        normalizedBaseHiddenRanges: [NSRange]
    ) {
        self.paragraphs = paragraphs
        self.base = base
        self.firstInParagraph = firstInParagraph
        self.overrideParagraph = overrideParagraph
        self.overrideEntries = overrideEntries
        self.normalizedBaseHiddenRanges = normalizedBaseHiddenRanges
    }

    /// A map identical to this one except that the entries of the paragraph
    /// containing `offset` are replaced.  O(entries in that paragraph).
    ///
    /// `entries` must be ascending, non-overlapping, and wholly inside that
    /// paragraph's content; anything else is refused and the receiver is
    /// returned unchanged, because a silently mangled map is the one failure
    /// this type exists to prevent.  Only one paragraph may be overridden at a
    /// time — callers derive from the document's collapsed map, never from
    /// another override.
    public func replacingParagraph(containing offset: Int, with entries: [DisplaySubstitution]) -> DisplayMap {
        let p = paragraphs.index(containing: Swift.max(0, Swift.min(offset, paragraphs.length)))
        guard overrideParagraph == nil || overrideParagraph == p else { return self }
        let bounds = paragraphs.range(at: p)
        var previousEnd = bounds.location
        for entry in entries {
            let r = entry.sourceRange
            guard r.length > 0, r.location >= previousEnd, r.upperBound <= bounds.upperBound else { return self }
            previousEnd = r.upperBound
        }
        return DisplayMap(paragraphs: paragraphs, base: base, firstInParagraph: firstInParagraph,
                          overrideParagraph: p, overrideEntries: entries,
                          normalizedBaseHiddenRanges: normalizedBaseHiddenRanges)
    }

    /// A paragraph-local reveal.  The base map already partitions its entries
    /// by paragraph, so dropping a handful of marker substitutions never
    /// needs to scan the document-wide hidden set.
    public func replacingParagraph(containing offset: Int,
                                   excluding sourceRanges: [NSRange]) -> DisplayMap {
        guard !sourceRanges.isEmpty else { return self }
        let p = paragraphs.index(containing: Swift.max(0, Swift.min(offset, paragraphs.length)))
        let kept = entries(inParagraphAt: p).filter { entry in
            !sourceRanges.contains { $0 == entry.sourceRange }
        }
        return replacingParagraph(containing: offset, with: Array(kept))
    }

    /// Hidden substitutions in one paragraph.  This is the companion to the
    /// paragraph override and keeps caret moves off the global range list.
    public func hiddenRanges(inParagraphContaining offset: Int) -> [NSRange] {
        let p = paragraphs.index(containing: Swift.max(0, Swift.min(offset, paragraphs.length)))
        return entries(inParagraphAt: p)
            .filter(\.isHidden)
            .map(\.sourceRange)
    }

    /// All substitutions in one physical paragraph. Used when a transient
    /// composition/reveal must alter hidden markers without dropping the
    /// same-length hard-wrap replacements that keep a grouped element safe.
    public func substitutions(inParagraphContaining offset: Int) -> [DisplaySubstitution] {
        let p = paragraphs.index(containing: Swift.max(0, Swift.min(offset, paragraphs.length)))
        return Array(entries(inParagraphAt: p))
    }

    /// Substitutions intersecting a source range, preserving map order. This
    /// is used by grouped TextKit elements, which can span several physical
    /// source paragraphs while still speaking source coordinates.
    public func substitutions(in sourceRange: NSRange) -> [DisplaySubstitution] {
        let lower = Swift.max(0, Swift.min(sourceRange.location, paragraphs.length))
        let upper = Swift.max(lower, Swift.min(sourceRange.upperBound, paragraphs.length))
        guard upper > lower, !base.isEmpty || !overrideEntries.isEmpty else { return [] }

        let first = paragraphs.index(containing: lower)
        let last = paragraphs.index(containing: Swift.max(lower, upper - 1))
        var result: [DisplaySubstitution] = []
        for paragraph in first...last {
            result.append(contentsOf: entries(inParagraphAt: paragraph).filter {
                $0.sourceRange.location < upper && $0.sourceRange.upperBound > lower
            })
        }
        return result
    }

    /// Ascending by location.  Already-ordered input — which is what every
    /// caller in this package produces — skips the sort after one linear check.
    private static func ordered(_ subs: [DisplaySubstitution]) -> [DisplaySubstitution] {
        var isSorted = true
        for i in 1..<Swift.max(1, subs.count)
        where subs[i - 1].sourceRange.location > subs[i].sourceRange.location {
            isSorted = false
            break
        }
        return isSorted ? subs : subs.sorted { $0.sourceRange.location < $1.sourceRange.location }
    }

    /// Convenience for the common case of pure marker hiding.
    public init(paragraphs: ParagraphIndex, hidden: [NSRange]) {
        self.init(paragraphs: paragraphs, substitutions: hidden.map(DisplaySubstitution.hide))
    }

    public var isIdentity: Bool { base.isEmpty && overrideEntries.isEmpty }

    /// Every substitution in document order.  Rebuilt on demand; nothing on
    /// the keystroke path reads it.
    public var substitutions: [DisplaySubstitution] {
        guard overrideParagraph != nil else { return base }
        var out: [DisplaySubstitution] = []
        out.reserveCapacity(base.count)
        for p in paragraphs.starts.indices { out.append(contentsOf: entries(inParagraphAt: p)) }
        return out
    }

    /// Effective hidden ranges for edit projection. The base set is cached;
    /// when a transient paragraph override exists, only that paragraph is
    /// replaced in the cached sequence.
    internal var hiddenRangesForEditProjection: [NSRange] {
        guard let overrideParagraph else { return normalizedBaseHiddenRanges }

        let overridden = paragraphs.range(at: overrideParagraph)
        var result: [NSRange] = []
        result.reserveCapacity(normalizedBaseHiddenRanges.count)
        for range in normalizedBaseHiddenRanges where range.upperBound <= overridden.location {
            result.append(range)
        }
        result.append(contentsOf: overrideEntries.lazy.compactMap { entry in
            entry.isHidden ? entry.sourceRange : nil
        })
        for range in normalizedBaseHiddenRanges where range.location >= overridden.upperBound {
            result.append(range)
        }
        return result
    }

    /// The cached base set is already normalized and does not include a
    /// transient caret override. Source edits replace the affected paragraph
    /// with identity presentation, so this is the only set needed for the
    /// projection hot path.
    internal var baseHiddenRangesForEditProjection: [NSRange] {
        normalizedBaseHiddenRanges
    }

    /// Ranges omitted entirely — what `drHidden` marks.
    public var hiddenRanges: [NSRange] {
        hiddenRangesForEditProjection
    }

    /// The entries in force for a paragraph: its override if it has one, its
    /// slice of the base otherwise.
    private func entries(inParagraphAt p: Int) -> ArraySlice<DisplaySubstitution> {
        if p == overrideParagraph { return overrideEntries[...] }
        let start = firstInParagraph[p]
        let end = paragraphs.end(ofParagraphAt: p)
        var i = start
        while i < base.count, base[i].sourceRange.location < end { i += 1 }
        return base[start..<i]
    }

    // MARK: Source → TextKit

    /// Total function.  Source offsets strictly inside a substitution collapse
    /// onto the TextKit offset of that substitution's start.
    public func textKitOffset(forSource source: Int) -> Int {
        let s = clampSource(source)
        let p = paragraphs.index(containing: s)
        var cursor = paragraphs.starts[p]
        var display = 0
        for sub in entries(inParagraphAt: p) {
            guard sub.sourceRange.location < s else { break }
            display += sub.sourceRange.location - cursor
            if s >= sub.sourceRange.upperBound {
                display += sub.displayLength
                cursor = sub.sourceRange.upperBound
            } else {
                if sub.preservesSourceOffsets {
                    return paragraphs.starts[p] + display + (s - sub.sourceRange.location)
                }
                return paragraphs.starts[p] + display
            }
        }
        return paragraphs.starts[p] + display + (s - cursor)
    }

    /// Endpoints are converted independently: lengths are meaningless in the
    /// TextKit space (see the file header).
    public func textKitRange(forSource range: NSRange) -> NSRange {
        let a = textKitOffset(forSource: range.location)
        let b = textKitOffset(forSource: range.upperBound)
        return NSRange(location: a, length: Swift.max(0, b - a))
    }

    // MARK: TextKit → Source

    /// Exact right inverse of `textKitOffset(forSource:)`:
    /// `textKitOffset(forSource: sourceOffset(forTextKit: t)) == t` for every
    /// reachable `t`.
    ///
    /// Where several source offsets share a TextKit offset, a *hidden* run
    /// resolves to the offset after it.  That choice is what makes typing at
    /// the visible start of `**bold**` extend the emphasis rather than land
    /// outside it, and typing at its visible end land outside rather than
    /// inside — the behaviour §6.1b asks for.  A positive-length replacement
    /// instead resolves to its start, so a caret before an inline object is
    /// before the object's source, not inside it.
    ///
    /// One boundary is worth stating: `textKitEnd(ofParagraphAt: p)` and the
    /// start of paragraph `p + 1` are the same document position with two
    /// spellings, and both resolve to the same source offset here.
    /// `textKitOffset(forSource:)` always produces the second spelling, which
    /// is also the one TextKit produces — a caret past a paragraph's
    /// terminator belongs to the following element.  So the round trip
    /// source → TextKit → source is exact everywhere, and TextKit → source →
    /// TextKit is exact for every offset TextKit can actually report.
    public func sourceOffset(forTextKit textKit: Int) -> Int {
        let t = clampSource(textKit)
        let p = paragraphs.index(containing: t)
        let paragraphEnd = paragraphs.end(ofParagraphAt: p)
        var cursor = paragraphs.starts[p]
        var remaining = t - cursor
        for sub in entries(inParagraphAt: p) {
            let visible = sub.sourceRange.location - cursor
            if remaining < visible { return cursor + remaining }
            remaining -= visible
            if remaining < sub.displayLength {
                return sub.preservesSourceOffsets
                    ? sub.sourceRange.location + remaining
                    : sub.sourceRange.location
            }
            remaining -= sub.displayLength
            cursor = sub.sourceRange.upperBound
        }
        // Landing exactly on a paragraph break puts us at the start of the next
        // paragraph, which may itself open with a hidden run — a heading's `# `
        // or a list item's `- [ ] `.  Resolve forward past it so the two
        // spellings of the break agree, and so a caret at the visible start of
        // such a line sits after its marker rather than on it (§6.1a).
        var result = Swift.min(cursor + remaining, paragraphEnd)
        while let next = substitutionStarting(at: result), next.displayLength == 0 {
            result = next.sourceRange.upperBound
        }
        return result
    }

    /// Mirror of `sourceOffset(forTextKit:)` for the *end* of a range.
    ///
    /// A caret resolves forward, past a hidden run, so typing at the visible
    /// start of `**bold**` extends the emphasis.  A selection's end has to
    /// resolve the other way, or selecting the visible word `bold` would yield
    /// the source `bold**` and ⌘C would paste a stray marker pair (§3.1, §9.5).
    public func sourceUpperBound(forTextKit textKit: Int) -> Int {
        let t = clampSource(textKit)
        let p = paragraphs.index(containing: t)
        let paragraphEnd = paragraphs.end(ofParagraphAt: p)
        var cursor = paragraphs.starts[p]
        var remaining = t - cursor
        for sub in entries(inParagraphAt: p) {
            let visible = sub.sourceRange.location - cursor
            // `<=` rather than `<`: stop *before* the run instead of after it.
            if remaining <= visible { return cursor + remaining }
            remaining -= visible
            if remaining <= sub.displayLength {
                return sub.preservesSourceOffsets
                    ? sub.sourceRange.location + remaining
                    : sub.sourceRange.upperBound
            }
            remaining -= sub.displayLength
            cursor = sub.sourceRange.upperBound
        }
        return Swift.min(cursor + remaining, paragraphEnd)
    }

    /// The location resolves forward and the upper bound backward, so a
    /// selection covers exactly the source the user can see.
    public func sourceRange(forTextKit range: NSRange) -> NSRange {
        let a = sourceOffset(forTextKit: range.location)
        guard range.length > 0 else { return NSRange(location: a, length: 0) }
        let b = sourceUpperBound(forTextKit: range.upperBound)
        return NSRange(location: a, length: Swift.max(0, b - a))
    }

    /// A source offset is *canonical* when it survives a source → TextKit →
    /// source round trip.  Non-canonical offsets are exactly those a caret can
    /// never occupy while the current substitutions are in force.
    public func isCanonical(_ source: Int) -> Bool {
        let s = clampSource(source)
        return sourceOffset(forTextKit: textKitOffset(forSource: s)) == s
    }

    /// Substitution whose source range ends exactly at `offset`, if any.
    /// Paragraph-local, so it stays cheap with an override in force.
    public func substitutionEnding(at offset: Int) -> DisplaySubstitution? {
        let p = paragraphs.index(containing: Swift.max(0, Swift.min(offset, paragraphs.length)))
        for sub in entries(inParagraphAt: p) where sub.sourceRange.upperBound == offset { return sub }
        // A run ending at a paragraph's first offset belongs to the previous one.
        guard p > 0 else { return nil }
        for sub in entries(inParagraphAt: p - 1) where sub.sourceRange.upperBound == offset { return sub }
        return nil
    }

    /// Substitution whose source range starts exactly at `offset`, if any.
    public func substitutionStarting(at offset: Int) -> DisplaySubstitution? {
        let p = paragraphs.index(containing: Swift.max(0, Swift.min(offset, paragraphs.length)))
        for sub in entries(inParagraphAt: p) where sub.sourceRange.location == offset { return sub }
        return nil
    }

    /// One past the last TextKit offset belonging to the paragraph at `p`.
    ///
    /// Not `textKitOffset(forSource: paragraphEnd)`: that source offset is the
    /// *next* paragraph's start and therefore resolves in the next paragraph's
    /// coordinates.  A paragraph break has two TextKit spellings — end of the
    /// previous element and start of the next — and TextKit itself always uses
    /// the second, which is why `textKitOffset(forSource:)` produces it too.
    public func textKitEnd(ofParagraphAt p: Int) -> Int {
        let range = paragraphs.range(at: p)
        var removed = 0
        for sub in entries(inParagraphAt: p) {
            removed += sub.sourceRange.length - sub.displayLength
        }
        return range.location + max(0, range.length - removed)
    }

    private func clampSource(_ offset: Int) -> Int {
        Swift.max(0, Swift.min(offset, paragraphs.length))
    }

    // MARK: Display strings

    /// The substituted attributed string for a paragraph, or `nil` when the
    /// paragraph is untouched and TextKit should use the storage as-is.
    public func displayString(
        forParagraphAt paragraphRange: NSRange,
        in storage: NSAttributedString,
        includingHardWrapReflow: Bool = true
    ) -> NSAttributedString? {
        let p = paragraphs.index(containing: paragraphRange.location)
        let local = entries(inParagraphAt: p).filter {
            includingHardWrapReflow || !$0.isHardWrapReflow
        }
        guard !local.isEmpty else { return nil }

        let out = NSMutableAttributedString()
        var cursor = paragraphRange.location
        for sub in local {
            guard sub.sourceRange.location >= cursor,
                  sub.sourceRange.upperBound <= paragraphRange.upperBound else { continue }
            if sub.sourceRange.location > cursor {
                out.append(storage.attributedSubstring(
                    from: NSRange(location: cursor, length: sub.sourceRange.location - cursor)))
            }
            if let replacement = sub.replacement { out.append(replacement) }
            cursor = sub.sourceRange.upperBound
        }
        if cursor < paragraphRange.upperBound {
            out.append(storage.attributedSubstring(
                from: NSRange(location: cursor, length: paragraphRange.upperBound - cursor)))
        }
        return out
    }

    /// The grouped-element counterpart to `displayString(forParagraphAt:)`.
    /// Unlike the paragraph-local API, this can span multiple source newline
    /// runs without changing the source/display coordinate contract.
    public func displayString(
        forSourceRange sourceRange: NSRange,
        in storage: NSAttributedString
    ) -> NSAttributedString? {
        let local = substitutions(in: sourceRange)
        guard !local.isEmpty else { return nil }

        let out = NSMutableAttributedString()
        var cursor = sourceRange.location
        for substitution in local {
            guard substitution.sourceRange.location >= cursor,
                  substitution.sourceRange.upperBound <= sourceRange.upperBound else { continue }
            if substitution.sourceRange.location > cursor {
                out.append(storage.attributedSubstring(from: NSRange(
                    location: cursor,
                    length: substitution.sourceRange.location - cursor
                )))
            }
            if let replacement = substitution.replacement {
                out.append(replacement)
            }
            cursor = substitution.sourceRange.upperBound
        }
        if cursor < sourceRange.upperBound {
            out.append(storage.attributedSubstring(from: NSRange(
                location: cursor,
                length: sourceRange.upperBound - cursor
            )))
        }
        return out
    }
}
