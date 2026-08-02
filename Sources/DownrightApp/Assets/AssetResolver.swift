import Foundation
import MarkdownCore

/// The source form of a Markdown image destination.
enum AssetReferenceKind: String, Sendable {
    case relativeLocal
    case absoluteLocal
    case fileURL
    case remoteHTTP
    case dataURL
    case unsafe
    case malformed
}

struct AssetReference: Sendable {
    let source: String
    /// Exact source characters covered by `destinationRange`.  For a
    /// reference image this is the definition destination, not its use label.
    let sourceText: String
    let destinationRange: NSRange
    let imageRange: NSRange
    let altText: String
    let title: String?
    let kind: AssetReferenceKind
    let url: URL?
    let line: Int
}

struct AssetMetadata: Sendable {
    let exists: Bool
    let isDirectory: Bool
    let byteSize: Int64?
    let fileExtension: String?
    let contentIdentity: String?

    init(
        exists: Bool,
        isDirectory: Bool,
        byteSize: Int64?,
        fileExtension: String?,
        contentIdentity: String? = nil
    ) {
        self.exists = exists
        self.isDirectory = isDirectory
        self.byteSize = byteSize
        self.fileExtension = fileExtension
        self.contentIdentity = contentIdentity
    }
}

/// File access is injected.  Asset analysis itself does not touch the disk.
struct AssetProbe: Sendable {
    let metadata: @Sendable (URL) -> AssetMetadata?

    init(metadata: @escaping @Sendable (URL) -> AssetMetadata?) {
        self.metadata = metadata
    }
}

struct AssetResolutionContext: Sendable {
    let documentURL: URL?
    let workspaceRoot: URL?
    let maximumBytes: Int64
    let supportedExtensions: Set<String>

    init(
        documentURL: URL? = nil,
        workspaceRoot: URL? = nil,
        maximumBytes: Int64 = 10 * 1024 * 1024,
        supportedExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "svg", "webp", "heic", "avif"]
    ) {
        self.documentURL = documentURL
        self.workspaceRoot = workspaceRoot?.standardizedFileURL
        self.maximumBytes = maximumBytes
        self.supportedExtensions = supportedExtensions
    }
}

enum AssetReferenceParser {
    static func references(in document: ParsedDocument, context: AssetResolutionContext) -> [AssetReference] {
        var output: [AssetReference] = []
        document.root.walk { block in
            for inline in block.inlines {
                inline.walk { span in
                    guard case let .image(source, alt) = span.kind else { return }
                    guard let parsed = parseDestination(
                        in: document.text as NSString,
                        imageRange: span.range,
                        fallbackSource: source
                    ) else { return }
                    let resolved = resolvedDestination(
                        parsed,
                        document: document
                    )
                    let kind = classify(resolved.source)
                    output.append(AssetReference(
                        source: resolved.source,
                        sourceText: (document.text as NSString).substring(with: resolved.range),
                        destinationRange: resolved.range,
                        imageRange: span.range,
                        altText: alt,
                        title: resolved.title,
                        kind: kind,
                        url: resolve(resolved.source, kind: kind, context: context),
                        line: document.line(at: span.range.location)
                    ))
                }
            }
        }
        return output
    }

    private struct Destination {
        let source: String
        let range: NSRange
        let title: String?
        let referenceIdentifier: String?
    }

    private static func resolvedDestination(
        _ parsed: Destination,
        document: ParsedDocument
    ) -> Destination {
        guard let identifier = parsed.referenceIdentifier,
              let definition = document.linkReferences[identifier.lowercased()],
              let definitionRange = definitionDestinationRange(
                definition, in: document.text as NSString
              ) else { return parsed }
        return Destination(
            source: definition.destination,
            range: definitionRange,
            title: definition.title,
            referenceIdentifier: identifier
        )
    }

    private static func definitionDestinationRange(
        _ definition: LinkReference,
        in text: NSString
    ) -> NSRange? {
        let line = text.substring(with: definition.range) as NSString
        let close = line.range(of: "]:")
        guard close.location != NSNotFound else { return nil }
        var start = close.location + close.length
        while start < line.length,
              (line.character(at: start) == 0x20 || line.character(at: start) == 0x09) {
            start += 1
        }
        guard start < line.length else { return nil }
        var end = start
        if line.character(at: start) == 0x3C {
            start += 1
            end = start
            while end < line.length, line.character(at: end) != 0x3E { end += 1 }
            guard end < line.length else { return nil }
        } else {
            end = start
            while end < line.length {
                let character = line.character(at: end)
                if character == 0x20 || character == 0x09 { break }
                end += 1
            }
        }
        guard end > start else { return nil }
        return NSRange(
            location: definition.range.location + start,
            length: end - start
        )
    }

    private static func parseDestination(in text: NSString, imageRange: NSRange, fallbackSource: String) -> Destination? {
        let rawString = text.substring(with: imageRange)
        let raw = rawString as NSString
        guard rawString.hasPrefix("![") else { return nil }
        var index = 2
        var depth = 1
        while index < raw.length {
            let character = raw.character(at: index)
            if character == 0x5C { index += 2; continue }
            if character == 0x5B { depth += 1 }
            if character == 0x5D {
                depth -= 1
                if depth == 0 { break }
            }
            index += 1
        }
        guard index < raw.length else { return nil }
        var cursor = index + 1
        while cursor < raw.length, raw.character(at: cursor) == 0x20 { cursor += 1 }
        guard cursor < raw.length, raw.character(at: cursor) == 0x28 else {
            // Reference images do not carry a destination at the use site.
            // Keep the label until `resolvedDestination` maps it to the exact
            // destination in the shared definition.
            let labelRange = raw.range(
                of: "]", options: [],
                range: NSRange(location: cursor, length: raw.length - cursor)
            )
            if cursor < raw.length, raw.character(at: cursor) == 0x5B,
               labelRange.location != NSNotFound {
                let range = NSRange(
                    location: imageRange.location + cursor,
                    length: labelRange.location + 1 - cursor
                )
                let identifier = raw.substring(with: NSRange(
                    location: cursor + 1, length: labelRange.location - cursor - 1
                ))
                return Destination(
                    source: fallbackSource, range: range, title: nil,
                    referenceIdentifier: identifier
                )
            }
            return nil
        }
        cursor += 1
        while cursor < raw.length, raw.character(at: cursor) == 0x20 { cursor += 1 }
        let destinationStart = cursor
        var destinationEnd = cursor
        if cursor < raw.length, raw.character(at: cursor) == 0x3C {
            cursor += 1
            let angleDestinationStart = cursor
            destinationEnd = cursor
            while cursor < raw.length, raw.character(at: cursor) != 0x3E { cursor += 1 }
            destinationEnd = cursor
            let source = raw.substring(with: NSRange(
                location: angleDestinationStart,
                length: destinationEnd - angleDestinationStart
            ))
            guard !source.isEmpty else { return nil }
            return Destination(
                source: source,
                range: NSRange(
                    location: imageRange.location + angleDestinationStart,
                    length: destinationEnd - angleDestinationStart
                ),
                title: parseTitle(in: raw, after: cursor + 1), referenceIdentifier: nil
            )
        } else {
            var nesting = 0
            while cursor < raw.length {
                let character = raw.character(at: cursor)
                if character == 0x5C { cursor += 2; continue }
                if character == 0x28 { nesting += 1 }
                if character == 0x29 {
                    if nesting == 0 { break }
                    nesting -= 1
                }
                if nesting == 0, character == 0x20 || character == 0x09 { break }
                cursor += 1
            }
            destinationEnd = cursor
        }
        let source = raw.substring(with: NSRange(location: destinationStart, length: destinationEnd - destinationStart))
        guard !source.isEmpty else { return nil }
        let destinationRange = NSRange(
            location: imageRange.location + destinationStart,
            length: destinationEnd - destinationStart
        )
        return Destination(
            source: source, range: destinationRange,
            title: parseTitle(in: raw, after: cursor), referenceIdentifier: nil
        )
    }

    private static func parseTitle(in raw: NSString, after cursor: Int) -> String? {
        var index = cursor
        while index < raw.length,
              (raw.character(at: index) == 0x20 || raw.character(at: index) == 0x09) {
            index += 1
        }
        guard index < raw.length else { return nil }
        let quote = raw.character(at: index)
        guard quote == 0x22 || quote == 0x27 else { return nil }
        index += 1
        let start = index
        while index < raw.length, raw.character(at: index) != quote {
            if raw.character(at: index) == 0x5C { index += 2 } else { index += 1 }
        }
        guard index < raw.length else { return nil }
        return raw.substring(with: NSRange(location: start, length: index - start))
    }

    static func classify(_ source: String) -> AssetReferenceKind {
        guard !source.isEmpty, !source.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return .malformed }
        let lower = source.lowercased()
        if lower.hasPrefix("data:") { return URL(string: source) == nil ? .malformed : .dataURL }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            guard let url = URL(string: source), url.host != nil else { return .malformed }
            return .remoteHTTP
        }
        if lower.hasPrefix("file://") {
            guard let url = URL(string: source), url.path.isEmpty == false else { return .malformed }
            return .fileURL
        }
        if let colon = source.firstIndex(of: ":"),
           !source[..<colon].contains("/"), !source[..<colon].contains("\\") {
            return .unsafe
        }
        if source.hasPrefix("/") || source.hasPrefix("~") { return .absoluteLocal }
        if source.contains("\0") || source == "." || source == ".." { return .unsafe }
        return .relativeLocal
    }

    private static func resolve(_ source: String, kind: AssetReferenceKind, context: AssetResolutionContext) -> URL? {
        switch kind {
        case .relativeLocal:
            guard let documentURL = context.documentURL else { return nil }
            let path = localPath(source)
            return documentURL.deletingLastPathComponent().appendingPathComponent(path).standardizedFileURL
        case .absoluteLocal:
            let path = localPath((source as NSString).expandingTildeInPath)
            return URL(fileURLWithPath: path).standardizedFileURL
        case .fileURL:
            return URL(string: source)?.standardizedFileURL
        default:
            return nil
        }
    }

    private static func localPath(_ source: String) -> String {
        let end = source.firstIndex(where: { $0 == "?" || $0 == "#" }) ?? source.endIndex
        let path = String(source[..<end])
        return path.removingPercentEncoding ?? path
    }
}
