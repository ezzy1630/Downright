#!/usr/bin/env swift
import AppKit

// Draws Downright's app icon at every size macOS asks for and writes an
// iconset.  Kept as source rather than a checked-in binary so the icon tracks
// the app's own palette — it is drawn with the same warm paper and accent the
// default themes use.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}
let outputDirectory = URL(fileURLWithPath: arguments[1])
try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let paper = color(0xF7F3EC)
let ink = color(0x2A2622)
let accent = color(0xC8722E)
let rule = color(0xDCD4C8)

func draw(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    let unit = size / 1024

    // Rounded page with the macOS icon margin.
    let inset = 96 * unit
    let page = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let radius = page.width * 0.2237  // matches the macOS squircle closely enough at every size

    NSGraphicsContext.current?.cgContext.setShadow(
        offset: CGSize(width: 0, height: -8 * unit),
        blur: 28 * unit,
        color: NSColor.black.withAlphaComponent(0.18).cgColor
    )
    paper.setFill()
    NSBezierPath(roundedRect: page, xRadius: radius, yRadius: radius).fill()
    NSGraphicsContext.current?.cgContext.setShadow(offset: .zero, blur: 0, color: nil)

    // Text lines: the document being read, at descending emphasis.
    let lineX = page.minX + page.width * 0.20
    let lineWidth = page.width * 0.60
    let lineHeight = page.height * 0.042
    var y = page.maxY - page.height * 0.22
    let widths: [CGFloat] = [1.0, 0.82, 0.9]
    for factor in widths {
        rule.setFill()
        NSBezierPath(
            roundedRect: NSRect(x: lineX, y: y, width: lineWidth * factor, height: lineHeight),
            xRadius: lineHeight / 2, yRadius: lineHeight / 2
        ).fill()
        y -= lineHeight * 2.3
    }

    // The mark: a downward-right chevron, drawn as a stroked path so it reads
    // at 16pt as well as at 1024.
    let chevron = NSBezierPath()
    let centre = NSPoint(x: page.midX - page.width * 0.02, y: page.minY + page.height * 0.29)
    let reach = page.width * 0.175
    chevron.move(to: NSPoint(x: centre.x - reach, y: centre.y + reach * 0.72))
    chevron.line(to: NSPoint(x: centre.x, y: centre.y - reach * 0.30))
    chevron.line(to: NSPoint(x: centre.x + reach, y: centre.y + reach * 0.72))
    chevron.lineWidth = page.width * 0.085
    chevron.lineCapStyle = .round
    chevron.lineJoinStyle = .round
    ink.setStroke()
    chevron.stroke()

    // Accent rule down the left edge, echoing the code-block treatment (§11.3).
    accent.setFill()
    let ruleWidth = page.width * 0.055
    let clip = NSBezierPath(roundedRect: page, xRadius: radius, yRadius: radius)
    NSGraphicsContext.saveGraphicsState()
    clip.addClip()
    NSBezierPath(rect: NSRect(x: page.minX, y: page.minY, width: ruleWidth, height: page.height)).fill()
    NSGraphicsContext.restoreGraphicsState()

    return image
}

func write(_ image: NSImage, pixels: Int, name: String) {
    guard let tiff = image.tiffRepresentation,
          let source = NSBitmapImageRep(data: tiff) else { return }
    let target = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    target.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
    source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels))
    NSGraphicsContext.restoreGraphicsState()

    guard let png = target.representation(using: .png, properties: [:]) else { return }
    try? png.write(to: outputDirectory.appendingPathComponent(name))
}

for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let pixels = points * scale
    let image = draw(size: CGFloat(pixels))
    let suffix = scale == 2 ? "@2x" : ""
    write(image, pixels: pixels, name: "icon_\(points)x\(points)\(suffix).png")
}

print("wrote iconset to \(outputDirectory.path)")
