import AppKit
import ImageIO
import Testing
import UniformTypeIdentifiers

@testable import MarkdownRender

@Suite("Bounded fragment image caches")
struct BoundedImageCacheTests {
    /// Writes a tiny real PNG and returns its URL, or records a failure.
    private func makeTestImage() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-image-cache-\(UUID().uuidString).png")
        let image = NSImage(size: NSSize(width: 4, height: 4))
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: 4, height: 4).fill()
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try png.write(to: url)
        return url
    }

    /// Main-actor-collected results for the async loader tests.  The
    /// completions are `@Sendable`, so the collector has to be Sendable too.
    private final class AsyncResults: @unchecked Sendable {
        var values: [NSImage?] = []
    }
    @Test("count and cost limits evict retained values")
    func limitsAreEnforced() {
        let cache = BoundedImageCache<String>(countLimit: 2, totalCostLimit: 8 * 1024)
        var builds = 0

        func makeImage() -> NSImage {
            NSImage(size: NSSize(width: 2, height: 2))
        }

        for key in ["one", "two"] {
            _ = cache.image(for: key, keyCost: 1) {
                builds += 1
                return makeImage()
            }
        }
        #expect(cache.countForTesting == 2)

        // Refresh one entry, then force an eviction.  The least-recently-used
        // value must leave first.
        _ = cache.image(for: "one", keyCost: 1) {
            builds += 1
            return makeImage()
        }
        _ = cache.image(for: "three", keyCost: 1) {
            builds += 1
            return makeImage()
        }
        #expect(cache.countForTesting == 2)
        // "two" was evicted; rebuilding it increments the create counter.
        _ = cache.image(for: "two", keyCost: 1) { builds += 1; return makeImage() }
        #expect(builds == 4)

        // Nil renders are never retained — they are cheap to reproduce and
        // must not pin failures in the cache while the document scrolls.
        let beforeNil = cache.countForTesting
        _ = cache.image(for: "missing", keyCost: 1) {
            builds += 1
            return nil
        }
        #expect(cache.countForTesting == beforeNil)
        #expect(builds == 5)
    }

    @Test("cached lookup is a pure miss and the async loader fills it")
    func asyncLoadPopulatesCache() async throws {
        let url = try makeTestImage()
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = ImageRenderCache()
        // The draw path's lookup must be a pure miss — no decode, no I/O.
        #expect(cache.cachedImage(for: url, maxPixelDimension: 16) == nil)

        let loaded = await withCheckedContinuation { continuation in
            cache.loadImageAsync(for: url, maxPixelDimension: 16) { image in
                continuation.resume(returning: image)
            }
        }
        #expect(loaded != nil)
        // The decode is now cached under the same identity the draw path uses.
        #expect(cache.cachedImage(for: url, maxPixelDimension: 16) != nil)
    }

    @Test("JPEG layout uses full oriented dimensions with a bounded bitmap", arguments: [
        (.up, false), (.upMirrored, false), (.down, false), (.downMirrored, false),
        (.leftMirrored, true), (.right, true), (.rightMirrored, true), (.left, true),
        (nil, false),
    ] as [(CGImagePropertyOrientation?, Bool)])
    func jpegLayoutMatchesOrientation(orientation: CGImagePropertyOrientation?, swapsAxes: Bool) async throws {
        let data = try makeJPEG(orientation: orientation)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        try #require(properties[kCGImagePropertyPixelWidth] as? Int == 320)
        try #require(properties[kCGImagePropertyPixelHeight] as? Int == 120)
        if let orientation {
            try #require(properties[kCGImagePropertyOrientation] as? UInt32 == orientation.rawValue)
        }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-image-cache-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)

        let cache = ImageRenderCache()
        let loaded = await withCheckedContinuation { continuation in
            cache.loadImageAsync(for: url, maxPixelDimension: 160) { image in
                continuation.resume(returning: image)
            }
        }
        let image = try #require(loaded)
        let cached = try #require(cache.cachedImage(for: url, maxPixelDimension: 160))
        let bitmap = try #require(cached.representations.first as? NSBitmapImageRep)
        let naturalSize = swapsAxes ? CGSize(width: 120, height: 320) : CGSize(width: 320, height: 120)
        let thumbnailSize = swapsAxes ? CGSize(width: 60, height: 160) : CGSize(width: 160, height: 60)
        #expect(image.size == naturalSize)
        #expect(cache.cachedSize(for: url) == naturalSize)
        #expect(cached.size == naturalSize)
        #expect(bitmap.size == naturalSize)
        #expect(CGSize(width: bitmap.pixelsWide, height: bitmap.pixelsHigh) == thumbnailSize)
    }

    private func makeJPEG(orientation: CGImagePropertyOrientation?) throws -> Data {
        let context = try #require(CGContext(
            data: nil, width: 320, height: 120, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
        context.setFillColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 320, height: 120))
        let image = try #require(context.makeImage())
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        let properties: [CFString: Any] = orientation.map { [kCGImagePropertyOrientation: $0.rawValue] } ?? [:]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        try #require(CGImageDestinationFinalize(destination))
        return data as Data
    }

    @Test("concurrent requests for one image share the load and both complete")
    func concurrentLoadsBothComplete() async throws {
        let url = try makeTestImage()
        defer { try? FileManager.default.removeItem(at: url) }

        let cache = ImageRenderCache()
        let results = await withCheckedContinuation { continuation in
            let collected = AsyncResults()
            let gate = DispatchGroup()
            func request() {
                gate.enter()
                cache.loadImageAsync(for: url, maxPixelDimension: 16) { image in
                    collected.values.append(image)
                    gate.leave()
                }
            }
            // Enter before scheduling so a fast decode can never leave the
            // group under zero.
            request()
            request()
            gate.notify(queue: .main) {
                continuation.resume(returning: collected.values)
            }
        }
        #expect(results.count == 2)
        #expect(results.allSatisfy { $0 != nil })
    }
}
