import Foundation
import XCTest

/// Acceptance coverage for the surface that SwiftPM's AppKit test runner
/// cannot provide: an actual Downright.app with a running display cycle.
final class DownrightActivatedAppTests: XCTestCase {
    private var app: XCUIApplication!
    private var root: URL!
    private var fixture: URL!
    private var captureDirectory: URL!

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
        app = XCUIApplication(url: host)
        app.launchArguments = [fixture.path]
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

    private func waitForFile(_ url: URL, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if FileManager.default.fileExists(atPath: url.path) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        } while Date() < deadline
        return false
    }
}
