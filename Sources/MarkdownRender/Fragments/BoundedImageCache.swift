import AppKit
import ImageIO

/// Small, cost-bounded image cache for rendered fragments.
///
/// Count limits alone are not enough here: one Mermaid diagram or formula can
/// be much larger than another.  Entries are evicted by least-recent use until
/// both the count and estimated decoded-pixel budgets hold.  A value too large
/// for the budget is returned to the caller but never retained.
final class BoundedImageCache<Key: Hashable> {
    private struct Entry {
        var image: NSImage?
        var cost: Int
        var stamp: UInt64
    }

    private let countLimit: Int
    private let totalCostLimit: Int
    private var entries: [Key: Entry] = [:]
    private var totalCost = 0
    private var stamp: UInt64 = 0
    private let lock = NSLock()

    init(countLimit: Int, totalCostLimit: Int) {
        self.countLimit = max(1, countLimit)
        self.totalCostLimit = max(1, totalCostLimit)
    }

    func image(for key: Key, keyCost: Int = 0, create: () -> NSImage?) -> NSImage? {
        lock.lock()
        if var hit = entries[key] {
            stamp &+= 1
            hit.stamp = stamp
            entries[key] = hit
            let image = hit.image
            lock.unlock()
            return image
        }
        lock.unlock()

        let image = create()
        // A nil render (malformed formula, unparseable diagram) must not be
        // cached: it costs nothing to reproduce and would otherwise pin the
        // failure in memory while the document scrolls past it.
        guard let image else { return nil }
        let cost = Self.cost(of: image) + max(1, keyCost)
        guard cost <= totalCostLimit else { return image }

        lock.lock()
        stamp &+= 1
        if let replaced = entries.updateValue(
            Entry(image: image, cost: cost, stamp: stamp), forKey: key) {
            totalCost -= replaced.cost
        }
        totalCost += cost
        trimLocked()
        lock.unlock()
        return image
    }

    /// Pure lookup that never runs the `create` closure.  The draw path must
    /// only ever see this: `image(for:keyCost:create:)` may perform I/O in
    /// `create`, and doing that on the main thread is what stalled the app
    /// when an uncached image scrolled into view.
    func cached(_ key: Key) -> NSImage? {
        lock.lock()
        defer { lock.unlock() }
        guard var hit = entries[key] else { return nil }
        stamp &+= 1
        hit.stamp = stamp
        entries[key] = hit
        return hit.image
    }

    /// Records a value produced off the main thread (e.g. a background
    /// decode).  Mirrors the admission rules of `image(for:keyCost:create:)`:
    /// a value too large for the budget is not retained.
    func store(_ image: NSImage, for key: Key, keyCost: Int = 0) {
        let cost = Self.cost(of: image) + max(1, keyCost)
        guard cost <= totalCostLimit else { return }
        lock.lock()
        stamp &+= 1
        if let replaced = entries.updateValue(
            Entry(image: image, cost: cost, stamp: stamp), forKey: key) {
            totalCost -= replaced.cost
        }
        totalCost += cost
        trimLocked()
        lock.unlock()
    }

    func removeAll() {
        lock.lock()
        entries.removeAll(keepingCapacity: true)
        totalCost = 0
        lock.unlock()
    }

    var countForTesting: Int {
        lock.lock()
        defer { lock.unlock() }
        return entries.count
    }

    private func trimLocked() {
        while entries.count > countLimit || totalCost > totalCostLimit {
            guard let victim = entries.min(by: { $0.value.stamp < $1.value.stamp }) else { return }
            entries.removeValue(forKey: victim.key)
            totalCost -= victim.value.cost
        }
    }

    private static func cost(of image: NSImage?) -> Int {
        guard let image else { return 1 }
        let pixels = image.representations.reduce(0) {
            max($0, safeProduct($1.pixelsWide, $1.pixelsHigh))
        }
        return safeProduct(max(1, pixels), 4)
    }

    private static func safeProduct(_ lhs: Int, _ rhs: Int) -> Int {
        guard lhs > 0, rhs > 0 else { return 1 }
        guard lhs <= Int.max / rhs else { return Int.max }
        return lhs * rhs
    }
}

/// Identity of a typeset formula in the shared math cache.  `padding` is part
/// of the identity: a block formula padded with 8pt of air is a different
/// bitmap from the same formula typeset inline without padding.
struct MathRendererCacheKey: Hashable {
    let source: String
    let display: Bool
    let pointSize: CGFloat
    let colorToken: String
    let padding: CGFloat
}

/// Identity of a rendered diagram.  `scale` is the backing pixel scale the
/// diagram was rasterised at, so the same source on a 1x and a 2x display
/// does not serve the wrong-density image.
struct MermaidCacheKey: Hashable {
    let source: String
    let styleToken: Int
    let scale: Int
}

enum MarkdownFragmentImageCaches {
    static let images = ImageRenderCache()
    static let math = BoundedImageCache<MathRendererCacheKey>(
        countLimit: 128, totalCostLimit: 16 * 1024 * 1024)
    static let mermaid = BoundedImageCache<MermaidCacheKey>(
        countLimit: 48, totalCostLimit: 24 * 1024 * 1024)
}

/// Loads only the pixels needed by the image viewport.  The returned image
/// keeps the source pixel dimensions as its point size so layout remains
/// stable even though its decoded representation is downsampled.
///
/// Decoding is a background job.  The draw path may only call `cachedImage`,
/// which is a pure in-memory lookup: the old sync loader ran
/// `CGImageSourceCreateWithURL` — a full disk read and decode — on the main
/// thread inside `drawObject`, so the first time an uncached image scrolled
/// into view the whole app blocked for however long the read took.  On a
/// large image, a network volume, or an iCloud placeholder that read is
/// seconds, which is the intermittent beachball.
final class ImageRenderCache {
    private struct Key: Hashable {
        let url: URL
        let maxPixelDimension: Int
    }

    /// Disk identity of a cached decode, so a file that changed on disk is
    /// re-decoded rather than served stale.  Only read by the background
    /// loader, which is the one place a stat is allowed.
    private struct Freshness: Hashable {
        let fileSize: Int64?
        let modified: Date?
    }

    private let cache = BoundedImageCache<Key>(countLimit: 96, totalCostLimit: 32 * 1024 * 1024)
    private var freshness: [URL: Freshness] = [:]
    private var failedLoads: Set<Key> = []
    /// Decodes in flight, keyed by the same identity `cachedImage` looks up,
    /// so a page of repeated images (or a split view showing one document
    /// twice) starts one decode instead of one per fragment.  Every caller's
    /// completion fires when the shared decode lands.
    private var inFlight: [Key: [(@Sendable @MainActor (NSImage?) -> Void)]] = [:]
    private let lock = NSLock()

    private func key(for url: URL, maxPixelDimension: Int) -> Key {
        Key(url: url.standardizedFileURL, maxPixelDimension: max(1, maxPixelDimension))
    }

    /// Pure cache lookup — never touches the filesystem, so it can never
    /// stall layout or drawing.  This is the only image access the draw path
    /// uses; a miss means "schedule an async load", never "read it now".
    func cachedImage(for url: URL, maxPixelDimension: Int) -> NSImage? {
        cache.cached(key(for: url, maxPixelDimension: maxPixelDimension))
    }

    /// Decodes `url` off the main thread, records it in the cache, then calls
    /// `completion` on the main actor with the result (nil when the file is
    /// missing or unreadable).  Concurrent requests for the same image share
    /// one decode.
    func loadImageAsync(
        for url: URL,
        maxPixelDimension: Int,
        completion: @escaping @Sendable @MainActor (NSImage?) -> Void
    ) {
        let key = key(for: url, maxPixelDimension: maxPixelDimension)
        lock.lock()
        if var callbacks = inFlight[key] {
            callbacks.append(completion)
            inFlight[key] = callbacks
            lock.unlock()
            return
        }
        inFlight[key] = [completion]
        lock.unlock()

        DispatchQueue.global(qos: .userInitiated).async {
            let image = self.decodeIfNeeded(for: key)
            let callbacks: [(@Sendable @MainActor (NSImage?) -> Void)]
            self.lock.lock()
            callbacks = self.inFlight.removeValue(forKey: key) ?? []
            self.lock.unlock()
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    for callback in callbacks { callback(image) }
                }
            }
        }
    }

    /// Runs on the background queue.  Re-decodes when the file is not cached
    /// yet or changed on disk since it was cached; otherwise returns the
    /// cached decode (re-decoding only if eviction dropped it).
    private func decodeIfNeeded(for key: Key) -> NSImage? {
        let url = key.url
        let current = Self.freshness(of: url)
        let cached = cache.cached(key)
        lock.lock()
        let changed = freshness[url] != current
        if changed {
            freshness[url] = current
            failedLoads.remove(key)
        }
        let isFailed = failedLoads.contains(key)
        lock.unlock()
        if isFailed, !changed { return nil }
        if let cached, !changed { return cached }
        guard let image = Self.downsampledImage(at: url, maxPixelDimension: key.maxPixelDimension) else {
            lock.lock()
            failedLoads.insert(key)
            lock.unlock()
            return nil
        }
        lock.lock()
        failedLoads.remove(key)
        lock.unlock()
        cache.store(image, for: key, keyCost: url.path.utf8.count)
        return image
    }

    private static func freshness(of url: URL) -> Freshness {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        return Freshness(fileSize: values?.fileSize.map(Int64.init), modified: values?.contentModificationDate)
    }

    private static func downsampledImage(at url: URL, maxPixelDimension: Int) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let sourceWidth = properties?[kCGImagePropertyPixelWidth] as? CGFloat
        let sourceHeight = properties?[kCGImagePropertyPixelHeight] as? CGFloat
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceShouldCache: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: sourceWidth ?? CGFloat(cgImage.width),
                         height: sourceHeight ?? CGFloat(cgImage.height)))
        // The *source* is the authority on transparency: a thumbnail can be
        // handed back in a format that no longer advertises it.  Fragments
        // matte a transparent image rather than letting the page colour show
        // through the artwork, so the flag has to survive the downsample.
        if let declared = properties?[kCGImagePropertyHasAlpha] as? Bool {
            image.representations.first?.hasAlpha = declared
        }
        return image
    }
}
