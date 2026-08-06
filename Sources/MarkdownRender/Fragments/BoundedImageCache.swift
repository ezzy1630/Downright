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
final class ImageRenderCache {
    private struct Key: Hashable {
        let url: URL
        let fileSize: Int64?
        let modified: Date?
        let maxPixelDimension: Int
    }

    private let cache = BoundedImageCache<Key>(countLimit: 96, totalCostLimit: 32 * 1024 * 1024)

    func image(for url: URL, maxPixelDimension: Int) -> NSImage? {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let key = Key(
            url: url.standardizedFileURL,
            fileSize: values?.fileSize.map(Int64.init),
            modified: values?.contentModificationDate,
            maxPixelDimension: max(1, maxPixelDimension))
        return cache.image(for: key, keyCost: url.path.utf8.count) {
            Self.downsampledImage(at: key.url, maxPixelDimension: key.maxPixelDimension)
        }
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
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: sourceWidth ?? CGFloat(cgImage.width),
                         height: sourceHeight ?? CGFloat(cgImage.height)))
    }
}
