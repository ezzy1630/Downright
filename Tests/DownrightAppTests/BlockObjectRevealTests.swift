import AppKit
import NativeUITestSupport
import Testing

@testable import DownrightApp
@testable import MarkdownRender

/// The table from issue #68: four physical lines including the delimiter, with
/// bold and code in a cell.
private let issueTable = """
    | Metric | Value | Notes |
    |---|---:|---|
    | Latency P50 | 1.61 ms | **bold** and `code` |
    | Latency P99 | 1.98 ms | second row |
    """

/// Issue #68: a block object (table, image line, diagram, front matter, display
/// math) swaps to source only while the caret is strictly inside it. Every
/// physical line of the object has to switch together, on entry and on exit,
/// including after Source Focus hands a caret inside the object back to
/// Document view.
@Suite(.serialized)
@MainActor
struct BlockObjectRevealTests {
    @Test func tableRevealFollowsCaretInDocumentView() async throws {
        let source = "Paragraph before.\n\n" + issueTable + "\n\nParagraph after.\n"
        try await UIDriver.withDocument(source) { ui in
            let table = try ui.range(of: issueTable)
            let anchor = try ui.point(onText: "Paragraph before.")
            try expect(.rendered, table, in: ui, "Before any click, the table", required: true)

            for exit in ["Paragraph after.", "Paragraph before."] {
                let row = try ui.range(of: "| Latency P50")
                let fragment = try #require(
                    try layoutFragment(at: row.location, in: ui.textView) as? TableRowFragment,
                    "The body row is not drawn as a table row: \(describe(table, in: ui))")
                let frame = fragment.layoutFragmentFrame
                let origin = ui.textView.textContainerOrigin
                // A user clicks the first cell's text, not the invisible pipes.
                let cell = NSPoint(x: origin.x + frame.minX + 24, y: origin.y + frame.midY)
                try ui.input.click(at: ui.textView.convert(cell, to: nil))
                let caret = ui.selectedSourceRange
                try #require(caret.length == 0 && caret.location > table.location && caret.location < table.upperBound,
                             "Clicking the rendered row put the caret at \(caret), outside table \(table)")
                try expect(.source, table, in: ui, "With the caret at \(caret.location) inside it, the table")

                try ui.click(onText: exit)
                try expectCaret(beforeMiddleOf: exit, in: ui)
                try expect(.rendered, table, in: ui, "After clicking \(exit.debugDescription), the table")
            }

            ui.check(Data(ui.source.utf8) == Data(source.utf8) && !ui.isDirty,
                     "Entering and leaving the table changed source or dirty state")
            let settled = try ui.point(onText: "Paragraph before.")
            ui.check(abs(settled.y - anchor.y) < 1,
                     "The paragraph above the table moved from y \(anchor.y) to \(settled.y)")
        }
    }

    struct RevealCase: CustomTestStringConvertible, Sendable {
        let name: String
        /// Exact object source, without its trailing newline.
        let object: String
        /// Unique text inside the object that a Source Focus click targets.
        let insideText: String
        let leadsDocument: Bool
        let needsImage: Bool

        var testDescription: String { name }

        var document: String {
            leadsDocument
                ? object + "\n\nParagraph before.\n\nParagraph after.\n"
                : "Paragraph before.\n\n" + object + "\n\nParagraph after.\n"
        }

        static let all: [RevealCase] = [
            RevealCase(name: "table", object: issueTable, insideText: "Latency P50",
                       leadsDocument: false, needsImage: false),
            RevealCase(name: "image line", object: "![Pixel](pixel.png)", insideText: "Pixel",
                       leadsDocument: false, needsImage: true),
            RevealCase(name: "mermaid", object: "```mermaid\ngraph TD\n  Alpha --> Beta\n```", insideText: "Alpha",
                       leadsDocument: false, needsImage: false),
            RevealCase(name: "front matter", object: "---\ntitle: Alpha\nstatus: draft\n---", insideText: "Alpha",
                       leadsDocument: true, needsImage: false),
            // Display math already tracks its own reveal; it guards the shared path.
            RevealCase(name: "display math", object: "$$\nE = mc^2\n$$", insideText: "mc^2",
                       leadsDocument: false, needsImage: false),
        ]
    }

    @Test(arguments: RevealCase.all)
    func objectRestoresAfterSourceFocusRoundTrip(_ object: RevealCase) async throws {
        let source = object.document
        let files: [String: Data] = try object.needsImage ? ["pixel.png": pixelPNG()] : [:]
        try await UIDriver.withDocument(source, files: files) { ui in
            let range = try ui.range(of: object.object)
            let anchor: NSPoint? = try object.leadsDocument ? nil : ui.point(onText: "Paragraph before.")
            try expect(.rendered, range, in: ui, "Before Source Focus, the \(object.name)", required: true)

            for exit in ["Paragraph after.", "Paragraph before."] {
                try toggleSourceFocus(ui, expecting: .document)
                try ui.click(onText: object.insideText)
                let caret = ui.selectedSourceRange
                try #require(caret.length == 0 && caret.location > range.location && caret.location < range.upperBound,
                             "Source Focus click put the caret at \(caret), outside \(object.name) \(range)")

                try toggleSourceFocus(ui, expecting: .none)
                ui.check(ui.selectedSourceRange == caret,
                         "Returning to Document view moved the caret from \(caret) to \(ui.selectedSourceRange)")
                try expect(.source, range, in: ui,
                           "Back in Document view with the caret at \(caret.location) inside it, the \(object.name)")

                try ui.click(onText: exit)
                try expectCaret(beforeMiddleOf: exit, in: ui)
                try expect(.rendered, range, in: ui,
                           "After Source Focus and a click on \(exit.debugDescription), the \(object.name)")
            }

            ui.check(Data(ui.source.utf8) == Data(source.utf8) && !ui.isDirty,
                     "The Source Focus round trip changed source or dirty state")
            if let anchor {
                let settled = try ui.point(onText: "Paragraph before.")
                ui.check(abs(settled.y - anchor.y) < 1,
                         "The paragraph above the \(object.name) moved from y \(anchor.y) to \(settled.y)")
            }
        }
    }

    // MARK: - Observation

    enum Presentation: String { case rendered, source, mixed }

    /// The fragment TextKit actually holds for each physical line of `range`.
    private func lineFragments(in range: NSRange, of ui: UIDriver) throws -> [NSTextLayoutFragment] {
        let text = ui.source as NSString
        var fragments: [NSTextLayoutFragment] = []
        var location = range.location
        while location < range.upperBound {
            fragments.append(try layoutFragment(at: location, in: ui.textView))
            location = NSMaxRange(text.lineRange(for: NSRange(location: location, length: 0)))
        }
        return fragments
    }

    private func expect(
        _ expected: Presentation, _ range: NSRange, in ui: UIDriver, _ subject: String,
        required: Bool = false, sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let fragments = try lineFragments(in: range, of: ui)
        let actual: Presentation = fragments.allSatisfy { $0 is ProseFragment } ? .source
            : fragments.allSatisfy { !($0 is ProseFragment) } ? .rendered : .mixed
        let message = "\(subject) should be \(expected.rawValue) but its lines are \(actual.rawValue): "
            + fragments.map { String(describing: type(of: $0)) }.joined(separator: ", ")
        if required {
            try #require(actual == expected, Comment(rawValue: message), sourceLocation: sourceLocation)
        } else {
            ui.check(actual == expected, message, sourceLocation: sourceLocation)
        }
    }

    private func describe(_ range: NSRange, in ui: UIDriver) -> String {
        do {
            return try lineFragments(in: range, of: ui).map { String(describing: type(of: $0)) }.joined(separator: ", ")
        } catch {
            return "unavailable (\(error))"
        }
    }

    private func layoutFragment(at sourceOffset: Int, in textView: MarkdownTextView) throws -> NSTextLayoutFragment {
        let layout = try #require(textView.textLayoutManager)
        let storage = try #require(layout.textContentManager)
        let offset = textView.currentDisplayMap.textKitOffset(forSource: sourceOffset)
        let location = try #require(storage.location(storage.documentRange.location, offsetBy: offset))
        layout.ensureLayout(for: NSTextRange(location: location))
        return try #require(layout.textLayoutFragment(for: location))
    }

    // MARK: - Input

    /// The user's ⌘⇧E binding, through the editor's real key handling.
    private func toggleSourceFocus(_ ui: UIDriver, expecting focus: SourceFocus) throws {
        try ui.press("e", modifiers: [.command, .shift])
        try #require(ui.textView.sourceFocus == focus,
                     "⌘⇧E left Source Focus at \(String(describing: ui.textView.sourceFocus)) instead of \(String(describing: focus))")
        ui.layout()
    }

    /// `click(onText:)` aims inside the middle glyph, which AppKit resolves to
    /// the boundary before it.
    private func expectCaret(beforeMiddleOf text: String, in ui: UIDriver) throws {
        let range = try ui.range(of: text)
        let expected = NSRange(location: range.location + (range.length - 1) / 2, length: 0)
        ui.check(ui.selectedSourceRange == expected,
                 "Clicking \(text.debugDescription) selected \(ui.selectedSourceRange) instead of \(expected)")
    }

    private func pixelPNG() throws -> Data {
        let image = NSImage(size: NSSize(width: 32, height: 16), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        let cgImage = try #require(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        return try #require(NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]))
    }
}
