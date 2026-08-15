import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

// Regressions for §6.1's soft-break handling and §11.1's vertical rhythm.
//
// Every case here is one that shipped: hard-wrapped prose inside a list item
// rendering with its source line breaks intact, a code row wrapping to the left
// of its own statement, a callout body indented a space further than the lines
// under it, two paragraphs meeting with a hairline between them, and a change
// highlight painting a bare rectangle where a fragment had drawn the text.

private func sheet() -> StyleSheet {
    StyleSheet(theme: .fallback, appearance: NSAppearance(named: .darkAqua) ?? NSAppearance.currentDrawing())
}

private func liveEngine() -> DecorationEngine {
    let engine = DecorationEngine(styleSheet: sheet())
    engine.policy = RenderMode.live.policy
    return engine
}

private func decorated(_ source: String) -> NSTextStorage {
    let storage = NSTextStorage(string: source)
    liveEngine().decorate(
        storage,
        document: MarkdownParser.parse(source),
        dirty: DirtySet(
            ranges: [NSRange(location: 0, length: (source as NSString).length)],
            isWholesale: true
        )
    )
    return storage
}

/// The plan plus the map a grouped element is actually built against.
///
/// Hidden runs carry length-preserving word joiners here, not the collapsing
/// `hide` entries of the logical map — that is what `MarkdownTextView` publishes
/// to its content storage, and a grouped element's contract is that its display
/// string and its source range stay the same length.
private func plan(_ source: String) -> (plan: HardWrapReflow.Plan, map: DisplayMap, text: NSString) {
    let text = source as NSString
    let document = MarkdownParser.parse(source)
    let hidden = liveEngine().hiddenRanges(document: document, caret: nil, selections: [])
    let made = HardWrapReflow.plan(document: document, text: text, hiddenRanges: hidden, enabled: true)
    let fillers = hidden.map { range in
        DisplaySubstitution(
            sourceRange: range,
            displayLength: range.length,
            replacement: NSAttributedString(string: String(repeating: joiner, count: range.length)),
            isHidden: true,
            preservesSourceOffsets: true
        )
    }
    let map = DisplayMap(
        paragraphs: ParagraphIndex(text: text),
        substitutions: fillers + made.substitutions.filter(\.isHardWrapReflow)
    )
    return (made, map, text)
}

/// What a hidden marker looks like in a laid-out element.
private let joiner = "\u{2060}"
/// What the padding of a collapsed soft break looks like.
private let pad = "\u{200B}"

private func style(_ storage: NSTextStorage, at offset: Int) -> NSParagraphStyle? {
    storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle
}

// MARK: - Soft breaks inside containers

private let wrappedListItem = """
3. **No WebView. Anywhere.** Math via SwiftMath, diagrams via
   beautiful-mermaid-swift, code via a native lexer, everything else through
   Core Text.

"""

@Test func aListItemsContinuationIndentIsNotAnExplicitBreakMarker() {
    // The two spaces that indent a continuation line sit *after* the newline, so
    // they cannot be the two-space hard-break marker — that has to precede it.
    // Reading them as one classified every wrapped line in every list as an
    // explicit break, which `HardWrapReflow` then refused to join.
    let document = MarkdownParser.parse(wrappedListItem)
    var kinds: [InlineKind] = []
    document.root.walk { block in
        for span in block.inlines {
            span.walk { if case .softBreak = $0.kind { kinds.append($0.kind) }
                        if case .lineBreak = $0.kind { kinds.append($0.kind) } }
        }
    }
    #expect(kinds.count == 2)
    #expect(kinds.allSatisfy { if case .softBreak = $0 { return true } else { return false } })
}

@Test func hardWrappedListProseJoinsWithSingleSpaces() {
    let (made, map, text) = plan(wrappedListItem)
    #expect(made.ranges.count == 1)
    guard let group = made.ranges.first else { return }
    let shown = map.displayString(forSourceRange: group, in: NSAttributedString(string: wrappedListItem))?.string
    guard let shown else {
        Issue.record("the list item produced no display string")
        return
    }
    // Length is preserved (the join pads with zero-width space), the source
    // newlines are gone, and no run of two spaces survived the continuation
    // indent.
    #expect((shown as NSString).length == group.length)
    #expect(!shown.dropLast().contains("\n"))
    #expect(!shown.contains("  "))
    #expect(shown.contains("diagrams via \(pad)\(pad)\(pad)beautiful-mermaid-swift"))
    _ = text
}

@Test func aReflowedListItemKeepsItsMarkerOnTheSameRow() {
    // The group has to start at the line, not at the paragraph: a group that
    // began after `3. ` left the marker as a physical paragraph of its own, and
    // a separate element is a separate row.
    let (made, _, _) = plan(wrappedListItem)
    #expect(made.ranges.first?.location == 0)
}

@Test func anExplicitTwoSpaceBreakStillSurvivesReflow() {
    let source = "line one with an explicit break  \nline two after it\n"
    let (made, _, _) = plan(source)
    #expect(made.ranges.isEmpty)
}

@Test func aBackslashBreakStillSurvivesReflow() {
    let source = "line one with a backslash break\\\nline two after it\n"
    let (made, _, _) = plan(source)
    #expect(made.ranges.isEmpty)
}

@Test func aStaleDocumentLongerThanTheBufferDoesNotOverrunIndents() {
    // The planner is defensive by contract: a parsed document can outlive the
    // buffer it was parsed from (an external rewrite racing the last parse), so
    // a paragraph range can run past `text.length`.  The continuation-indent
    // walk indexed the text by that unclamped range and read one past the end.
    //
    // Three leading spaces keep this a soft break (four would make a code
    // block), and the truncated buffer ends mid-indent so the walk reaches the
    // very end of the text and used to read one character past it.
    let source = "line one\n   line two\n"
    let document = MarkdownParser.parse(source)
    let truncated = String(source.prefix(12)) as NSString  // "line one\n   "
    let made = HardWrapReflow.plan(document: document, text: truncated, hiddenRanges: [], enabled: true)
    #expect(made.substitutions.allSatisfy { $0.sourceRange.upperBound <= truncated.length })
    #expect(made.substitutions.contains { $0.sourceRange == NSRange(location: 9, length: 3) })
}

@Test func aCalloutBodyDoesNotOpenWithASpace() {
    // A quoted paragraph's range begins on the newline that ends the line above
    // it, so the terminator that opens the element joins nothing.  Rendered as a
    // space it indented the first line of every callout body one space further
    // than the lines beneath it.
    let source = """
    > [!NOTE]
    > Agents emit these constantly, so they get a real treatment: a coloured left
    > rule and an icon, never a filled box.

    """
    let (made, map, _) = plan(source)
    guard let group = made.ranges.first,
          let shown = map.displayString(forSourceRange: group, in: NSAttributedString(string: source))?.string
    else {
        Issue.record("the callout body produced no group")
        return
    }
    #expect(!shown.hasPrefix(" "))
    #expect(shown.hasPrefix(pad), "the terminator that opens the element contributes no space")
    #expect(shown.contains("coloured left \(joiner)\(joiner)rule"))
}

// MARK: - Marker identity

@Test func adjacentBlockAndInlineMarkersKeepSeparateRanges() {
    // A reveal names the marker it is un-hiding by its exact range.  Fusing a
    // list marker with the `**` beside it left the opening marker unrevealable
    // while its closing twin revealed normally, so a stray `**` was left sitting
    // in the middle of rendered prose.
    let source = "3. **No WebView.** Math via SwiftMath.\n"
    let hidden = liveEngine().hiddenRanges(
        document: MarkdownParser.parse(source), caret: nil, selections: [])
    #expect(hidden.contains(NSRange(location: 0, length: 3)))
    #expect(hidden.contains(NSRange(location: 3, length: 2)))
    #expect(!hidden.contains(NSRange(location: 0, length: 5)))
}

@Test func rangeSetDisjointFusesOverlapsAndKeepsNeighbours() {
    let fused = RangeSet.disjoint([
        NSRange(location: 0, length: 3),
        NSRange(location: 3, length: 2),
        NSRange(location: 4, length: 4),
    ])
    #expect(fused == [NSRange(location: 0, length: 3), NSRange(location: 3, length: 5)])
}

@Test func aNestedItemsContainerIndentIsHidden() {
    // Depth sets a nested row's edge, not byte count — otherwise a two-space and
    // a four-space nesting of the same item land in different columns, and the
    // source spaces indent it a second time on top of the head indent.
    let source = "- [x] Notarise and publish\n  - [ ] Sparkle appcast\n"
    let hidden = liveEngine().hiddenRanges(
        document: MarkdownParser.parse(source), caret: nil, selections: [])
    let indent = NSRange(location: 27, length: 2)
    #expect(hidden.contains { NSIntersectionRange($0, indent).length == indent.length })
}

// MARK: - Vertical rhythm

@Test func aHardWrappedParagraphKeepsTheAirAfterIt() {
    // Blank source lines collapse to a hairline because `paragraphSpacing` is
    // meant to supply the air.  Zeroing that on the whole block deleted it, and
    // two hard-wrapped paragraphs then met one point apart.
    let source = """
    Reading position persists per file regardless of whether the bytes changed, so
    long documents behave like books.

    The density gutter shows the whole shape of a document at a glance.

    """
    let storage = decorated(source)
    let text = source as NSString
    let opening = style(storage, at: 0)
    let closing = style(storage, at: text.range(of: "long documents").location)
    #expect(opening?.paragraphSpacing == 0)          // a join, not a close
    #expect((closing?.paragraphSpacing ?? 0) > 0)    // the close keeps its air
    #expect(closing?.paragraphSpacingBefore == 0)    // and adds none of its own
}

@Test func lineHeightLandsOnAnEvenPointAtTheDefaultBody() {
    // The baseline grid is quantised in half units so 26pt is reachable; whole
    // units could only produce 24 or 28 at a 16pt body.
    let style = sheet()
    #expect(style.bodyFont().pointSize == 16)
    #expect(style.lineHeight == 26)
    #expect(style.baselineGrid == 6.5)
}

@Test func aHeadingFollowingAHeadingBindsTighterThanOneFollowingProse() {
    let stacked = decorated("## Section\n\n### Subsection\n\nBody text here.\n")
    let afterProse = decorated("## Section\n\nBody text here.\n\n### Subsection\n\nMore body.\n")
    let stackedBefore = style(stacked, at: ("## Section\n\n### Subsection\n\nBody text here.\n" as NSString)
        .range(of: "### Subsection").location)?.paragraphSpacingBefore ?? 0
    let proseBefore = style(afterProse, at: ("## Section\n\nBody text here.\n\n### Subsection\n\nMore body.\n" as NSString)
        .range(of: "### Subsection").location)?.paragraphSpacingBefore ?? 0
    #expect(stackedBefore < proseBefore)
}

// MARK: - Code rows

@Test func aWrappedCodeRowHangsPastItsOwnIndent() {
    let source = """
    ```swift
    func decorate(_ storage: NSTextStorage, document: ParsedDocument) {
        let markers = hiddenRanges(document: document, caret: nil, selections: [])
    }
    ```

    """
    let storage = decorated(source)
    let text = source as NSString
    let outer = style(storage, at: text.range(of: "func decorate").location)
    let inner = style(storage, at: text.range(of: "let markers").location)
    guard let outer, let inner else {
        Issue.record("a code row carried no paragraph style")
        return
    }
    // Same left edge for the row itself, but the indented row's wraps resume
    // past its four columns rather than back at the block's edge.
    #expect(inner.firstLineHeadIndent == outer.firstLineHeadIndent)
    #expect(inner.headIndent > outer.headIndent)
    #expect(inner.defaultTabInterval > 0)
}

@Test func codeRowIndentColumnsCountTabsToTheirStops() {
    #expect(BlockStyleFactory.indentColumns(of: "    let x = 1" as NSString) == 4)
    #expect(BlockStyleFactory.indentColumns(of: "\tlet x = 1" as NSString) == RenderMetrics.codeTabColumns)
    #expect(BlockStyleFactory.indentColumns(of: "no indent" as NSString) == 0)
}

// MARK: - The hidden-range mirror

@Test @MainActor func theHiddenAttributeMirrorsWhatTheMapHides() {
    // `.drHidden` exists so everything reading the storage rather than the
    // display map — rich-text copy, HTML export, the Quick Look renderer — sees
    // the decision layout made.  It is refreshed in caret-sized scopes, so its
    // failure mode is a *partial* mirror: correct where the caret has been and
    // silent elsewhere, which reads as syntax leaking into copied or exported
    // text from parts of the document nobody happened to click in.
    //
    // Compared against the policy for the caret the view actually has, because a
    // caret legitimately reveals its own span's markers — comparing against the
    // caret-less set would assert that reveal does not work.
    let source = """
    # Title with **bold** in it

    Prose with `code` and *emphasis*, then a table and a callout below.

    | | |
    |---|---|
    | `⌘E` | Use selection for Find |

    > [!NOTE]
    > A callout whose header line is hidden syntax.

    - [x] A task whose marker is hidden too

    """
    let text = source as NSString
    let whole = NSRange(location: 0, length: text.length)
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 620, height: 1400), storage: storage, styleSheet: sheet())
    view.mode = .live
    view.update(document: MarkdownParser.parse(source), dirty: DirtySet(ranges: [whole], isWholesale: true))
    view.prepareForDisplay()

    func mirrored() -> [NSRange] {
        var out: [NSRange] = []
        storage.enumerateAttribute(.drHidden, in: whole) { value, range, _ in
            if value != nil { out.append(range) }
        }
        return RangeSet.normalized(out)
    }
    func owed() -> [NSRange] {
        RangeSet.normalized(liveEngine().hiddenRanges(
            document: MarkdownParser.parse(source),
            caret: view.primarySourceCaret,
            selections: view.sourceSelectedRanges))
    }

    #expect(mirrored() == owed(), "first paint")

    let word = text.range(of: "Prose")
    view.changeMarks = [.init(kind: .modified, range: word, words: [word], visited: false, deletedText: "")]
    #expect(mirrored() == owed(), "after an overlay change")

    // Walk the caret across the document.  A reveal is paragraph-local by
    // design, so what is asserted here is the other half: moving the caret must
    // never *erase* the mirror somewhere else.  The sweep that repopulates it is
    // scoped, and a scope wider than the set it repopulates from is exactly how
    // markers go missing — which is what the two assertions above caught.
    let elsewhere = [
        text.range(of: "> [!NOTE]"),
        text.range(of: "- [x] "),
    ]
    for probe in ["bold", "emphasis", "hidden syntax", "A task whose"] {
        let target = text.range(of: probe)
        view.setSourceSelectedRanges([NSRange(location: target.location, length: 0)])
        let after = mirrored()
        for range in elsewhere where !range.contains(offset: target.location) {
            #expect(
                after.contains { NSIntersectionRange($0, range).length == range.length },
                "caret at \(probe) kept \(text.substring(with: range).debugDescription) mirrored"
            )
        }
    }
}

@Test @MainActor func anIncrementalReparseRepairsTheMirrorOverWholeBlocks() {
    // The path an external write takes: reparse, then re-decorate only the
    // blocks the AST diff reports.  Decoration grows each dirty range to whole
    // blocks and wipes their attributes, so repairing the mirror over the
    // *reported* range leaves the rest of those blocks claiming nothing is
    // hidden in them — markers that would then leak into a copy or an export.
    let source = """
    Prose with `code` and *emphasis* that an agent is about to rewrite.

    A second paragraph with `more code` left alone.

    """
    let text = source as NSString
    let whole = NSRange(location: 0, length: text.length)
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 620, height: 900), storage: storage, styleSheet: sheet())
    view.mode = .live
    view.update(document: MarkdownParser.parse(source), dirty: DirtySet(ranges: [whole], isWholesale: true))
    view.prepareForDisplay()

    func mirroredMarkers() -> [String] {
        var out: [String] = []
        storage.enumerateAttribute(.drHidden, in: whole) { value, range, _ in
            if value != nil { out.append(text.substring(with: range)) }
        }
        return out
    }
    let before = mirroredMarkers()
    #expect(before == ["`", "`", "*", "*", "`", "`"], "every inline marker starts out mirrored")

    // A one-word dirty range inside the first paragraph, which is what a diff of
    // a small external edit produces.
    let word = text.range(of: "rewrite")
    view.update(
        document: MarkdownParser.parse(source),
        dirty: DirtySet(ranges: [word], isWholesale: false))
    #expect(mirroredMarkers() == before, "the block's other markers stay mirrored")
}

// MARK: - The task checkbox, in both places

@Test func theTaskCheckboxTickCarriesItsOwnFieldInEveryTheme() {
    // §8.5 makes the document ornament and the Tasks-panel control one checkbox,
    // so their paint has one definition on `StyleSheet`.  The tick now sits on a
    // tinted field rather than on a solid accent slab, which means its contrast
    // is a property of the theme and has to be asserted per theme: an accent
    // that cannot carry a stroke against the page makes a ticked box read as an
    // empty one, which is worse than the loud slab it replaced (§11.4).
    for theme in ThemeStore().themes {
        for appearance in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)].compactMap({ $0 }) {
            let sheet = StyleSheet(theme: theme, appearance: appearance)
            let field = composite(sheet.taskFieldColor, over: sheet.background)
            let tick = composite(sheet.taskTickColor, over: field)
            let ratio = StyleSheet.contrastRatio(tick, field)
            #expect(ratio >= 3, "\(theme.name)/\(appearance.name.rawValue): tick on field is \(ratio):1")
        }
    }
}

@Test func anOpenCheckboxRingStaysVisibleAgainstThePage() {
    // The ring is the whole affordance when the box is open.  The floor here is
    // the palette's own `textSecondary`, not the drawing — the light themes sit
    // just over 3:1 at rest and Increase Contrast lifts them past 7:1.
    for theme in ThemeStore().themes {
        let sheet = StyleSheet(theme: theme, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
        let ring = composite(sheet.taskRingColor(checked: false), over: sheet.background)
        let ratio = StyleSheet.contrastRatio(ring, sheet.background)
        #expect(ratio >= 2.9, "\(theme.name): open ring is \(ratio):1 against the page")
    }
}

/// A colour with alpha, resolved against what sits behind it — contrast is a
/// property of what reaches the screen, not of the token.
private func composite(_ color: NSColor, over background: NSColor) -> NSColor {
    ColorResolver.blend(background, color.withAlphaComponent(1), color.alphaComponent)
}

// MARK: - Table cells

@Test func anEmptyTableCellHasNoContentOfItsOwn() {
    // A cell's range reaches across the row's `|`, so with no inline span to
    // bound it the delimiter became the cell's content: a headerless table —
    // `| | | |`, which is how a keybinding table is usually written — drew stray
    // pipe glyphs where its header row should have been blank, and every "is
    // this header empty?" question answered no.
    let source = """
    | | |
    |---|---|
    | `⌘E` | Use selection for Find |

    """
    let document = MarkdownParser.parse(source)
    var header: TableRow?
    document.root.walk { block in
        if case .table(let data) = block.content { header = data.headerRow }
    }
    guard let header else {
        Issue.record("the table did not parse")
        return
    }
    for cell in header.cells {
        #expect(cell.contentRange.length == 0, "an empty cell has no content")
        #expect(cell.inlines.isEmpty)
        let text = (source as NSString).substring(with: cell.contentRange)
        #expect(!text.contains("|"))
    }
}

// MARK: - Tables: keeping columns must not cost text

@Test func aTableThatWouldClipACellIsNotWorthKeepingInColumns() {
    // The degradation ladder chooses a rung on width alone, so a layout that fits
    // the measure can still ellipsise a cell past the three-line cap — which a
    // stack would have shown in full.  A column's shape is worth less than the
    // words in it, so `fitsWithoutClipping` is what the ladder consults before
    // keeping columns.
    //
    // Measured against an unbounded height on purpose: the row-height pass caps
    // its own measurement at three lines and so cannot tell a cell that fills
    // them from one that wanted five.
    let source = """
    | Source | Detail |
    |---|---|
    | short | A cell carrying several sentences of prose, far more than three lines of it once the column has been squeezed down, which is exactly the case that must not be kept in columns. |

    """
    let storage = decorated(source)
    let style = sheet()
    var table: TableData?
    MarkdownParser.parse(source).root.walk { block in
        if case .table(let data) = block.content { table = data }
    }
    guard let table else {
        Issue.record("the table did not parse")
        return
    }

    // Wide enough for three lines, then narrow enough that it cannot be.
    #expect(TableLayout.fitsWithoutClipping(
        rows: table.rows,
        cellText: table.rows.map { $0.cells.map { TableCellPresentation.plainText(for: $0, in: storage) } },
        widths: [80, 460], style: style, scale: 1
    ))
    #expect(!TableLayout.fitsWithoutClipping(
        rows: table.rows,
        cellText: table.rows.map { $0.cells.map { TableCellPresentation.plainText(for: $0, in: storage) } },
        widths: [80, 120], style: style, scale: 1
    ))
}

// MARK: - Grouped elements

@Test @MainActor func adjacentReflowGroupsStaySeparateElements() {
    // A nested item's group starts exactly where its parent's ends.  Fusing
    // ranges that merely touch made the two one element — so the child was
    // wrapped into its parent's paragraph and laid out at the parent's indent
    // instead of one level in.
    let source = """
    - Parent item wrapped in the source across two physical lines here so it
      needs a reflow group of its own.
      - Child item also wrapped in the source across two physical lines so it
        needs one too.

    """
    let text = source as NSString
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 620, height: 1200), storage: storage, styleSheet: sheet())
    view.mode = .live
    view.update(
        document: MarkdownParser.parse(source),
        dirty: DirtySet(ranges: [NSRange(location: 0, length: text.length)], isWholesale: true))
    view.prepareForDisplay()

    guard let manager = view.textLayoutManager else {
        Issue.record("the view had no layout manager")
        return
    }
    manager.ensureLayout(for: manager.documentRange)
    var indents: [CGFloat] = []
    manager.enumerateTextLayoutFragments(from: manager.documentRange.location, options: []) { fragment in
        guard let paragraph = fragment.textElement as? NSTextParagraph,
              paragraph.attributedString.length > 0,
              let style = paragraph.attributedString
                .attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        else { return true }
        indents.append(style.headIndent)
        return true
    }
    #expect(indents.count >= 2, "the parent and the child must be separate elements")
    if indents.count >= 2 {
        #expect(indents[1] > indents[0], "the child element lays out one level deeper")
    }
}

// MARK: - Overlays

@Test @MainActor func aChangeHighlightNeverTintsARunWithNoGlyphs() {
    // §8.1 highlights changed words *in the rendered prose*.  A table cell, a
    // diagram and a hidden callout header have no glyphs of their own on screen,
    // so a background colour there painted a bare rectangle of tint — the stray
    // shaded squares that appeared whenever an agent wrote to the file.
    let source = """
    Prose with a changed word in it.

    | | |
    |---|---|
    | `⌘E` | Use selection for Find |

    > [!NOTE]
    > A callout whose header line is hidden syntax.

    """
    let text = source as NSString
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 620, height: 1200), storage: storage, styleSheet: sheet())
    view.mode = .live
    view.update(
        document: MarkdownParser.parse(source),
        dirty: DirtySet(ranges: [NSRange(location: 0, length: text.length)], isWholesale: true))
    view.prepareForDisplay()

    let row = text.range(of: "| `⌘E` | Use selection for Find |")
    // The header is hidden syntax whose title the callout fragment draws itself,
    // so it is the case that made the overlay ask the display map rather than
    // trust the `.drHidden` mirror, which is refreshed in caret-sized scopes.
    let calloutHeader = text.range(of: "> [!NOTE]")
    let word = text.range(of: "changed word")
    view.changeMarks = [
        .init(kind: .modified, range: word, words: [word], visited: false, deletedText: ""),
        .init(kind: .modified, range: row, words: [row], visited: false, deletedText: ""),
        .init(kind: .modified, range: calloutHeader, words: [calloutHeader], visited: false, deletedText: ""),
    ]
    view.prepareForDisplay()

    var tinted: [NSRange] = []
    storage.enumerateAttribute(.backgroundColor, in: NSRange(location: 0, length: text.length)) { value, range, _ in
        if value != nil { tinted.append(range) }
    }
    #expect(tinted == [word])
}

/// The same rule, on the draw path that never got it.
///
/// `tint` was taught to ask `glyphBearingRanges` first; the inline-code pill
/// was not, so a table full of `code` in its cells scattered rounded rectangles
/// across the object at positions taken from the hidden linear layout — visible
/// tint, no text under it, nowhere near the cell the span actually lives in.
///
/// The pill is now drawn by the fragment that draws the glyphs, from its own
/// line fragments, so the rule holds structurally: a fragment that replaces its
/// text has no line to measure and never reaches the pill code at all.
@Test @MainActor func anInlineCodePillNeverPaintsOverAGlyphReplacedFragment() throws {
    let source = """
    Prose with `inline code` in it.

    | | |
    |---|---|
    | `⌘E` | Use selection for Find |

    """
    let text = source as NSString
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 620, height: 1200), storage: storage, styleSheet: sheet())
    view.mode = .read
    view.update(
        document: MarkdownParser.parse(source),
        dirty: DirtySet(ranges: [NSRange(location: 0, length: text.length)], isWholesale: true))
    view.prepareForDisplay()

    let bands = pillBandsByFragment(in: view)

    // The span in prose keeps its pill: TextKit draws those glyphs.
    let prose = bands.first { $0.text.contains("inline code") }
    #expect(prose?.bands.isEmpty == false)

    // The span inside the table gets none — the table fragment replaces the
    // glyphs, so there is nothing on screen for a pill to sit behind.
    #expect(bands.filter { $0.text.contains("⌘E") }.allSatisfy { $0.bands.isEmpty })
}

/// The defect the pill was moved into the fragment for.
///
/// The pills used to be painted by the *view*, from absolute rectangles it
/// measured by source range and remembered between passes.  Absolute geometry
/// is only true of the layout it was measured in, and TextKit 2 relays out
/// constantly, so the pill stayed where the text had been: rounded rectangles
/// of tint stranded in the margin and over the heading below, while every code
/// span on screen had none.  Guarding that with a "has the layout moved?"
/// fingerprint is a guess, and the reflow that preserves the guess is the one
/// that ships the bug.
///
/// Measured from the line fragment it belongs to, the pill cannot be stale:
/// there is nothing remembered to go stale.  This reflows the document under
/// the same view — which is what a window resize, a font change, an agent
/// rewrite, or TextKit resolving an estimate all do — and asks where the pills
/// are now.
@Test @MainActor func anInlineCodePillIsMeasuredFromTheLineItSitsOn() throws {
    var source = ""
    for index in 1...40 {
        source += "## Section \(index)\n\nProse for section \(index) that runs on long enough to wrap.\n\n"
    }
    source += "Then a paragraph with `a code span` in the middle of it.\n"
    let text = source as NSString
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 620, height: 900), storage: storage, styleSheet: sheet())
    view.mode = .read
    view.update(
        document: MarkdownParser.parse(source),
        dirty: DirtySet(ranges: [NSRange(location: 0, length: text.length)], isWholesale: true))
    view.prepareForDisplay()

    func pillSitsOnItsText() throws {
        let layout = try #require(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var checked = false
        layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
            let bands = fragment.inlineCodePillBands(at: .zero)
            guard let band = bands.first else { return true }
            let line = try? #require(fragment.textLineFragments.first { $0.typographicBounds.intersects(band) })
            guard let line else { return true }
            // Vertically the band *is* the line, and horizontally it bounds the
            // run with a hair of air on each side — never the whole measure,
            // and never a rectangle floating in a line of its own.
            #expect(abs(band.minY - line.typographicBounds.minY) < 0.01)
            #expect(abs(band.height - line.typographicBounds.height) < 0.01)
            #expect(band.width > 8 && band.width < line.typographicBounds.width)
            #expect(band.minX >= -NSTextLayoutFragment.inlineCodePillPadX)
            checked = true
            return true
        }
        #expect(checked, "the document has a code span, so some fragment must have a pill")
    }

    try pillSitsOnItsText()
    // Reflow everything: every wrap, every fragment position, moves.
    view.applyResponsiveMeasure(420)
    try pillSitsOnItsText()
    view.applyResponsiveMeasure(700)
    try pillSitsOnItsText()
}

/// A span that ends its line still gets a pill.
///
/// Hidden syntax lives in the display string as zero-width joiners, and the
/// last one on a line reports its location as the line's *left* edge — so a
/// closing backtick at the end of a line measured the run as zero width and
/// dropped it.  A one-item list whose whole content is a path, which is most of
/// what an agent writes, lost every pill that way.
@Test @MainActor func anInlineCodePillSurvivesEndingItsLine() throws {
    let source = """
    - `Scripts/bundle-app.sh`
    - `Package.swift` — the package manifest

    """
    let text = source as NSString
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 620, height: 400), storage: storage, styleSheet: sheet())
    view.mode = .read
    view.update(
        document: MarkdownParser.parse(source),
        dirty: DirtySet(ranges: [NSRange(location: 0, length: text.length)], isWholesale: true))
    view.prepareForDisplay()

    let bands = pillBandsByFragment(in: view)
    let ending = try #require(bands.first { $0.text.contains("bundle-app.sh") })
    let middle = try #require(bands.first { $0.text.contains("package manifest") })
    #expect(ending.bands.count == 1)
    #expect(middle.bands.count == 1)
    // The longer path gets the wider pill: the one that ends the line is
    // measured, not defaulted to the whole line or to nothing.
    #expect((ending.bands.first?.width ?? 0) > (middle.bands.first?.width ?? 0))
}

/// Invisibles moved onto the same path, and for the same reason: their marks
/// were the second cache of absolute rectangles keyed on a layout fingerprint.
@Test @MainActor func invisibleMarksAreMeasuredFromTheLineTheySitOn() throws {
    let source = "Two words here.\n"
    let text = source as NSString
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 620, height: 400), storage: storage, styleSheet: sheet())
    view.mode = .source
    view.configuration.showInvisibles = true
    view.update(
        document: MarkdownParser.parse(source),
        dirty: DirtySet(ranges: [NSRange(location: 0, length: text.length)], isWholesale: true))
    view.prepareForDisplay()

    let layout = try #require(view.textLayoutManager)
    layout.ensureLayout(for: layout.documentRange)
    var boxes: [(box: CGRect, isTab: Bool)] = []
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
        boxes += fragment.invisibleMarkBoxes(at: .zero)
        return true
    }
    // One mark per space, each sitting on the line it belongs to and no wider
    // than the space it stands for.
    #expect(boxes.count == 2)
    #expect(boxes.allSatisfy { !$0.isTab && $0.box.width > 0 && $0.box.width < 20 })
    #expect(boxes.allSatisfy { $0.box.minY == 0 })

    view.configuration.showInvisibles = false
    layout.ensureLayout(for: layout.documentRange)
    var remaining = 0
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
        remaining += fragment.invisibleMarkBoxes(at: .zero).count
        return true
    }
    #expect(remaining == 0)
}

/// Every fragment's pill geometry, paired with the text it lays out.
@MainActor func pillBandsByFragment(
    in view: MarkdownTextView
) -> [(text: String, bands: [CGRect])] {
    guard let layout = view.textLayoutManager else { return [] }
    var out: [(String, [CGRect])] = []
    layout.enumerateTextLayoutFragments(from: layout.documentRange.location, options: []) { fragment in
        let text = fragment.textLineFragments
            .map { $0.attributedString.string }
            .joined()
        let bands = (fragment as? DownrightFragment)?.suppressesText == true
            ? []
            : fragment.inlineCodePillBands(at: .zero)
        out.append((text, bands))
        return true
    }
    return out
}
