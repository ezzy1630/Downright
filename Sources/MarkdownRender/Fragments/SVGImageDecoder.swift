import AppKit

/// Native bitmap conversion for local and explicitly requested remote SVGs.
/// It never resolves a URL or accesses the network.
public enum SVGImageDecoder {
    public static func decode(_ data: Data, maxPixelDimension: Int) -> NSImage? {
        guard data.count <= 20 * 1024 * 1024, let svg = NSImage(data: data),
              svg.size.width.isFinite, svg.size.height.isFinite,
              svg.size.width > 0, svg.size.height > 0 else { return nil }
        let bound = CGFloat(min(2048, max(1, maxPixelDimension)))
        let ratio = min(1, bound / max(svg.size.width, svg.size.height))
        let size = CGSize(width: max(1, svg.size.width * ratio), height: max(1, svg.size.height * ratio))
        guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(ceil(size.width)), pixelsHigh: Int(ceil(size.height)),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        svg.draw(in: CGRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()
        guard let cgImage = bitmap.cgImage else { return nil }
        return NSImage(cgImage: cgImage, size: size)
    }
}
