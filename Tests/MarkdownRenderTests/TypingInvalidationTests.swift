import AppKit
import MarkdownCore
@testable import MarkdownRender
import Testing

@MainActor
@Test("Document-mode parse commits never publish a whole-storage attribute edit")
func documentTypingKeepsAttributeInvalidationLocal() {
    let paragraph = "A paragraph whose attributes should remain outside the dirty edit scope."
    let text = (0..<80).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
    let storage = NSTextStorage(string: text)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 720, height: 420),
        storage: storage
    )
    let document = MarkdownParser.parse(text)
    view.update(document: document, dirty: .wholesale)

    let probe = TextStorageEditProbe()
    storage.delegate = probe
    let dirty = NSRange(location: 4, length: 8)
    view.update(
        document: document,
        dirty: DirtySet(ranges: [dirty], isWholesale: false)
    )

    #expect(!probe.attributeEdits.isEmpty)
    #expect(probe.attributeEdits.allSatisfy { $0.length < storage.length / 4 })
}

@MainActor
@Test("A parse commit does not repaint distant search overlays")
func typingKeepsOverlayInvalidationLocal() {
    let paragraph = "match in a paragraph whose overlay is outside the edit scope."
    let text = (0..<80).map { "## Section \($0)\n\n\(paragraph)" }.joined(separator: "\n\n")
    let storage = NSTextStorage(string: text)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 720, height: 420),
        storage: storage
    )
    let document = MarkdownParser.parse(text)
    view.update(document: document, dirty: .wholesale)

    let source = text as NSString
    var hits: [NSRange] = []
    var cursor = 0
    while cursor < source.length {
        let search = NSRange(location: cursor, length: source.length - cursor)
        let hit = source.range(of: "match", options: [], range: search)
        guard hit.location != NSNotFound else { break }
        hits.append(hit)
        cursor = hit.upperBound
    }
    view.searchHits = hits

    let probe = TextStorageEditProbe()
    storage.delegate = probe
    let dirty = NSRange(location: 4, length: 8)
    view.update(
        document: document,
        dirty: DirtySet(ranges: [dirty], isWholesale: false)
    )

    #expect(!probe.attributeEdits.isEmpty)
    #expect(probe.attributeEdits.allSatisfy { $0.length < storage.length / 4 })
}

@MainActor
@Test("Typing keeps unaffected rendered objects alive until parse commit")
func typingProjectsRenderedObjectsAcrossTheEdit() {
    let text = "Intro.\n\nMath $x^2$ and reference [^1].\n\n[^1]: Note.\n\nTail."
    let storage = NSTextStorage(string: text)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 720, height: 420),
        storage: storage
    )
    view.update(document: MarkdownParser.parse(text), dirty: .wholesale)

    let before = view.currentDisplayMap.substitutions.filter {
        !$0.isHidden && !$0.isHardWrapReflow
    }
    #expect(before.count >= 2)

    #expect(view.performSourceEdit(
        range: NSRange(location: 0, length: 0),
        replacement: "Z"
    ))

    let projected = view.currentDisplayMap.substitutions.filter {
        !$0.isHidden && !$0.isHardWrapReflow
    }
    #expect(projected.count == before.count)
    #expect(zip(before, projected).allSatisfy { old, new in
        new.sourceRange.location == old.sourceRange.location + 1
            && new.sourceRange.length == old.sourceRange.length
    })
}

@MainActor
@Test("Cursor position uses the live paragraph index")
func cursorPositionTracksEditsWithoutScanningTheDocument() {
    let storage = NSTextStorage(string: "first\nsecond\nthird")
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 720, height: 420),
        storage: storage
    )
    view.update(document: MarkdownParser.parse(storage.string), dirty: .wholesale)

    #expect(view.sourcePosition(at: 8) == (line: 2, column: 3))
    #expect(view.performSourceEdit(
        range: NSRange(location: 0, length: 0),
        replacement: "new\n"
    ))
    #expect(view.sourcePosition(at: 12) == (line: 3, column: 3))
}

@MainActor
private final class TextStorageEditProbe: NSObject, NSTextStorageDelegate {
    var attributeEdits: [NSRange] = []

    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedAttributes) else { return }
        MainActor.assumeIsolated { attributeEdits.append(editedRange) }
    }
}
