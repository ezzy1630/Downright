import AppKit
import CoreFoundation
import NativeUITestSupport
import Testing

@testable import DownrightApp
@testable import MarkdownRender

@Suite(.serialized)
@MainActor
struct NativeUIDriverTests {
    @Test func headingDoubleClickAndRenderedEmphasisDrag() async throws {
        try await UIDriver.withDocument("# Title\n\nBefore **bold words** after.\n") { ui in
            try ui.doubleClick(onText: "Title")
            ui.check(ui.selectedSourceRange == NSRange(location: 2, length: 5),
                     "Double-click selected \(ui.selectedSourceRange) instead of Title")
            try ui.drag(fromText: "Before", toText: "after")
            ui.check(ui.selectedSourceText == "Before **bold words** after",
                     "Drag selected \(String(reflecting: ui.selectedSourceText))")
        }
    }

    @Test func codeWordAndDragAcrossLinkAndTable() async throws {
        let block = """
        Before [local link](#end).

        | Label | Value |
        | --- | --- |
        | Alpha | Beta |

        After
        """
        try await UIDriver.withDocument("# Start\n\n```swift\nlet answer = 42\n```\n\n" + block + "\n\n# End\n") { ui in
            try ui.doubleClick(onText: "answer")
            ui.check(ui.selectedSourceText == "answer", "Code double-click selected \(ui.selectedSourceRange)")
            try ui.drag(fromText: "Before", toText: "After")
            ui.check(ui.selectedSourceText == block, "Link/table drag selected \(ui.selectedSourceRange)")
        }
    }

    @Test func dragAcrossInlineImagePreservesItsMarkdown() async throws {
        let image = NSImage(size: NSSize(width: 32, height: 16), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
        let line = "Before ![Badge](badge.png) after"
        try await UIDriver.withDocument("# Assets\n\n" + line + ".\n", files: ["badge.png": png]) { ui in
            let range = try ui.range(of: "![Badge](badge.png)")
            try await ui.wait(until: {
                ui.textView.currentDisplayMap.substitutions(in: range).contains {
                    $0.replacement?.attribute(.attachment, at: 0, effectiveRange: nil) != nil
                }
            }, "the local badge to replace its inline alt text with an image")
            try ui.drag(fromText: "Before", toText: "after")
            ui.check(ui.selectedSourceText == line, "Image drag selected \(ui.selectedSourceRange)")
            ui.check(Data(ui.source.utf8) == Data(("# Assets\n\n" + line + ".\n").utf8), "Image interaction changed source bytes")
        }
    }

    @Test func dragAfterTheFixtureWindowResignsKeyStillSelects() async throws {
        // Hosted runners can resign the invisible window's key state while a
        // test awaits; the next mouse-down was then swallowed as a first click.
        try await UIDriver.withDocument("# Title\n\nBefore **bold words** after.\n") { ui in
            ui.window.resignKey()
            try ui.drag(fromText: "Before", toText: "after")
            ui.check(ui.selectedSourceText == "Before **bold words** after",
                     "Drag after resignKey selected \(ui.selectedSourceRange)")
        }
    }

    @Test func listReturnAndUndoRedo() async throws {
        let initial = "- alpha\n"
        try await UIDriver.withDocument(initial) { ui in
            try ui.click(onText: "alpha")
            for _ in 0..<3 { try ui.press(.right) }
            ui.check(ui.selectedSourceRange == NSRange(location: 7, length: 0), "The caret did not land at the list item's end")
            try ui.press(.return)
            let continued = "- alpha\n- \n"
            ui.check(ui.source == continued && ui.isDirty, "Return produced \(ui.source.debugDescription)")
            try ui.type("b")
            let edited = "- alpha\n- b\n"
            let document = ui.controller.markdownDocument
            try await ui.wait(until: {
                document.lastCompletedParseRevision == document.revision &&
                    ui.textView.parsedDocument.length == edited.utf16.count
            }, "the renderer to adopt the edited list")
            ui.check(ui.source == edited && ui.isDirty, "Typing produced \(ui.source.debugDescription)")
            try ui.input.sendAction(Selector(("undo:")), to: ui.window)
            ui.check(ui.source == continued, "Undo produced \(ui.source.debugDescription)")
            try ui.input.sendAction(Selector(("undo:")), to: ui.window)
            ui.check(ui.source == initial && !ui.isDirty, "Undo to disk produced \(ui.source.debugDescription), dirty \(ui.isDirty)")
            try ui.input.sendAction(Selector(("redo:")), to: ui.window)
            ui.check(ui.source == continued && ui.isDirty, "Redo produced \(ui.source.debugDescription)")
            let persisted = try Data(contentsOf: ui.fixture)
            ui.check(persisted == Data(initial.utf8), "Editing and undo changed the file before Save")
        }
    }

    @Test func checkboxDoubleClickTogglesOnlyOnce() async throws {
        let initial = "- [ ] First task\n- [x] Second task\n"
        try await UIDriver.withDocument(initial) { ui in
            try ui.input.click(at: firstCheckboxPoint(in: ui), count: 2)
            let expected = "- [x] First task\n- [x] Second task\n"
            ui.check(ui.source == expected && !ui.isDirty,
                     "Double-click left \(ui.source.debugDescription), dirty \(ui.isDirty)")
            let persisted = try Data(contentsOf: ui.fixture)
            ui.check(persisted == Data(expected.utf8), "The checkbox did not write exactly one change to disk")
            try ui.doubleClick(onText: "Second")
            ui.check(ui.selectedSourceText == "Second", "Double-click selected \(ui.selectedSourceRange) in the task label")
        }
    }

    @Test func discardAppliesWhenLinkDestinationOpensDuringSavePrompt() async throws {
        let original = "[Open sibling](B.md)\n\n- [ ] First task\n\nOriginal prose.\n"
        let sibling = "# B\n"
        try await UIDriver.withDocument(original, files: ["B.md": Data(sibling.utf8)]) { ui in
            let app = AppDelegate()
            let other = DocumentWindowController()
            app.adopt(ui.controller)
            defer {
                other.window?.orderOut(nil)
                other.documentWillClose()
                other.close()
                ui.controller.onClose = nil
                other.onClose = nil
            }
            try ui.click(onText: "Original prose")
            try ui.type("declined ")
            try #require(ui.isDirty)
            ui.controller.markdownDocument.ensureParsedCurrent()
            ui.layout()
            let destination = ui.root.appendingPathComponent("B.md")
            var openedDuringPrompt = false
            var awaitingPrompt = true
            defer { awaitingPrompt = false }
            CFRunLoopPerformBlock(CFRunLoopGetMain(), RunLoop.Mode.modalPanel.rawValue as CFString) {
                MainActor.assumeIsolated {
                    guard awaitingPrompt else { return }
                    defer { NSApp.stopModal(withCode: .alertSecondButtonReturn) }
                    do {
                        try other.open(destination, mode: .live)
                        other.window?.alphaValue = 0
                        other.window?.ignoresMouseEvents = true
                        app.adopt(other)
                        openedDuringPrompt = true
                    } catch {
                        Issue.record("Could not open the sibling during the save prompt: \(error)")
                    }
                }
            }

            try ui.click(onText: "Open sibling")
            try #require(openedDuringPrompt, "The sibling must open inside the save prompt")
            #expect(other.window?.isVisible == true, "The link must bring the existing destination forward")
            #expect(ui.controller.markdownDocument.url == ui.fixture.resolvingSymlinksInPath())
            #expect(ui.source == original)
            #expect(!ui.isDirty)
            #expect(!ui.controller.markdownDocument.undoManager.canUndo)

            try ui.input.click(at: firstCheckboxPoint(in: ui))
            let expected = original.replacingOccurrences(of: "- [ ]", with: "- [x]")
            #expect(ui.source == expected)
            #expect(try Data(contentsOf: ui.fixture) == Data(expected.utf8))
        }
    }

    @Test func checkboxLeavesExistingUnsavedEditsInMemory() async throws {
        let original = "- [ ] First task\n\nOriginal prose.\n"
        try await UIDriver.withDocument(original) { ui in
            defer { ui.controller.markdownDocument.discardUnsavedChanges() }
            try ui.click(onText: "Original prose")
            try ui.type("unsaved ")
            let edited = ui.source
            try #require(ui.isDirty)
            ui.controller.markdownDocument.ensureParsedCurrent()
            ui.layout()

            try ui.input.click(at: firstCheckboxPoint(in: ui))

            #expect(ui.source == edited.replacingOccurrences(of: "- [ ]", with: "- [x]"))
            #expect(ui.isDirty)
            #expect(try Data(contentsOf: ui.fixture) == Data(original.utf8))
        }
    }

    @Test func taskPanelEditsLeaveExistingUnsavedEditsInMemory() async throws {
        // Same policy as the checkbox: after "Discard" during a cancelled
        // Quit, the refused text is still on screen and must not reach disk
        // through the Task panel.
        let original = "- [ ] First task\n\nOriginal prose.\n"
        try await UIDriver.withDocument(original) { ui in
            defer { ui.controller.markdownDocument.discardUnsavedChanges() }
            try ui.click(onText: "Original prose")
            try ui.type("unsaved ")
            try #require(ui.isDirty)
            ui.controller.taskPanel(TaskPanelView(), didRequestNewTask: "Second task", headingIndex: nil)
            #expect(ui.source.contains("Second task") && ui.source.contains("unsaved "))
            #expect(ui.isDirty)
            #expect(try Data(contentsOf: ui.fixture) == Data(original.utf8))
        }
    }

    @Test func taskPanelEditOnACleanDocumentStillWritesThrough() async throws {
        let original = "- [ ] First task\n"
        try await UIDriver.withDocument(original) { ui in
            ui.controller.taskPanel(TaskPanelView(), didRequestNewTask: "Second task", headingIndex: nil)
            #expect(!ui.isDirty)
            let saved = try String(contentsOf: ui.fixture, encoding: .utf8)
            #expect(saved.contains("Second task"))
        }
    }

    private func firstCheckboxPoint(in ui: UIDriver) throws -> NSPoint {
        let task = try #require(ui.textView.parsedDocument.tasks.first)
        let line = try #require(ui.textView.rect(forOffset: task.contentRange.location))
        let style = ui.textView.styleSheet
        let checkbox = ListOrnamentFragment.taskBoxRect(
            textEdge: line.minX, centreY: line.minY + min(style.lineHeight, line.height) * 0.44,
            bodySize: style.bodyFont().pointSize
        )
        return ui.textView.convert(NSPoint(x: checkbox.midX, y: checkbox.midY), to: nil)
    }

    @Test func encodedHeadingLinkAndHistoryRestoreTheReadingPosition() async throws {
        let original = "[Open encoded heading](my%20notes.md#target)\n\n" +
            (1...40).map { "Original paragraph \($0).\n\n" }.joined()
        let paragraphs = (1...60).map { "Paragraph \($0) keeps the destination tall.\n\n" }.joined()
        let destination = "# Sibling\n\n" + paragraphs + "## Target\n\nDestination.\n\n" + paragraphs
        try await UIDriver.withDocument(original, files: ["my notes.md": Data(destination.utf8)]) { ui in
            let clip = ui.controller.primaryContainer.scrollView.contentView
            let originY = clip.bounds.minY
            try ui.click(onText: "Open encoded heading")
            ui.check(ui.window.representedURL?.lastPathComponent == "my notes.md" && ui.source == destination,
                     "Click did not open the encoded sibling in the same window")
            let target = (destination as NSString).range(of: "## Target")
            let targetPoint = try ui.point(atSourceOffset: target.location + 3)
            let targetY = clip.bounds.minY
            ui.check(targetY > originY, "Opening the heading did not scroll to the destination")
            try ui.press("[", modifiers: [.command, .control])
            ui.check(ui.source == original && abs(clip.bounds.minY - originY) < 1,
                     "Back did not restore the original file and scroll position")
            try ui.press("]", modifiers: [.command, .control])
            ui.check(ui.source == destination && abs(clip.bounds.minY - targetY) < 1,
                     "Forward did not restore the destination file and scroll position")
            let forwardPoint = try ui.point(atSourceOffset: target.location + 3)
            ui.check(abs(forwardPoint.y - targetPoint.y) < 1, "Forward moved the target heading within the viewport")
        }
    }

    // Observed 2026-11-18: while the main display sleeps, wheel events reach
    // the scroll view but the viewport never moves (identical before and after
    // unrelated merges), and the test passes with the display awake. Skip
    // visibly rather than fail the local gate; hosted runners keep it enabled.
    @Test(.enabled(if: CGDisplayIsAsleep(CGMainDisplayID()) == 0, "Requires an awake main display"))
    func scrollWheelMovesTheRenderedViewport() async throws {
        let source = "# Start\n\n" + (1...60).map { "Line \($0) in the document.\n\n" }.joined()
        try await UIDriver.withDocument(source) { ui in
            let clip = ui.controller.primaryContainer.scrollView.contentView
            let origin = clip.bounds.minY
            try ui.scroll(lines: 10)
            try await ui.input.wait(until: { clip.bounds.minY > origin },
                                    "the scroll wheel to move the document viewport from y=\(origin)",
                                    notification: NSView.boundsDidChangeNotification, object: clip)
            ui.check(ui.source == source && !ui.isDirty, "Scrolling changed the document")
        }
    }

    @Test func formattedCopyCutAndPastePreserveExactBytes() async throws {
        let original = "# Title\n\nBefore **café** after.\n"
        try await UIDriver.withDocument(original) { ui in
            try ui.drag(fromText: "Before", toText: "after")
            let selection = "Before **café** after"
            ui.check(ui.selectedSourceText == selection, "Unexpected selection before copy \(ui.selectedSourceRange)")
            try ui.input.withPrivatePasteboard { pasteboard in
                let editor = ui.window.firstResponder
                try ui.input.sendAction(#selector(NSText.copy(_:)), to: editor)
                ui.check(pasteboard.string(forType: .string) == "Before café after", "Copy lost the visible clipboard flavor")
                ui.check(pasteboard.string(forType: .downrightMarkdown).map { Data($0.utf8) } == Data(selection.utf8),
                         "Copy lost the exact Markdown clipboard flavor")
                try ui.input.sendAction(#selector(NSText.cut(_:)), to: editor)
                ui.check(ui.source == "# Title\n\n.\n" && ui.isDirty, "Cut produced \(ui.source.debugDescription)")
                try ui.input.sendAction(#selector(NSText.paste(_:)), to: editor)
                ui.check(Data(ui.source.utf8) == Data(original.utf8) && !ui.isDirty,
                         "Paste produced \(ui.source.debugDescription), dirty \(ui.isDirty)")
            }
        }
    }

    @Test func typographyPopupRerendersOpenDocument() async throws {
        try await UIDriver.withDocument("# Title\n\nBody text.\n\n`code`\n") { ui in
            let previous = Preferences.shared.values
            let originalPreviewMeasure = PreviewAppearanceStore.measureCharacters
            defer { Preferences.shared.update { $0 = previous } }
            let pane = PreferencesWindowController.controller(for: .typography)
            let popups = controls(of: NSPopUpButton.self, in: pane.view)
            let popup = try #require(popups.first { $0.accessibilityLabel() == "Font family" })
            let oldBody = ui.textView.styleSheet.bodyFont().familyName
            let oldCode = ui.textView.styleSheet.monoFont().familyName
            let replacement = try #require(["Georgia", "Helvetica", "Times New Roman"].first {
                $0 != oldBody && popup.itemTitles.contains($0)
            }, "No alternate installed body font is offered in Typography")
            popup.selectItem(withTitle: replacement)
            let action = try #require(popup.action)
            try #require(popup.sendAction(action, to: popup.target), "Typography popup did not dispatch its action")
            let body = try ui.range(of: "Body text.")
            let rendered = ui.textView.textStorage?.attribute(.font, at: body.location, effectiveRange: nil) as? NSFont
            ui.check(rendered?.familyName == replacement, "Laid-out body font is \(String(reflecting: rendered?.familyName))")
            ui.check(ui.textView.styleSheet.monoFont().familyName == oldCode, "Body font changed the code family")
            let width = try #require(popups.first { $0.accessibilityLabel() == "Line width" })
            let oldMeasure = ui.textView.styleSheet.measureWidth
            let characterCount: CGFloat = previous.typography.measureCharacters == 60 ? 120 : 60
            width.selectItem(withTitle: TypographyConfig.measureTitle(characterCount))
            let widthAction = try #require(width.action)
            try #require(width.sendAction(widthAction, to: width.target))
            ui.check(Preferences.shared.values.typography.measureCharacters == characterCount &&
                         ui.textView.styleSheet.measureWidth != oldMeasure,
                     "The line width popup did not update the open document")
            ui.check(PreviewAppearanceStore.measureCharacters == originalPreviewMeasure,
                     "The test process wrote the user's global Quick Look setting")
            ui.check(ui.source == "# Title\n\nBody text.\n\n`code`\n" && !ui.isDirty,
                     "A typography change edited the document")
        }
    }

    @Test func splitEditorsTakePointerFocusAndKeepSharedSource() async throws {
        let original = "# Title\n\nLeft and right read the same Markdown."
        try await UIDriver.withDocument(original) { ui in
            let split = MainMenu.commandItem(.splitView)
            let action = try #require(split.action)
            try ui.input.sendAction(action, to: ui.controller, from: split)
            let left = try #require(ui.controller.primaryContainer?.textView)
            let right = try #require(ui.controller.splitContainer?.textView)
            ui.layout()
            let location = try ui.range(of: "Markdown").location
            let target = try ui.point(atSourceOffset: location, in: right)
            try ui.input.click(at: target)
            ui.check(ui.window.firstResponder === right, "A click in the second pane left focus in the first")
            try ui.type("!")
            let edited = "# Title\n\nLeft and right read the same !Markdown."
            ui.check(left.textStorage?.string == edited && right.textStorage?.string == edited,
                     "Typing in the second pane did not update both panes")
            try ui.input.sendAction(action, to: ui.controller, from: split)
            ui.check(ui.controller.splitContainer == nil && ui.source == edited,
                     "Closing the second pane did not preserve the edit")
        }
    }

    @Test(arguments: [RenderMode.live, .source])
    func deletingAnAccidentalSpaceMakesTheWindowClean(mode: RenderMode) async throws {
        let source = "# Title\n\nAn unterminated paragraph."
        try await UIDriver.withDocument(source, mode: mode) { ui in
            try ui.click(onText: "unterminated")
            try ui.type(" ")
            ui.check(ui.isDirty && ui.window.isDocumentEdited, "Typing did not mark the document and window edited")
            try ui.press(.delete)
            ui.check(Data(ui.source.utf8) == Data(source.utf8) && !ui.isDirty && !ui.window.isDocumentEdited,
                     "Deleting the space did not clear the edited mark and restore all bytes")
        }
    }

    @Test
    func doubleClickSelectsRenderedEmphasisAfterTheFirstClickRevealsMarkers() async throws {
        try await UIDriver.withDocument("# Title\n\nBefore **café** after.\n") { ui in
            try ui.doubleClick(onText: "café")
            ui.check(ui.selectedSourceRange == NSRange(location: 18, length: 4),
                     "Double-click selected \(ui.selectedSourceRange) instead of the word")
        }
    }

    @Test(arguments: ["`café`", "***café***"])
    func doubleClickSelectsOnlyTheRenderedWordInInlineSyntax(markdown: String) async throws {
        let source = "# Title\n\nBefore \(markdown) after.\n"
        try await UIDriver.withDocument(source) { ui in
            let word = try ui.range(of: "café")
            try ui.doubleClick(onText: "café")
            ui.check(ui.selectedSourceRange == word,
                     "Double-click in \(markdown) selected \(ui.selectedSourceRange), expected \(word)")
        }
    }

    @Test
    func optionDoubleClickSelectsAWordInARenderedLink() async throws {
        let source = "# Title\n\nBefore [café menu](sibling.md) after.\n"
        try await UIDriver.withDocument(source, files: ["sibling.md": Data("# Sibling\n".utf8)]) { ui in
            let word = try ui.range(of: "café")
            try ui.input.click(at: ui.point(onText: "café"), count: 2, modifiers: .option)
            ui.check(ui.selectedSourceRange == word,
                     "Option-double-click in a link selected \(ui.selectedSourceRange), expected \(word)")
            ui.check(ui.window.representedURL == ui.fixture, "Selecting link text followed the link")
        }
    }

    @Test
    func tripleClickSelectsTheRenderedEmphasisParagraph() async throws {
        let paragraph = "Before ***café*** after.\n"
        try await UIDriver.withDocument("# Title\n\n" + paragraph + "\nNext paragraph.\n") { ui in
            let range = try ui.range(of: paragraph)
            try ui.input.click(at: ui.point(onText: "café"), count: 3)
            ui.check(ui.selectedSourceRange == range,
                     "Triple-click selected \(ui.selectedSourceRange), expected \(range)")
        }
    }

    @Test
    func singleClickKeepsTheCaretAtTheRenderedEmphasisHit() async throws {
        try await UIDriver.withDocument("# Title\n\nBefore **café** after.\n") { ui in
            let word = try ui.range(of: "café")
            let opener = NSRange(location: word.location - 2, length: 2)
            let openerIsHidden = { ui.textView.currentDisplayMap.substitutions(in: opener).contains(where: \.isHidden) }
            try #require(openerIsHidden(), "The opening marker must start hidden")
            try ui.click(onText: "café")
            ui.check(ui.selectedSourceRange == NSRange(location: word.location + 1, length: 0),
                     "Single click placed the caret at \(ui.selectedSourceRange)")
            ui.check(!openerIsHidden(), "The opening marker should reveal after one click")
        }
    }

    @Test
    func doubleClickThenDragExtendsTheWordSelection() async throws {
        try await UIDriver.withDocument("# Title\n\nBefore **café** after.\n") { ui in
            try ui.input.doubleClickAndDrag(from: ui.point(onText: "café"), to: ui.point(onText: "after"))
            ui.check(ui.selectedSourceText == "café** after",
                     "Double-click drag selected \(ui.selectedSourceRange) \(String(reflecting: ui.selectedSourceText))")
        }
    }

    @Test
    func cuttingAWholeFormattedWordRoundTripsItsDelimiters() async throws {
        let source = "# Title\n\nBefore **café** after.\n"
        try await UIDriver.withDocument(source) { ui in
            try ui.drag(fromText: "café", toText: "café")
            try #require(ui.selectedSourceText == "café", "Drag must select exactly the visible word")
            try ui.input.withPrivatePasteboard { pasteboard in
                let editor = ui.window.firstResponder
                try ui.input.sendAction(#selector(NSText.cut(_:)), to: editor)
                ui.check(pasteboard.string(forType: .downrightMarkdown) == "**café**",
                         "Cut did not copy the entire formatted word")
                ui.check(ui.source == "# Title\n\nBefore  after.\n", "Cut left \(ui.source.debugDescription)")
                try ui.input.sendAction(#selector(NSText.paste(_:)), to: editor)
                ui.check(Data(ui.source.utf8) == Data(source.utf8) && !ui.isDirty,
                         "Formatted cut/paste returned \(ui.source.debugDescription), dirty \(ui.isDirty)")
            }
        }
    }

    @Test
    func renderedMathImmediatelyAfterHeadingAllowsExactSourceSelection() async throws {
        let source = "# Title\n$$f(x)$$\n\nAfter\n"
        try await UIDriver.withDocument(source) { ui in
            let formula = try ui.range(of: "$$f(x)$$")
            let latex = try ui.range(of: "f(x)")
            let fragment = try #require(try layoutFragment(at: formula.location, in: ui.textView) as? MathFragment)
            let frame = fragment.layoutFragmentFrame
            let origin = ui.textView.textContainerOrigin
            let center = NSPoint(x: origin.x + frame.minX + fragment.contentWidth / 2, y: origin.y + frame.midY)
            try ui.input.click(at: ui.textView.convert(center, to: nil))
            ui.check(ui.selectedSourceRange == NSRange(location: latex.location, length: 0),
                     "Clicking typeset math put the caret at \(ui.selectedSourceRange) instead of the LaTeX start")
            try ui.drag(fromText: "f(", toText: "x)")
            ui.check(ui.selectedSourceText == "f(x)", "LaTeX drag selected \(ui.selectedSourceRange)")
        }
    }

    @Test(arguments: [2, 3])
    func multiClickCenteredDisplayMathSelectsRevealedLatex(clickCount: Int) async throws {
        let source = "# Title\n$$f(x)$$\n\nAfter\n"
        try await UIDriver.withDocument(source) { ui in
            let formula = try ui.range(of: "$$f(x)$$")
            let latex = try ui.range(of: "f(x)")
            let fragment = try #require(try layoutFragment(at: formula.location, in: ui.textView) as? MathFragment)
            let frame = fragment.layoutFragmentFrame
            let origin = ui.textView.textContainerOrigin
            let center = NSPoint(x: origin.x + frame.minX + fragment.contentWidth / 2, y: origin.y + frame.midY)

            try ui.input.click(at: ui.textView.convert(center, to: nil), count: clickCount)

            ui.check(ui.selectedSourceRange == latex,
                     "\(clickCount) clicks selected \(ui.selectedSourceRange) instead of \(latex)")
            let revealed = try layoutFragment(at: latex.location, in: ui.textView)
            ui.check(!(revealed is MathFragment), "Selecting the formula should keep its LaTeX visible")
            ui.check(ui.source == source && !ui.isDirty, "Selecting the formula changed its source")
        }
    }

    private func layoutFragment(at sourceOffset: Int, in textView: MarkdownTextView) throws -> NSTextLayoutFragment {
        let layout = try #require(textView.textLayoutManager)
        let storage = try #require(layout.textContentManager)
        let offset = textView.currentDisplayMap.textKitOffset(forSource: sourceOffset)
        let location = try #require(storage.location(storage.documentRange.location, offsetBy: offset))
        layout.ensureLayout(for: NSTextRange(location: location))
        return try #require(layout.textLayoutFragment(for: location))
    }

    private func controls<T: NSView>(of type: T.Type, in view: NSView) -> [T] {
        (view as? T).map { [$0] } ?? view.subviews.flatMap { controls(of: type, in: $0) }
    }
}
