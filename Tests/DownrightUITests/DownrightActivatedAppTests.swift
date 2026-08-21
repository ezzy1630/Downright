import Foundation
import XCTest

/// Acceptance coverage for the surface that SwiftPM's AppKit test runner
/// cannot provide: an actual Downright.app with a running display cycle.
final class DownrightActivatedAppTests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!
    private var fixture: URL!
    private var captureDirectory: URL!
    private var isProductionUpdaterSmoke = false

    override func setUpWithError() throws {
        continueAfterFailure = false

        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-activated-app-\(UUID().uuidString)", isDirectory: true)
        captureDirectory = root.appendingPathComponent("capture", isDirectory: true)
        try FileManager.default.createDirectory(at: captureDirectory, withIntermediateDirectories: true)

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
        app.launchEnvironment["DOWNRIGHT_DEBUG_CAPTURE"] = captureDirectory.path
    }

    override func tearDown() {
        app?.terminate()
        if let root {
            try? FileManager.default.removeItem(at: root)
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

        // This capture is produced by DocumentWindowController only after the
        // active window has completed TextKit 2's first display cycle. It is
        // the concrete proof missing from headless cacheDisplay tests.
        let containerCapture = captureDirectory.appendingPathComponent("container.png")
        XCTAssertTrue(waitForFile(containerCapture, timeout: 15))
        XCTAssertGreaterThan((try Data(contentsOf: containerCapture)).count, 1_000)

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
