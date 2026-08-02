import Foundation
import MarkdownCore

/// The revision attached to one immutable source snapshot.
///
/// A value type makes it difficult to accidentally compare a parse result from
/// one source edit with the revision of another edit.
struct MarkdownParseRevision: RawRepresentable, Comparable, Sendable {
    let rawValue: UInt64

    init(rawValue: UInt64) {
        self.rawValue = rawValue
    }

    static let zero = MarkdownParseRevision(rawValue: 0)

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    func advanced() -> Self {
        Self(rawValue: rawValue &+ 1)
    }
}

struct MarkdownParseResult: Sendable {
    let revision: MarkdownParseRevision
    let text: String
    let document: ParsedDocument
    let dirty: DirtySet
}

/// Pure parse work.  The app runs the worker in a detached user-initiated task;
/// tests can inject a deterministic async closure without sleeping.
struct MarkdownParseWorker: Sendable {
    typealias Operation = @Sendable (
        _ text: String,
        _ previous: ParsedDocument,
        _ revision: MarkdownParseRevision
    ) async -> MarkdownParseResult

    let operation: Operation

    init(operation: Operation? = nil) {
        self.operation = operation ?? Self.defaultOperation
    }

    func run(
        text: String,
        previous: ParsedDocument,
        revision: MarkdownParseRevision
    ) async -> MarkdownParseResult {
        await operation(text, previous, revision)
    }

    private static let defaultOperation: Operation = { text, previous, revision in
        let document = MarkdownParser.parse(text)
        let dirty = ASTDiff.dirtySet(old: previous, new: document)
        return MarkdownParseResult(
            revision: revision, text: text, document: document, dirty: dirty
        )
    }
}
