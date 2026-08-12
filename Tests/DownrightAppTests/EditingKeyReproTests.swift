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
        pressTab(into: view)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        controller.window?.layoutIfNeeded()
        view.resizeToFitContent()

        #expect(abs(clip.bounds.origin.y - expectedY) < 2)
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
        let expectedY = clip.bounds.origin.y

        #expect(controller.perform(.promoteHeading))
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.35))
        controller.window?.layoutIfNeeded()

        #expect(abs(clip.bounds.origin.y - expectedY) < 2)
        #expect(controller.markdownDocument.text.contains("## Detail 20"))
    }
}
