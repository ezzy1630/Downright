import AppKit
import Testing

@testable import MarkdownRender

@Suite("Bounded fragment image caches")
struct BoundedImageCacheTests {
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
}
