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
        #expect(rail.accessibilityLabel() == "Markdown gutter")
        #expect(rail.accessibilityCustomActions()?.map(\.name) == ["Toggle current heading"])
        #expect(density.accessibilityRole() == .scrollBar)
        #expect(density.accessibilityCustomActions()?.map(\.name) == ["Show document outline"])
        #expect(view.accessibilityRole() == .textArea)
        #expect(view.accessibilityCustomActions()?.map(\.name) == ["Open link at caret", "Copy code block"])
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
}
