import AppKit
import MarkdownCore
@testable import MarkdownRender
import Testing

@MainActor
private final class PathExistenceProbe: MarkdownTextViewDelegate {
    private(set) var calls = 0
    var exists = true

    func markdownTextView(_ view: MarkdownTextView, pathExistsFor token: PathToken) -> Bool {
        calls += 1
        return exists
    }
}

@MainActor
@Test("Split panes cannot restore stale path existence after a shared refresh")
func splitPathCachesInvalidateTogether() throws {
    let text = "`fixtures/report.md`"
    let document = MarkdownParser.parse(text)
    let token = try #require(document.pathTokens.first)
    let storage = NSTextStorage(string: text)
    let primary = MarkdownTextView(frame: .zero, storage: storage)
    let split = MarkdownTextView(frame: .zero, storage: storage)
    let probe = PathExistenceProbe()
    probe.exists = false
    primary.markdownDelegate = probe
    split.markdownDelegate = probe
    primary.update(document: document, dirty: .wholesale)
    split.update(document: document, dirty: .wholesale)
    #expect(storage.attribute(.drPathExists, at: token.range.location, effectiveRange: nil) as? Bool == false)

    probe.exists = true
    primary.invalidatePathExistenceCache()
    split.invalidatePathExistenceCache()
    primary.refreshPathExistence()
    #expect(storage.attribute(.drPathExists, at: token.range.location, effectiveRange: nil) as? Bool == true)

    split.update(document: document, dirty: DirtySet(ranges: [token.range], isWholesale: false))
    #expect(storage.attribute(.drPathExists, at: token.range.location, effectiveRange: nil) as? Bool == true)
}

@MainActor
@Test("Dense path refreshes yield between bounded attribute batches")
func densePathRefreshIsChunked() async throws {
    let text = (0..<512).map { "`fixtures/file-\($0).md`" }.joined(separator: "\n")
    let document = MarkdownParser.parse(text)
    #expect(document.pathTokens.count == 512)

    let storage = NSTextStorage(string: text)
    let view = MarkdownTextView(
        frame: NSRect(x: 0, y: 0, width: 720, height: 420),
        storage: storage
    )
    view.update(document: document, dirty: .wholesale)
    let probe = PathExistenceProbe()
    view.markdownDelegate = probe

    view.refreshPathExistence()
    #expect(probe.calls == 128, "the first main-loop turn must stay bounded")

    let deadline = Date().addingTimeInterval(2)
    while probe.calls < document.pathTokens.count, Date() < deadline {
        await Task.yield()
    }
    #expect(probe.calls == document.pathTokens.count)
}

@MainActor
@Test("A cancelled dense path clear can restart after a parse commit")
func cancelledDensePathClearRestarts() async throws {
    let text = (0..<512).map { "`missing/file-\($0).md`" }.joined(separator: "\n")
    let document = MarkdownParser.parse(text)
    let storage = NSTextStorage(string: text)
    let view = MarkdownTextView(frame: .zero, storage: storage)
    let probe = PathExistenceProbe()
    probe.exists = false
    view.markdownDelegate = probe
    view.update(document: document, dirty: .wholesale)

    probe.exists = true
    view.refreshPathExistence()
    #expect(probe.calls >= 128)
    // A parse commit cancels the remaining scheduled batches.
    view.update(document: document, dirty: DirtySet(ranges: [document.pathTokens[0].range], isWholesale: false))
    view.refreshPathExistence()

    let deadline = Date().addingTimeInterval(2)
    while Date() < deadline {
        let allNeutral = document.pathTokens.allSatisfy {
            storage.attribute(.drPathExists, at: $0.range.location, effectiveRange: nil) as? Bool == true
        }
        if allNeutral { return }
        await Task.yield()
    }
    Issue.record("the restarted clear left stale missing-path attributes")
}

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
