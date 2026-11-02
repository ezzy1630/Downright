import AppKit
import MarkdownRender
import Testing
@testable import DownrightApp

private final class PlantUMLWorkerTestAnchor: NSObject {}

struct PlantUMLWorkerTests {
    @MainActor
    @Test func transientFailureCanRetryAfterCooldown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plantuml-retry-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker")
        try Data("#!/bin/sh\ncat >/dev/null\nexit 1\n".utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let renderer = try #require(LocalPlantUMLRenderer(executable: worker, retryDelay: 0))
        let source = "@startuml\nA -> B\n@enduml"
        await withCheckedContinuation { continuation in
            renderer.render(source: source, dark: false) { continuation.resume() }
        }
        #expect(!renderer.hasFailed(source: source, dark: false))
        try Data("#!/bin/sh\ncat >/dev/null\nprintf '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>'\n".utf8).write(to: worker)
        await withCheckedContinuation { continuation in
            renderer.render(source: source, dark: false) { continuation.resume() }
        }
        #expect(renderer.cachedImage(source: source, dark: false) != nil)
    }

    @Test func missingResourcesExitCleanlyInsteadOfTrapping() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plantuml-missing-resources-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let copied = root.appendingPathComponent("down")
        try FileManager.default.copyItem(at: executable, to: copied)
        let process = Process()
        process.executableURL = copied
        process.arguments = ["--downright-render-plantuml"]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data("@startuml\nA -> B\n@enduml".utf8))
        try input.fileHandleForWriting.close()
        process.waitUntilExit()
        #expect(process.terminationReason == .exit)
        #expect(process.terminationStatus == 65)
    }

    @MainActor
    @Test func capacityDefersRenderingWithoutCachingFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plantuml-capacity-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker")
        try Data("#!/bin/sh\ncat >/dev/null\nsleep 0.02\nprintf '<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"10\" height=\"10\"><rect width=\"10\" height=\"10\"/></svg>'\n".utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let renderer = try #require(LocalPlantUMLRenderer(executable: worker))
        let overflow = "@startuml\nOverflow -> Worker\n@enduml"
        await withCheckedContinuation { continuation in
            for index in 0..<16 {
                renderer.render(source: "@startuml\nA -> B: \(index)\n@enduml", dark: false) {}
            }
            renderer.render(source: overflow, dark: false) { continuation.resume() }
            #expect(!renderer.hasFailed(source: overflow, dark: false))
        }
        #expect(!renderer.hasFailed(source: overflow, dark: false))
        await withCheckedContinuation { continuation in
            renderer.render(source: overflow, dark: false) { continuation.resume() }
        }
        #expect(renderer.cachedImage(source: overflow, dark: false) != nil)
    }

    @Test func workerThatExitsBeforeReadingCannotTerminateTheHost() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plantuml-early-exit-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        #expect(LocalPlantUMLRenderer.renderSVG(source: String(repeating: "x", count: 32_768), dark: false, executable: worker) == nil)
    }

    private var executable: URL {
        if let path = ProcessInfo.processInfo.environment["DOWNRIGHT_TEST_CLI_EXECUTABLE"] {
            return URL(fileURLWithPath: path)
        }
        return Bundle(for: PlantUMLWorkerTestAnchor.self).bundleURL
            .deletingLastPathComponent().appendingPathComponent("down")
    }

    @Test func officialEngineRendersCommonDiagramsThroughBundledCLI() throws {
        let examples = [
            ("Alice -> Bob: Hello", ["Alice", "Bob", "Hello"]),
            ("class User {\n +name: String\n}\nUser --> Account", ["User", "Account", "name"]),
            ("start\n:Read document;\n:Render diagram;\nstop", ["Read document", "Render diagram"]),
            ("[*] --> Idle\nIdle --> Active : Open\nActive --> [*]", ["Idle", "Active", "Open"]),
            ("component Client\ncomponent Server\nClient --> Server", ["Client", "Server"]),
        ]
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        for (body, labels) in examples {
            let source = "@startuml\n\(body)\n@enduml"
            let data = try #require(LocalPlantUMLRenderer.renderSVG(source: source, dark: false, executable: executable))
            let svg = try #require(String(data: data, encoding: .utf8))
            #expect(svg.hasPrefix("<svg"))
            #expect(!svg.contains("An error has occurred"))
            #expect(!svg.contains("Syntax Error"))
            #expect(!svg.contains("#00000000"), "AppKit needs SVG opacity attributes for transparent fills")
            for label in labels { #expect(svg.contains(label), "Missing \(label)") }
            #expect(SVGImageDecoder.decode(data, maxPixelDimension: 2048) != nil)
        }
    }

    @Test func retinaRasterKeepsLogicalDiagramSize() throws {
        let svg = Data("<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"100\" height=\"50\"><rect width=\"100\" height=\"50\" fill=\"red\"/></svg>".utf8)
        let image = try #require(SVGImageDecoder.decode(svg, maxPixelDimension: 2048, scale: 2))
        #expect(image.size == NSSize(width: 100, height: 50))
        let bitmap = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        #expect(bitmap.width == 200)
        #expect(bitmap.height == 100)
    }

    @Test func darkAppearanceAndBlockedIncludesRemainLocal() throws {
        let source = "@startuml\nAlice -> Bob: Hello\n@enduml"
        let light = try #require(LocalPlantUMLRenderer.renderSVG(source: source, dark: false, executable: executable))
        let dark = try #require(LocalPlantUMLRenderer.renderSVG(source: source, dark: true, executable: executable))
        #expect(light != dark)
        let blocked = "@startuml\n!include /etc/passwd\nAlice -> Bob: Hello\n@enduml"
        let data = try #require(LocalPlantUMLRenderer.renderSVG(source: blocked, dark: false, executable: executable))
        let svg = try #require(String(data: data, encoding: .utf8))
        #expect(!svg.contains("root:*"))
        #expect(svg.contains("include") || svg.contains("error"))
        #expect(LocalPlantUMLRenderer.renderSVG(source: String(repeating: "x", count: 32_769), dark: false, executable: executable) == nil)
    }

    @Test func stalledWorkerIsKilledWithinDeadline() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("plantuml-worker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("worker")
        try Data("#!/bin/sh\ntrap '' TERM\nwhile :; do :; done\n".utf8).write(to: worker)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: worker.path)
        let start = Date()
        #expect(LocalPlantUMLRenderer.renderSVG(source: "@startuml\nA -> B\n@enduml", dark: false, executable: worker, timeout: 0.1) == nil)
        #expect(Date().timeIntervalSince(start) < 2)
    }
}
