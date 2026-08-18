import CoreServices
import Foundation
import MarkdownCore

/// Stable keys shared by Core Spotlight, the filesystem importer, and tests.
/// The importer emits only local facts derived from the file; it never
/// evaluates code fences or follows links.
@available(macOS 14.0, *)
public enum SpotlightMetadataKey {
    public static let title = "kMDItemTitle"
    public static let textContent = "kMDItemTextContent"
    public static let keywords = "kMDItemKeywords"
    public static let kind = "kMDItemKind"
    public static let contentType = "kMDItemContentType"
}

@available(macOS 14.0, *)
public struct SpotlightMetadata: Equatable, Sendable {
    public var title: String
    public var textContent: String
    public var keywords: [String]
    public var contentType: String

    public init(title: String, textContent: String, keywords: [String], contentType: String) {
        self.title = title
        self.textContent = textContent
        self.keywords = keywords
        self.contentType = contentType
    }

    public var attributes: [String: Any] {
        [
            SpotlightMetadataKey.title: title,
            SpotlightMetadataKey.textContent: textContent,
            SpotlightMetadataKey.keywords: keywords,
            SpotlightMetadataKey.kind: "Markdown document",
            SpotlightMetadataKey.contentType: contentType,
        ]
    }
}

/// Parser-backed metadata extraction used by both the running app and the
/// background Spotlight importer. File IO stays at this boundary so the
/// parser remains the source of truth and tests can inject text directly.
@available(macOS 14.0, *)
public enum SpotlightMetadataImporter {
    public static let markdownExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd",
    ]

    public static func metadata(forText text: String, url: URL) -> SpotlightMetadata {
        let document = MarkdownParser.parse(text, options: .structureOnly)
        let title = document.headings.first?.title
            ?? document.frontMatter?.fields.first(where: { $0.key.lowercased() == "title" })?.value
            ?? url.deletingPathExtension().lastPathComponent
        let keywords = document.frontMatter?.fields
            .filter { ["tag", "tags", "keyword", "keywords"].contains($0.key.lowercased()) }
            .flatMap { field in
                field.value
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            .filter { !$0.isEmpty }
            .map { String($0) } ?? []
        return SpotlightMetadata(
            title: title,
            textContent: text,
            keywords: keywords,
            contentType: contentType(for: url)
        )
    }

    public static func metadata(at url: URL) throws -> SpotlightMetadata {
        guard accepts(url) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard let head = DocumentIO.readHead(contentsOf: url, limit: 2 * 1024 * 1024) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return metadata(forText: head, url: url)
    }

    public static func accepts(_ url: URL) -> Bool {
        url.isFileURL && markdownExtensions.contains(url.pathExtension.lowercased())
    }

    public static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": "net.daringfireball.markdown"
        default: "com.ezzy.downright.markdown"
        }
    }
}

/// C-callable bridge used by the CFPlugIn shim. The importer process has no
/// AppKit or window-server dependency; it fills the dictionary handed to it
/// by Spotlight with values produced by the shared parser.
@available(macOS 14.0, *)
@_cdecl("DownrightSpotlightPopulateMetadata")
public func downrightSpotlightPopulateMetadata(
    _ attributes: CFMutableDictionary?,
    _ contentTypeUTI: CFString?,
    _ pathToFile: CFString?
) -> Bool {
    guard let attributes, let pathToFile else { return false }
    let path = pathToFile as String
    let url = URL(fileURLWithPath: path)
    guard let metadata = try? SpotlightMetadataImporter.metadata(at: url) else { return false }

    let values: [(CFString, CFTypeRef)] = [
        (kMDItemTitle, metadata.title as CFString),
        (kMDItemTextContent, metadata.textContent as CFString),
        (kMDItemKeywords, metadata.keywords as CFArray),
        (kMDItemKind, "Markdown document" as CFString),
    ]
    for (key, value) in values {
        CFDictionarySetValue(
            attributes,
            Unmanaged.passUnretained(key).toOpaque(),
            Unmanaged.passUnretained(value).toOpaque()
        )
    }
    return true
}
