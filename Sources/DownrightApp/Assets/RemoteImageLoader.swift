// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import ImageIO
import MarkdownRender
import AppKit

/// Fetches HTTPS images only after View > Load Remote Images for this document.
///
/// Loading a web image tells its server your IP address and when you opened
/// the document, so each document requires explicit permission. Requests
/// carry no cookies or credentials, and responses go
/// through a small cache of their own.
@MainActor
final class RemoteImageLoader: RemoteImageLoading {

    /// Larger responses are refused rather than decoded.
    nonisolated static let maximumBytes = 20 * 1024 * 1024

    private let session: URLSession
    private let images = NSCache<NSString, NSImage>()
    private var failed: Set<URL> = []
    private var queued: [(url: URL, dimension: Int)] = []
    private var tasks: [NSString: URLSessionTask] = [:]
    private var activeRequests = 0
    private var waiting: [NSString: [@MainActor (NSImage?) -> Void]] = [:]

    init(session: URLSession = RemoteImageLoader.makeSession()) {
        self.session = session
        images.totalCostLimit = 64 * 1024 * 1024
    }

    deinit {
        tasks.values.forEach { $0.cancel() }
        session.invalidateAndCancel()
    }

    nonisolated static func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        configuration.httpAdditionalHeaders = ["Accept": "image/*"]
        configuration.urlCache = URLCache(memoryCapacity: 4 * 1024 * 1024, diskCapacity: 0, diskPath: nil)
        configuration.requestCachePolicy = .useProtocolCachePolicy
        return URLSession(configuration: configuration)
    }

    nonisolated func cachedImage(for url: URL, maxPixelDimension: Int) -> NSImage? {
        MainActor.assumeIsolated { images.object(forKey: Self.key(url, maxPixelDimension)) }
    }

    nonisolated func hasFailed(_ url: URL) -> Bool {
        MainActor.assumeIsolated { failed.contains(url) }
    }

    nonisolated func loadImage(
        for url: URL, maxPixelDimension: Int, completion: @escaping @MainActor (NSImage?) -> Void
    ) {
        MainActor.assumeIsolated {
            start(url, maxPixelDimension: maxPixelDimension, completion: completion)
        }
    }

    private func start(_ url: URL, maxPixelDimension: Int, completion: @escaping @MainActor (NSImage?) -> Void) {
        let key = Self.key(url, maxPixelDimension)
        guard waiting[key] == nil else {
            waiting[key]?.append(completion)
            return
        }
        waiting[key] = [completion]
        queued.append((url, maxPixelDimension))
        startQueuedRequests()
    }

    private func startQueuedRequests() {
        while activeRequests < 4, !queued.isEmpty {
            let request = queued.removeFirst()
            activeRequests += 1
            let task = RemoteImageTransfer.fetch(request.url, configuration: session.configuration, maximumBytes: Self.maximumBytes) { [weak self] data, response, error in
                let decoded = Self.decode(data: data, response: response, error: error, maxPixelDimension: request.dimension)
                Task { @MainActor in
                    self?.finish(request.url, maxPixelDimension: request.dimension, result: decoded)
                }
            }
            tasks[Self.key(request.url, request.dimension)] = task
        }
    }

    private func finish(_ url: URL, maxPixelDimension: Int, result: Decoded) {
        activeRequests -= 1
        tasks.removeValue(forKey: Self.key(url, maxPixelDimension))
        defer { startQueuedRequests() }
        let image: NSImage?
        switch result {
        case .image(let decoded):
            image = decoded
        case .failed:
            image = nil
        }
        deliver(url, maxPixelDimension: maxPixelDimension, image: image)
    }

    private func deliver(_ url: URL, maxPixelDimension: Int, image: NSImage?) {
        if let image {
            let cost = Int(image.size.width * image.size.height * 4) + (image.animatedSource?.retainedByteCount ?? 0)
            images.setObject(image, forKey: Self.key(url, maxPixelDimension), cost: cost)
        } else {
            failed.insert(url)
        }
        let completions = waiting.removeValue(forKey: Self.key(url, maxPixelDimension)) ?? []
        completions.forEach { $0(image) }
    }

    private nonisolated static func key(_ url: URL, _ dimension: Int) -> NSString {
        "\(dimension)|\(url.absoluteString)" as NSString
    }

    enum Decoded {
        case image(NSImage)
        case failed
    }

    /// Runs on the session's queue: checks the response and decodes raster
    /// formats, downsampled the way local images are.
    nonisolated static func decode(data: Data?, response: URLResponse?, error: Error?,
                                   maxPixelDimension: Int) -> Decoded {
        guard error == nil, let data, !data.isEmpty, data.count <= maximumBytes else { return .failed }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { return .failed }
        let mime = (response?.mimeType ?? "").lowercased()
        if mime.contains("svg") || looksLikeSVG(data) {
            guard let image = SVGImageDecoder.decode(data, maxPixelDimension: maxPixelDimension) else { return .failed }
            return .image(image)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return .failed }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelDimension,
            kCGImageSourceShouldCache: false,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return .failed
        }
        // Retain a bounded raster, fitted by the renderer to its column.
        let image = NSImage(cgImage: cgImage, size: CGSize(width: CGFloat(cgImage.width), height: CGFloat(cgImage.height)))
        // Multi-frame images keep this still frame plus their animation,
        // which the native playback view decodes on demand.
        image.animatedSource = AnimatedImageSource(data: data)
        return .image(image)
    }

    nonisolated static func looksLikeSVG(_ data: Data) -> Bool {
        let head = String(decoding: data.prefix(512), as: UTF8.self).lowercased()
        return head.contains("<svg")
    }
}
