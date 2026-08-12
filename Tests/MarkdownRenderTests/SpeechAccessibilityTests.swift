import AppKit
import MarkdownCore
import Testing

@testable import MarkdownRender

@MainActor
@Suite("Speech accessibility", .serialized)
struct SpeechAccessibilityTests {
    @Test("speech uses rendered text and maps words to source")
    func renderedTextAndSourceMapping() {
        let source = "Read **this** now."
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 300),
            storage: NSTextStorage(string: source)
        )
        view.mode = .read
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)

        let whole = NSRange(location: 0, length: (source as NSString).length)
        let spoken = view.renderedStringForSpeech(sourceRange: whole)
        #expect(spoken == "Read this now.")

        let word = (spoken as NSString).range(of: "this")
        #expect(view.sourceRangeForSpeechRange(word, within: whole) == NSRange(location: 7, length: 4))
    }

    @Test("custom rails and rendered actions expose explicit accessibility roles")
    func rendererAccessibilitySurface() {
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 300),
            storage: NSTextStorage(string: "# Heading\n"))
        let rail = GutterRailView(textView: view)
        let density = DensityGutterView(styleSheet: view.styleSheet)

        #expect(rail.accessibilityRole() == .group)
        #expect(rail.accessibilityLabel() == "Document margin")
        #expect(rail.accessibilityCustomActions()?.map(\.name) == [
            "Choose current heading level", "Toggle current section fold",
        ])
        #expect(density.accessibilityRole() == .scrollBar)
        #expect(density.accessibilityCustomActions()?.map(\.name) == ["Show document outline"])
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityCustomActions()?.map(\.name) == ["Open link at caret", "Copy code block"])
    }

    @Test("heading rail does not activate a caret heading from empty margin")
    func headingRailHitIsBoundToChip() {
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 300),
            storage: NSTextStorage(string: "# Heading\n\nBody\n")
        )
        view.mode = .read
        view.update(document: MarkdownParser.parse(view.textStorage?.string ?? ""), dirty: .wholesale)
        let rail = GutterRailView(textView: view)
        rail.frame = NSRect(x: 0, y: 0, width: RenderMetrics.gutterWidth, height: 300)
        rail.reload()

        // The caret can still make the heading active, but empty rail space is
        // not a heading control. Only the drawn H-chip is actionable.
        view.setSourceSelectedRanges([NSRange(location: 0, length: 0)])
        #expect(rail.headingIndex(at: NSPoint(x: rail.bounds.midX, y: 8)) == nil)
    }

    @Test("rendered fragments expose semantic accessibility children")
    func renderedFragmentChildren() {
        let source = """
        | A | B |
        | - | - |
        | 1 | 2 |

        $$x^2$$

        ```mermaid
        graph LR; A-->B
        ```
        """
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            storage: NSTextStorage(string: source)
        )
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)

        let labels = (view.accessibilityChildren() ?? []).compactMap {
            ($0 as? NSAccessibilityElement)?.accessibilityLabel()
        }
        #expect(labels.contains("Markdown table"))
        #expect(labels.contains("Display math"))
        #expect(labels.contains("Mermaid diagram"))
    }

    @Test("rendered front matter is an accessible edit action")
    func frontMatterAccessibilityAction() throws {
        let source = "---\ntitle: Draft\nauthor: Ezzy\n---\n\n# Body\n"
        let view = MarkdownTextView(
            frame: NSRect(x: 0, y: 0, width: 640, height: 480),
            storage: NSTextStorage(string: source)
        )
        let delegate = FrontMatterActivationProbe()
        view.markdownDelegate = delegate
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)

        let action = try #require((view.accessibilityChildren() ?? []).compactMap {
            $0 as? NSAccessibilityElement
        }.first { $0.accessibilityLabel() == "Edit document metadata" })
        #expect(action.accessibilityRole() == .button)
        #expect(action.isAccessibilityEnabled())
        #expect(action.accessibilityPerformPress())
        #expect(delegate.activations == 1)
    }
}

@MainActor
private final class FrontMatterActivationProbe: MarkdownTextViewDelegate {
    var activations = 0

    func markdownTextView(_ view: MarkdownTextView, didActivateFrontMatterAt range: NSRange) {
        activations += 1
    }
}
