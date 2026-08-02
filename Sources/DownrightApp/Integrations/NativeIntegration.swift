import AppKit
import Foundation
import UniformTypeIdentifiers

/// The small command surface shared by Services, App Intents, and future
/// share extensions.  Integrations never reach into a window controller: they
/// resolve a file, then hand it to this one owner.
@available(macOS 14.0, *)
@MainActor
public final class IntegrationRegistry {
    public static let shared = IntegrationRegistry()

    public typealias OpenHandler = @MainActor (URL) -> Void

    public var openHandler: OpenHandler?

    public init(openHandler: OpenHandler? = nil) {
        self.openHandler = openHandler
    }

    @discardableResult
    public func open(_ url: URL) -> Bool {
        let fileURL = url.standardizedFileURL
        guard NativeIntegrationPolicy.accepts(fileURL),
              FileManager.default.fileExists(atPath: fileURL.path)
        else { return false }
        openHandler?(fileURL)
        return openHandler != nil
    }
}

/// Pure routing rules.  Keeping these separate makes extension entry points
/// testable without starting AppKit or touching a user's files.
@available(macOS 14.0, *)
public enum NativeIntegrationPolicy {
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd",
    ]

    public static func accepts(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        return markdownExtensions.contains(url.pathExtension.lowercased())
    }

    public static func normalizedPath(_ value: String) -> URL? {
        let expanded = (value as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded).standardizedFileURL
        return accepts(url) ? url : nil
    }
}

/// Input decoding for an AppKit Services provider.  Finder sends file URLs;
/// text editors may send a path string, so support both without guessing at
/// arbitrary URLs or shell commands.
@available(macOS 14.0, *)
public enum ServiceInputResolver {
    public static func urls(from pasteboard: NSPasteboard) -> [URL] {
        let candidates = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] ?? []
        let fileURLs = candidates.filter {
            NativeIntegrationPolicy.accepts($0) && FileManager.default.fileExists(atPath: $0.path)
        }
        if !fileURLs.isEmpty { return fileURLs }

        guard let text = pasteboard.string(forType: .string) else { return [] }
        return text
            .split(whereSeparator: \.isNewline)
            .compactMap { NativeIntegrationPolicy.normalizedPath(String($0).trimmingCharacters(in: .whitespaces)) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}

/// Principal class for the optional macOS Services registration.  The service
/// itself is declared by the app's Info.plist; this class only handles the
/// pasteboard and delegates opening to `IntegrationRegistry`.
@available(macOS 14.0, *)
@MainActor
public final class DownrightServicesProvider: NSObject {
    @objc(openMarkdownInDownright:userData:error:)
    public func openMarkdown(
        _ pasteboard: NSPasteboard,
        userData: String?,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = ServiceInputResolver.urls(from: pasteboard)
        guard !urls.isEmpty else {
            error.pointee = "The selection does not contain a Markdown file." as NSString
            return
        }
        let opened = urls.filter { IntegrationRegistry.shared.open($0) }.count
        if opened == 0 {
            error.pointee = "Downright is not ready to open this file." as NSString
        }
    }
}
