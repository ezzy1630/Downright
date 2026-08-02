// swift-tools-version: 6.0
import Foundation
import PackageDescription

// XCTest ships with Xcode, not with the Command Line Tools.  swift-testing
// *does* ship with the CLT, but it sits outside SwiftPM's default framework
// search path, so `swift test` finds neither out of the box on a CLT-only
// machine.  Detect that and add the paths; on a machine with Xcode this is a
// no-op and the standard toolchain is used unmodified.
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltLibraries = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let selectedDeveloperPath: String = {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = output
    guard (try? process.run()) != nil else { return "" }
    process.waitUntilExit()
    return String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}()
let needsCLTTestPaths = FileManager.default.fileExists(
    atPath: cltFrameworks + "/Testing.framework"
) && selectedDeveloperPath.hasPrefix("/Library/Developer/CommandLineTools")

let testSwiftSettings: [SwiftSetting] = needsCLTTestPaths
    ? [.swiftLanguageMode(.v5), .unsafeFlags(["-F", cltFrameworks])]
    : [.swiftLanguageMode(.v5)]

// `-rpath` is a linker flag, not a driver flag, so it has to be handed through
// with `-Xlinker`; passing it bare makes swiftc reject the whole invocation.
let testLinkerSettings: [LinkerSetting] = needsCLTTestPaths
    ? [.unsafeFlags([
        "-F", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", cltLibraries,
      ])]
    : []

// Downright — a native macOS markdown reader/editor for a world where most
// markdown is written by machines.  See markdown-app-spec.md.
//
// Layout mirrors §12 of the spec:
//   MarkdownCore    parse + extension passes + AST diff   (no UI, no AppKit)
//   MarkdownRender  decoration engine, layout fragments   (AppKit)
//   DownrightApp    windows, modes, sidebar, AI layer
//   DownrightQL     Quick Look preview extension          (needs Xcode to bundle)
//   DownrightThumb  Quick Look thumbnail extension        (needs Xcode to bundle)
//   down            terminal launcher
//
// MarkdownCore and MarkdownRender are the standalone artifacts worth releasing
// on their own, so they carry no dependency on the app target.

let package = Package(
    name: "Downright",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MarkdownCore", targets: ["MarkdownCore"]),
        .library(name: "MarkdownRender", targets: ["MarkdownRender"]),
        .executable(name: "Downright", targets: ["DownrightApp"]),
        .executable(name: "down", targets: ["down"]),
        .executable(name: "drbench", targets: ["drbench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-markdown.git", branch: "main"),
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.0"),
        .package(url: "https://github.com/lukilabs/beautiful-mermaid-swift.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "MarkdownCore",
            dependencies: [.product(name: "Markdown", package: "swift-markdown")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "MarkdownRender",
            dependencies: [
                "MarkdownCore",
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "BeautifulMermaid", package: "beautiful-mermaid-swift"),
            ],
            resources: [.copy("Themes")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "DownrightApp",
            dependencies: ["MarkdownCore", "MarkdownRender"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The §12 budget, made runnable: `swift run -c release drbench`.
        .executableTarget(
            name: "drbench",
            dependencies: [
                "MarkdownCore", "MarkdownRender",
                .product(name: "Markdown", package: "swift-markdown"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "down",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // The Quick Look extensions build as libraries here so they are
        // type-checked in CI.  Producing the actual `.appex` bundles needs an
        // Xcode app-extension target — see Docs/QUICKLOOK.md.
        .target(
            name: "DownrightQL",
            dependencies: ["MarkdownCore", "MarkdownRender"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .target(
            name: "DownrightThumb",
            dependencies: ["MarkdownCore", "MarkdownRender"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "MarkdownCoreTests",
            dependencies: ["MarkdownCore"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "MarkdownRenderTests",
            dependencies: ["MarkdownRender"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "DownrightAppTests",
            dependencies: ["DownrightApp"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
