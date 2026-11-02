import AppKit
import JavaScriptCore

/// Runs only in the CLI worker. The host gives this process a wall-clock
/// deadline; untrusted diagram preprocessing never runs in the editor process.
public enum PlantUMLRuntime {
    public static let maximumSourceBytes = 32_768
    public static let maximumSVGBytes = 1_048_576

    public enum RenderError: Error {
        case unavailable, invalidSource, renderingFailed, oversizedOutput
    }

    public static func render(source: String, dark: Bool) throws -> Data {
        guard source.utf8.count <= maximumSourceBytes,
              source.contains("@startuml"), source.contains("@enduml") else {
            throw RenderError.invalidSource
        }
        guard let context = JSContext() else { throw RenderError.unavailable }
        let measure: @convention(block) (String, String, Double, String) -> [Double] = { text, family, size, style in
            let pointSize = min(256, max(1, size.isFinite ? size : 14))
            let font = NSFont(name: family, size: pointSize) ?? NSFont.systemFont(ofSize: pointSize)
            var traits: NSFontTraitMask = []
            if style.contains("bold") { traits.insert(.boldFontMask) }
            if style.contains("italic") { traits.insert(.italicFontMask) }
            let resolved = NSFontManager.shared.convert(font, toHaveTrait: traits)
            return [Double((text as NSString).size(withAttributes: [.font: resolved]).width),
                    Double(resolved.ascender), Double(-resolved.descender)]
        }
        let base64: @convention(block) (String) -> [UInt8] = { Array(Data(base64Encoded: $0) ?? Data()) }
        context.setObject(measure, forKeyedSubscript: "nativeMeasure" as NSString)
        context.setObject(base64, forKeyedSubscript: "nativeBase64" as NSString)
        let adjacent = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("../Resources/PlantUML/runtime.js").standardizedFileURL
        let url: URL
        if let adjacent, FileManager.default.fileExists(atPath: adjacent.path) {
            url = adjacent
        } else {
            guard let bundled = Bundle.module.url(forResource: "runtime", withExtension: "js", subdirectory: "PlantUML") else {
                throw RenderError.unavailable
            }
            url = bundled
        }
        context.evaluateScript(try String(contentsOf: url, encoding: .utf8), withSourceURL: url)
        guard context.exception == nil else { throw RenderError.renderingFailed }
        context.objectForKeyedSubscript("startRender")?.call(withArguments: [source, dark])
        for _ in 0..<10_000 {
            guard context.exception == nil else { throw RenderError.renderingFailed }
            if let value = context.objectForKeyedSubscript("result"), !value.isNull, !value.isUndefined,
               let svg = value.toString(), svg.hasPrefix("<svg") {
                let data = Data(svg.utf8)
                guard data.count <= maximumSVGBytes else { throw RenderError.oversizedOutput }
                return data
            }
            if let error = context.objectForKeyedSubscript("failure"), !error.isNull, !error.isUndefined {
                throw RenderError.renderingFailed
            }
            context.evaluateScript("pump()")
        }
        throw RenderError.renderingFailed
    }
}
