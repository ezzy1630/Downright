import Foundation
import MarkdownCore

/// Stable keys used by the Spotlight importer and by metadata tests.  The
/// importer emits only local facts derived from the file; it never evaluates
/// code fences or follows links.
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

/// Shared metadata extraction logic for an MDImporter extension.  Keep file
/// IO at this boundary so the parser remains the source of truth and tests can
/// inject text directly.
@available(macOS 14.0, *)
public enum SpotlightMetadataImporter {
    public static func metadata(forText text: String, url: URL) -> SpotlightMetadata {
        let document = MarkdownParser.parse(text, options: .structureOnly)
        let title = document.headings.first?.title
            ?? document.frontMatter?.fields.first(where: { $0.key.lowercased() == "title" })?.value
            ?? url.deletingPathExtension().lastPathComponent
        let keywords = document.frontMatter?.fields
            .filter { ["tag", "tags", "keyword", "keywords"].contains($0.key.lowercased()) }
            .flatMap { $0.value.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } }
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
        guard NativeIntegrationPolicy.accepts(url) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let (text, _) = try DocumentIO.read(contentsOf: url)
        return metadata(forText: text, url: url)
    }

    public static func contentType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "md", "markdown", "mdown", "mkd": "net.daringfireball.markdown"
        default: "com.unrulyagency.downright.markdown"
        }
    }
}
