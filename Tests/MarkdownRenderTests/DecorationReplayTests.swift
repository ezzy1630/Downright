// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import AppKit
import MarkdownCore
import Testing

@testable import MarkdownRender

/// Decorating the same text twice with one engine must give the same
/// attributes: the second pass replays cached programs instead of decorating
/// live, and the two paths must not diverge.
@Suite("Decoration replay")
struct DecorationReplayTests {
    static let text = """
    # Title

    - A plain bullet
    - A bullet with `inline code`
      - A nested bullet
    1. First
    2. Second

    - [x] done
    - [ ] open

    Closing paragraph.
    """

    private func paragraphStyles(_ storage: NSTextStorage) -> [String] {
        var out: [String] = []
        (storage.string as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: storage.length), options: .byParagraphs
        ) { _, range, _, _ in
            guard range.length > 0 else { return }
            var effective = NSRange()
            let style = storage.attribute(.paragraphStyle, at: range.location, longestEffectiveRange: &effective, in: range) as? NSParagraphStyle
            out.append("\(range.location) run=\(effective.length)/\(range.length) before=\(style?.paragraphSpacingBefore ?? -1) after=\(style?.paragraphSpacing ?? -1) head=\(style?.headIndent ?? -1)")
        }
        return out
    }

    @Test("A second decoration of the same text matches the first")
    func replayMatchesLive() {
        let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua)!)
        let engine = DecorationEngine(styleSheet: sheet)
        engine.policy = RenderMode.read.policy
        let document = MarkdownParser.parse(Self.text)

        let first = NSTextStorage(string: Self.text)
        engine.decorate(first, document: document, dirty: .wholesale)
        let second = NSTextStorage(string: Self.text)
        engine.decorate(second, document: document, dirty: .wholesale)

        let a = paragraphStyles(first), b = paragraphStyles(second)
        for (lhs, rhs) in zip(a, b) where lhs != rhs {
            Issue.record("live \(lhs)\nreplay \(rhs)")
        }
        #expect(a.count == b.count)
    }
}
