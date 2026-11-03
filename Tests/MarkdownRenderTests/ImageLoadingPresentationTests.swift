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

    private func writePNG(to url: URL) throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        for x in 0..<4 { for y in 0..<4 { bitmap.setColor(.white, atX: x, y: y) } }
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func load(_ url: URL, cache: ImageRenderCache) async -> NSImage? {
        await withCheckedContinuation { continuation in
            cache.loadImageAsync(for: url, maxPixelDimension: 16) { image in
                continuation.resume(returning: image)
            }
        }
    }

    @Test func imageDimensionsSurvivePixelEviction() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png"), second = root.appendingPathComponent("second.png")
        try writePNG(to: first)
        try writePNG(to: second)
        let cache = ImageRenderCache(countLimit: 1, totalCostLimit: 1024)
        #expect(await load(first, cache: cache) != nil)
        #expect(cache.cachedSize(for: first) == CGSize(width: 4, height: 4))
        #expect(await load(second, cache: cache) != nil)
        #expect(cache.cachedImage(for: first, maxPixelDimension: 16) == nil)
        #expect(cache.cachedSize(for: first) == CGSize(width: 4, height: 4),
                "pixel eviction must not collapse the height of an offscreen image")
    }

    @Test func missingLocalImageRecordsFailureAndRecoversWhenCreated() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("downright-missing-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ImageRenderCache()
        #expect(await load(url, cache: cache) == nil)
        #expect(cache.hasFailed(for: url, maxPixelDimension: 16))
        #expect(cache.cachedSize(for: url) == nil)
        try writePNG(to: url)
        #expect(await load(url, cache: cache) != nil)
        #expect(!cache.hasFailed(for: url, maxPixelDimension: 16))
        #expect(cache.cachedSize(for: url) == CGSize(width: 4, height: 4))
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
