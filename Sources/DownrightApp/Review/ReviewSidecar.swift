import Foundation
import MarkdownCore

enum ReviewKind: String, Codable, CaseIterable {
    case comment
    case suggestion
}

enum ReviewState: String, Codable, CaseIterable {
    case open
    case resolved
    case rejected
}

enum ReviewAnchorStatus: String, Codable {
    case exact
    case shifted
    case stale
    case orphan
}

/// A source anchor keeps the original UTF-16 range and enough context to find
/// it again after an edit.  The selected source is local sidecar data only.
struct ReviewAnchor: Codable, Equatable, Hashable {
    let range: NSRange
    let selectedText: String
    let beforeFingerprint: String
    let afterFingerprint: String

    init(range: NSRange, selectedText: String, beforeFingerprint: String, afterFingerprint: String) {
        self.range = range
        self.selectedText = selectedText
        self.beforeFingerprint = beforeFingerprint
        self.afterFingerprint = afterFingerprint
    }

    private enum CodingKeys: String, CodingKey { case location, length, selectedText, beforeFingerprint, afterFingerprint }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            range: NSRange(
                location: try values.decode(Int.self, forKey: .location),
                length: try values.decode(Int.self, forKey: .length)
            ),
            selectedText: try values.decode(String.self, forKey: .selectedText),
            beforeFingerprint: try values.decode(String.self, forKey: .beforeFingerprint),
            afterFingerprint: try values.decode(String.self, forKey: .afterFingerprint)
        )
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(range.location, forKey: .location)
        try values.encode(range.length, forKey: .length)
        try values.encode(selectedText, forKey: .selectedText)
        try values.encode(beforeFingerprint, forKey: .beforeFingerprint)
        try values.encode(afterFingerprint, forKey: .afterFingerprint)
    }
}

struct ReviewItem: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: ReviewKind
    let anchor: ReviewAnchor
    let body: String
    let replacement: String?
    var state: ReviewState

    init(
        id: UUID = UUID(),
        kind: ReviewKind,
        anchor: ReviewAnchor,
        body: String,
        replacement: String? = nil,
        state: ReviewState = .open
    ) {
        self.id = id
        self.kind = kind
        self.anchor = anchor
        self.body = body
        self.replacement = replacement
        self.state = state
    }

    var title: String { kind == .comment ? "Comment" : "Suggestion" }
}

struct ReviewSidecar: Codable, Equatable {
    var version: Int = 1
    var reviews: [ReviewItem] = []
}

protocol ReviewSidecarStore: AnyObject {
    func load(for documentURL: URL) throws -> ReviewSidecar
    func save(_ sidecar: ReviewSidecar, for documentURL: URL) throws
}

final class LocalReviewSidecarStore: ReviewSidecarStore {
    /// Sidecars are repository-controlled input. Bound the read before JSON
    /// decoding so a checkout cannot make opening a small Markdown file pull
    /// an arbitrarily large adjacent review file into memory.
    static let maximumBytes = 8 * 1024 * 1024

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func load(for documentURL: URL) throws -> ReviewSidecar {
        let url = Self.sidecarURL(for: documentURL)
        guard FileManager.default.fileExists(atPath: url.path) else { return ReviewSidecar() }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count <= Self.maximumBytes else { throw CocoaError(.fileReadTooLarge) }
        return try decoder.decode(ReviewSidecar.self, from: data)
    }

    func save(_ sidecar: ReviewSidecar, for documentURL: URL) throws {
        let url = Self.sidecarURL(for: documentURL)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try encoder.encode(sidecar).write(to: url, options: .atomic)
    }

    static func sidecarURL(for documentURL: URL) -> URL {
        documentURL.appendingPathExtension("downright-reviews.json")
    }
}

struct ReviewResolution: Equatable {
    let status: ReviewAnchorStatus
    let range: NSRange?
}

enum ReviewApplyResult {
    case applied(TextEdit)
    case stale(ReviewAnchorStatus)
}

enum ReviewSidecarEngine {
    static func makeReview(
        kind: ReviewKind,
        in text: String,
        range: NSRange,
        body: String,
        replacement: String? = nil
    ) -> ReviewItem? {
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let anchor = ReviewAnchorResolver.makeAnchor(in: text, range: range) else { return nil }
        return ReviewItem(kind: kind, anchor: anchor, body: body, replacement: replacement)
    }

    static func applySuggestion(_ review: ReviewItem, to text: String) -> ReviewApplyResult {
        guard review.kind == .suggestion, let replacement = review.replacement else {
            return .stale(.orphan)
        }
        let resolution = ReviewAnchorResolver.resolve(review.anchor, in: text)
        guard let range = resolution.range, resolution.status == .exact || resolution.status == .shifted else {
            return .stale(resolution.status)
        }
        let source = (text as NSString).substring(with: range)
        guard source == review.anchor.selectedText else { return .stale(.stale) }
        return .applied(TextEdit(range: range, replacement: replacement, summary: "Apply Suggestion"))
    }

    static func criticMarkupRanges(in text: String) -> [NSRange] {
        let patterns = ["\\+\\+[^+]+\\+\\+", "\\{--[^-]+--\\}", "==[^=]+=="]
        let source = text as NSString
        return patterns.flatMap { pattern in
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return [NSRange]() }
            return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { $0.range }
        }
    }
}
