import Testing

@testable import MarkdownRender

@Suite("Bounded fragment image caches")
struct BoundedImageCacheTests {
    @Test("count and cost limits evict retained values")
    func limitsAreEnforced() {
        let cache = BoundedImageCache<String>(countLimit: 2, totalCostLimit: 8)
        var builds = 0

        for key in ["one", "two"] {
            _ = cache.image(for: key, keyCost: 1) {
                builds += 1
                return nil
            }
        }
        #expect(cache.countForTesting == 2)

        // Refresh one entry, then force an eviction.  The least-recently-used
        // value must leave first, even when the values are negative cache hits.
        _ = cache.image(for: "one", keyCost: 1) {
            builds += 1
            return nil
        }
        _ = cache.image(for: "three", keyCost: 1) {
            builds += 1
            return nil
        }
        #expect(cache.countForTesting == 2)
        #expect(cache.image(for: "two", keyCost: 1) { builds += 1; return nil } == nil)
        #expect(builds == 4)

        // An entry larger than the byte ceiling is never retained.
        _ = cache.image(for: "oversized", keyCost: 100) {
            builds += 1
            return nil
        }
        #expect(cache.countForTesting == 2)
    }
}
