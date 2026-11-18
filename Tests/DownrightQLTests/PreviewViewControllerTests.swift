import AppKit
import Foundation
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightQL

@Suite("Hosted Quick Look preview")
@MainActor
struct PreviewViewControllerTests {
    @Test("An empty Markdown file opens as a blank preview")
    func emptyDocumentOpens() async throws {
        try await withPreview("") { _, container, _ in
            #expect(container.textView.string.isEmpty)
        }
    }

    @Test("The large-file notice stays accurate when byte limits cut the first block")
    func giantBlockHasAccuratePreviewNotice() async throws {
        let giantBlock = "# Sample\n\n" + String(repeating: "Body text. ", count: 200_000)
        try await withPreview(giantBlock) { controller, container, _ in
            #expect(container.textView.string.utf8.count < giantBlock.utf8.count)
            func textFields(in view: NSView) -> [NSTextField] {
                (view as? NSTextField).map { [$0] } ?? view.subviews.flatMap(textFields(in:))
            }
            let labels = textFields(in: controller.view).map(\.stringValue)
            #expect(labels.contains("Showing part of this large file"))
        }
    }

    @Test("Preview resolves sibling images under the renderer's safe-relative policy")
    func relativeImagesUseThePreviewedFile() async throws {
        try await withPreview("# Sample\n\n![Sibling](sample.png)\n") { _, container, url in
            let image = try #require(LocalAssetPolicy.request(
                raw: "sample.png", documentURL: container.textView.documentURL
            ))
            #expect(image.url == LocalAssetPolicy.canonicalFileURL(url.deletingLastPathComponent()
                .appendingPathComponent("sample.png")))
            #expect(LocalAssetPolicy.allows(image))
            let traversal = try #require(LocalAssetPolicy.request(
                raw: "../sample.png", documentURL: container.textView.documentURL
            ))
            #expect(!LocalAssetPolicy.allows(traversal))
            #expect(container.textView.remoteImageLoader == nil)
            #expect(container.textView.plantUMLRenderer == nil)
            #expect(!container.textView.allowsAnimatedImages)
        }
    }

    @Test("Hovering a heading mark identifies that heading")
    func headingFractionRoundTripsToItsOwnSection() async throws {
        // This places the second heading at UTF-16 offset 47 of 82. The
        // normalized mark times document length is just under 47 in Double.
        let source = "# First\n\n" + String(repeating: "a", count: 36) + "\n\n## Second\n\n"
            + String(repeating: "b", count: 24)
        try await withPreview(source) { controller, container, _ in
            let rail = try #require(container.leadingAccessory as? DensityGutterView)
            let second = try #require(rail.bands.last { band in
                if case .heading(level: 2) = band.kind { return true }
                return false
            })
            let card = controller.densityGutter(rail, previewAtFraction: second.startFraction)
            #expect(card?.title == "Second")
            #expect(card?.context.hasPrefix("Section 2 of 2") == true)
        }
    }

    @Test("A live appearance change updates the page and rail together")
    func appearanceChangeRecolorsRail() async throws {
        try await withPreview("# Sample\n\nBody\n") { controller, container, _ in
            let rail = try #require(container.leadingAccessory as? DensityGutterView)
            for name: NSAppearance.Name in [.aqua, .darkAqua, .aqua] {
                controller.view.appearance = try #require(NSAppearance(named: name))
                controller.view.displayIfNeeded()
                #expect(container.styleSheet.appearance.bestMatch(from: [.aqua, .darkAqua]) == name)
                #expect(rail.styleSheet.appearance.bestMatch(from: [.aqua, .darkAqua]) == name)
            }
        }
    }

    @Test("The preview accepts keyboard navigation before the first click")
    func previewTakesKeyboardFocusWhenWindowHasNone() async throws {
        _ = NSApplication.shared
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 800),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        try await withPreview("# Sample\n\nBody\n", in: window) { _, container, _ in
            #expect(window.firstResponder === container.textView)
        }
    }

    private func withPreview(
        _ source: String,
        in window: NSWindow? = nil,
        check: (PreviewViewController, MarkdownContainerView, URL) throws -> Void
    ) async throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-ql-host-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("sample.md")
        try source.write(to: url, atomically: true, encoding: .utf8)
        let controller = PreviewViewController()
        window?.contentViewController = controller
        if let window { window.makeFirstResponder(window) }
        let error = await withCheckedContinuation { continuation in
            controller.preparePreviewOfFile(at: url) { continuation.resume(returning: $0) }
        }
        if let error { throw error }
        #expect(controller.view.bounds.width == 720)
        controller.view.layoutSubtreeIfNeeded()
        let container = try #require(controller.view.subviews.compactMap { $0 as? MarkdownContainerView }.first)
        try check(controller, container, url)
    }
}
