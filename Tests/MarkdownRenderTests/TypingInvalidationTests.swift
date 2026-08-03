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
