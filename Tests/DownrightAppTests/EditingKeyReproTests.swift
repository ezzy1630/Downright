import AppKit
import Testing
import MarkdownCore
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct EditingKeyReproTests {
    private func makeController(text: String, file fileURL: URL) throws -> DocumentWindowController {
        try text.write(to: fileURL, atomically: true, encoding: .utf8)
        let controller = DocumentWindowController()
        try controller.open(fileURL, mode: .live)
        return controller
    }

    private func type(_ character: Character, into textView: NSTextView) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: textView.window?.windowNumber ?? 0,
            context: nil,
            characters: String(character),
            charactersIgnoringModifiers: String(character),
            isARepeat: false,
            keyCode: 0
        )!
        textView.keyDown(with: event)
    }

    private func pressDelete(into textView: NSTextView) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: textView.window?.windowNumber ?? 0,
            context: nil,
            characters: String(UnicodeScalar(NSDeleteCharacter)!),
            charactersIgnoringModifiers: String(UnicodeScalar(NSDeleteCharacter)!),
            isARepeat: false,
            keyCode: 51
        )!
        textView.keyDown(with: event)
    }

    @Test func typingThroughRealKeyDownMutatesDocument() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyRepro-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = try makeController(text: "# Title\n\nBody text.\n", file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.primaryContainer.textView)
        // Document mode hides the heading marker; a caret at the visible start
        // of `# Title` resolves after `# `, so seed the caret in the body.
        let body = (controller.markdownDocument.text as NSString).range(of: "Body text.")
        controller.primaryContainer.textView.setSourceSelectedRanges([
            NSRange(location: body.location, length: 0)
        ])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let before = controller.markdownDocument.text
        type("x", into: controller.primaryContainer.textView)
        type("y", into: controller.primaryContainer.textView)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(controller.primaryContainer.textView.isEditable)
        #expect(controller.markdownDocument.text != before)
        #expect(controller.markdownDocument.text.contains("xyBody text."))
    }

    @Test func typingAtHeadingStartExtendsVisibleTitle() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproHeading-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = try makeController(text: "# Title\n\nBody text.\n", file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.primaryContainer.textView)
        controller.primaryContainer.textView.setSourceSelectedRanges([
            NSRange(location: 0, length: 0)
        ])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        type("x", into: controller.primaryContainer.textView)
        type("y", into: controller.primaryContainer.textView)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        // Hidden `# ` stays put; typing lands in the visible title.
        #expect(controller.markdownDocument.text.hasPrefix("# xyTitle"))
    }

    @Test func deleteThroughRealKeyDownMutatesDocument() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproDel-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = try makeController(text: "# Title\n\nBody text.\n", file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.primaryContainer.textView)
        // Put the caret at the end so delete-backward removes a real character.
        let end = (controller.markdownDocument.text as NSString).length
        controller.primaryContainer.textView.setSourceSelectedRanges([
            NSRange(location: end, length: 0)
        ])
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        let before = controller.markdownDocument.text
        pressDelete(into: controller.primaryContainer.textView)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.2))

        #expect(controller.primaryContainer.textView.isEditable)
        #expect(controller.markdownDocument.text != before)
        #expect(controller.markdownDocument.text == "# Title\n\nBody text.")
    }
}
