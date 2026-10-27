import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@MainActor
@Suite(.serialized)
struct NativeLinkActivationTests {
    @Test func appKitLinkActivationUsesTheMarkdownHost() {
        let text = "[Sibling](notes.md)\n"
        let storage = NSTextStorage(string: text)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        let host = LinkHost()
        view.markdownDelegate = host
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        #expect(view.moveToLink(forward: true))
        // The entry point NSTextView invokes during native link tracking.
        view.clicked(onLink: "notes.md", at: view.selectedRange().location)
        #expect(host.destinations == ["notes.md"])
        #expect(storage.string == text)
    }
}

@MainActor
private final class LinkHost: MarkdownTextViewDelegate {
    var destinations: [String] = []
    func markdownTextView(
        _ view: MarkdownTextView, didActivateLink destination: String,
        at range: NSRange, modifiers: NSEvent.ModifierFlags
    ) {
        destinations.append(destination)
    }
}
