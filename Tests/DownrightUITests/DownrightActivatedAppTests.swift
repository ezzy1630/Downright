import AppKit
import XCTest
import ImageIO
import UniformTypeIdentifiers

/// Acceptance coverage for the surface that SwiftPM's AppKit test runner
/// cannot provide: an actual Downright.app with a running display cycle.
final class DownrightActivatedAppTests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!
    private var fixture: URL!
    private var isProductionUpdaterSmoke = false

    override func setUpWithError() throws {
        continueAfterFailure = false

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-activated-app-\(UUID().uuidString)", isDirectory: true)
        let support = root.appendingPathComponent("support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // Keep first-run registration UI out of this acceptance case. The app
        // still launches normally; only its state is isolated to this fixture.
        let preferences = #"{"hasAnsweredSetup":true,"restoreSession":false,"defaultMode":"live"}"#
        try Data(preferences.utf8).write(
            to: support.appendingPathComponent("preferences.json"),
            options: .atomic
        )

        fixture = root.appendingPathComponent("activated-fixture.md")
        let body = (1...80).map { "Paragraph \($0) keeps the live viewport exercised." }.joined(separator: "\n\n")
        try Data(("# Activated app fixture\n\n## First section\n\n" + body + "\n\n## Later section\n\nThe end.\n").utf8)
            .write(to: fixture, options: .atomic)

        // Resolve the host from the test bundle instead of Launch Services. A
        // developer may have another Downright.app open; URL-based UI testing
        // must still exercise this exact build product.
        let testBundle = Bundle(for: DownrightActivatedAppTests.self).bundleURL
        let runner = testBundle
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let productDirectory = runner.deletingLastPathComponent()
        let siblingHost = productDirectory.appendingPathComponent("Downright.app", isDirectory: true)
        let host = FileManager.default.fileExists(atPath: siblingHost.path)
            ? siblingHost
            : runner
        XCTAssertTrue(FileManager.default.fileExists(atPath: host.path), "test host is missing: \(host.path)")
        let hostInfo = Bundle(url: host)?.infoDictionary ?? [:]
        isProductionUpdaterSmoke = hostInfo["CFBundleIdentifier"] as? String == "com.ezzy.downright"
            && hostInfo["SUFeedURL"] as? String != nil
        app = XCUIApplication(url: host)
        // A prior menu-bar session can leave AppKit with no restorable window.
        // Ignore that user-state input so this test always exercises the exact
        // fixture launch and does not depend on whichever Downright ran before it.
        app.launchArguments = [fixture.path, "-ApplePersistenceIgnoreState", "YES"]
        if isProductionUpdaterSmoke {
            // The release smoke intentionally drives the manual menu check;
            // automatic checks must not race that interaction on a fresh CI
            // machine and make the result nondeterministic.
            app.launchArguments += [
                "-SUEnableAutomaticChecks", "NO",
                "-SUAutomaticallyUpdate", "NO",
            ]
        }
        app.launchEnvironment["DOWNRIGHT_SUPPORT_DIRECTORY"] = support.path
        app.launchEnvironment["DOWNRIGHT_DEBUG_LAYOUT"] = "1"
    }

    override func tearDown() {
        app?.terminate()
        if let root {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func testInlineImagesAndAnimationControlsKeepSourceExact() throws {
        let badge = NSImage(size: NSSize(width: 120, height: 24), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let bitmap = try XCTUnwrap(badge.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let png = try XCTUnwrap(NSBitmapImageRep(cgImage: bitmap).representation(using: .png, properties: [:]))
        try png.write(to: root.appendingPathComponent("badge.png"))
        let gif = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(gif, UTType.gif.identifier as CFString, 2, nil))
        // Pause must remain observable while XCTest snapshots the control;
        // ImageIO otherwise writes this short fixture as a one-shot animation.
        CGImageDestinationSetProperties(destination, [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]
        ] as CFDictionary)
        for _ in 0..<2 {
            CGImageDestinationAddImage(destination, bitmap, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (gif as Data).write(to: root.appendingPathComponent("demo.gif"))
        let source = """
        # Image reading

        Before ![Inline badge](badge.png) after.

        <p>
        <img src="badge.png" width="90" height="18" alt="First badge">
        <img src="badge.png" width="90" height="18" alt="Second badge">
        </p>

        ![Animated demo](demo.gif)
        """
        let original = Data(source.utf8)
        try original.write(to: fixture)
        app.launch()
        app.activate()
        let play = app.buttons["Play image"].firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 20))
        play.click()
        let pause = app.buttons["Pause image"].firstMatch
        XCTAssertTrue(pause.waitForExistence(timeout: 5))
        pause.click()
        XCTAssertTrue(play.waitForExistence(timeout: 5))
        XCTAssertEqual(try Data(contentsOf: fixture), original)
        app.terminate()
        app.launch()
        app.activate()
        XCTAssertTrue(play.waitForExistence(timeout: 15))
        XCTAssertEqual(try Data(contentsOf: fixture), original)
        let capture = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        capture.name = "Inline images and paused animation"
        capture.lifetime = .keepAlways
        add(capture)
    }

    func testUnterminatedParagraphRendersWithoutChangingSource() throws {
        let text = "An unterminated Markdown paragraph remains visible and keeps every source byte. A native text surface must render this document without needing a final newline or another paragraph to initialize its viewport."
        let original = Data(text.utf8)
        try original.write(to: fixture)
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.textViews["Document editor"].waitForExistence(timeout: 15))
        assertVisibleProse(in: window.scrollViews.firstMatch, window: window)
        XCTAssertEqual(try Data(contentsOf: fixture), original)
    }

    func testPointerLinkOpensInPlaceAndBackReturns() throws {
        let target = root.appendingPathComponent("sibling.md")
        try Data("# Sibling\n\nDestination text.\n".utf8).write(to: target)
        try Data("[Open sibling document](sibling.md)\n".utf8).write(to: fixture)
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let window = app.windows.firstMatch
        let editor = window.textViews["Document editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        add(XCTAttachment(screenshot: window.screenshot()))
        // The fixture is one body-text line. Aim inside its first word after
        // the 44pt reveal slack and 36pt top inset, using native pointer input.
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 60, dy: 49)).click()
        // macOS windows expose their caption as title, independently of label.
        // Resolve that title afresh after each document changes the caption.
        let opened = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", "sibling.md")).firstMatch
        XCTAssertTrue(opened.waitForExistence(timeout: 10),
                      "A real link click must open the sibling in this window without a system error: \(app.windows.debugDescription)")
        XCTAssertEqual(app.windows.count, 1)
        app.typeKey("[", modifierFlags: [.command, .control])
        let returned = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", fixture.lastPathComponent)).firstMatch
        XCTAssertTrue(returned.waitForExistence(timeout: 10), app.windows.debugDescription)
        add(XCTAttachment(screenshot: returned.screenshot()))
    }

    func testEncodedHeadingLinkSupportsDeepBackAndForward() throws {
        let target = root.appendingPathComponent("my notes.md")
        let paragraphs = (1...100).map { "Paragraph \($0) keeps the destination tall." }.joined(separator: "\n\n")
        try Data(("# Sibling\n\n" + paragraphs + "\n\n## Target\n\nDestination.\n\n" + paragraphs).utf8).write(to: target)
        // Keep the original scrollable too, so both returns expose a native
        // scroll position rather than relying on a missing/hidden scroller.
        let originalBody = (1...40).map { "Original paragraph \($0)." }.joined(separator: "\n\n")
        try Data(("[Open encoded heading](my%20notes.md#target)\n\n" + originalBody).utf8).write(to: fixture)
        app.launch()
        app.activate()
        let initialWindow = app.windows.firstMatch
        let editor = initialWindow.textViews["Document editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 15))
        let originalPosition = try waitForScrollPosition(in: initialWindow) { $0 < 0.01 }
        editor.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: 60, dy: 49)).click()
        let destination = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", target.lastPathComponent)).firstMatch
        XCTAssertTrue(destination.waitForExistence(timeout: 10), app.windows.debugDescription)
        // TextKit estimates the unvisited document height, so normalized
        // scrollbar percentages cannot identify a source heading reliably.
        // Check the actual heading near the top of the rendered viewport.
        assertVisibleHeading("Target", in: destination.scrollViews.firstMatch)
        let targetPosition = try waitForScrollPosition(in: destination) { $0 > 0.01 }
        assertVisibleProse(in: destination.scrollViews.firstMatch, window: destination)
        let destinationCapture = XCTAttachment(screenshot: destination.screenshot())
        destinationCapture.lifetime = .keepAlways
        add(destinationCapture)
        app.typeKey("[", modifierFlags: [.command, .control])
        let original = app.windows.matching(NSPredicate(format: "title BEGINSWITH %@", fixture.lastPathComponent)).firstMatch
        XCTAssertTrue(original.waitForExistence(timeout: 10), app.windows.debugDescription)
        _ = try waitForScrollPosition(in: original) { abs($0 - originalPosition) < 0.01 }
        app.typeKey("]", modifierFlags: [.command, .control])
        XCTAssertTrue(destination.waitForExistence(timeout: 10), app.windows.debugDescription)
        _ = try waitForScrollPosition(in: destination) { abs($0 - targetPosition) < 0.01 }
        assertVisibleHeading("Target", in: destination.scrollViews.firstMatch)
        app.typeKey("[", modifierFlags: [.command, .control])
        XCTAssertTrue(original.waitForExistence(timeout: 10), app.windows.debugDescription)
        _ = try waitForScrollPosition(in: original) { abs($0 - originalPosition) < 0.01 }
        XCTAssertEqual(app.windows.count, 1)
    }

    func testDeletingAccidentalSpaceClosesWithoutSavePrompt() throws {
        try assertAccidentalSpaceClosesCleanly(inSourceMode: false)
    }

    func testDeletingAccidentalSpaceInSourceClosesWithoutSavePrompt() throws {
        try assertAccidentalSpaceClosesCleanly(inSourceMode: true)
    }

    private func assertAccidentalSpaceClosesCleanly(inSourceMode: Bool) throws {
        try Data("[Sibling document](sibling.md)\n".utf8).write(to: fixture)
        let original = try Data(contentsOf: fixture)
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let mode = app.radioButtons[inSourceMode ? "Source" : "Document"]
        XCTAssertTrue(mode.waitForExistence(timeout: 15))
        mode.click()
        let editor = app.windows.firstMatch.textViews[inSourceMode ? "Markdown source editor" : "Document editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey(.home, modifierFlags: .command)
        editor.typeText(" ")
        editor.typeKey(.delete, modifierFlags: [])
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows["Downright"].waitForExistence(timeout: 10),
                      "Returning to the saved text must close without a Save/Discard prompt")
        XCTAssertEqual(try Data(contentsOf: fixture), original)
    }

    func testLastDocumentClosePreferences() throws {
        for behavior in ["showStartWindow", "doNothing", "quit"] {
            let preferences = "{\"hasAnsweredSetup\":true,\"restoreSession\":false,\"lastDocumentCloseBehavior\":\"\(behavior)\"}"
            try Data(preferences.utf8).write(to: root.appendingPathComponent("support/preferences.json"))
            app.launch()
            app.activate()
            XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 15))
            app.typeKey("w", modifierFlags: .command)
            switch behavior {
            case "showStartWindow":
                XCTAssertTrue(app.windows["Downright"].waitForExistence(timeout: 10))
            case "doNothing":
                let closed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "count == 0"), object: app.windows)
                XCTAssertEqual(XCTWaiter.wait(for: [closed], timeout: 10), .completed)
                XCTAssertNotEqual(app.state, .notRunning)
            default:
                XCTAssertTrue(app.wait(for: .notRunning, timeout: 10))
            }
            app.terminate()
        }
    }

    func testActivatedBundleRendersAndKeepsSourceEditingLive() throws {
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        add(XCTAttachment(screenshot: window.screenshot()))

        let rendered = app.radioButtons["Document"]
        let source = app.radioButtons["Source"]
        XCTAssertTrue(rendered.waitForExistence(timeout: 10), "the real toolbar never exposed Document mode")
        XCTAssertTrue(source.waitForExistence(timeout: 10), "the real toolbar never exposed Source mode")

        assertVisibleProse(in: window.scrollViews.firstMatch, window: window)

        source.click()
        let editor = app.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "Source mode did not expose an editable text view")
        editor.click()
        editor.typeText("!")
        editor.typeKey("z", modifierFlags: .command)
        rendered.click()

        XCTAssertTrue(rendered.isSelected || rendered.value as? String == "Selected")
        add(XCTAttachment(screenshot: window.screenshot()))
    }

    func testHTMLExportThroughSavePanelPreservesEditedMarkdown() throws {
        let original = try Data(contentsOf: fixture)
        let edited = "# Export acceptance current buffer\n\n[Next section](sibling.md#details)\n"
        let destination = root.appendingPathComponent("activated-fixture.html")

        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))
        let source = app.radioButtons["Source"]
        XCTAssertTrue(source.waitForExistence(timeout: 10))
        source.click()
        let editor = window.textViews.firstMatch
        XCTAssertTrue(editor.waitForExistence(timeout: 10))
        editor.click()
        editor.typeKey("a", modifierFlags: .command)
        editor.typeText(edited)
        XCTAssertEqual(editor.value as? String, edited)

        // Exercise the actual command and NSSavePanel, including its enabled
        // Save action. A disabled panel must fail this test rather than being
        // bypassed through the exporter or a direct write.
        app.typeKey("e", modifierFlags: [.command, .control])
        let savePanel = app.dialogs["save-panel"]
        let save = savePanel.buttons["OKButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Export HTML did not open a save panel")
        app.typeKey("g", modifierFlags: [.command, .shift])
        app.typeText(root.path)
        app.typeKey(.return, modifierFlags: [])
        let saveEnabled = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == true AND enabled == true AND hittable == true"),
            object: save
        )
        XCTAssertEqual(XCTWaiter.wait(for: [saveEnabled], timeout: 10), .completed,
                       "Save never became enabled after choosing the export folder")
        save.click()
        XCTAssertTrue(waitForFile(destination, timeout: 15), "the save panel did not create the HTML export")
        let html = try String(contentsOf: destination, encoding: .utf8)
        XCTAssertTrue(html.contains(">Export acceptance current buffer</h1>"))
        XCTAssertTrue(html.contains("href=\"sibling.html#details\""))
        XCTAssertEqual(editor.value as? String, edited, "export changed the source buffer")

        // Occlusion autosave may legitimately persist the edit while the panel
        // is open. Both generations remain Markdown; export must never write
        // HTML or its rewritten sibling link back to the source document.
        let sourceBytes = try Data(contentsOf: fixture)
        XCTAssertTrue(sourceBytes == original || sourceBytes == Data(edited.utf8),
                      "export rewrote the source file beyond the user's edit")
        add(XCTAttachment(screenshot: window.screenshot()))
    }

    func testSplitViewCreatesTwoInteractiveDocumentPanes() throws {
        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 15))

        let windowMenu = app.menuBars.menuBarItems["Window"]
        XCTAssertTrue(windowMenu.waitForExistence(timeout: 10), "the Window menu was not built")
        windowMenu.click()
        let splitView = app.menuItems["Split View"]
        XCTAssertTrue(splitView.waitForExistence(timeout: 10), "the split-view command is missing")
        XCTAssertTrue(splitView.isEnabled, "the split-view command is disabled for a document")
        splitView.click()

        let editors = window.textViews.matching(identifier: "Document editor")
        XCTAssertEqual(editors.count, 2, "split view did not expose two document editors")
        let left = editors.element(boundBy: 0)
        let right = editors.element(boundBy: 1)
        XCTAssertTrue(left.isHittable)
        XCTAssertTrue(right.isHittable)
        XCTAssertLessThan(left.frame.midX, right.frame.midX)
        for pane in window.scrollViews.allElementsBoundByIndex {
            assertVisibleProse(in: pane, window: window)
        }
        let splitScreenshot = XCTAttachment(screenshot: window.screenshot())
        splitScreenshot.lifetime = .keepAlways
        add(splitScreenshot)

        right.click()
        right.typeText("!")

        windowMenu.click()
        app.menuItems["Split View"].click()
        XCTAssertEqual(window.textViews.matching(identifier: "Document editor").count, 1)
        let survivingValue = window.textViews["Document editor"].value as? String
        XCTAssertTrue(survivingValue?.contains("!") == true)
    }

    /// Release-only smoke coverage for the path that previously crashed:
    /// launch a production-configured app built as an older version, invoke
    /// the real menu command, let Sparkle drive the custom panel through its
    /// result transition, then dismiss without installing anything.
    func testProductionUpdaterCheckDoesNotCrash() throws {
        guard isProductionUpdaterSmoke else {
            throw XCTSkip("production updater smoke requires the production host bundle")
        }

        app.launch()
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))

        let applicationMenu = app.menuBars.menuBarItems["Downright"]
        XCTAssertTrue(applicationMenu.waitForExistence(timeout: 10), "the application menu was not built")
        applicationMenu.click()

        let checkForUpdates = app.menuItems["Check for Updates…"]
        XCTAssertTrue(checkForUpdates.waitForExistence(timeout: 10), "the updater menu command is missing")
        XCTAssertTrue(checkForUpdates.isEnabled, "the production updater command is disabled")
        checkForUpdates.click()

        let updatesWindow = app.windows["Updates"]
        XCTAssertTrue(updatesWindow.waitForExistence(timeout: 30), "the updater panel never appeared")
        add(XCTAttachment(screenshot: updatesWindow.screenshot()))

        // The public feed should offer an update because this smoke bundle is
        // deliberately built with a lower version. Accept a no-update result
        // too: it still exercises the same footer rebuild and proves the app
        // survives a healthy, already-current channel.
        guard let dismissButton = waitForButton(
            in: updatesWindow,
            titles: ["Later", "OK", "Cancel", "Cancel Download"],
            timeout: 30
        ) else {
            add(XCTAttachment(screenshot: updatesWindow.screenshot()))
            XCTFail("the updater panel exposed no safe dismissal action")
            return
        }
        dismissButton.click()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "the app stopped after the updater check")
    }

    private func assertVisibleHeading(_ heading: String, in pane: XCUIElement,
                                      file: StaticString = #filePath, line: UInt = #line) {
        // Read the actual line under a native pointer at the navigation's
        // 36pt top inset. A source value or estimated scrollbar fraction
        // cannot establish which heading occupies this screen position.
        let pasteboard = NSPasteboard.general
        var savedItems: [NSPasteboardItem] = []
        for original in pasteboard.pasteboardItems ?? [] {
            let saved = NSPasteboardItem()
            for type in original.types {
                if let data = original.data(forType: type) { saved.setData(data, forType: type) }
            }
            savedItems.append(saved)
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(savedItems)
        }
        let editor = pane.textViews["Document editor"]
        XCTAssertTrue(editor.waitForExistence(timeout: 10), file: file, line: line)
        let columnX = editor.frame.minX - pane.frame.minX + 60
        pane.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            .withOffset(CGVector(dx: columnX, dy: 49)).click()
        app.typeKey(.leftArrow, modifierFlags: [.command])
        app.typeKey(.rightArrow, modifierFlags: [.command, .shift])
        pasteboard.clearContents()
        app.typeKey("c", modifierFlags: [.command])
        var observed = "No copied text"
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard let text = pasteboard.string(forType: .string) else { return false }
            observed = text
            return text.trimmingCharacters(in: CharacterSet(charactersIn: "# \t\n")) == heading
        }, object: nil)
        let result = XCTWaiter.wait(for: [expected], timeout: 10)
        let attachment = XCTAttachment(screenshot: pane.screenshot())
        attachment.name = "Viewport heading: " + heading
        attachment.lifetime = .keepAlways
        add(attachment)
        XCTAssertEqual(result, .completed,
                       "Expected heading \(heading) at the top of the viewport; native line copy returned \(observed)",
                       file: file, line: line)
    }

    private func assertVisibleProse(in pane: XCUIElement, window: XCUIElement,
                                    file: StaticString = #filePath, line: UInt = #line) {
        // WindowServer pixels are the acceptance surface. A nonempty source
        // accessibility value or cacheDisplay PNG also passes for a blank pane.
        // Exclude the margin controls, toolbar, scrollbar and bottom chrome.
        var lastScreenshot: XCUIScreenshot?
        var edgeCount = 0
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let screenshot = window.screenshot()
            lastScreenshot = screenshot
            guard let bitmap = NSBitmapImageRep(data: screenshot.pngRepresentation),
                  let image = bitmap.cgImage, window.frame.width > 0 else { return false }
            let scale = CGFloat(image.width) / window.frame.width
            let viewport = pane.frame.intersection(window.frame)
            let crop = CGRect(x: (viewport.minX - window.frame.minX + viewport.width * 0.20) * scale,
                              y: (viewport.minY - window.frame.minY + 24) * scale,
                              width: viewport.width * 0.60 * scale,
                              height: max(0, viewport.height - 48) * scale).integral
            guard crop.width > 2, crop.height > 2, let prose = image.cropping(to: crop) else { return false }
            let width = prose.width, height = prose.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(prose, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { return false }
            edgeCount = 0
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 1, to: width, by: 2) {
                    let index = (y * width + x) * 4
                    let red = abs(Int(pixels[index]) - Int(pixels[index - 4]))
                    let green = abs(Int(pixels[index + 1]) - Int(pixels[index - 3]))
                    let blue = abs(Int(pixels[index + 2]) - Int(pixels[index - 2]))
                    let contrast = max(red, max(green, blue))
                    if contrast > 40 { edgeCount += 1 }
                }
            }
            // Several visible lines yield thousands of edges. An empty pane,
            // insertion caret or a single gutter badge cannot satisfy this.
            return edgeCount > 150
        }, object: nil)
        let result: XCTWaiter.Result = XCTWaiter.wait(for: [expected], timeout: 10)
        if result != .completed {
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Full screen at missing prose"
            screen.lifetime = .keepAlways
            add(screen)
        }
        if let lastScreenshot {
            let attachment = XCTAttachment(screenshot: lastScreenshot)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(result, .completed, "Visible prose is missing (\(edgeCount) contrasting pixel edges)",
                       file: file, line: line)
    }

    private func waitForScrollPosition(
        in window: XCUIElement, matching predicate: @escaping (Double) -> Bool
    ) throws -> Double {
        // The document map is a sibling of the scroll view. Querying within
        // the scroll view observes AppKit's actual vertical viewport control.
        let scroller = window.scrollViews.firstMatch.scrollBars.firstMatch
        var position: Double?
        var lastValue = "No vertical scroller"
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard scroller.exists else { return false }
            let raw = scroller.value
            lastValue = String(describing: raw)
            let value: Double?
            if let number = raw as? NSNumber {
                value = number.doubleValue
            } else if let text = raw as? String {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                value = trimmed.hasSuffix("%")
                    ? Double(trimmed.dropLast()).map { $0 / 100 }
                    : Double(trimmed)
            } else { value = nil }
            guard let value, value.isFinite, (0...1).contains(value), predicate(value) else { return false }
            position = value
            return true
        }, object: nil)
        let result = XCTWaiter.wait(for: [expected], timeout: 10)
        if result != .completed {
            let screen = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screen.name = "Full screen at unexpected scroll position"
            screen.lifetime = .keepAlways
            add(screen)
        }
        XCTAssertEqual(result, .completed,
                       "Expected native document scroll position. Last value: \(lastValue). \(window.debugDescription)")
        return try XCTUnwrap(position)
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }

    private func waitForButton(
        in window: XCUIElement,
        titles: [String],
        timeout: TimeInterval
    ) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for title in titles {
                let button = window.buttons[title]
                if button.exists { return button }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        } while Date() < deadline
        return nil
    }
}
