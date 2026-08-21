import AppKit
import Testing
import MarkdownCore
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct EditingKeyReproTests {
    @discardableResult
    private func pumpMainRunLoop(
        until condition: () -> Bool,
        timeout: TimeInterval = 1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .common, before: min(
                deadline, Date().addingTimeInterval(0.01)))
        }
        return condition()
    }

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

    private func pressCommandA(into textView: NSTextView) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: textView.window?.windowNumber ?? 0,
            context: nil,
            characters: "a",
            charactersIgnoringModifiers: "a",
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

    private func pressOptionDelete(into textView: NSTextView) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.option],
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

    @Test("opening a document does not select all text")
    func openingDocumentStartsWithCaretOnly() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproInitialSelection-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "# Title\n\nBody text.\n"
        let controller = try makeController(text: source, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.primaryContainer.textView)

        #expect(pumpMainRunLoop {
            controller.primaryContainer.textView.selectedRange().length == 0
        })
        #expect(controller.primaryContainer.textView.selectedRange().length == 0)
        #expect(controller.primaryContainer.textView.sourceSelectedRange.length == 0)
    }

    @Test("opening a second document clears the previous document selection")
    func openingSecondDocumentClearsPreviousSelection() throws {
        let firstURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproPreviousSelection-\(UUID().uuidString).md")
        let secondURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproNextSelection-\(UUID().uuidString).md")
        defer {
            try? FileManager.default.removeItem(at: firstURL)
            try? FileManager.default.removeItem(at: secondURL)
        }
        let controller = try makeController(text: "# First\n\nold body\n", file: firstURL)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        pressCommandA(into: view)
        #expect(view.selectedRange().length > 0)

        try "# Second\n\nnew body\n".write(to: secondURL, atomically: true, encoding: .utf8)
        try controller.open(secondURL, mode: .live)

        // The open path clears AppKit's stale native selection synchronously,
        // then restores the new document's saved position on the next frame.
        // Include the persisted state so this cannot pass before that restore.
        #expect(pumpMainRunLoop {
            view.selectedRange().length == 0
                && controller.markdownDocument.state.selectionLength == 0
        })
        #expect(view.selectedRange().length == 0)
        #expect(view.sourceSelectedRange.length == 0)
    }

    @Test("a stale persisted Select All becomes a caret on reopen")
    func staleFullDocumentSelectionIsMigrated() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproStaleSelection-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "# Existing selection\n\nBody text.\n"
        try source.write(to: url, atomically: true, encoding: .utf8)

        var state = DocumentStateStore.shared.state(for: url)
        state.selectionLocation = 0
        state.selectionLength = (source as NSString).length
        DocumentStateStore.shared.save(state, for: url)

        let controller = DocumentWindowController()
        try controller.open(url, mode: .live)
        defer { controller.close() }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.makeFirstResponder(controller.primaryContainer.textView)

        #expect(pumpMainRunLoop {
            controller.primaryContainer.textView.selectedRange().length == 0
                && controller.markdownDocument.state.selectionLength == 0
        })
        #expect(controller.primaryContainer.textView.sourceSelectedRange.length == 0)
    }

    private func pressTab(into textView: NSTextView) {
        let event = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: textView.window?.windowNumber ?? 0,
            context: nil,
            characters: "\t",
            charactersIgnoringModifiers: "\t",
            isARepeat: false,
            keyCode: 48
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
        #expect(pumpMainRunLoop {
            controller.primaryContainer.textView.rect(forOffset: body.location) != nil
        })

        let before = controller.markdownDocument.text
        type("x", into: controller.primaryContainer.textView)
        type("y", into: controller.primaryContainer.textView)
        #expect(pumpMainRunLoop { controller.markdownDocument.text.contains("xyBody text.") })

        #expect(controller.primaryContainer.textView.isEditable)
        #expect(controller.markdownDocument.text != before)
        #expect(controller.markdownDocument.text.contains("xyBody text."))
    }

    @Test("native undo and redo round-trip a rendered edit")
    func nativeUndoRedoRoundTripTyping() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproUndoRedo-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "# Title\n\nBody text.\n"
        let controller = try makeController(text: source, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        let body = (source as NSString).range(of: "Body text.")
        view.setSourceSelectedRanges([NSRange(location: body.location, length: 0)])
        #expect(pumpMainRunLoop { view.rect(forOffset: body.location) != nil })

        type("x", into: view)
        #expect(pumpMainRunLoop { controller.markdownDocument.text.contains("xBody text.") })
        #expect(controller.markdownDocument.undoManager.canUndo)

        controller.markdownDocument.undoManager.undo()
        #expect(pumpMainRunLoop { controller.markdownDocument.text == source })
        #expect(controller.markdownDocument.text == source)
        #expect(controller.markdownDocument.undoManager.canRedo)

        controller.markdownDocument.undoManager.redo()
        #expect(pumpMainRunLoop { controller.markdownDocument.text.contains("xBody text.") })
        #expect(controller.markdownDocument.text.contains("xBody text."))
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
        #expect(pumpMainRunLoop { controller.primaryContainer.textView.rect(forOffset: 0) != nil })

        type("x", into: controller.primaryContainer.textView)
        type("y", into: controller.primaryContainer.textView)
        #expect(pumpMainRunLoop { controller.markdownDocument.text.hasPrefix("# xyTitle") })

        // Hidden `# ` stays put; typing lands in the visible title.
        #expect(controller.markdownDocument.text.hasPrefix("# xyTitle"))
    }

    @Test("Select All includes hidden Markdown before a replacement")
    func selectAllReplacesTheWholeSourceDocument() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproSelectAll-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "## Existing heading\n\nBody.\n"
        let controller = try makeController(text: source, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        pressCommandA(into: view)

        #expect(view.sourceSelectedRange == NSRange(
            location: 0, length: (source as NSString).length
        ))

        for character in "## xyzxyz" { type(character, into: view) }
        #expect(pumpMainRunLoop { controller.markdownDocument.text == "## xyzxyz" })

        #expect(controller.markdownDocument.text == "## xyzxyz")
        #expect(view.sourceSelectedRange == NSRange(location: 9, length: 0))
    }

    @Test("Select All stays source-wide when the live projection is fully elided")
    func selectAllSurvivesFullyElidedProjection() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproElidedSelectAll-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let source = "A body with no heading is hidden at top-level zoom.\n"
        let controller = try makeController(text: source, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        // A zero-length caret is intentionally a visibility probe for
        // structural zoom. Use a non-empty selection here so the projection
        // can remain fully elided while this test exercises Select All.
        view.setSourceSelectedRanges([NSRange(location: 0, length: 1)])
        view.zoomLevel = .h1
        #expect(view.textStorage?.attribute(.drElided, at: 0, effectiveRange: nil) != nil)

        pressCommandA(into: view)
        #expect(view.sourceSelectedRange == NSRange(
            location: 0, length: (source as NSString).length
        ))

        type("x", into: view)
        #expect(pumpMainRunLoop { controller.markdownDocument.text == "x" })
        #expect(controller.markdownDocument.text == "x")
    }

    @Test("Real key events keep the caret line fixed through the async parse")
    func typingKeepsCaretLineFixed() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproCamera-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = (0..<50).map {
            "## Section \($0)\n\nParagraph \($0) stays on screen while the user types."
        }.joined(separator: "\n\n")
        let controller = try makeController(text: text, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.setContentSize(NSSize(width: 900, height: 640))
        controller.window?.layoutIfNeeded()
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        let target = (text as NSString).range(of: "Paragraph 25")
        var caret = target.upperBound
        view.setSourceSelectedRanges([NSRange(location: caret, length: 0)])
        view.resizeToFitContent()
        view.scroll(toOffset: target.location, position: .center, animated: false)
        let clip = controller.primaryContainer.scrollView.contentView
        let screenY = try #require(view.rect(forOffset: caret)).minY - clip.bounds.origin.y

        for character in "abc" {
            type(character, into: view)
            caret += 1
            let currentY = try #require(view.rect(forOffset: caret)).minY - clip.bounds.origin.y
            #expect(abs(currentY - screenY) < 1, "the key event moved the caret line")
        }
        #expect(pumpMainRunLoop { controller.markdownDocument.text.contains("abc") })
        controller.window?.layoutIfNeeded()
        let settledY = try #require(view.rect(forOffset: caret)).minY - clip.bounds.origin.y
        #expect(abs(settledY - screenY) < 1, "the parse commit moved the caret line")
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
        #expect(pumpMainRunLoop {
            controller.primaryContainer.textView.rect(forOffset: end) != nil
        })

        let before = controller.markdownDocument.text
        pressDelete(into: controller.primaryContainer.textView)
        #expect(pumpMainRunLoop { controller.markdownDocument.text == "# Title\n\nBody text." })

        #expect(controller.primaryContainer.textView.isEditable)
        #expect(controller.markdownDocument.text != before)
        #expect(controller.markdownDocument.text == "# Title\n\nBody text.")
    }

    @Test("Option-Delete deletes the previous source word")
    func deleteWordThroughRealKeyDownMutatesDocument() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproWordDel-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "alpha beta gamma\n"
        let controller = try makeController(text: text, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        let gamma = (text as NSString).range(of: "gamma")
        view.setSourceSelectedRanges([NSRange(location: gamma.upperBound, length: 0)])
        #expect(pumpMainRunLoop { view.rect(forOffset: gamma.upperBound) != nil })

        pressOptionDelete(into: view)
        #expect(pumpMainRunLoop { controller.markdownDocument.text == "alpha beta \n" })

        #expect(controller.markdownDocument.text == "alpha beta \n")
        #expect(view.sourceSelectedRange == NSRange(location: gamma.location, length: 0))
    }

    @Test("native word movement stays in source coordinates")
    func nativeWordMovementPreservesSourceCaret() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproWordMove-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = "alpha beta gamma\n"
        let controller = try makeController(text: text, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        let gamma = (text as NSString).range(of: "gamma")
        view.setSourceSelectedRanges([NSRange(location: gamma.upperBound, length: 0)])
        #expect(pumpMainRunLoop { view.rect(forOffset: gamma.upperBound) != nil })

        view.moveWordBackward(nil)

        #expect(view.sourceSelectedRange == NSRange(location: gamma.location, length: 0))
    }

    @Test("split panes keep their own caret and viewport")
    func splitPanesKeepInteractionStateIndependent() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproSplit-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let text = (0..<45).map {
            "## Section \($0)\n\nParagraph \($0) keeps the two editing surfaces readable."
        }.joined(separator: "\n\n")
        let controller = try makeController(text: text, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.setContentSize(NSSize(width: 1000, height: 640))
        controller.toggleSplitView()
        controller.window?.layoutIfNeeded()
        let primary = controller.primaryContainer.textView
        let split = try #require(controller.splitContainer?.textView)
        primary.resizeToFitContent()
        split.resizeToFitContent()

        let firstTarget = (text as NSString).range(of: "Section 10")
        let secondTarget = (text as NSString).range(of: "Section 35")
        primary.scroll(toOffset: firstTarget.location, position: .top, animated: false)
        split.scroll(toOffset: secondTarget.location, position: .top, animated: false)
        let primaryViewport = primary.enclosingScrollView?.contentView.bounds.origin.y ?? 0
        let splitSelection = NSRange(location: secondTarget.location + 3, length: 0)
        split.setSourceSelectedRanges([splitSelection])

        controller.markdownTextViewDidChangeSelection(split)
        controller.markdownTextViewDidScroll(split)

        #expect(split.sourceSelectedRange == splitSelection)
        #expect(primary.sourceSelectedRange != splitSelection)
        #expect(abs((primary.enclosingScrollView?.contentView.bounds.origin.y ?? 0) - primaryViewport) < 1)

        controller.window?.makeFirstResponder(split)
        let splitViewport = split.enclosingScrollView?.contentView.bounds.origin.y ?? 0
        controller.toggleSplitView()

        #expect(controller.splitContainer == nil)
        #expect(controller.window?.firstResponder === primary)
        #expect(primary.sourceSelectedRange == splitSelection)
        #expect(abs((primary.enclosingScrollView?.contentView.bounds.origin.y ?? 0) - splitViewport) < 1)
    }

    @Test("Tab after live edits cannot stack fragments or move the camera")
    func tabAfterLiveEditsKeepsLayoutAndViewportStable() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproTab-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let sections = (0..<30).map {
            "## Section \($0)\n\nParagraph \($0) stays readable with **emphasis** and `code`."
        }.joined(separator: "\n\n")
        let text = "---\ntitle: Layout fixture\nauthor: Downright\n---\n\n# Title\n\nFirst sentence.\n\n\(sections)\n"
        let controller = try makeController(text: text, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.setContentSize(NSSize(width: 900, height: 640))
        controller.window?.layoutIfNeeded()
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        let target = (text as NSString).range(of: "Paragraph 15 stays readable")
        view.setSourceSelectedRanges([NSRange(location: target.upperBound, length: 0)])
        view.resizeToFitContent()
        let clip = controller.primaryContainer.scrollView.contentView
        view.scroll(toOffset: target.location, position: .center, animated: false)
        let expectedY = clip.bounds.origin.y
        #expect(expectedY > 100)

        type("x", into: view)
        pressDelete(into: view)
        view.insertNewline(nil)
        type("t", into: view)
        type("a", into: view)
        type("i", into: view)
        type("l", into: view)
        pressTab(into: view)
        #expect(pumpMainRunLoop { controller.markdownDocument.text.contains("\ntail\t") })
        controller.window?.layoutIfNeeded()
        view.resizeToFitContent()

        #expect(abs(clip.bounds.origin.y - expectedY) < 2)
        #expect(controller.markdownDocument.text.contains("\ntail\t"))
        let layout = try #require(view.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        var frames: [NSRect] = []
        layout.enumerateTextLayoutFragments(
            from: layout.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            frames.append(fragment.layoutFragmentFrame)
            return true
        }
        for pair in zip(frames, frames.dropFirst()) {
            #expect(
                pair.1.minY + 0.5 >= pair.0.maxY,
                "layout fragments overlap: \(pair.0) then \(pair.1)"
            )
        }
    }

    @Test("Outline jumps materialize only the destination viewport")
    func outlineJumpDoesNotRetainFragmentsFromTheOldCamera() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproOutline-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let rows = (0..<16).map { "| Row \($0) | Value \($0) |" }.joined(separator: "\n")
        let padding = (0..<35).map {
            "## Section \($0)\n\nParagraph \($0) keeps enough content between navigation targets."
        }.joined(separator: "\n\n")
        let text = "# Title\n\n\(padding)\n\n## Tables\n\n| Name | Value |\n| --- | --- |\n\(rows)\n\n## End\n\nDone.\n"
        let controller = try makeController(text: text, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.setContentSize(NSSize(width: 900, height: 640))
        controller.window?.layoutIfNeeded()
        let view = controller.primaryContainer.textView
        view.resizeToFitContent()
        let tables = (text as NSString).range(of: "## Tables").location
        view.scroll(toOffset: tables, position: .top, animated: false)

        let clip = controller.primaryContainer.scrollView.contentView
        let visible = clip.documentVisibleRect
        let layout = try #require(view.textLayoutManager)
        var visibleFrames: [NSRect] = []
        layout.enumerateTextLayoutFragments(
            from: layout.documentRange.location,
            options: [.ensuresLayout]
        ) { fragment in
            if fragment.layoutFragmentFrame.intersects(visible) {
                visibleFrames.append(fragment.layoutFragmentFrame)
            }
            return true
        }
        #expect(!visibleFrames.isEmpty)
        for pair in zip(visibleFrames, visibleFrames.dropFirst()) {
            #expect(
                pair.1.minY + 0.5 >= pair.0.maxY,
                "destination fragments overlap: \(pair.0) then \(pair.1)"
            )
        }
        #expect(view.topVisibleOffset >= tables - 4)
    }

    @Test("Heading commands preserve the caret camera")
    func headingCommandKeepsViewportStable() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproHeading-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let sections = (0..<35).map {
            "## Section \($0)\n\nParagraph \($0) keeps the page tall.\n\n### Detail \($0)\n\nBody."
        }.joined(separator: "\n\n")
        let text = "# Title\n\n\(sections)\n"
        let controller = try makeController(text: text, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.setContentSize(NSSize(width: 900, height: 640))
        controller.window?.layoutIfNeeded()
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        let target = (text as NSString).range(of: "### Detail 20")
        view.setSourceSelectedRanges([NSRange(location: target.location + 5, length: 0)])
        view.resizeToFitContent()
        view.scroll(toOffset: target.location, position: .center, animated: false)
        let clip = controller.primaryContainer.scrollView.contentView
        let expectedScreenY = try #require(view.rect(forOffset: target.location)).minY
            - clip.bounds.origin.y

        #expect(controller.perform(.promoteHeading))
        #expect(pumpMainRunLoop { controller.markdownDocument.text.contains("## Detail 20") })
        controller.window?.layoutIfNeeded()

        let actualScreenY = try #require(view.rect(forOffset: target.location)).minY
            - clip.bounds.origin.y
        #expect(abs(actualScreenY - expectedScreenY) < 2)
        #expect(controller.markdownDocument.text.contains("## Detail 20"))
    }

    @Test("Rendered heading picker commits in place before the next frame")
    func headingPickerKeepsClickedHeadingFixed() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproHeadingPicker-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let sections = (0..<35).map {
            "## Section \($0)\n\nParagraph \($0) keeps the page tall."
        }.joined(separator: "\n\n")
        let text = "# Title\n\n\(sections)\n"
        let controller = try makeController(text: text, file: url)
        defer { controller.close() }

        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        controller.window?.setContentSize(NSSize(width: 900, height: 640))
        controller.window?.layoutIfNeeded()
        let view = controller.primaryContainer.textView
        view.resizeToFitContent()
        let headingIndex = try #require(
            controller.markdownDocument.parsed.headings.firstIndex { $0.title == "Section 20" }
        )
        let offset = controller.markdownDocument.parsed.headings[headingIndex].range.location
        view.scroll(toOffset: offset, position: .center, animated: false)
        let clip = controller.primaryContainer.scrollView.contentView
        let before = try #require(view.rect(forOffset: offset)).minY - clip.bounds.origin.y

        controller.markdownTextView(view, didRequestHeadingLevel: 3, headingIndex: headingIndex)
        controller.window?.layoutIfNeeded()

        #expect(controller.markdownDocument.parsed.headings[headingIndex].level == 3)
        let after = try #require(view.rect(forOffset: offset)).minY - clip.bounds.origin.y
        #expect(abs(after - before) < 2, "the picker moved its clicked heading")
    }

    @Test("IME marked text owns a valid undo group")
    func markedTextUsesValidUndoGrouping() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("EditingKeyReproIME-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let controller = try makeController(text: "# 入力\n\nBody\n", file: url)
        defer { controller.close() }
        let view = controller.primaryContainer.textView
        controller.window?.makeFirstResponder(view)
        view.setSourceSelectedRanges([NSRange(location: 7, length: 0)])

        // NSTextView raises an Objective-C exception when its private marked-
        // text undo registration runs without a group. Reaching the assertions
        // is therefore the regression proof for the crash boundary.
        view.setMarkedText(
            "かな",
            selectedRange: NSRange(location: 2, length: 0),
            replacementRange: view.sourceSelectedRange
        )
        #expect(view.hasMarkedText())
        #expect(controller.markdownDocument.text.contains("かな"))
        view.unmarkText()
        #expect(!view.hasMarkedText())
    }
}
