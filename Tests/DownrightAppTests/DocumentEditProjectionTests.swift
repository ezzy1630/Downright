import AppKit
import Foundation
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightApp

/// Fragment payloads are reference values riding on NSTextStorage attribute
/// runs.  Runs move with an edit; payload ranges do not — unless every edit
/// funnel projects them.  The view's own funnel already did; these tests pin
/// the document-level funnels (commands, undo/redo, external absorption),
/// which previously left unchanged blocks below an edit pointing at pre-edit
/// offsets until some later decoration happened to touch them.
@Suite("Document edits project fragment payloads", .serialized)
struct DocumentEditProjectionTests {
    private let source = """
    Intro paragraph.

    ```swift
    let a = 1
    ```

    Tail paragraph.
    """

    @Test @MainActor
    func commandEditsShiftPayloadRangesBelowTheEdit() throws {
        let fixture = try Fixture(text: source)
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)

        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 420),
            storage: document.storage
        )
        view.update(document: document.parsed, dirty: .wholesale)

        // Locate the fenced code block's payload in the decorated storage.
        let fenceLine = (source as NSString).range(of: "```swift")
        guard fenceLine.location != NSNotFound else {
            Issue.record("fixture lost its code fence")
            return
        }
        guard let payloadBefore = document.storage.attribute(
            .drFragment, at: fenceLine.location, effectiveRange: nil
        ) as? FragmentPayload else {
            Issue.record("the code block must carry a fragment payload")
            return
        }

        // A document-level edit above the fence: two inserted characters.
        #expect(document.replace(
            NSRange(location: 0, length: 0),
            with: "Hi",
            actionName: "Type"
        ))

        // The payload must now describe where the block lives *after* the
        // edit, matching what a fresh parse of the current text says.
        let reparsed = MarkdownParser.parse(document.text)
        var expected = NSRange(location: 0, length: 0)
        reparsed.root.walk { block in
            if case .codeBlock(.some, true, _) = block.content, expected.length == 0 {
                expected = block.range
            }
        }
        #expect(expected.length > 0)
        #expect(payloadBefore.sourceRange.location == fenceLine.location + 2)
        #expect(payloadBefore.sourceRange.location == expected.location,
                "projected payload must agree with the fresh parse")
    }

    @Test @MainActor
    func undoRedoKeepsPayloadsAligned() throws {
        let fixture = try Fixture(text: source)
        defer { fixture.remove() }
        let document = MarkdownDocument()
        try document.open(fixture.url)

        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 720, height: 420),
            storage: document.storage
        )
        view.update(document: document.parsed, dirty: .wholesale)

        let fenceLine = (source as NSString).range(of: "```swift")
        let payload = document.storage.attribute(
            .drFragment, at: fenceLine.location, effectiveRange: nil
        ) as? FragmentPayload
        let originalLocation = fenceLine.location

        #expect(document.replace(
            NSRange(location: 0, length: 0), with: "XYZ", actionName: "Type"
        ))
        #expect(payload?.sourceRange.location == originalLocation + 3)

        document.undoManager.undo()
        #expect(payload?.sourceRange.location == originalLocation,
                "undo is itself an edit through replace() and must project too")

        document.undoManager.redo()
        #expect(payload?.sourceRange.location == originalLocation + 3)
    }
}

private struct Fixture {
    let root: URL
    let url: URL

    init(text: String) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-payload-projection-\(UUID().uuidString)", isDirectory: true)
        url = root.appendingPathComponent("note.md")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
