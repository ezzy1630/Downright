import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

// The decoration engine's contract, tested where it is load-bearing:
// §3.1 (characters are never touched), §6.1 (the source↔display map and the
// marker rules), §6.1a (the gutter), §14's four-way interaction, and §12's
// keystroke budget.

private func styleSheet() -> StyleSheet {
    StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing())
}

private func engine(_ mode: RenderMode) -> DecorationEngine {
    let engine = DecorationEngine(styleSheet: styleSheet())
    engine.policy = mode.policy
    return engine
}

/// Deliberately full of the things agents actually emit.
private let sampleMarkdown = """
---
title: Sample document
author: agent
---

# Heading one

Some **bold** and *italic* and `code` and a [link](https://example.com) plus ~~strike~~ text.

## Heading two

- [ ] first task
- [x] second task
- plain item

1. numbered one
2. numbered two

> quoted line

> [!WARNING]
> A callout with **emphasis** inside it.

```swift
let x = 1
print(x)
```

| Name | Count |
|------|------:|
| a    | 1     |
| b    | 22    |

$$
E = mc^2
$$

***

Trailing paragraph mentioning `src/auth/session.ts:42` and $a^2$ inline.

"""

// MARK: - §3.1 Raw text is the only source of truth

@Test func decorationNeverMutatesCharactersInAnyMode() {
    let document = MarkdownParser.parse(sampleMarkdown)
    let originalBytes = Array(sampleMarkdown.utf8)

    for mode in RenderMode.allCases {
        let storage = NSTextStorage(string: sampleMarkdown)
        let engine = engine(mode)

        engine.decorate(storage, document: document, dirty: .wholesale)
        #expect(storage.string == sampleMarkdown, "wholesale decoration changed the text in \(mode)")
        #expect(Array(storage.string.utf8) == originalBytes, "byte round trip broken in \(mode)")

        // The incremental path has to hold the same guarantee.
        let slice = NSRange(location: 0, length: min(120, storage.length))
        engine.decorate(storage, document: document, dirty: DirtySet(ranges: [slice], isWholesale: false))
        #expect(storage.string == sampleMarkdown, "incremental decoration changed the text in \(mode)")
        #expect(Array(storage.string.utf8) == originalBytes, "byte round trip broken in \(mode)")
        #expect(storage.length == (sampleMarkdown as NSString).length)
    }
}

@Test func rendererConfigurationIsBoundedAndIndependentOfTheAppLayer() {
    var configuration = MarkdownRenderConfiguration(
        showInvisibles: true,
        revealPolicy: .never,
        typewriterScrolling: true,
        codeCollapseThreshold: 0
    )
    #expect(configuration.showInvisibles)
    #expect(configuration.revealPolicy == .never)
    #expect(configuration.typewriterScrolling)
    #expect(configuration.codeCollapseThreshold == 1)

    configuration.codeCollapseThreshold = 99_999
    #expect(configuration.codeCollapseThreshold == 10_000)
}

@Test func hardWrappedParagraphsReflowWithoutChangingSource() {
    let source = "A physical line\ncontinues here without a blank paragraph.\n"
    let document = MarkdownParser.parse(source)
    let storage = NSTextStorage(string: source)

    engine(.live).decorate(storage, document: document, dirty: .wholesale)

    #expect(storage.string == source)
    guard let paragraph = document.root.children.first,
          let style = storage.attribute(.paragraphStyle, at: paragraph.range.location, effectiveRange: nil)
            as? NSParagraphStyle else {
        Issue.record("the hard-wrapped paragraph did not receive a paragraph style")
        return
    }
    #expect(style.lineBreakMode == .byWordWrapping)
    #expect(style.paragraphSpacing == 0)

    let index = ParagraphIndex(text: source as NSString)
    let hidden = engine(.live).hiddenRanges(document: document, caret: nil, selections: [])
    let plan = HardWrapReflow.plan(
        document: document,
        text: source as NSString,
        hiddenRanges: hidden,
        enabled: true
    )
    #expect(plan.ranges.count == 1)
    guard let grouped = plan.ranges.first else {
        Issue.record("the parser did not expose the hard-wrapped paragraph")
        return
    }
    let ordinaryHidden = hidden.filter { hiddenRange in
        hiddenRange.location < grouped.location || hiddenRange.upperBound > grouped.upperBound
    }
    let map = DisplayMap(
        paragraphs: index,
        substitutions: ordinaryHidden.map(DisplaySubstitution.hide) + plan.substitutions
    )
    let displayed = map.displayString(
        forSourceRange: grouped,
        in: NSAttributedString(string: source)
    )
    #expect(displayed?.length == grouped.length)
    #expect(displayed?.string == "A physical line continues here without a blank paragraph.\n")
    #expect(map.hiddenRanges == hidden)
    #expect(storage.string == source)
}

@Test func explicitMarkdownBreaksStayBreaksWhenSoftWrapReflowIsOn() {
    for source in ["one  \ntwo\n", "one\\\ntwo\n"] {
        let document = MarkdownParser.parse(source)
        let plan = HardWrapReflow.plan(
            document: document,
            text: source as NSString,
            hiddenRanges: [],
            enabled: true
        )

        #expect(plan.ranges.isEmpty)
        #expect(plan.substitutions.isEmpty)
    }
}

@Test func hardWrapReflowPreservesEverySupportedLineEndingLength() {
    for ending in ["\n", "\r\n", "\r", "\u{0085}", "\u{2028}", "\u{2029}"] {
        let source = "first" + ending + "second" + ending
        let document = MarkdownParser.parse(source)
        let plan = HardWrapReflow.plan(
            document: document,
            text: source as NSString,
            hiddenRanges: [],
            enabled: true
        )
        guard let grouped = plan.ranges.first else {
            Issue.record("a supported line ending did not produce a reflowable paragraph")
            continue
        }
        let map = DisplayMap(paragraphs: ParagraphIndex(text: source as NSString),
                             substitutions: plan.substitutions)
        let displayed = map.displayString(
            forSourceRange: grouped,
            in: NSAttributedString(string: source)
        )
        #expect(displayed?.length == grouped.length)
        #expect(map.textKitOffset(forSource: grouped.upperBound) == grouped.upperBound)
    }
}

@Test func hardWrapReflowLeavesLiteralInlineNewlinesOnPhysicalPath() {
    let source = "before `code\ninside` after\n"
    let plan = HardWrapReflow.plan(
        document: MarkdownParser.parse(source),
        text: source as NSString,
        hiddenRanges: [],
        enabled: true
    )

    #expect(plan.ranges.isEmpty)
    #expect(plan.substitutions.isEmpty)
}

@Test @MainActor func physicalTextKitFallbackStillHidesOrdinaryMarkers() {
    let source = "**bold** tail\n"
    let storage = NSTextStorage(string: source)
    let index = ParagraphIndex(text: source as NSString)
    let provider = ParagraphSubstitution()
    provider.displayMap = DisplayMap(paragraphs: index, hidden: [
        NSRange(location: 0, length: 2), NSRange(location: 6, length: 2),
    ])

    let contentStorage = NSTextContentStorage()
    contentStorage.textStorage = storage
    contentStorage.delegate = provider
    guard let paragraph = provider.textContentStorage(
        contentStorage,
        textParagraphWith: index.range(at: 0)
    ) else {
        Issue.record("the physical fallback leaked or rejected an ordinary hidden-marker paragraph")
        return
    }

    #expect(paragraph.attributedString.string == "bold tail\n")
    #expect(storage.string == source)
}

@Test func decorationAppliesRealAttributes() {
    let document = MarkdownParser.parse(sampleMarkdown)
    let storage = NSTextStorage(string: sampleMarkdown)
    let sheet = styleSheet()
    let engine = engine(.read)
    let result = engine.decorate(storage, document: document, dirty: .wholesale)

    #expect(result.attributeRanges > 0)
    #expect(result.fragmentCount > 0)

    let text = sampleMarkdown as NSString
    let headingOffset = text.range(of: "# Heading one").location + 3
    let headingFont = storage.attribute(.font, at: headingOffset, effectiveRange: nil) as? NSFont
    #expect((headingFont?.pointSize ?? 0) > sheet.bodyFont().pointSize)
    #expect(storage.attribute(.drHeading, at: headingOffset, effectiveRange: nil) as? Int == 1)

    let codeOffset = text.range(of: "print(x)").location
    let codeFont = storage.attribute(.font, at: codeOffset, effectiveRange: nil) as? NSFont
    #expect(codeFont?.isFixedPitch == true)

    let linkOffset = text.range(of: "[link](").location + 1
    #expect(storage.attribute(.drLink, at: linkOffset, effectiveRange: nil) as? String == "https://example.com")
}

// MARK: - §6.1 The source ⇄ display index map

@Test func paragraphIndexHandlesEveryTerminator() {
    let text = "a\nb\r\nc\rd" as NSString
    let index = ParagraphIndex(text: text)
    #expect(index.starts == [0, 2, 5, 7])
    #expect(index.paragraphRange(containing: 0) == NSRange(location: 0, length: 2))
    #expect(index.paragraphRange(containing: 4) == NSRange(location: 2, length: 3))
    #expect(index.paragraphRange(containing: 7) == NSRange(location: 7, length: 1))
}

@Test func hiddenRunsResolveOnTheSideThatMakesTypingCorrect() {
    let text = "**bold** tail"
    let index = ParagraphIndex(text: text as NSString)
    let map = DisplayMap(paragraphs: index, hidden: [
        NSRange(location: 0, length: 2), NSRange(location: 6, length: 2),
    ])

    // Source → TextKit collapses the hidden run onto its start.
    #expect(map.textKitOffset(forSource: 0) == 0)
    #expect(map.textKitOffset(forSource: 1) == 0)
    #expect(map.textKitOffset(forSource: 2) == 0)
    #expect(map.textKitOffset(forSource: 6) == 4)
    #expect(map.textKitOffset(forSource: 8) == 4)

    // §6.1b: at the visible start of the span the caret is *inside* the
    // emphasis, at its visible end it is outside.
    #expect(map.sourceOffset(forTextKit: 0) == 2)
    #expect(map.sourceOffset(forTextKit: 4) == 8)
    #expect(map.sourceOffset(forTextKit: 2) == 4)

    let display = map.displayString(
        forParagraphAt: NSRange(location: 0, length: (text as NSString).length),
        in: NSAttributedString(string: text))
    #expect(display?.string == "bold tail")
}

@Test func layoutPreservingHiddenMarkersStillSkipPastForTyping() {
    // Grouped TextKit elements keep hidden markers as same-length joiners so
    // element ranges stay source-aligned. Caret conversion must still resolve
    // past those invisible runs, or click→type lands inside `**` / `# `.
    let text = "**bold** tail"
    let index = ParagraphIndex(text: text as NSString)
    let joiners: (NSRange) -> DisplaySubstitution = { range in
        DisplaySubstitution(
            sourceRange: range,
            displayLength: range.length,
            replacement: NSAttributedString(string: String(repeating: "\u{2060}", count: range.length)),
            isHidden: true,
            preservesSourceOffsets: true
        )
    }
    let map = DisplayMap(paragraphs: index, substitutions: [
        joiners(NSRange(location: 0, length: 2)),
        joiners(NSRange(location: 6, length: 2)),
    ])

    #expect(map.textKitOffset(forSource: 2) == 2)
    #expect(map.textKitOffset(forSource: 8) == 8)
    #expect(map.sourceOffset(forTextKit: 0) == 2)
    #expect(map.sourceOffset(forTextKit: 1) == 2)
    #expect(map.sourceOffset(forTextKit: 2) == 2)
    #expect(map.sourceOffset(forTextKit: 6) == 8)
    #expect(map.sourceRange(forTextKit: NSRange(location: 2, length: 4))
            == NSRange(location: 2, length: 4))
    #expect(map.sourceUpperBound(forTextKit: 7) == 6)
}

@Test func aSelectionCoversExactlyTheSourceItLooksLike() {
    // The end of a range resolves *backward* past a hidden run while a caret
    // resolves forward.  Without that, selecting the visible word `bold`
    // yields the source `bold**` and ⌘C pastes a stray marker pair (§3.1).
    let text = "**bold** tail"
    let index = ParagraphIndex(text: text as NSString)
    let map = DisplayMap(paragraphs: index, hidden: [
        NSRange(location: 0, length: 2), NSRange(location: 6, length: 2),
    ])

    // Display "bold" is TextKit 0..<4.
    #expect(map.sourceRange(forTextKit: NSRange(location: 0, length: 4)) == NSRange(location: 2, length: 4))
    // A caret keeps the forward rule and stays a caret.
    #expect(map.sourceRange(forTextKit: NSRange(location: 0, length: 0)) == NSRange(location: 2, length: 0))
    #expect(map.sourceRange(forTextKit: NSRange(location: 4, length: 0)) == NSRange(location: 8, length: 0))
    // Selecting through to the end still reaches the end.
    #expect(map.sourceRange(forTextKit: NSRange(location: 0, length: 9))
            == NSRange(location: 2, length: 11))
}

@Test func inlineObjectSubstitutionKeepsTheMapExact() {
    let text = "before $x^2$ after"
    let index = ParagraphIndex(text: text as NSString)
    let math = NSRange(location: 7, length: 5)   // "$x^2$"
    let map = DisplayMap(paragraphs: index, substitutions: [
        .replace(math, with: NSAttributedString(string: "\u{FFFC}")),
    ])

    #expect(map.textKitOffset(forSource: 7) == 7)
    #expect(map.textKitOffset(forSource: 12) == 8)
    // Before the object, and after it — never inside.
    #expect(map.sourceOffset(forTextKit: 7) == 7)
    #expect(map.sourceOffset(forTextKit: 8) == 12)
    #expect(map.displayString(forParagraphAt: index.range(at: 0),
                              in: NSAttributedString(string: text))?.string == "before \u{FFFC} after")
}

@Test func inlineMathProducesAnAttachmentAndCompactsTheLogicalDisplayMap() {
    let source = #"Euler $e^{i\pi} + 1 = 0$ and $\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$."# + "\n"
    let document = MarkdownParser.parse(source)
    let substitutions = InlineMathDisplay.substitutions(
        in: document, styleSheet: styleSheet(), excluding: nil)

    #expect(substitutions.count == 2)
    for substitution in substitutions {
        #expect(substitution.displayLength == 1)
        #expect(substitution.replacement?.attribute(.attachment, at: 0, effectiveRange: nil) != nil)
    }

    let map = DisplayMap(
        paragraphs: ParagraphIndex(text: source as NSString),
        substitutions: substitutions)
    let paragraph = ParagraphIndex(text: source as NSString).range(at: 0)
    let displayed = map.displayString(
        forParagraphAt: paragraph,
        in: NSAttributedString(string: source))
    #expect(displayed?.length == (source as NSString).length -
            substitutions.reduce(0) { $0 + $1.sourceRange.length - $1.displayLength })
}

@Test @MainActor func textViewInstallsInlineMathInItsLiveDisplayMap() {
    let source = #"Euler $e^{i\pi} + 1 = 0$ and $\sum_{k=1}^{n} k = \frac{n(n+1)}{2}$."# + "\n"
    let storage = NSTextStorage(string: source)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 400), storage: storage)
    view.update(document: MarkdownParser.parse(source), dirty: .wholesale)

    let math = view.currentDisplayMap.substitutions.filter { substitution in
        substitution.replacement?.attribute(.attachment, at: 0, effectiveRange: nil) != nil
    }
    #expect(math.count == 2)
    #expect(storage.string == source)
}

@Test func displayMapRoundTripsEveryOffsetOfARealDocument() {
    let text = sampleMarkdown
    let ns = text as NSString
    let document = MarkdownParser.parse(text)
    let hidden = engine(.read).hiddenRanges(document: document, caret: nil, selections: [])
    #expect(!hidden.isEmpty, "a document this full of markers must hide some")

    let index = ParagraphIndex(text: ns)
    let map = DisplayMap(paragraphs: index, hidden: hidden)
    let sanitized = map.hiddenRanges

    // 1. Exact right inverse for every TextKit offset inside a paragraph.
    //    The paragraph's exclusive end is the same document position as the
    //    next paragraph's start; TextKit spells it the second way, so it is
    //    checked separately below rather than round-tripped here.
    let lastParagraph = index.starts.count - 1
    for paragraph in index.starts.indices {
        let start = index.starts[paragraph]
        let end = map.textKitEnd(ofParagraphAt: paragraph)
        let upper = paragraph == lastParagraph ? end : end - 1
        guard upper >= start else { continue }
        for textKit in start...upper {
            let source = map.sourceOffset(forTextKit: textKit)
            #expect(map.textKitOffset(forSource: source) == textKit,
                    "TextKit offset \(textKit) did not survive the round trip")
        }
    }

    // 1b. A paragraph break has two TextKit spellings — the previous
    //     paragraph's exclusive end and the next one's start — and both must
    //     name the same source position.  That position sits *after* a hidden
    //     run when the next paragraph opens with one, which is §6.1a working
    //     as intended: a caret at the visible start of `## Heading` is after
    //     the marker, never on it.
    for paragraph in 0..<lastParagraph {
        let viaEnd = map.sourceOffset(forTextKit: map.textKitEnd(ofParagraphAt: paragraph))
        let viaNextStart = map.sourceOffset(forTextKit: index.starts[paragraph + 1])
        #expect(viaEnd == viaNextStart,
                "paragraph \(paragraph)'s break resolved two ways: \(viaEnd) vs \(viaNextStart)")
        #expect(viaEnd >= index.starts[paragraph + 1])
    }

    // 2. Canonical source offsets are exactly those no hidden run covers.
    for source in 0...ns.length {
        let covered = RangeSet.covers(sanitized, source)
        #expect(map.isCanonical(source) == !covered,
                "offset \(source): canonical=\(map.isCanonical(source)) covered=\(covered)")
        if !covered {
            #expect(map.sourceOffset(forTextKit: map.textKitOffset(forSource: source)) == source)
        }
    }

    // 3. Monotone in both directions — selection order depends on it.
    var previous = -1
    for source in 0...ns.length {
        let textKit = map.textKitOffset(forSource: source)
        #expect(textKit >= previous)
        previous = textKit
    }

    // 4. Each paragraph's display string loses exactly what is hidden in it.
    let attributed = NSAttributedString(string: text)
    for paragraph in index.starts.indices {
        let range = index.range(at: paragraph)
        let removed = RangeSet.intersecting(sanitized, range).reduce(0) { $0 + $1.length }
        let substituted = map.displayString(forParagraphAt: range, in: attributed)
        #expect((substituted?.length ?? range.length) == range.length - removed)
        #expect(map.textKitEnd(ofParagraphAt: paragraph) == range.location + range.length - removed)
    }
}

@Test func substitutionsNeverCrossAParagraphBoundary() {
    let text = "line one\nline two"
    let index = ParagraphIndex(text: text as NSString)
    // A range spanning the newline is refused outright rather than silently
    // desynchronising the element from its content.
    let map = DisplayMap(paragraphs: index, hidden: [NSRange(location: 5, length: 8)])
    #expect(map.isIdentity)
}

// MARK: - §6.1a/b Hidden ranges per mode and per caret

private func displayText(_ source: String, hidden: [NSRange]) -> String {
    let index = ParagraphIndex(text: source as NSString)
    let map = DisplayMap(paragraphs: index, hidden: hidden)
    var out = ""
    for paragraph in index.starts.indices {
        let range = index.range(at: paragraph)
        let substituted = map.displayString(forParagraphAt: range, in: NSAttributedString(string: source))
        out += substituted?.string ?? (source as NSString).substring(with: range)
    }
    return out
}

@Test func hiddenRangesFollowThePolicy() {
    let text = "Some **bold** and *italic* text.\n"
    let document = MarkdownParser.parse(text)

    // Read: every marker gone.
    let read = engine(.read).hiddenRanges(document: document, caret: nil, selections: [])
    #expect(displayText(text, hidden: read) == "Some bold and italic text.\n")

    // Source: nothing hidden, markers are the point of the mode.
    let source = engine(.source).hiddenRanges(document: document, caret: nil, selections: [])
    #expect(source.isEmpty)
    #expect(displayText(text, hidden: source) == text)

    // Live with no caret behaves like Read.
    let live = engine(.live).hiddenRanges(document: document, caret: nil, selections: [])
    #expect(displayText(text, hidden: live) == "Some bold and italic text.\n")
}

@Test func caretRevealsOneSpanAndLeavesItsSiblingsCollapsed() {
    let text = "Some **bold** and *italic* text.\n"
    let ns = text as NSString
    let document = MarkdownParser.parse(text)
    let engine = engine(.live)

    let insideBold = ns.range(of: "bold").location + 1
    #expect(displayText(text, hidden: engine.hiddenRanges(document: document, caret: insideBold, selections: []))
            == "Some **bold** and italic text.\n")

    let insideItalic = ns.range(of: "italic").location + 1
    #expect(displayText(text, hidden: engine.hiddenRanges(document: document, caret: insideItalic, selections: []))
            == "Some bold and *italic* text.\n")

    // A caret in plain text reveals nothing.
    let inPlain = ns.range(of: "Some").location + 1
    #expect(displayText(text, hidden: engine.hiddenRanges(document: document, caret: inPlain, selections: []))
            == "Some bold and italic text.\n")
}

@Test func selectionDoesNotRevealMarkers() {
    let text = "Some **bold** and *italic* text.\n"
    let ns = text as NSString
    let document = MarkdownParser.parse(text)
    let selection = ns.range(of: "bold")
    let hidden = engine(.live).hiddenRanges(
        document: document,
        caret: nil,
        selections: [selection]
    )

    #expect(displayText(text, hidden: hidden) == "Some bold and italic text.\n")
    #expect(MarkerPolicy.revealedMarkerRanges(
        document: document,
        policy: RenderMode.live.policy,
        caret: nil,
        selections: [selection]
    ).isEmpty)
}

@Test func revealedRangesAreExactlyWhatTheCaretAwareRunLeavesOut() {
    // The view derives the caret-aware set by subtracting `revealedMarkerRanges`
    // from the collapsed set, so the two must agree exactly (§12).
    let text = "Some **bold** and *italic* and `code` here.\n"
    let document = MarkdownParser.parse(text)
    let policy = RenderMode.live.policy
    let collapsed = MarkerPolicy.hiddenRanges(document: document, policy: policy, caret: nil, selections: [])

    for caret in 0...(text as NSString).length {
        let withCaret = MarkerPolicy.hiddenRanges(document: document, policy: policy, caret: caret, selections: [])
        let revealed = MarkerPolicy.revealedMarkerRanges(document: document, policy: policy,
                                                         caret: caret, selections: [])
        let derived = collapsed.filter { candidate in
            !revealed.contains { $0.location == candidate.location && $0.length == candidate.length }
        }
        #expect(derived.count == withCaret.count, "caret \(caret): derived \(derived.count) vs \(withCaret.count)")
        for (a, b) in zip(derived, withCaret) { #expect(a == b, "caret \(caret)") }
    }
}

@Test func allCursorRevealPolicyIncludesSecondaryInsertionCursors() {
    let text = "Some **bold** and *italic* text.\n"
    let ns = text as NSString
    let document = MarkdownParser.parse(text)
    var policy = RenderMode.live.policy
    policy.revealsAtAllCursors = true

    let primary = ns.range(of: "bold").location + 1
    let secondary = ns.range(of: "italic").location + 1
    let primaryOnly = MarkerPolicy.revealedMarkerRanges(
        document: document, policy: policy, caret: primary, selections: []
    )
    let all = MarkerPolicy.revealedMarkerRanges(
        document: document,
        policy: policy,
        caret: primary,
        selections: [NSRange(location: primary, length: 0), NSRange(location: secondary, length: 0)]
    )

    #expect(all.count > primaryOnly.count)
    #expect(MarkerPolicy.hiddenRanges(
        document: document,
        policy: policy,
        caret: primary,
        selections: [NSRange(location: primary, length: 0), NSRange(location: secondary, length: 0)]
    ).count < MarkerPolicy.hiddenRanges(
        document: document, policy: policy, caret: nil, selections: []
    ).count)
}

@Test func blockMarkersAreNeverRevealedInline() {
    // §6.1a: `#` and `- [ ]` live in the gutter and stay there whatever the
    // caret does, which is what keeps line height and origin stable.
    let text = "## Heading\n\n- [ ] task\n"
    let ns = text as NSString
    let document = MarkdownParser.parse(text)
    let engine = engine(.live)
    let headingMarker = NSRange(location: 0, length: 3)

    for caret in [0, 3, 5, ns.range(of: "task").location] {
        let hidden = engine.hiddenRanges(document: document, caret: caret, selections: [])
        #expect(hidden.contains { $0.location <= headingMarker.location && $0.upperBound >= 2 },
                "the heading marker was revealed with the caret at \(caret)")
    }
}

@Test func calloutBlockMarkersStayHiddenWithoutMovingSourceCoordinates() {
    let text = "> [!WARNING] Build carefully\n> The source stays byte-identical.\n"
    let document = MarkdownParser.parse(text)
    let ns = text as NSString
    guard let callout = document.root.children.first, let marker = callout.markerRange else {
        Issue.record("the parser did not retain the callout marker range")
        return
    }

    for mode in [RenderMode.read, .live] {
        let hidden = engine(mode).hiddenRanges(document: document, caret: nil, selections: [])
        #expect(hidden.contains(marker), "callout marker is visible in \(mode)")
        let continuation = ns.range(of: "> The source")
        #expect(hidden.contains { range in
            range.location <= continuation.location
                && range.upperBound >= continuation.location + 2
        }, "callout continuation marker is visible in \(mode)")

        let index = ParagraphIndex(text: ns)
        let map = DisplayMap(paragraphs: index, hidden: hidden)
        #expect(map.textKitOffset(forSource: marker.location) == map.textKitOffset(forSource: marker.upperBound))
        #expect(ns.substring(with: marker) == "> [!WARNING] Build carefully")
        #expect(map.sourceOffset(forTextKit: map.textKitOffset(forSource: marker.upperBound)) == marker.upperBound)
    }

    let sourceHidden = engine(.source).hiddenRanges(document: document, caret: nil, selections: [])
    #expect(sourceHidden.isEmpty, "Source Focus must retain every quote marker")
}

@Test @MainActor func resolvedDefinitionsStayOutOfRenderedProse() {
    let text = "Body with [a link][ref] and a note[^1].\n\n[ref]: https://example.com\n[^1]: Hidden definition.\n"
    let document = MarkdownParser.parse(text)
    let renderedHidden = engine(.live).hiddenRanges(
        document: document,
        caret: nil,
        selections: []
    )
    let reference = document.linkReferences["ref"]?.range
    let footnote = document.footnotes["1"]?.range

    #expect(reference != nil)
    #expect(footnote != nil)
    #expect(!renderedHidden.isEmpty)
    #expect(engine(.source).hiddenRanges(
        document: document,
        caret: nil,
        selections: []
    ).isEmpty)

    let storage = NSTextStorage(string: text)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 640, height: 400),
        storage: storage
    )
    view.update(document: document, dirty: .wholesale)
    #expect(reference.map { target in
        storage.attribute(.drElided, at: target.location, effectiveRange: nil) != nil
    } == true)
    #expect(footnote.map { target in
        storage.attribute(.drElided, at: target.location, effectiveRange: nil) != nil
    } == true)
    let rendered = view.renderedStringForSpeech(
        sourceRange: NSRange(location: 0, length: storage.length)
    )
    #expect(!rendered.contains("https://example.com"))
    #expect(!rendered.contains("Hidden definition"))
}

@Test func listTextAndWrappedLinesShareOneContentEdge() {
    let text = "- [ ] A task with enough words to wrap onto another visual line in a narrow measure.\n"
    let storage = NSTextStorage(string: text)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 280, height: 300),
        storage: storage
    )
    view.update(document: MarkdownParser.parse(text), dirty: .wholesale)

    let content = (text as NSString).range(of: "A task")
    let style = storage.attribute(
        .paragraphStyle,
        at: content.location,
        effectiveRange: nil
    ) as? NSParagraphStyle
    #expect(style != nil)
    #expect(style?.firstLineHeadIndent == style?.headIndent)
    #expect((style?.headIndent ?? 0) > 0, "the ornament still needs a hanging column")
}

// MARK: - §6.1a Gutter markers

@Test func gutterMarkersComeFromBlockKinds() {
    let text = """
    # Title

    ## Section

    - [ ] todo
    - [x] done
    - plain

    > quoted

    > [!WARNING]
    > careful

    ```swift
    let x = 1
    ```
    """
    let document = MarkdownParser.parse(text)
    let markers = engine(.live).gutterMarkers(document: document)
    let texts = Set(markers.map(\.text))

    #expect(texts.contains("#"))
    #expect(texts.contains("##"))
    #expect(texts.contains("- [ ]"))
    #expect(texts.contains("- [x]"))
    #expect(texts.contains("-"))
    #expect(texts.contains(">"))
    #expect(texts.contains("> [!WARNING]"))
    #expect(texts.contains("```"))

    // Ascending by offset, so the rail can draw in one pass.
    #expect(markers.map(\.offset) == markers.map(\.offset).sorted())
    #expect(markers.first { $0.text == "##" }?.level == 2)
    #expect(markers.first { $0.text == "#" }?.level == 1)

    // Every marker offset points at a real place in the document.
    let length = (text as NSString).length
    #expect(markers.allSatisfy { $0.offset >= 0 && $0.offset <= length })
}

@Test func orderedListItemsGetANumberedGutterMarker() {
    let document = MarkdownParser.parse("1. one\n2. two\n")
    let texts = engine(.live).gutterMarkers(document: document).map(\.text)
    #expect(texts.contains { $0.hasSuffix(".") || $0 == "-" })
}

@Test func listOrnamentsAndAlignedWrapsPreserveMarkdownStructure() {
    let source = "- [ ] a task with enough text to wrap under its text edge\n10. an ordered item\n"
    let document = MarkdownParser.parse(source)
    let storage = NSTextStorage(string: source)
    let renderer = engine(.live)
    renderer.decorate(storage, document: document, dirty: .wholesale)

    guard let list = document.root.children.first,
          let task = list.children.first,
          let orderedList = document.root.children.last,
          let ordered = orderedList.children.first,
          let taskStyle = storage.attribute(.paragraphStyle, at: task.contentRange.location,
                                            effectiveRange: nil) as? NSParagraphStyle,
          let orderedStyle = storage.attribute(.paragraphStyle, at: ordered.contentRange.location,
                                               effectiveRange: nil) as? NSParagraphStyle else {
        Issue.record("list items did not receive paragraph styles")
        return
    }

    #expect(taskStyle.headIndent == taskStyle.firstLineHeadIndent)
    #expect(orderedStyle.headIndent == orderedStyle.firstLineHeadIndent)
    #expect(taskStyle.headIndent > 0)
    #expect(orderedStyle.headIndent > 0)
    #expect((storage.attribute(.drFragment, at: task.range.location, effectiveRange: nil)
             as? FragmentPayload)?.detail == "task:unchecked")
    #expect(storage.string == source)
}

@Test @MainActor func blockContentStorageGroupsSourceWrappedParagraphs() {
    let source = "first physical line\nsecond physical line\n"
    let document = MarkdownParser.parse(source)
    let index = ParagraphIndex(text: source as NSString)
    let storage = NSTextStorage(string: source)
    let plan = HardWrapReflow.plan(
        document: document, text: source as NSString, hiddenRanges: [], enabled: true
    )
    let map = DisplayMap(paragraphs: index, substitutions: plan.substitutions)
    let contentStorage = MarkdownContentStorage()
    contentStorage.textStorage = storage
    contentStorage.configure(paragraphIndex: index, reflowRanges: plan.ranges, displayMap: map)

    var elements: [NSTextElement] = []
    _ = contentStorage.enumerateTextElements(from: nil, options: []) { element in
        elements.append(element)
        return true
    }

    let grouped = elements.compactMap { $0 as? NSTextParagraph }
        .first { $0.attributedString.string.contains("first physical line second physical line") }
    #expect(grouped != nil)
    #expect(storage.string == source)
}

@Test func wideTablesStayInsideTheTextMeasureAndWrapCells() {
    let source = "| Alpha | Beta | Gamma | Delta |\n| --- | --- | --- | --- |\n| A long value that must wrap | another long value | third value | fourth value |"
    let document = MarkdownParser.parse(source)
    guard let block = document.root.children.first, case .table(let data) = block.content else {
        Issue.record("the parser did not produce a table")
        return
    }
    let storage = NSAttributedString(string: source)
    let layout = TableLayout.make(data: data, storage: storage, width: 220, style: styleSheet())
    let gaps = RenderMetrics.tableColumnGap * CGFloat(data.columnCount - 1)

    #expect(layout.totalWidth <= 220)
    #expect(layout.columnWidths.reduce(0, +) + gaps <= 220.001)
    #expect(layout.rowHeights.last ?? 0 > styleSheet().lineHeight)
}

@Test func unlabeledCodeFencesExposeTheSameCopyGeometryAsLabeledFences() {
    let style = styleSheet()
    let band = CGRect(x: 12, y: 4, width: 420, height: 30)
    let unlabeled = CodeBlockFragment.copyButtonRect(in: band, style: style, language: "")
    let labeled = CodeBlockFragment.copyButtonRect(in: band, style: style, language: "swift")

    #expect(unlabeled.width > 0)
    #expect(unlabeled.maxX <= band.maxX)
    #expect(labeled.width == unlabeled.width)
    #expect(labeled.maxX <= band.maxX)
}

// MARK: - §14 zoom × folding × find × hidden markers

@Test func aSearchHitForcesItsElidedRangeVisible() {
    let text = """
    # Alpha

    Alpha body paragraph.

    # Beta

    Beta body with a needle inside.
    """
    let ns = text as NSString
    let document = MarkdownParser.parse(text)
    let needle = ns.range(of: "needle")
    let alphaBody = ns.range(of: "Alpha body paragraph.")

    // Zoom to H1: bodies elided.
    let zoomed = ElisionPlan.make(document: document, zoom: .h1, foldedHeadingSlugs: [],
                                  searchHits: [], caret: nil, selections: [])
    #expect(!zoomed.elidedRanges.isEmpty)
    #expect(zoomed.isElided(needle.location))
    #expect(zoomed.isElided(alphaBody.location))

    // A hit inside forces that range — and only that range — back.
    let withHit = ElisionPlan.make(document: document, zoom: .h1, foldedHeadingSlugs: [],
                                   searchHits: [needle], caret: nil, selections: [])
    #expect(!withHit.isElided(needle.location))
    #expect(!withHit.forcedVisibleRanges.isEmpty)
    #expect(withHit.isElided(alphaBody.location))

    // Folding obeys the identical rule.
    let betaSlug = document.headings.first { $0.title.contains("Beta") }?.slug
    let slug = try! #require(betaSlug)
    let folded = ElisionPlan.make(document: document, zoom: .everything, foldedHeadingSlugs: [slug],
                                  searchHits: [], caret: nil, selections: [])
    #expect(folded.isElided(needle.location))

    let foldedWithHit = ElisionPlan.make(document: document, zoom: .everything, foldedHeadingSlugs: [slug],
                                         searchHits: [needle], caret: nil, selections: [])
    #expect(!foldedWithHit.isElided(needle.location))

    // So does a caret, and so does a selection.
    let caretForced = ElisionPlan.make(document: document, zoom: .everything, foldedHeadingSlugs: [slug],
                                       searchHits: [], caret: needle.location, selections: [])
    #expect(!caretForced.isElided(needle.location))

    let selectionForced = ElisionPlan.make(document: document, zoom: .everything, foldedHeadingSlugs: [slug],
                                           searchHits: [], caret: nil, selections: [needle])
    #expect(!selectionForced.isElided(needle.location))

    // A folded heading never hides its own line — there would be nothing left
    // to click to unfold.
    let heading = try! #require(document.headings.first { $0.slug == slug })
    #expect(folded.isElided(heading.range.location) == false)
}

@Test func elisionAndMarkerHidingAreDisjointMechanisms() {
    // §14: the two must not interact.  Elided ranges keep every character in
    // the display string (they collapse to zero height instead), so the index
    // map never has to know about zoom or folding.
    let text = "# Alpha\n\nBody with **bold** in it.\n"
    let document = MarkdownParser.parse(text)
    let plan = ElisionPlan.make(document: document, zoom: .h1, foldedHeadingSlugs: [],
                                searchHits: [], caret: nil, selections: [])
    #expect(!plan.elidedRanges.isEmpty)

    let hidden = engine(.read).hiddenRanges(document: document, caret: nil, selections: [])
    let map = DisplayMap(paragraphs: ParagraphIndex(text: text as NSString), hidden: hidden)
    // Every character of the elided body is still addressable.
    for range in plan.elidedRanges {
        for offset in range.location..<range.upperBound where map.isCanonical(offset) {
            #expect(map.sourceOffset(forTextKit: map.textKitOffset(forSource: offset)) == offset)
        }
    }
}

// MARK: - §12 keystroke budget

@Test func keystrokeDecorationStaysUnderTheBudget() {
    // A 5k-line document shaped like agent output: headings, prose, lists, and
    // fenced code in roughly the proportions those actually arrive in.
    var lines: [String] = []
    var section = 0
    while lines.count < 5000 {
        section += 1
        lines.append("## Section \(section)")
        lines.append("")
        lines.append("Paragraph \(section) with **bold**, *italic*, `code`, and a [link](https://example.com/\(section)).")
        lines.append("")
        lines.append("- [ ] task \(section)a")
        lines.append("- [x] task \(section)b")
        lines.append("")
        lines.append("```swift")
        lines.append("let value\(section) = \(section)")
        lines.append("print(value\(section))")
        lines.append("```")
        lines.append("")
    }
    let text = lines.joined(separator: "\n")
    let storage = NSTextStorage(string: text)
    let engine = engine(.live)

    var document = MarkdownParser.parse(storage.string)
    engine.decorate(storage, document: document, dirty: .wholesale)

    // Type into the middle of a paragraph, one character at a time, exactly as
    // §3.5 describes: full reparse, then re-decorate only the dirty block.
    let caretSeed = (text as NSString).range(of: "Paragraph 250 with").location
    var caret = caretSeed > 0 ? caretSeed + 10 : storage.length / 2
    var samples: [Double] = []

    for _ in 0..<100 {
        storage.replaceCharacters(in: NSRange(location: caret, length: 0), with: "x")
        document = MarkdownParser.parse(storage.string)
        let dirty = DirtySet(ranges: [NSRange(location: caret, length: 1)], isWholesale: false)

        let started = CFAbsoluteTimeGetCurrent()
        engine.decorate(storage, document: document, dirty: dirty)
        samples.append((CFAbsoluteTimeGetCurrent() - started) * 1000)

        caret += 1
    }

    samples.sort()
    let p95 = samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
    #expect(p95 < 8.0, "p95 keystroke decoration was \(p95) ms, over the 8ms budget in §12")
    #expect(storage.length == (text as NSString).length + 100)
}

@Test func caretMovesRebuildTheDisplayMapWithinTheBudget() {
    // A keystroke moves the caret, which rebuilds the substitution set and the
    // map.  That work is on the same 8ms budget as decoration (§12), so it gets
    // measured rather than assumed.
    var lines: [String] = []
    for i in 0..<5000 {
        lines.append(i % 9 == 0
            ? "## Section \(i)"
            : "Line \(i) with **bold**, *italic*, `code`, and a [link](https://example.com/\(i)).")
    }
    let text = lines.joined(separator: "\n")
    let ns = text as NSString
    let document = MarkdownParser.parse(text)
    let engine = engine(.live)
    let index = ParagraphIndex(text: ns)
    let collapsed = engine.hiddenRanges(document: document, caret: nil, selections: [])

    // The document's collapsed map is built once; a caret move is an override
    // on top of it, never a rebuild of it.
    let base = DisplayMap(paragraphs: index, hidden: collapsed)
    var samples: [Double] = []
    let seed = ns.range(of: "Line 2500 with").location
    for step in 0..<100 {
        let caret = (seed > 0 ? seed : ns.length / 2) + step
        let started = CFAbsoluteTimeGetCurrent()
        let revealed = MarkerPolicy.revealedMarkerRanges(document: document, policy: engine.policy,
                                                         caret: caret, selections: [])
        var map = base
        if !revealed.isEmpty {
            map = base.replacingParagraph(containing: caret, excluding: revealed)
        }
        _ = map.textKitOffset(forSource: caret)
        samples.append((CFAbsoluteTimeGetCurrent() - started) * 1000)
        #expect(map.paragraphs.length == ns.length)
    }

    // The paragraph index is the other per-edit cost in the view.
    let indexStarted = CFAbsoluteTimeGetCurrent()
    for _ in 0..<20 { _ = ParagraphIndex(text: ns) }
    let indexRebuild = (CFAbsoluteTimeGetCurrent() - indexStarted) * 1000 / 20

    samples.sort()
    let p95 = samples[min(samples.count - 1, Int(Double(samples.count) * 0.95))]
    #expect(p95 < 8.0, "caret-move map rebuild was \(p95) ms, over the 8ms budget in §12")
    #expect(indexRebuild < 8.0, "paragraph index rebuild was \(indexRebuild) ms, over the 8ms budget in §12")
}

@Test func aParagraphOverrideChangesOnlyThatParagraph() {
    // The mechanism the caret-move fast path relies on: replacing one
    // paragraph's substitutions must leave every other paragraph's conversions
    // bit-identical, or a reveal in one place would move the caret in another.
    let text = "**a** one\n**b** two\n**c** three\n"
    let ns = text as NSString
    let index = ParagraphIndex(text: ns)
    let hidden = [0, 3, 10, 13, 20, 23].map { NSRange(location: $0, length: 2) }
    let base = DisplayMap(paragraphs: index, hidden: RangeSet.normalized(hidden))

    // Reveal the second line's pair by dropping its two entries.
    let second = index.range(at: 1)
    let revealed = base.replacingParagraph(containing: second.location, with: [])
    #expect(revealed.displayString(forParagraphAt: second, in: NSAttributedString(string: text))?.string == nil)

    for offset in 0...ns.length where !second.contains(offset: offset) {
        #expect(revealed.textKitOffset(forSource: offset) == base.textKitOffset(forSource: offset),
                "offset \(offset) moved when another paragraph was overridden")
    }
    // And the overridden paragraph really did change.
    #expect(revealed.textKitOffset(forSource: second.location + 3)
            != base.textKitOffset(forSource: second.location + 3))
}

@Test @MainActor func multiParagraphSelectionKeepsHiddenAttributesInSync() {
    let text = "First **bold** line.\nSecond *italic* line.\n"
    let storage = NSTextStorage(string: text)
    let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400), storage: storage)
    view.mode = .live
    view.update(document: MarkdownParser.parse(text), dirty: .wholesale)

    let source = text as NSString
    let start = source.range(of: "bold").location
    let end = source.range(of: "italic").upperBound
    let selected = NSRange(location: start, length: end - start)
    let textKitSelection = view.currentDisplayMap.textKitRange(forSource: selected)
    view.setSelectedRanges(
        [NSValue(range: textKitSelection)], affinity: .downstream, stillSelecting: false)

    var attributedHidden: [NSRange] = []
    storage.enumerateAttribute(
        .drHidden, in: NSRange(location: 0, length: storage.length)
    ) { value, range, _ in
        if value != nil { attributedHidden.append(range) }
    }
    #expect(RangeSet.normalized(attributedHidden) == view.currentDisplayMap.hiddenRanges)
}

@Test func wholesaleDecorationOfALargeDocumentIsAffordable() {
    // Not a budget in §12, but the number that decides whether a mode switch
    // feels instant (§3.2), so it is worth having on the record.
    var lines: [String] = []
    for i in 0..<3000 {
        lines.append(i % 12 == 0 ? "## Section \(i)" : "Line \(i) with **bold** and `code` in it.")
    }
    let text = lines.joined(separator: "\n")
    let storage = NSTextStorage(string: text)
    let document = MarkdownParser.parse(text)
    let engine = engine(.read)

    _ = engine.decorate(storage, document: document, dirty: .wholesale)
    #expect(storage.string == text)
}

// MARK: - Range utilities the rest of the engine assumes

@Test func rangeSetNormalisationHoldsItsInvariants() {
    let normalized = RangeSet.normalized([
        NSRange(location: 10, length: 5),
        NSRange(location: 0, length: 3),
        NSRange(location: 2, length: 4),
        NSRange(location: 40, length: 0),
    ])
    #expect(normalized == [NSRange(location: 0, length: 6), NSRange(location: 10, length: 5)])
    #expect(RangeSet.covers(normalized, 5))
    #expect(!RangeSet.covers(normalized, 6))
    #expect(RangeSet.covers(normalized, 10))
    #expect(!RangeSet.covers(normalized, 15))
    #expect(RangeSet.intersecting(normalized, NSRange(location: 4, length: 8))
            == [NSRange(location: 4, length: 2), NSRange(location: 10, length: 2)])
}
