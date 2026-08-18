import AppKit
import Testing

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
