#!/usr/bin/env swift
import AppKit

// Builds the macOS iconset from the approved brand master.  Keeping one source
// image prevents the app bundle, start screen, and README from drifting apart.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    FileHandle.standardError.write(Data("usage: make-icon.swift <output.iconset>\n".utf8))
    exit(64)
}

let outputDirectory = URL(fileURLWithPath: arguments[1])
let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
let masterURL = repositoryRoot.appendingPathComponent("Resources/AppIcon.png")

guard let master = NSImage(contentsOf: masterURL) else {
    FileHandle.standardError.write(Data("missing icon master: \(masterURL.path)\n".utf8))
    exit(66)
}

try FileManager.default.createDirectory(
    at: outputDirectory,
    withIntermediateDirectories: true
)

func write(pixels: Int, name: String) throws {
    guard let target = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    target.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
    NSGraphicsContext.current?.imageInterpolation = .high
    master.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let png = target.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try png.write(to: outputDirectory.appendingPathComponent(name), options: .atomic)
}

for (points, scale) in [
    (16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
    (128, 2), (256, 1), (256, 2), (512, 1), (512, 2),
] {
    let suffix = scale == 2 ? "@2x" : ""
    try write(
        pixels: points * scale,
        name: "icon_\(points)x\(points)\(suffix).png"
    )
}

print("wrote iconset to \(outputDirectory.path)")
