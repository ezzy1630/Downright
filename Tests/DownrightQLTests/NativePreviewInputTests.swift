import AppKit
import NativeUITestSupport
import Testing

@testable import DownrightQL
@testable import MarkdownRender

@Suite(.serialized)
@MainActor
struct NativePreviewInputTests {
    @Test func narrowQuickLookHeadingHoverKeepsTheRailClear() async throws {
        _ = NSApplication.shared
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-preview-ui-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("outline.md")
        let source = "# First\n\nOpening.\n\n## Second\n\nA different section.\n"
        try Data(source.utf8).write(to: url)

        let preview = PreviewViewController()
        let width = QuickLookPolicy.minimumDensityGutterWidth
        let window = NSWindow(
            contentRect: NSRect(x: 100, y: 100, width: width, height: 500),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        defer {
            for child in window.childWindows ?? [] {
                (child as? DensityGutterPreviewWindow)?.hide(immediately: true)
            }
            window.orderOut(nil)
            window.resignKey()
            window.close()
        }
        window.contentViewController = preview
        let error = await withCheckedContinuation { continuation in
            preview.preparePreviewOfFile(at: url) { continuation.resume(returning: $0) }
        }
        if let error { throw error }

        window.setContentSize(NSSize(width: width, height: 500))
        let input = WindowInput(window)
        preview.view.layoutSubtreeIfNeeded()
        let container = try #require(preview.view.subviews.compactMap { $0 as? MarkdownContainerView }.first)
        let rail = try #require(container.leadingAccessory as? DensityGutterView)
        let marks = rail.markPositionsForTesting
        try #require(marks.count == 2, "Both heading marks must be laid out")
        let target = rail.convert(NSPoint(x: rail.bounds.midX, y: marks[1]), to: nil)
        try #require(window.childWindows?.isEmpty != false, "A tooltip was already open")
        let hit = window.contentView?.hitTest(target)
        try #require(hit === rail, "The heading mark is under \(String(describing: hit))")
        try input.move(to: target)
        try await input.wait(until: {
            window.childWindows?.contains { $0.isVisible } == true
        }, "the second heading's Quick Look hover card to appear")
        let card = try #require(window.childWindows?.first { $0.isVisible } as? DensityGutterPreviewWindow)
        let screenRail = window.convertToScreen(rail.convert(rail.bounds, to: nil))
        #expect(card.frame.minX >= screenRail.maxX)
        #expect(window.frame.contains(card.frame))
        #expect(card.ignoresMouseEvents, "The narrow overlay must pass pointer events through")
        let secondY = card.frame.midY
        let first = rail.convert(NSPoint(x: rail.bounds.midX, y: marks[0]), to: nil)
        try input.move(to: first)
        #expect(card.frame.midY > secondY, "The hover card must follow the pointer to the preceding heading")
        #expect(card.frame.minX >= screenRail.maxX)
        #expect(!window.isKeyWindow && !NSApp.isActive)
        #expect(try Data(contentsOf: url) == Data(source.utf8))
    }
}
