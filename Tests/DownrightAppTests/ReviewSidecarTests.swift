import Foundation
import Testing
import MarkdownCore
@testable import DownrightApp

@Suite(.serialized)
struct ReviewSidecarTests {
    @Test func anchorResolvesExactAndFarShiftedSource() throws {
        let before = String(repeating: "prefix\n", count: 20) + "Keep this sentence." + "\ntrailer"
        let range = (before as NSString).range(of: "Keep this sentence.")
        let anchor = try #require(ReviewAnchorResolver.makeAnchor(in: before, range: range))
        #expect(ReviewAnchorResolver.resolve(anchor, in: before).status == .exact)

        let after = String(repeating: "new line\n", count: 20) + before
        let shifted = ReviewAnchorResolver.resolve(anchor, in: after)
        #expect(shifted.status == .shifted)
        #expect(shifted.range?.location == range.location + 9 * 20)
    }

    @Test func changedContextIsStaleAndMissingSourceIsOrphan() throws {
        let text = "before\nKeep this\nafter"
        let range = (text as NSString).range(of: "Keep this")
        let anchor = try #require(ReviewAnchorResolver.makeAnchor(in: text, range: range))
        #expect(ReviewAnchorResolver.resolve(anchor, in: "changed\nKeep this\nafter").status == .stale)
        #expect(ReviewAnchorResolver.resolve(anchor, in: "before\nGone\nafter").status == .orphan)
    }

    @Test func suggestionPreviewRequiresFreshSourceAndReturnsOneEdit() throws {
        let text = "Use the old API."
        let range = (text as NSString).range(of: "old API")
        let anchor = try #require(ReviewAnchorResolver.makeAnchor(in: text, range: range))
        let review = ReviewItem(kind: .suggestion, anchor: anchor, body: "Use new API", replacement: "new API")
        guard case .applied(let edit) = ReviewSidecarEngine.applySuggestion(review, to: text) else {
            Issue.record("fresh suggestion should produce an edit")
            return
        }
        #expect(edit.range == range)
        #expect(edit.replacement == "new API")
        guard case .stale = ReviewSidecarEngine.applySuggestion(review, to: "Use another API.") else {
            Issue.record("changed source must reject the suggestion")
            return
        }
    }

    @Test func reviewCreationKeepsCommentsAndSuggestionsSeparate() throws {
        let text = "Review this line."
        let range = (text as NSString).range(of: "this line")
        let comment = try #require(ReviewSidecarEngine.makeReview(
            kind: .comment, in: text, range: range, body: "Clarify this."
        ))
        let suggestion = try #require(ReviewSidecarEngine.makeReview(
            kind: .suggestion, in: text, range: range,
            body: "Use a shorter phrase.", replacement: "the line"
        ))
        #expect(comment.kind == .comment)
        #expect(comment.replacement == nil)
        #expect(suggestion.kind == .suggestion)
        #expect(suggestion.replacement == "the line")
    }

    @Test func sidecarStoreRoundTripsOutsideMarkdownFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("note.md")
        let anchor = try #require(ReviewAnchorResolver.makeAnchor(in: "Text", range: NSRange(location: 0, length: 4)))
        let original = ReviewSidecar(reviews: [
            ReviewItem(kind: .comment, anchor: anchor, body: "Check this"),
            ReviewItem(
                kind: .suggestion,
                anchor: anchor,
                body: "Replace this",
                replacement: "Other",
                state: .rejected
            ),
        ])
        let store = LocalReviewSidecarStore()
        try store.save(original, for: document)
        let loaded = try store.load(for: document)
        #expect(loaded == original)
        #expect(FileManager.default.fileExists(atPath: LocalReviewSidecarStore.sidecarURL(for: document).path))
    }

    @Test func criticMarkupIsDetectedButNeverGenerated() {
        let source = "++add++ and {--remove--} and ==mark=="
        #expect(ReviewSidecarEngine.criticMarkupRanges(in: source).count == 3)
        #expect(ReviewSidecarEngine.criticMarkupRanges(in: "plain markdown").isEmpty)
    }
}
