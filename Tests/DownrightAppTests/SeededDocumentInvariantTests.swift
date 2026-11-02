import AppKit
import Foundation
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightApp

/// Fixed seeds are replayable regressions, not probabilistic CI outcomes.
@MainActor
@Suite("Seeded source and presentation invariants", .serialized)
struct SeededDocumentInvariantTests {
    private struct Generator {
        var state: UInt64
        mutating func index(_ count: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 32) % UInt64(count))
        }
    }

    private let original = "# Heading 👩🏽‍💻\r\n\r\n**café** and e\u{301}, 中文.\r\n- [ ] task\r\n\r\n```swift\r\nlet x = 1\r\n```\r\n"

    @Test(arguments: [UInt64(0xC0FFEE), 0xD15A1A7, 0x5E1EC7])
    func editUndoRedoAndPresentationPreserveSource(seed: UInt64) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downright-seeded-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("note.md")
        let bytes = Data(original.utf8)
        try bytes.write(to: url)
        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }
        let primary = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 720, height: 420), storage: document.storage)
        let secondary = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 540, height: 420), storage: document.storage)
        let engine = DecorationEngine(styleSheet: StyleSheet(theme: .fallback,
            appearance: NSAppearance(named: .aqua) ?? NSAppearance.currentDrawing()))
        engine.policy = RenderMode.read.policy
        var generator = Generator(state: seed)
        var states = [document.text]
        let insertions = ["👩🏽‍💻", "e\u{301}", "中文", "\n", "**bold**", "[x](note.md)", "", "\t"]

        for step in 0..<48 {
            let characters = Array(states.last!)
            let start = generator.index(characters.count + 1)
            let count = generator.index(min(3, characters.count - start) + 1)
            let replacement = insertions[generator.index(insertions.count)]
            let prefix = String(characters[..<start])
            let removed = String(characters[start..<(start + count)])
            let range = NSRange(location: prefix.utf16.count, length: removed.utf16.count)
            let expected = (states.last! as NSString).replacingCharacters(in: range, with: replacement)
            if document.replace(range, with: replacement, actionName: "Seeded edit") {
                states.append(expected)
            }
            let context = "seed=\(seed) step=\(step)"
            #expect(document.text.utf16.elementsEqual(expected.utf16), "\(context)")
            document.ensureParsedCurrent()
            #expect(document.parsed.length == document.storage.length, "\(context)")

            // Both panes must adopt the current presentation before either
            // decorates their shared storage, just like the window controller.
            primary.update(document: document.parsed, dirty: .wholesale)
            secondary.adoptSharedPresentation(from: primary)
            primary.mode = .source
            secondary.mode = .source
            let caret = NSRange(location: document.storage.length, length: 0)
            primary.setSourceSelectedRanges([caret])
            primary.mode = .read
            secondary.adoptSharedPresentation(from: primary)
            secondary.mode = .read
            primary.mode = .source
            #expect(primary.sourceSelectedRange == caret, "\(context)")
            #expect(primary.textStorage === secondary.textStorage)
            #expect(document.text.utf16.elementsEqual(expected.utf16), "\(context)")

            let map = DisplayMap(paragraphs: ParagraphIndex(text: document.text as NSString),
                hidden: engine.hiddenRanges(document: document.parsed, caret: nil, selections: []))
            var previous = -1
            for offset in 0...document.storage.length {
                let displayed = map.textKitOffset(forSource: offset)
                #expect(displayed >= previous, "\(context) offset=\(offset)")
                if map.isCanonical(offset) {
                    #expect(map.sourceOffset(forTextKit: displayed) == offset, "\(context) offset=\(offset)")
                }
                previous = displayed
            }
            #expect(try Data(contentsOf: url) == bytes, "presentation or editing wrote the file: \(context)")
        }

        for expected in states.dropLast().reversed() {
            document.undoManager.undo()
            #expect(document.text.utf16.elementsEqual(expected.utf16), "undo seed=\(seed)")
        }
        #expect(!document.isDirty, "undo to exact saved bytes must clear dirty state, seed=\(seed)")
        for expected in states.dropFirst() {
            document.undoManager.redo()
            #expect(document.text.utf16.elementsEqual(expected.utf16), "redo seed=\(seed)")
        }
        try document.save()
        #expect(!document.isDirty)
        #expect(try DocumentIO.read(contentsOf: url).text.utf16.elementsEqual(document.text.utf16))
    }

    @Test(arguments: [UInt64(0xC0FFEE), 0xD15A1A7, 0x5E1EC7])
    func returningToSavedSourceNeverDiscardsAnExternalConflict(seed: UInt64) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("downright-conflict-\(UUID()).md")
        try Data(original.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let document = MarkdownDocument()
        try document.open(url)
        defer { document.close() }
        var generator = Generator(state: seed)
        let addition = String(repeating: "👩🏽‍💻", count: 1 + generator.index(5))
        document.replace(NSRange(location: 0, length: 0), with: addition, actionName: "Seeded edit")
        let external = Data(("# External \(seed)\n" + original).utf8)
        try external.write(to: url, options: .atomic)
        #expect(throws: SaveError.self) { try document.save() }
        document.undoManager.undo()
        #expect(!document.isDirty)
        #expect(document.pendingConflict != nil)
        #expect(document.presentationState.phase == .conflict)
        _ = document.saveIfNeeded()
        #expect(try Data(contentsOf: url) == external, "seed=\(seed)")
    }
}
