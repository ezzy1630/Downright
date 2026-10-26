import AppKit
import Foundation
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct NativePolishRegressionTests {
    private func fixture(_ text: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("polish-\(UUID().uuidString).md")
        try Data(text.utf8).write(to: url)
        return url
    }

    @Test func splitPreservesRenderedLinksAndSource() throws {
        let text = "# Heading\n\n[Link](notes.md) and **bold** text.\n"
        let url = try fixture(text)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = DocumentWindowController()
        try controller.open(url, mode: .live)
        defer { controller.close() }
        controller.markdownDocument.ensureParsedCurrent()
        let offset = (text as NSString).range(of: "Link").location
        #expect(controller.markdownDocument.storage.attribute(.drLink, at: offset, effectiveRange: nil) as? String == "notes.md")
        controller.toggleSplitView()
        let second = try #require(controller.splitContainer)
        #expect(second.textView.parsedDocument.text == text)
        #expect(controller.markdownDocument.storage.attribute(.drLink, at: offset, effectiveRange: nil) as? String == "notes.md")
        #expect(controller.primaryContainer.textView.moveToLink(forward: true))
        #expect(controller.markdownDocument.text == text)
    }

    @Test func documentLinksHaveTransactionalBackAndForward() throws {
        let first = try fixture("# First\n")
        let second = try fixture("# Second\n")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let controller = DocumentWindowController()
        try controller.open(first, mode: .live)
        defer { controller.close() }
        #expect(controller.openInPlace(second))
        #expect(controller.jumpHistory.canGoBack)
        controller.goBack()
        #expect(controller.markdownDocument.url == first.resolvingSymlinksInPath())
        #expect(controller.jumpHistory.canGoForward)
        try FileManager.default.removeItem(at: second)
        controller.goForward()
        #expect(controller.markdownDocument.url == first.resolvingSymlinksInPath())
        #expect(controller.jumpHistory.canGoForward)
        #expect(!controller.openInPlace(second))
        #expect(controller.jumpHistory.canGoForward)
    }

    @Test func closedFindAdvancesThroughHitsInTheSameViewport() throws {
        let url = try fixture("needle one needle two needle three\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = DocumentWindowController()
        try controller.open(url, mode: .live)
        defer { controller.close() }
        controller.applyFindQuery(FindQuery(text: "needle"))
        controller.advanceFind(forward: true)
        #expect(controller.primaryContainer.textView.currentSearchHit?.location == 11)
        controller.advanceFind(forward: true)
        #expect(controller.primaryContainer.textView.currentSearchHit?.location == 22)
        controller.advanceFind(forward: false)
        #expect(controller.primaryContainer.textView.currentSearchHit?.location == 11)
    }

    @Test func openingAnotherDocumentRestoresItsSplitState() throws {
        let first = try fixture("# First\n")
        let second = try fixture("# Second\n")
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let controller = DocumentWindowController()
        try controller.open(first, mode: .live)
        defer { controller.close() }
        controller.toggleSplitView()
        #expect(controller.openInPlace(second))
        #expect(controller.splitContainer == nil)
        #expect(controller.openInPlace(first))
        #expect(controller.splitContainer != nil)
        #expect(controller.openInPlace(first))
        #expect(controller.splitContainer != nil)
    }

    @Test(arguments: [true, false])
    func splitDividerAndResizeKeepBothPanesReadable(isVertical: Bool) {
        let split = ThemedSplitView(styleSheet: .current, isVertical: isVertical, minimumPaneLength: 256)
        split.frame = NSRect(x: 0, y: 0, width: isVertical ? 1_000 : 400, height: isVertical ? 400 : 1_000)
        split.addArrangedSubview(NSView())
        split.addArrangedSubview(NSView())
        // Detached split views may defer initial pane layout until display.
        split.adjustSubviews()
        split.setPosition(900, ofDividerAt: 0)
        func expectReadablePanes() {
            let first = split.arrangedSubviews[0].frame
            let second = split.arrangedSubviews[1].frame
            for pane in [first, second] {
                #expect((isVertical ? pane.width : pane.height) >= 256)
                #expect(split.bounds.contains(pane))
                #expect((isVertical ? pane.height : pane.width) == (isVertical ? split.bounds.height : split.bounds.width))
            }
            #expect(abs((isVertical ? second.minX - first.maxX : second.minY - first.maxY) - split.dividerThickness) < 0.01)
        }
        expectReadablePanes()
        split.frame.size = NSSize(width: isVertical ? 520 : 400, height: isVertical ? 400 : 520)
        split.layoutSubtreeIfNeeded()
        expectReadablePanes()
    }

    @Test func autosaveWaitsUntilTypingHasBeenIdle() async throws {
        let url = try fixture("before\n")
        defer { try? FileManager.default.removeItem(at: url) }
        let original = Preferences.shared.values.autosaveEnabled
        Preferences.shared.update { $0.autosaveEnabled = true }
        defer { Preferences.shared.update { $0.autosaveEnabled = original } }
        let controller = DocumentWindowController()
        try controller.open(url, mode: .live)
        defer { controller.close() }
        controller.markdownDocument.replace(NSRange(location: 0, length: 6), with: "first", actionName: "Edit")
        try await Task.sleep(for: .seconds(1.2))
        controller.markdownDocument.replace(NSRange(location: 0, length: 5), with: "second", actionName: "Edit")
        try await Task.sleep(for: .seconds(1.1))
        #expect(try String(contentsOf: url, encoding: .utf8) == "before\n")
        // The no-save assertion above straddles the superseded deadline.
        // After that, wait for the actual write rather than assuming the main
        // queue must execute the idle timer within a 200ms CI scheduling margin.
        let deadline = ContinuousClock.now + .seconds(5)
        while try String(contentsOf: url, encoding: .utf8) != "second\n", ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "second\n")
    }

    @Test(arguments: ["[Sibling](notes.md)\n", "**Bold** text\n", "`Code` text\n", "# Heading\n\nBody\n"])
    func insertedSpaceBeforeHiddenSyntaxCanBeDeletedExactly(_ original: String) throws {
        let url = try fixture(original)
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = DocumentWindowController()
        try controller.open(url, mode: .live)
        defer { controller.close() }
        controller.markdownDocument.ensureParsedCurrent()
        let editor = controller.primaryContainer.textView
        #expect(editor.performSourceEdit(range: NSRange(location: 0, length: 0), replacement: " "))
        #expect(editor.sourceSelectedRange == NSRange(location: 1, length: 0))
        controller.markdownDocument.ensureParsedCurrent()
        editor.deleteBackward(nil)
        controller.markdownDocument.ensureParsedCurrent()
        #expect(controller.markdownDocument.text.utf16.elementsEqual(original.utf16))
        #expect(!controller.markdownDocument.isDirty)
    }

    @Test func encodedDocumentLinkOpensItsHeading() throws {
        let first = try fixture("# First\n")
        let target = first.deletingLastPathComponent().appendingPathComponent("polish notes \(UUID().uuidString).md")
        try Data("# Second\n\n## Target\n\nDestination.\n".utf8).write(to: target)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: target) }
        let controller = DocumentWindowController()
        try controller.open(first, mode: .live)
        defer { controller.close() }
        let encoded = try #require(target.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
        controller.markdownTextView(controller.primaryContainer.textView,
                                    didActivateLink: encoded + "#target", at: NSRange(location: 0, length: 0), modifiers: [])
        #expect(controller.markdownDocument.url == target.resolvingSymlinksInPath())
        #expect(controller.jumpHistory.current?.offset == 10)
        controller.goBack()
        #expect(controller.markdownDocument.url == first.resolvingSymlinksInPath())
    }

    @Test func linkedHeadingRestoresBothDestinationSplitViewports() throws {
        let first = try fixture("# First\n")
        let prefix = (1...60).map { "Paragraph \($0).\n\n" }.joined()
        let target = try fixture(prefix + "## Target\n\n" + prefix)
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: target) }
        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(target, mode: .live)
        controller.showWindow(nil)
        controller.window?.contentView?.layoutSubtreeIfNeeded()
        controller.primaryContainer.textView.prepareForDisplay()
        controller.toggleSplitView()
        #expect(controller.openInPlace(first))
        #expect(controller.openInPlace(target, fragment: "target"))
        let secondary = try #require(controller.splitContainer)
        let primaryOffset = controller.primaryContainer.textView.topVisibleOffset
        let secondaryOffset = secondary.textView.topVisibleOffset
        #expect(primaryOffset > prefix.utf16.count - 100)
        #expect(abs(primaryOffset - secondaryOffset) < 40)
        controller.goBack()
        #expect(controller.markdownDocument.url == first.resolvingSymlinksInPath())
        controller.goForward()
        #expect(controller.markdownDocument.url == target.resolvingSymlinksInPath())
        #expect(controller.primaryContainer.textView.topVisibleOffset > prefix.utf16.count - 100)
        #expect(try #require(controller.splitContainer).textView.topVisibleOffset > prefix.utf16.count - 100)
    }

    @Test(arguments: [CGFloat(60), 80, 110])
    func explicitReadingWidthSurvivesWideWindowLayout(_ characters: CGFloat) throws {
        var theme = Theme.fallback
        theme.typography.measureCharacters = characters
        let sheet = StyleSheet(theme: theme, appearance: try #require(NSAppearance(named: .aqua)))
        #expect(abs(sheet.measureWidth / sheet.averageCharacterWidth - characters) < 0.001)
        let container = MarkdownContainerView(storage: NSTextStorage(string: "Text\n"), styleSheet: sheet)
        container.frame = NSRect(x: 0, y: 0, width: 1600, height: 700)
        container.layoutSubtreeIfNeeded()
        let width = try #require(container.textView.textContainer).size.width - RenderMetrics.codeBleed
        #expect(abs(width / sheet.averageCharacterWidth - characters) < 0.001)
    }

    @Test func narrowPaneFitsItsTextWithoutChangingThePreference() throws {
        var theme = Theme.fallback
        theme.typography.measureCharacters = 110
        let sheet = StyleSheet(theme: theme, appearance: try #require(NSAppearance(named: .aqua)))
        let container = MarkdownContainerView(storage: NSTextStorage(string: "Text\n"), styleSheet: sheet)
        container.frame = NSRect(x: 0, y: 0, width: 340, height: 700)
        container.layoutSubtreeIfNeeded()
        let width = try #require(container.textView.textContainer).size.width
        let trailingEdge = container.scrollView.contentInsets.left + container.textView.textContainerOrigin.x + width
        #expect(trailingEdge <= container.scrollView.bounds.width)
        #expect(container.styleSheet.theme.typography.measureCharacters == 110)
    }

    @Test func oldAndUnknownLastWindowSettingsPreserveTheDefault() throws {
        let legacy = try JSONDecoder().decode(Preferences.Values.self, from: Data("{}".utf8))
        #expect(legacy.lastDocumentCloseBehavior == .showStartWindow)
        let unknown = try JSONDecoder().decode(Preferences.Values.self, from: Data(#"{"lastDocumentCloseBehavior":"future-option","restoreSession":false}"#.utf8))
        #expect(unknown.lastDocumentCloseBehavior == .showStartWindow)
        #expect(!unknown.restoreSession)
        for behavior in LastDocumentCloseBehavior.allCases {
            var values = Preferences.Values()
            values.lastDocumentCloseBehavior = behavior
            let restored = try JSONDecoder().decode(Preferences.Values.self, from: JSONEncoder().encode(values))
            #expect(restored.lastDocumentCloseBehavior == behavior)
        }
    }

    @Test func localLinksDecodePathsOnceAndSeparateFragments() throws {
        let base = URL(fileURLWithPath: "/tmp/docs/README.md")
        let link = try #require(LocalDocumentLink("../my%20notes%23draft.md#part%20two", documentURL: base))
        #expect(link.url.path == "/tmp/my notes#draft.md")
        #expect(link.fragment == "part two")
        let literalPercent = try #require(LocalDocumentLink("literal%2520name.md", documentURL: base))
        #expect(literalPercent.url.path == "/tmp/docs/literal%20name.md")
        let absolute = try #require(LocalDocumentLink("file:///tmp/my%20notes.md#target", documentURL: nil))
        #expect(absolute.url.path == "/tmp/my notes.md")
        #expect(absolute.fragment == "target")
        #expect(LocalDocumentLink("https://example.com/notes.md", documentURL: base) == nil)
        #expect(LocalDocumentLink("notes.md", documentURL: nil) == nil)
    }
}
