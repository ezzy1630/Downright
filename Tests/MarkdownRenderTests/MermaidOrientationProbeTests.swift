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
/// known-good upright output; the fragment then draws that
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
    // Neither bitmap can be compared as-is: the bridge now returns the diagram
    // cropped to its own ink, while the known-good path keeps whatever margin
    // the library's reported bounds happen to carry.  Comparing them means
    // comparing *drawings*, so both are reduced to their ink box first and the
    // two boxes are mapped onto each other.  (The magic 24-pixel crop this
    // replaced assumed a fixed 24-*point* padding on our side only; it survived
    // by luck at 2× and stopped describing either image once the bridge began
    // trimming.)
    guard let inkA = inkBox(a), let inkB = inkBox(b) else {
        Issue.record("one of the renders is blank")
        return
    }
    let xScale = CGFloat(inkB.width) / CGFloat(inkA.width)
    let yScale = CGFloat(inkB.height) / CGFloat(inkA.height)
    var differing = 0
    var total = 0
    for y in stride(from: inkA.minY, to: inkA.maxY, by: 2) {
        for x in stride(from: inkA.minX, to: inkA.maxX, by: 2) {
            let ox = min(inkB.minX + Int(CGFloat(x - inkA.minX) * xScale), b.pixelsWide - 1)
            let oy = min(inkB.minY + Int(CGFloat(y - inkA.minY) * yScale), b.pixelsHigh - 1)
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

/// A diagram's image must *be* the diagram.
///
/// `prepared.bounds` is the layout's own idea of its extent, and for a sequence
/// diagram in particular that is materially taller than anything drawn —
/// reserved lifeline runway that never gets used.  The fragment sizes itself
/// from the image, so every point of unused bounds became a band of dead space
/// under the diagram that no fragment-side padding could remove.
@Test @MainActor func mermaidBridgeTrimsToItsOwnInk() throws {
    let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    // A sequence diagram: the shape whose reported bounds overshoot worst.
    let source = """
    sequenceDiagram
        Agent->>Disk: write temp file
        Agent->>Disk: rename() over target
        Disk->>Downright: FSEvents on parent directory
    """
    guard let image = MermaidRendererBridge.image(source: source, styleSheet: sheet),
          let rep = bitmapRep(of: image), let ink = inkBox(rep) else {
        Issue.record("diagram did not render")
        return
    }

    // Every edge of the bitmap must carry ink: if a full row or column at any
    // border is transparent, the image is still padded.
    #expect(ink.minX == 0, "\(ink.minX) blank columns on the left edge")
    #expect(ink.minY == 0, "\(ink.minY) blank rows on the top edge")
    #expect(ink.maxX == rep.pixelsWide, "\(rep.pixelsWide - ink.maxX) blank columns on the right edge")
    #expect(ink.maxY == rep.pixelsHigh, "\(rep.pixelsHigh - ink.maxY) blank rows on the bottom edge")
}

/// The smallest pixel box containing every non-transparent pixel, as
/// half-open `minX..<maxX` / `minY..<maxY` bounds.
///
/// Mirrors `MermaidRendererBridge.inkBounds` — including its alpha floor, so
/// antialiasing haloes do not inflate the box — but reads an
/// `NSBitmapImageRep` rather than a live context, because the probe only ever
/// has finished images to work with.
private func inkBox(_ rep: NSBitmapImageRep) -> (minX: Int, minY: Int, maxX: Int, maxY: Int, width: Int, height: Int)? {
    guard let data = rep.bitmapData, rep.samplesPerPixel >= 4 else {
        // No alpha channel: the whole bitmap is ink.
        guard rep.pixelsWide > 0, rep.pixelsHigh > 0 else { return nil }
        return (0, 0, rep.pixelsWide, rep.pixelsHigh, rep.pixelsWide, rep.pixelsHigh)
    }
    var minX = rep.pixelsWide, minY = rep.pixelsHigh, maxX = -1, maxY = -1
    for y in 0..<rep.pixelsHigh {
        for x in 0..<rep.pixelsWide where data[y * rep.bytesPerRow + x * rep.samplesPerPixel + 3] > 8 {
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
        }
    }
    guard maxX >= minX, maxY >= minY else { return nil }
    return (minX, minY, maxX + 1, maxY + 1, maxX - minX + 1, maxY - minY + 1)
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
