import AppKit
import MarkdownCore
@testable import MarkdownRender
import Testing

// The layout map stands a run of word joiners in for every hidden Markdown
// marker so TextKit elements keep source-length ranges (§6.1).  Those joiners
// have to carry the storage's own attributes at the marker, or the line they
// sit on picks up the wrong metrics.  Building them is on the keystroke path,
// so the construction is deliberately indirect — these tests pin the result.

private let markerRichText = """
# Heading one

Some **bold** text with `code` and *emphasis* on one line.

## Heading two

- [ ] A task with **bold** inside
- [x] A finished task

> A quote with `inline code`.

### Heading three

More prose with [a link](https://example.com) and **more bold**.
"""

@MainActor
private func decoratedView() -> (MarkdownTextView, NSTextStorage) {
    let storage = NSTextStorage(string: markerRichText)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 720, height: 420),
        storage: storage
    )
    view.update(document: MarkdownParser.parse(markerRichText), dirty: .wholesale)
    return (view, storage)
}

/// The attributes that decide how a run is laid out and drawn.
///
/// Downright's own bookkeeping keys are excluded deliberately: `drHidden` is
/// mirrored onto the storage *after* the map is built, so a filler has never
/// carried it, and none of the private keys reach the typesetter.
@MainActor
private func renderingAttributes(
    of attributed: NSAttributedString, at index: Int
) -> [NSAttributedString.Key: Any] {
    var attributes = attributed.attributes(at: index, effectiveRange: nil)
    for key in MarkdownTextView.privateAttributeKeys { attributes.removeValue(forKey: key) }
    return attributes
}

@MainActor
private func fillerMatchesStorage(
    _ substitution: DisplaySubstitution, storage: NSTextStorage
) -> Bool {
    guard let replacement = substitution.replacement, replacement.length > 0 else { return true }
    let actual = renderingAttributes(of: replacement, at: 0)
    let expected = renderingAttributes(of: storage, at: substitution.sourceRange.location)
    return NSDictionary(dictionary: actual).isEqual(to: expected)
}

@MainActor
@Test("Hidden-marker layout fillers carry the storage's attributes at the marker")
func layoutFillersMatchStorageAttributes() {
    let (view, storage) = decoratedView()
    let hidden = view.currentDisplayMap.substitutions.filter { $0.isHidden }
    #expect(!hidden.isEmpty)

    for substitution in hidden {
        #expect(
            fillerMatchesStorage(substitution, storage: storage),
            "filler at \(substitution.sourceRange) lost the storage's attributes"
        )
    }
}

@MainActor
@Test("A colour-only theme swap rebuilds displayed paragraph attributes")
func themeSwapRebuildsDisplayedParagraphAttributes() throws {
    let themes = ThemeStore().themes
    let light = try #require(themes.first { $0.name == "Paper Light" })
    let dark = try #require(themes.first { $0.name == "Warm Dark" })
    let lightSheet = StyleSheet(theme: light, appearance: NSAppearance(named: .aqua)!)
    let darkSheet = StyleSheet(theme: dark, appearance: NSAppearance(named: .darkAqua)!)
    let storage = NSTextStorage(string: markerRichText)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 720, height: 420),
        storage: storage,
        styleSheet: lightSheet
    )
    view.update(document: MarkdownParser.parse(markerRichText), dirty: .wholesale)

    view.styleSheet = darkSheet

    let hidden = view.currentDisplayMap.substitutions.filter { $0.isHidden }
    #expect(!hidden.isEmpty)
    for substitution in hidden {
        #expect(
            fillerMatchesStorage(substitution, storage: storage),
            "theme swap left a cached light-theme filler at \(substitution.sourceRange)"
        )
    }
}

@MainActor
@Test("Hidden-marker layout fillers are source-length runs of word joiners")
func layoutFillersPreserveSourceLength() {
    let (view, _) = decoratedView()
    let hidden = view.currentDisplayMap.substitutions.filter { $0.isHidden }
    #expect(!hidden.isEmpty)

    for substitution in hidden {
        guard let replacement = substitution.replacement else { continue }
        #expect(replacement.length == substitution.sourceRange.length)
        #expect(replacement.string.allSatisfy { $0 == "\u{2060}" })
    }
}

@MainActor
@Test("A caret move keeps every other paragraph's fillers intact")
func caretMoveLeavesOtherParagraphFillersIntact() {
    let (view, storage) = decoratedView()
    let before = view.currentDisplayMap.substitutions.filter { $0.isHidden }

    // Put the caret inside the last heading, which reveals that paragraph's
    // markers and must leave every other paragraph exactly as it was.
    let caret = (markerRichText as NSString).range(of: "### Heading three").location + 5
    view.setSourceSelectedRanges([NSRange(location: caret, length: 0)])

    let revealedParagraph = view.paragraphRange(containing: caret)
    let after = view.currentDisplayMap.substitutions.filter { $0.isHidden }

    for substitution in after
    where NSIntersectionRange(substitution.sourceRange, revealedParagraph).length == 0 {
        #expect(
            fillerMatchesStorage(substitution, storage: storage),
            "filler at \(substitution.sourceRange) drifted after a caret move"
        )
    }
    // The reveal drops entries, never adds them.
    #expect(after.count <= before.count)
}
