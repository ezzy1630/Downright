import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

/// P1-6/7 + P2-18 regression: a nested list item must keep its own deeper
/// indent.  The root cause was `applyBase` spreading a parent item's paragraph
/// style across its whole subtree; NSTextStorage's paragraph fixup then
/// flattened the child's indent back to the parent's.
@Test @MainActor func nestedTaskKeepsItsIndent() throws {
    let text = """
    - [ ] top task
      - [x] nested task
        - [ ] doubly nested
    - [ ] sibling task
    """
    let storage = NSTextStorage(string: text)
    let document = MarkdownParser.parse(text)
    let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    let engine = DecorationEngine(styleSheet: sheet)
    engine.policy = RenderMode.read.policy
    engine.decorate(storage, document: document, dirty: .wholesale)

    func headIndent(at offset: Int) -> CGFloat? {
        guard offset < storage.length else { return nil }
        return (storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.headIndent
    }
    func offset(of needle: String) -> Int {
        (text as NSString).range(of: needle).location
    }

    let top = headIndent(at: offset(of: "top task"))
    let nested = headIndent(at: offset(of: "nested task"))
    let doubly = headIndent(at: offset(of: "doubly nested"))
    let sibling = headIndent(at: offset(of: "sibling task"))

    print("PROBE indents: top=\(top ?? -1) nested=\(nested ?? -1) doubly=\(doubly ?? -1) sibling=\(sibling ?? -1)")
    #expect(top != nil && nested != nil && doubly != nil && sibling != nil)
    #expect(nested! > top!, "nested item lost its indent")
    #expect(doubly! > nested!, "doubly-nested item lost its indent")
    #expect(abs(sibling! - top!) < 0.5, "sibling task should match the top level")
}

/// P1-6/7: every task line, whatever its depth, owns its paragraph style and
/// the parent's style never leaks onto the child's paragraph.
@Test @MainActor func paragraphStyleNeverLeaksAcrossChildren() throws {
    let text = """
    - [ ] parent
      - [x] child one
      - [ ] child two
    """
    let storage = NSTextStorage(string: text)
    let document = MarkdownParser.parse(text)
    let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    let engine = DecorationEngine(styleSheet: sheet)
    engine.policy = RenderMode.read.policy
    engine.decorate(storage, document: document, dirty: .wholesale)

    let childRange = (text as NSString).range(of: "child one")
    var childStyle = NSRange(location: 0, length: 0)
    let childHead = (storage.attribute(.paragraphStyle, at: childRange.location,
                                       effectiveRange: &childStyle) as? NSParagraphStyle)?.headIndent
    // The child's style must not extend back over the parent's paragraph.
    let parentOffset = (text as NSString).range(of: "parent").location
    let parentStyle = (storage.attribute(.paragraphStyle, at: parentOffset, effectiveRange: nil) as? NSParagraphStyle)
    #expect(childHead != nil)
    #expect(childStyle.location > parentOffset, "child paragraph style leaked back onto the parent line")
}

/// P0-3/4 guard: a fenced code block is a leaf block — every paragraph inside
/// it, fences included, must keep the code paragraph style (indent + inset),
/// so the chrome band starts at the code's own indent and never at the
/// document edge.
@Test @MainActor func codeBlockKeepsItsParagraphStyleAcrossFences() throws {
    let text = """
    ```swift
    let x = 1
    let y = 2
    ```
    """
    let storage = NSTextStorage(string: text)
    let document = MarkdownParser.parse(text)
    let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    let engine = DecorationEngine(styleSheet: sheet)
    engine.policy = RenderMode.read.policy
    engine.decorate(storage, document: document, dirty: .wholesale)

    func headIndent(at offset: Int) -> CGFloat {
        (storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? -1
    }
    let first = (text as NSString).range(of: "```swift").location
    let body = (text as NSString).range(of: "let x = 1").location
    let last = (text as NSString).range(of: "```").location
    let fh = headIndent(at: first)
    let bh = headIndent(at: body)
    let lh = headIndent(at: last)
    print("CODEBLOCK indents: fence=\(fh) body=\(bh) close=\(lh)")
    #expect(fh > 0, "opening fence lost the code paragraph style")
    #expect(bh > 0, "code body lost the code paragraph style")
    #expect(lh > 0, "closing fence lost the code paragraph style")
    #expect(abs(fh - bh) < 0.5 && abs(lh - bh) < 0.5, "fences and body must share one indent")
}

/// P1-6/7: the task checkbox must sit fully inside the reserved marker column
/// — box plus gap plus ≥ 4pt clearance — so it can never be clipped at the
/// fragment origin, at any nesting depth.
@Test @MainActor func taskMarkerColumnReservesCheckboxGeometry() throws {
    let text = """
    - [ ] top
      - [ ] nested
    """
    let storage = NSTextStorage(string: text)
    let document = MarkdownParser.parse(text)
    let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    let engine = DecorationEngine(styleSheet: sheet)
    engine.policy = RenderMode.read.policy
    engine.decorate(storage, document: document, dirty: .wholesale)

    func headIndent(at offset: Int) -> CGFloat {
        (storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
    }
    let top = headIndent(at: (text as NSString).range(of: "top").location)
    print("MARKERCOLUMN top headIndent=\(top) required=\(RenderMetrics.taskMarkerColumn)")
    #expect(top >= RenderMetrics.taskMarkerColumn, "task marker column is too narrow for the checkbox")
}

/// P0 regression (StyleKey + ProgramKey): a bullet and a task at the same
/// depth with identical label text share a hash/cache key.  The task must keep
/// the full checkbox column and the bullet the narrow bullet column — never
/// whichever one decorated first.  A tasks-only probe could not catch a
/// mixed-document collision, so this interleaves a bullet before a task.
@Test @MainActor func bulletAndTaskAtSameDepthKeepSeparateColumns() throws {
    let text = """
    - alpha
    - [ ] alpha
    """
    let storage = NSTextStorage(string: text)
    let document = MarkdownParser.parse(text)
    let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    let engine = DecorationEngine(styleSheet: sheet)
    engine.policy = RenderMode.read.policy
    engine.decorate(storage, document: document, dirty: .wholesale)

    func headIndent(at offset: Int) -> CGFloat {
        (storage.attribute(.paragraphStyle, at: offset, effectiveRange: nil) as? NSParagraphStyle)?.headIndent ?? 0
    }
    let ns = text as NSString
    let bulletOffset = ns.range(of: "alpha").location
    let rest = NSRange(location: bulletOffset + 1, length: ns.length - bulletOffset - 1)
    let taskOffset = ns.range(of: "alpha", options: [], range: rest).location
    let bullet = headIndent(at: bulletOffset)
    let task = headIndent(at: taskOffset)
    print("MIXCOLUMN bullet=\(bullet) task=\(task) taskRequired=\(RenderMetrics.taskMarkerColumn)")
    #expect(task >= RenderMetrics.taskMarkerColumn, "task lost its checkbox column to a cached bullet style")
    #expect(bullet < RenderMetrics.taskMarkerColumn, "bullet took the task checkbox column")
    #expect(bullet < task, "both rows share one marker column")
}

/// P2-21/23: malformed front matter (a stray `t---` opener) must be reported
/// as a diagnostic rather than silently styling the leak as body prose; valid
/// front matter must not be flagged.
@Test @MainActor func malformedFrontMatterIsReported() throws {
    let malformed = "t---\ntitle: Sample\n---\n\nBody"
    let good = "---\ntitle: Sample\n---\n\nBody"

    let bad = DocumentHealth.analyze(malformed)
    print("FRONTMATTER bad ids: \(bad.map { $0.id })")
    #expect(bad.contains { $0.id == "frontmatter.malformed-delimiter" })

    let ok = DocumentHealth.analyze(good)
    #expect(!ok.contains { $0.id.hasPrefix("frontmatter.") })
}

/// P0-2: block math renders through the shared renderer with 8pt of padding
/// on every edge, so a tall formula can never clip through its line box.
@Test @MainActor func blockMathGetsPadding() throws {
    let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
    guard let unpadded = MathRenderer.image(latex: "\\frac{a}{b}", display: true,
                                            pointSize: 18, color: sheet.text),
          let padded = MathRenderer.image(latex: "\\frac{a}{b}", display: true,
                                          pointSize: 18, color: sheet.text, padding: 8) else {
        Issue.record("math renderer returned nil")
        return
    }
    print("MATH sizes: unpadded=\(unpadded.size) padded=\(padded.size)")
    #expect(padded.size.width - unpadded.size.width >= 15.9, "block math should carry 8pt of air per side")
    #expect(padded.size.height - unpadded.size.height >= 15.9)
}

/// P0-5 regression: a task label must end at its own line terminator, never
/// swallowing nested children's text.  The list item's `contentRange` is the
/// source of truth — the derived task list reads it directly.
@Test @MainActor func taskLabelExcludesChildren() throws {
    let text = """
    - [ ] Notarise and publish
      - [ ] Sparkle appcast
      - [x] Ad-hoc signing for local runs
    """
    let document = MarkdownParser.parse(text)
    print("TASKLABEL labels: \(document.tasks.map { $0.text })")
    #expect(document.tasks.count == 3)
    #expect(document.tasks[0].text == "Notarise and publish", "parent label swallowed its children: \(document.tasks[0].text)")
    #expect(document.tasks[1].text == "Sparkle appcast")
    #expect(document.tasks[2].text == "Ad-hoc signing for local runs")
}
