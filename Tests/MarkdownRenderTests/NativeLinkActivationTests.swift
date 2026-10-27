import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@MainActor
@Suite(.serialized)
struct NativeLinkActivationTests {
    @Test(arguments: ["", "\n", " after.\n"])
    func firstLineNativeLinkHitUsesReaderTypography(_ suffix: String) throws {
        let text = "[Open sibling document](sibling.md)" + suffix
        var theme = try #require(ThemeStore.shared.themes.first { $0.name == "Paper Light" })
        theme.typography = .default
        let sheet = StyleSheet(theme: theme, appearance: NSAppearance(named: .aqua)!)
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage, styleSheet: sheet)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1020, height: 674),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = container
        defer { window.orderOut(nil); window.close() }
        let view = container.textView
        view.mode = .read
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        window.orderFront(nil)
        container.layoutSubtreeIfNeeded()
        view.prepareForDisplay()
        window.displayIfNeeded()
        // The same native editor point used by activated-app acceptance: it
        // lands on the visible first word while the Markdown stays hidden.
        let point = NSPoint(x: 60, y: 49)
        #expect(view.attribute(.drLink, at: point)?.value as? String == "sibling.md")
        if suffix.hasPrefix(" ") {
            let space = (text as NSString).range(of: " after.").location
            let edge = try #require(view.rect(forOffset: space))
            #expect(view.attribute(.drLink, at: NSPoint(x: edge.minX + 1, y: edge.midY)) == nil)
        }
        #expect(storage.string == text)
    }

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
