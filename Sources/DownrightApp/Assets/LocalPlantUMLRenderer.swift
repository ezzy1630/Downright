import AppKit
import Darwin
import MarkdownRender

/// A bounded, disposable CLI process keeps diagram preprocessing and JSCore
/// allocations outside the editor. Only the bundled executable can run.
@MainActor
final class LocalPlantUMLRenderer: PlantUMLRendering {
    private let images = NSCache<NSString, NSImage>()
    private let failures = NSCache<NSString, NSString>()
    private var waiting: [String: [@MainActor () -> Void]] = [:]
    private let queue = DispatchQueue(label: "com.ezzy.downright.plantuml", qos: .utility)
    private let executable: URL?

    init(executable: URL? = Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("down")) {
        self.executable = executable
        images.totalCostLimit = 32 * 1024 * 1024
        images.countLimit = 32
        failures.countLimit = 64
    }

    private nonisolated static func key(_ source: String, _ dark: Bool) -> String { (dark ? "dark:" : "light:") + source }

    nonisolated func cachedImage(source: String, dark: Bool) -> NSImage? {
        MainActor.assumeIsolated { images.object(forKey: Self.key(source, dark) as NSString) }
    }

    nonisolated func hasFailed(source: String, dark: Bool) -> Bool {
        MainActor.assumeIsolated { failures.object(forKey: Self.key(source, dark) as NSString) != nil }
    }

    nonisolated func render(source: String, dark: Bool, completion: @escaping @MainActor () -> Void) {
        MainActor.assumeIsolated { start(source: source, dark: dark, completion: completion) }
    }

    private func start(source: String, dark: Bool, completion: @escaping @MainActor () -> Void) {
        let key = Self.key(source, dark)
        if waiting[key] != nil { waiting[key]?.append(completion); return }
        guard images.object(forKey: key as NSString) == nil,
              failures.object(forKey: key as NSString) == nil else { return }
        guard source.utf8.count <= 32_768, let executable else {
            failures.setObject("unavailable", forKey: key as NSString)
            DispatchQueue.main.async { completion() }
            return
        }
        guard waiting.count < 16 else {
            // Capacity is temporary, unlike malformed source. Wake the
            // fragment after the queued workers have made room for its retry.
            queue.async { DispatchQueue.main.async { completion() } }
            return
        }
        waiting[key] = [completion]
        queue.async { [weak self] in
            let data = Self.renderSVG(source: source, dark: dark, executable: executable)
            let image = data.flatMap { SVGImageDecoder.decode($0, maxPixelDimension: 2048, scale: 2) }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if let image {
                    let cost = Int(image.size.width * image.size.height * 16)
                    self.images.setObject(image, forKey: key as NSString, cost: cost)
                } else {
                    self.failures.setObject("failed", forKey: key as NSString)
                }
                let callbacks = self.waiting.removeValue(forKey: key) ?? []
                callbacks.forEach { $0() }
            }
        }
    }

    nonisolated static func renderSVG(source: String, dark: Bool, executable: URL, timeout: TimeInterval = 5) -> Data? {
        guard source.utf8.count <= 32_768 else { return nil }
        let process = Process()
        process.executableURL = executable
        process.arguments = [dark ? "--downright-render-plantuml-dark" : "--downright-render-plantuml"]
        process.environment = ["PATH": "/usr/bin:/bin"]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) != -1 else { return nil }
        do { try process.run() } catch { return nil }
        let deadline = DispatchWorkItem {
            guard process.isRunning else { return }
            process.terminate()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.2) {
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        do {
            try input.fileHandleForWriting.write(contentsOf: Data(source.utf8))
            try input.fileHandleForWriting.close()
            var data = Data()
            while data.count <= 1_048_576 {
                let chunk = try output.fileHandleForReading.read(upToCount: min(65_536, 1_048_577 - data.count)) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
            if data.count > 1_048_576, process.isRunning { process.terminate() }
            process.waitUntilExit()
            guard process.terminationStatus == 0, !data.isEmpty, data.count <= 1_048_576 else { return nil }
            return data
        } catch {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
            return nil
        }
    }
}
