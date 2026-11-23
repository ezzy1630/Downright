import AppKit
import Testing

@testable import MarkdownRender

/// Block math is drawn from a padded image (`MathFragment` asks for 8pt of air).
/// The unpadded formula is a drawing-handler image that `drawNSImage` rasterizes
/// at the destination's scale; this checks the padded one keeps that density on
/// 1x and 2x destinations instead of carrying one bitmap made at creation time.
@Suite(.serialized)
@MainActor
struct MathRasterDensityTests {
    /// Unique to this suite so no earlier test's cache entry stands in for it.
    static let latex = #"\frac{\alpha}{\beta + 7} = \sqrt{\gamma_{density}}"#
    static let padding: CGFloat = 8

    @Test(arguments: [1, 2])
    func paddedBlockMathDrawsAtTheDestinationDensity(scale: Int) throws {
        let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
        let control = try #require(MathRenderer.image(latex: Self.latex, display: true,
                                                      pointSize: 18, color: sheet.text))
        let padded = try #require(MathRenderer.image(latex: Self.latex, display: true,
                                                     pointSize: 18, color: sheet.text, padding: Self.padding))
        let environment = "main screen scale \(NSScreen.main?.backingScaleFactor ?? 0), "
            + "padded representations \(padded.representations.map { "\(type(of: $0)) \($0.pixelsWide)x\($0.pixelsHigh)" })"

        let canvasSize = CGSize(width: ceil(padded.size.width), height: ceil(padded.size.height))
        let controlCanvas = try canvas(size: canvasSize, scale: scale)
        let paddedCanvas = try canvas(size: canvasSize, scale: scale)

        // The pixels `drawNSImage` obtains for this destination.
        let wanted = Int((control.size.width * CGFloat(scale)).rounded())
        let controlPixels = try pixelWidth(of: control, in: controlCanvas)
        try #require(abs(controlPixels - wanted) <= 1,
                     "Control: the unpadded formula gave \(controlPixels)px for \(wanted)px at \(scale)x; \(environment)")
        let paddedWanted = Int((padded.size.width * CGFloat(scale)).rounded())
        let paddedPixels = try pixelWidth(of: padded, in: paddedCanvas)
        #expect(abs(paddedPixels - paddedWanted) <= 1,
                "Padded block math gave \(paddedPixels)px for \(paddedWanted)px at \(scale)x; \(environment)")

        // The drawn result: the padded formula over the unpadded one at the same place.
        drawNSImage(control, in: CGRect(x: Self.padding, y: Self.padding,
                                        width: control.size.width, height: control.size.height), in: controlCanvas)
        drawNSImage(padded, in: CGRect(origin: .zero, size: padded.size), in: paddedCanvas)
        let difference = try inkAlphaDifference(controlCanvas, paddedCanvas)
        #expect(difference.inkPixels > 0, "Neither drawing produced ink at \(scale)x")
        #expect(difference.mean <= 16,
                "Padded block math differs from the directly drawn formula by \(difference.mean)/255 on "
                    + "\(difference.inkPixels) ink pixels at \(scale)x; \(environment)")
    }

    // MARK: - Bitmaps

    private func canvas(size: CGSize, scale: Int) throws -> CGContext {
        let context = try #require(CGContext(
            data: nil,
            width: Int(size.width) * scale, height: Int(size.height) * scale,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: CGFloat(scale), y: CGFloat(scale))
        return context
    }

    /// The same request `drawNSImage` makes for this context.
    private func pixelWidth(of image: NSImage, in context: CGContext) throws -> Int {
        var proposed = CGRect(origin: .zero, size: image.size)
        let drawing = NSGraphicsContext(cgContext: context, flipped: true)
        return try #require(image.cgImage(forProposedRect: &proposed, context: drawing, hints: nil)).width
    }

    /// Mean absolute alpha difference over pixels either drawing touched.
    private func inkAlphaDifference(_ lhs: CGContext, _ rhs: CGContext) throws -> (mean: Double, inkPixels: Int) {
        let left = try #require(lhs.data).assumingMemoryBound(to: UInt8.self)
        let right = try #require(rhs.data).assumingMemoryBound(to: UInt8.self)
        try #require(lhs.width == rhs.width && lhs.height == rhs.height && lhs.bytesPerRow == rhs.bytesPerRow)
        var total = 0
        var ink = 0
        for row in 0..<lhs.height {
            for column in 0..<lhs.width {
                let alpha = row * lhs.bytesPerRow + column * 4 + 3
                let a = Int(left[alpha])
                let b = Int(right[alpha])
                guard a > 0 || b > 0 else { continue }
                total += abs(a - b)
                ink += 1
            }
        }
        return (ink == 0 ? 0 : Double(total) / Double(ink), ink)
    }
}
