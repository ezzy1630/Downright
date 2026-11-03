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

    private func writePNG(to url: URL, size: Int = 4) throws {
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let bytes = try #require(bitmap.bitmapData)
        bytes.initialize(repeating: 255, count: bitmap.bytesPerRow * bitmap.pixelsHigh)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url)
    }

    private func load(_ url: URL, cache: ImageRenderCache, dimension: Int = 16) async -> NSImage? {
        await withCheckedContinuation { continuation in
            cache.loadImageAsync(for: url, maxPixelDimension: dimension) { image in
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

    @Test func downsampledPixelsFitTheCacheDespiteLargeNaturalSize() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("downright-downsample-\(UUID().uuidString).png")
        try writePNG(to: url, size: 1024)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ImageRenderCache(totalCostLimit: 1024 * 1024)
        #expect(await load(url, cache: cache, dimension: 64) != nil)
        #expect(cache.cachedImage(for: url, maxPixelDimension: 64) != nil,
                "the cache must charge for decoded pixels rather than the image's natural point size")
        #expect(cache.cachedSize(for: url) == CGSize(width: 1024, height: 1024))
    }

    @Test func paintingAnOffscreenImageDoesNotStartALoad() throws {
        let prefix = String(repeating: "A paragraph before the image.\n\n", count: 100)
        let source = prefix + "![Offscreen](https://example.com/offscreen.png)\n"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        let scroll = NSScrollView(frame: view.frame)
        scroll.documentView = view
        let loader = PendingImages()
        view.remoteImageLoader = loader
        view.mode = .read
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        view.prepareForDisplay()
        let manager = try #require(view.textLayoutManager)
        let location = try #require(manager.textContentManager?.location(
            manager.documentRange.location, offsetBy: prefix.utf16.count))
        manager.ensureLayout(for: manager.documentRange)
        let fragment = try #require(manager.textLayoutFragment(for: location) as? ImageFragment)
        #expect(fragment.layoutFragmentFrame.minY > scroll.contentSize.height)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        fragment.drawObject(at: .zero, in: graphics.cgContext)
        #expect(loader.requests == 0, "offscreen rendering surfaces must not load pixels")
        #expect(storage.string == source)
    }

    @Test func missingLocalImageRecordsFailureAndRecoversWhenCreated() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("downright-missing-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = ImageRenderCache()
        #expect(await load(url, cache: cache) == nil)
        #expect(await load(url, cache: cache, dimension: 32) == nil)
        #expect(cache.hasFailed(for: url, maxPixelDimension: 16))
        #expect(cache.cachedSize(for: url) == nil)
        try writePNG(to: url)
        #expect(await load(url, cache: cache) != nil)
        #expect(await load(url, cache: cache, dimension: 32) != nil)
        #expect(!cache.hasFailed(for: url, maxPixelDimension: 16))
        #expect(!cache.hasFailed(for: url, maxPixelDimension: 32))
        #expect(cache.cachedSize(for: url) == CGSize(width: 4, height: 4))
    }

    @Test func wideLayoutDecodesOnlyTheFittedImagePixels() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-fitted-\(UUID().uuidString).png").resolvingSymlinksInPath()
        try writePNG(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let cache = MarkdownFragmentImageCaches.images
        #expect(await load(url, cache: cache) != nil)
        let source = "![](\(url.lastPathComponent))\n"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 2400, height: 800), storage: storage)
        view.documentURL = url.deletingLastPathComponent().appendingPathComponent("document.md")
        view.mode = .read
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        view.prepareForDisplay()
        view.fragmentContext.contentWidth = 2400
        let manager = try #require(view.textLayoutManager)
        let fragment = try #require(manager.textLayoutFragment(for: manager.documentRange.location) as? ImageFragment)
        let bitmap = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 800, pixelsHigh: 600,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let graphics = try #require(NSGraphicsContext(bitmapImageRep: bitmap))
        fragment.drawObject(at: .zero, in: graphics.cgContext)
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let dimension = Int(ceil(4 * scale))
        let deadline = ContinuousClock().now + .seconds(2)
        while cache.cachedImage(for: url, maxPixelDimension: dimension) == nil,
              ContinuousClock().now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(cache.cachedImage(for: url, maxPixelDimension: dimension) != nil,
                "a wide document must request the fitted image pixels, not a column-sized bitmap")
        #expect(storage.string == source)
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
