// Adapted from Downright-patches; see Docs/Downright-patches-LICENSE.txt.
import ImageIO
import ObjectiveC
import AppKit

public final class AnimatedImageSource: @unchecked Sendable {
    /// Browsers show a GIF delay of 10 ms or less as 100 ms; many GIFs rely
    /// on it (a delay of 0 is common), so play them the same.
    static let minimumDelay: TimeInterval = 0.011
    static let substitutedDelay: TimeInterval = 0.1

    public let frameCount: Int
    /// Seconds each frame shows, after the browser substitution above.
    public let delays: [TimeInterval]
    /// 0 plays forever; n plays n times, then rests on the last frame.
    public let loopCount: Int
    public let pixelSize: CGSize

    /// Encoded bytes and timing metadata retained alongside the still frame.
    public var retainedByteCount: Int { (data?.count ?? 0) + delays.count * MemoryLayout<TimeInterval>.stride }

    private let url: URL?
    private let data: Data?

    /// `nil` for a single-frame image: those stay ordinary stills.
    public convenience init?(url: URL) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        self.init(source: source, url: url, data: nil)
    }

    public convenience init?(data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        self.init(source: source, url: nil, data: data)
    }

    private init?(source: CGImageSource, url: URL?, data: Data?) {
        let count = CGImageSourceGetCount(source)
        guard count > 1 else { return nil }
        frameCount = count
        delays = (0..<count).map { Self.delay(of: source, at: $0) }
        loopCount = Self.loopCount(of: source)
        let first = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        pixelSize = CGSize(width: first?[kCGImagePropertyPixelWidth] as? CGFloat ?? 0,
                           height: first?[kCGImagePropertyPixelHeight] as? CGFloat ?? 0)
        self.url = url
        self.data = data
    }

    /// A fresh ImageIO source.  Each player decodes on its own queue with its
    /// own source rather than sharing one across threads.
    func makeImageSource() -> CGImageSource? {
        if let url { return CGImageSourceCreateWithURL(url as CFURL, nil) }
        if let data { return CGImageSourceCreateWithData(data as CFData, nil) }
        return nil
    }

    /// The fully composed frame `index` (ImageIO applies GIF disposal), no
    /// larger than `maxPixelDimension`.
    static func frame(_ index: Int, of source: CGImageSource, maxPixelDimension: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelDimension),
            kCGImageSourceShouldCache: false,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary)
    }

    static func delay(of source: CGImageSource, at index: Int) -> TimeInterval {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        var delay: Double?
        for (dictionary, unclamped, clamped) in Self.timingKeys {
            guard let info = properties?[dictionary] as? [CFString: Any] else { continue }
            delay = (info[unclamped] as? Double) ?? (info[clamped] as? Double)
            if delay != nil { break }
        }
        return normalized(delay ?? 0)
    }

    static func normalized(_ delay: TimeInterval) -> TimeInterval {
        delay.isFinite && delay >= minimumDelay ? delay : substitutedDelay
    }

    static func loopCount(of source: CGImageSource) -> Int {
        let properties = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
        for (dictionary, key) in Self.loopKeys {
            if let info = properties?[dictionary] as? [CFString: Any], let count = info[key] as? Int {
                return max(0, count)
            }
        }
        return 0
    }

    private static let timingKeys: [(CFString, CFString, CFString)] = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFUnclampedDelayTime, kCGImagePropertyGIFDelayTime),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGUnclampedDelayTime, kCGImagePropertyAPNGDelayTime),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPUnclampedDelayTime, kCGImagePropertyWebPDelayTime),
    ]

    private static let loopKeys: [(CFString, CFString)] = [
        (kCGImagePropertyGIFDictionary, kCGImagePropertyGIFLoopCount),
        (kCGImagePropertyPNGDictionary, kCGImagePropertyAPNGLoopCount),
        (kCGImagePropertyWebPDictionary, kCGImagePropertyWebPLoopCount),
    ]
}

private nonisolated(unsafe) var animatedSourceKey: UInt8 = 0

extension NSImage {
    /// The animation this still frame belongs to, if it has more than one
    /// frame.  Carried on the image itself so every cache and code path that
    /// already handles stills passes animations through untouched.
    public var animatedSource: AnimatedImageSource? {
        get { objc_getAssociatedObject(self, &animatedSourceKey) as? AnimatedImageSource }
        set { objc_setAssociatedObject(self, &animatedSourceKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
}
