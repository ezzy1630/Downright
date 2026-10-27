#!/usr/bin/env swift
import AppKit

// Builds the GitHub social preview card from the same brand master the app
// bundle and README use.  Deriving the card from Resources/AppIcon.png keeps
// the repository link card, the app icon, and the README hero in sync.
//
// The card is 1280x640, which is what GitHub asks for; it renders the link
// card at 640x320 and as small as 320x160, so the lockup has to survive a 4x
// downscale.  Uploading it is a web-UI step: GitHub exposes no API for the
// social preview, so regenerating this file does not change the live card.

let arguments = CommandLine.arguments
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let outputURL = arguments.count >= 2
    ? URL(fileURLWithPath: arguments[1])
    : repositoryRoot.appendingPathComponent("Docs/marketing/github-social-preview.png")
let masterURL = repositoryRoot.appendingPathComponent("Resources/AppIcon.png")

guard let masterData = try? Data(contentsOf: masterURL),
      let masterRep = NSBitmapImageRep(data: masterData) else {
    FileHandle.standardError.write(Data("missing icon master: \(masterURL.path)\n".utf8))
    exit(66)
}

// MARK: - Brand palette, sampled from the master

func srgb(_ hex: UInt32) -> NSColor {
    NSColor(
        srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
        green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255,
        alpha: 1
    )
}

let cream = srgb(0xEFE7DD)
let navyTop = srgb(0x101924)
let navyBottom = srgb(0x1F2E40)
let accent = srgb(0x4C8CD4)
let muted = srgb(0x93A6BC)

// MARK: - Cut the icon's opaque white surround away

/// The master is a flat RGB render: a warm cream and navy body sitting on a
/// neutral white field with a soft grey contact shadow.  Every body pixel is
/// either warm or dark, and every surround pixel is neutral and light, so
/// flood filling the neutral field inward from the canvas corners yields an
/// exact mask without having to guess Apple's continuous-corner geometry.
func maskedIcon(from rep: NSBitmapImageRep) -> NSImage {
    let width = rep.pixelsWide
    let height = rep.pixelsHigh
    var isSurround = [Bool](repeating: false, count: width * height)
    var isBody = [Bool](repeating: false, count: width * height)

    for y in 0..<height {
        for x in 0..<width {
            guard let color = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
            let red = color.redComponent
            let green = color.greenComponent
            let blue = color.blueComponent
            let isWarm = (red - blue) > 0.028
            let isDark = max(red, max(green, blue)) < 0.60
            isBody[y * width + x] = isWarm || isDark
        }
    }

    var queue: [Int] = []
    for corner in [0, width - 1, (height - 1) * width, height * width - 1] where !isBody[corner] {
        isSurround[corner] = true
        queue.append(corner)
    }
    while let index = queue.popLast() {
        let x = index % width
        let y = index / width
        for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
            let nx = x + dx
            let ny = y + dy
            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
            let neighbor = ny * width + nx
            guard !isBody[neighbor], !isSurround[neighbor] else { continue }
            isSurround[neighbor] = true
            queue.append(neighbor)
        }
    }

    // Grow the cut by a couple of pixels so the antialiased seam between the
    // white field and the cream body does not survive as a bright fringe on a
    // dark background.
    for _ in 0..<2 {
        var grown = isSurround
        for y in 0..<height {
            for x in 0..<width where !isSurround[y * width + x] {
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    if isSurround[ny * width + nx] { grown[y * width + x] = true; break }
                }
            }
        }
        isSurround = grown
    }

    guard let output = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: width,
        pixelsHigh: height,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: width * 4,
        bitsPerPixel: 32
    ), let pixels = output.bitmapData else {
        FileHandle.standardError.write(Data("could not allocate icon mask\n".utf8))
        exit(70)
    }

    for y in 0..<height {
        for x in 0..<width {
            let index = y * width + x
            let offset = index * 4
            if isSurround[index] {
                pixels[offset] = 0; pixels[offset + 1] = 0
                pixels[offset + 2] = 0; pixels[offset + 3] = 0
                continue
            }
            let color = rep.colorAt(x: x, y: y)!.usingColorSpace(.sRGB)!
            pixels[offset] = UInt8(color.redComponent * 255)
            pixels[offset + 1] = UInt8(color.greenComponent * 255)
            pixels[offset + 2] = UInt8(color.blueComponent * 255)
            pixels[offset + 3] = 255
        }
    }

    let image = NSImage(size: NSSize(width: width, height: height))
    image.addRepresentation(output)
    return image
}

let icon = maskedIcon(from: masterRep)

// MARK: - Compose the 1280x640 card

let cardSize = NSSize(width: 1280, height: 640)
guard let canvas = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(cardSize.width),
    pixelsHigh: Int(cardSize.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { exit(70) }
canvas.size = cardSize

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: canvas)
NSGraphicsContext.current?.imageInterpolation = .high
let context = NSGraphicsContext.current!.cgContext

let cardRect = NSRect(origin: .zero, size: cardSize)
NSGradient(colors: [navyBottom, navyTop])!.draw(in: cardRect, angle: 78)

// A cool wash behind the icon so the cream body is never the only light source.
context.saveGState()
context.clip(to: cardRect)
let glow = NSGradient(colors: [
    accent.withAlphaComponent(0.20),
    accent.withAlphaComponent(0),
])!
glow.draw(
    fromCenter: NSPoint(x: 268, y: 330),
    radius: 0,
    toCenter: NSPoint(x: 268, y: 330),
    radius: 430,
    options: []
)
context.restoreGState()

// Hairline frame, so the card still reads as a card against dark link surfaces.
cream.withAlphaComponent(0.09).setStroke()
let frame = NSBezierPath(rect: cardRect.insetBy(dx: 0.5, dy: 0.5))
frame.lineWidth = 1
frame.stroke()

let iconSide: CGFloat = 288
let iconRect = NSRect(x: 104, y: (cardSize.height - iconSide) / 2, width: iconSide, height: iconSide)
context.saveGState()
context.setShadow(
    offset: CGSize(width: 0, height: -14),
    blur: 42,
    color: NSColor.black.withAlphaComponent(0.55).cgColor
)
icon.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
context.restoreGState()

// MARK: - Type

func serif(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
    let descriptor = base.fontDescriptor.withDesign(.serif) ?? base.fontDescriptor
    return NSFont(descriptor: descriptor, size: size) ?? base
}

func draw(
    _ text: String,
    at point: NSPoint,
    font: NSFont,
    color: NSColor,
    tracking: CGFloat = 0,
    lineHeight: CGFloat? = nil
) {
    let paragraph = NSMutableParagraphStyle()
    if let lineHeight {
        paragraph.minimumLineHeight = lineHeight
        paragraph.maximumLineHeight = lineHeight
    }
    var attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: color,
        .paragraphStyle: paragraph,
    ]
    if tracking != 0 { attributes[.kern] = tracking }
    NSAttributedString(string: text, attributes: attributes).draw(at: point)
}

let textLeft: CGFloat = 452

draw("Downright", at: NSPoint(x: textLeft, y: 372), font: serif(92, .bold), color: cream, tracking: -1.5)

// Accent rule keyed to the single blue list row in the icon.
accent.setFill()
NSBezierPath(roundedRect: NSRect(x: textLeft + 2, y: 346, width: 72, height: 5), xRadius: 2.5, yRadius: 2.5).fill()

draw(
    "A beautiful native Markdown editor\nand reader for macOS.",
    at: NSPoint(x: textLeft, y: 236),
    font: NSFont.systemFont(ofSize: 33, weight: .medium),
    color: muted,
    lineHeight: 45
)

draw(
    "MACOS 14+   ·   OPEN SOURCE   ·   MIT",
    at: NSPoint(x: textLeft + 1, y: 186),
    font: NSFont.systemFont(ofSize: 18, weight: .semibold),
    color: muted.withAlphaComponent(0.72),
    tracking: 2.6
)

NSGraphicsContext.restoreGraphicsState()

guard let png = canvas.representation(using: .png, properties: [:]) else { exit(70) }

// GitHub rejects a social preview larger than 1 MB.
let uploadLimit = 1_048_576
guard png.count <= uploadLimit else {
    FileHandle.standardError.write(Data(
        "social preview is \(png.count) bytes, over GitHub's \(uploadLimit) byte limit\n".utf8
    ))
    exit(65)
}

try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)
try png.write(to: outputURL, options: .atomic)
let headroom = uploadLimit - png.count
print("wrote \(outputURL.path) (\(png.count) bytes, \(headroom) under the GitHub limit)")
