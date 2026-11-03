import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@MainActor
struct ImageLoadingPresentationTests {
    private final class PendingImages: RemoteImageLoading {
        var requests = 0
        func cachedImage(for url: URL, maxPixelDimension: Int) -> NSImage? { nil }
        func hasFailed(_ url: URL) -> Bool { false }
        func loadImage(for url: URL, maxPixelDimension: Int,
                       completion: @escaping @MainActor (NSImage?) -> Void) {
            requests += 1
        }
    }

    @Test func measuringImagesDoesNotStartLoadsButDrawingDoes() throws {
        let source = "![First](https://example.com/first.png)\n"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        let loader = PendingImages()
        view.remoteImageLoader = loader
        view.mode = .read
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        view.prepareForDisplay()
        let manager = try #require(view.textLayoutManager)
        let fragment = try #require(manager.textLayoutFragment(for: manager.documentRange.location) as? ImageFragment)
        for _ in 0..<5 { _ = fragment.overrideHeight }
        #expect(loader.requests == 0, "measuring offscreen images must not start loads that evict visible pictures")
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        for _ in 0..<5 { fragment.drawObject(at: .zero, in: graphics.cgContext) }
        #expect(loader.requests == 1, "redrawing a pending image must share its existing request")
        #expect(storage.string == source)
    }
}
