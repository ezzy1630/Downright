import AppKit
import Foundation
import Testing
import MarkdownCore
import BeautifulMermaid
@testable import MarkdownRender

/// Regression probes for the P0-1 mermaid text-inversion defect.
///
/// The library ships two AppKit render paths: `MermaidImageRenderer._renderPrepared`
/// (which our bridge used to call and which skips the y-flip) and
/// `MermaidLayer.renderImage` (the path the library's own views use).  The bridge
/// now replicates the flipped `MermaidLayer` sequence, so its bitmap must match the
/// known-good output and must be upright on its own; the fragment then draws that
/// bitmap through `drawNSImage`, whose orientation behaviour is unchanged from the
/// pipeline that produced the audited screenshots.
@Test @MainActor func mermaidBridgeMatchesKnownGoodPath() throws {
    let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    let source = """
    flowchart LR
        A["Start"] --> B["Process"]
        B --> C{"Decision"}
        C -->|yes| D["Done"]
    """
    let theme = MermaidRendererBridge.theme(from: sheet)
    let config = LayoutConfig()

    // Known-good: the CALayer path's own bitmap renderer.
    let layer = MermaidLayer()
    layer.source = source
    layer.theme = theme
    layer.layoutConfig = config
    let knownGood = layer.renderImage(scale: 2)

    // Our bridge output.
    let ours = MermaidRendererBridge.image(source: source, styleSheet: sheet)

    guard let knownGood, let ours else {
        Issue.record("renderer returned nil: knownGood=\(knownGood != nil) ours=\(ours != nil)")
        return
    }
    dumpForInspection(ours, name: "mermaid-ours.png")
    dumpForInspection(knownGood, name: "mermaid-known-good.png")

    let a = bitmapRep(of: ours)
    let b = bitmapRep(of: knownGood)
    guard let a, let b, let aData = a.bitmapData, let bData = b.bitmapData else {
        Issue.record("no bitmap reps")
        return
    }
    // The bridge adds 24pt of padding on every side; the known-good path does
    // not.  Crop the padding band (in *our* pixel units — the bridge renders at
    // whatever scale the environment's screen reports) and map the remaining
    // inner region onto the known-good bitmap before comparing.
    let cropX = min(24, a.pixelsWide / 4)
    let cropY = min(24, a.pixelsHigh / 4)
    let innerW = a.pixelsWide - cropX * 2
    let innerH = a.pixelsHigh - cropY * 2
    guard innerW > 0, innerH > 0, b.pixelsWide >= innerW, b.pixelsHigh >= innerH else {
        Issue.record("unexpected pixel sizes: ours=\(a.pixelsWide)x\(a.pixelsHigh) known=\(b.pixelsWide)x\(b.pixelsHigh)")
        return
    }
    let xScale = CGFloat(b.pixelsWide) / CGFloat(innerW)
    let yScale = CGFloat(b.pixelsHigh) / CGFloat(innerH)
    var differing = 0
    var total = 0
    for y in stride(from: cropY, to: a.pixelsHigh - cropY, by: 2) {
        for x in stride(from: cropX, to: a.pixelsWide - cropX, by: 2) {
            let ox = min(Int(CGFloat(x - cropX) * xScale), b.pixelsWide - 1)
            let oy = min(Int(CGFloat(y - cropY) * yScale), b.pixelsHigh - 1)
            let o = y * a.bytesPerRow + x * a.samplesPerPixel
            let p = oy * b.bytesPerRow + ox * b.samplesPerPixel
            let dr = abs(Int(aData[o]) - Int(bData[p]))
            let dg = abs(Int(aData[o + 1]) - Int(bData[p + 1]))
            let db = abs(Int(aData[o + 2]) - Int(bData[p + 2]))
            if dr + dg + db > 60 { differing += 1 }
            total += 1
        }
    }
    let fraction = Double(differing) / Double(max(1, total))
    print("MERMAID bridge-vs-known-good diff=\(String(format: "%.3f", fraction))")
    #expect(fraction < 0.05, "bridge no longer matches known-good render path")
}

/// The bridge bitmap itself must read upright: a label glyph's widest stroke
/// (the "T" crossbar) must sit in the upper half of the content's row span.
@Test @MainActor func mermaidBridgeBitmapIsUpright() throws {
    let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    let source = """
    flowchart LR
        A["Start"] --> B["Process"]
        B --> C{"Decision"}
        C -->|yes| D["Done"]
    """
    guard let image = MermaidRendererBridge.image(source: source, styleSheet: sheet),
          let rep = bitmapRep(of: image) else {
        Issue.record("bridge produced no renderable bitmap")
        return
    }
    let fraction = crossbarFraction(of: rep)
    print("MERMAID bridge bitmap crossbar fraction=\(String(format: "%.3f", fraction)) (upright < 0.5)")
    #expect(fraction < 0.5, "bridge bitmap has upside-down labels")
}

/// Measures where the label's widest dark row falls within the content's row
/// span, in top-down bitmap order.  A "T"-shaped label's crossbar is its widest
/// stroke; upright text puts it above the content's vertical centre.
private func crossbarFraction(of rep: NSBitmapImageRep) -> Double {
    let w = rep.pixelsWide, h = rep.pixelsHigh
    guard let data = rep.bitmapData, w > 0, h > 0 else { return 0.5 }
    // Fallback theme is near-black; hunt for any pixel clearly different from it.
    var minY = h, maxY = -1
    for y in stride(from: 0, to: h, by: 2) {
        for x in stride(from: 0, to: w, by: 2) {
            let o = y * rep.bytesPerRow + x * rep.samplesPerPixel
            let r = Int(data[o]), g = Int(data[o + 1]), b = Int(data[o + 2])
            if r + g + b > 120 {
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
    }
    guard maxY > minY else { return 0.5 }
    var widest = 0
    var widestY = minY
    for y in stride(from: minY, through: maxY, by: 2) {
        var cnt = 0
        for x in stride(from: 0, to: w, by: 2) {
            let o = y * rep.bytesPerRow + x * rep.samplesPerPixel
            let r = Int(data[o]), g = Int(data[o + 1]), b = Int(data[o + 2])
            if r + g + b > 120 { cnt += 1 }
        }
        if cnt > widest { widest = cnt; widestY = y }
    }
    return Double(widestY - minY) / Double(maxY - minY)
}

/// An `NSImage` may be backed by a CGImage rather than an NSBitmapImageRep;
/// convert through a TIFF so the probe always sees raw pixels.
private func bitmapRep(of image: NSImage) -> NSBitmapImageRep? {
    if let direct = image.representations.first as? NSBitmapImageRep { return direct }
    guard let tiff = image.tiffRepresentation else { return nil }
    return NSBitmapImageRep(data: tiff)
}

private func dumpForInspection(_ image: NSImage, name: String) {
    guard let directory = ProcessInfo.processInfo.environment["DOWNRIGHT_RENDER_DUMP"] else { return }
    guard let rep = bitmapRep(of: image),
          let png = rep.representation(using: .png, properties: [:]) else { return }
    let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? png.write(to: url)
}
