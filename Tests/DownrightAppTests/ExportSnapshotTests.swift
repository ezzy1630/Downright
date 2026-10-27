import AppKit
import Testing
import MarkdownCore
import MarkdownRender
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct ExportSnapshotTests {
    @Test(arguments: [(10.0, 60), (100.0, 100), (120.0, 120)])
    func exportedMeasureUsesTheSupportedRange(requested: Double, expected: Int) {
        var theme = ThemeStore.shared.current
        theme.typography.measureCharacters = requested
        let html = HTMLExporter(document: MarkdownParser.parse("Body"), theme: theme,
                                title: "Measure", baseDirectory: nil, imageProvider: nil).html()
        #expect(html.contains("max-width: \(expected)ch;"))
    }

    @Test func fullWidthExportHasNoCharacterCap() {
        var theme = ThemeStore.shared.current
        theme.typography.measureCharacters = TypographyConfig.fullWidthMeasure
        let html = HTMLExporter(document: MarkdownParser.parse("Body"), theme: theme,
                                title: "Measure", baseDirectory: nil, imageProvider: nil).html()
        #expect(html.contains("max-width: none;"))
        #expect(!html.contains("max-width: 1000ch;"))
    }

    @Test(arguments: [false, true])
    func exportIncludesEditsBeforeAsyncParsingFinishes(forPrint: Bool) {
        let controller = DocumentWindowController()
        defer { controller.close() }
        let document = controller.markdownDocument
        document.adopt(text: "# Original\n", displayURL: nil)
        document.storage.replaceCharacters(in: NSRange(location: 2, length: 8), with: "Current")
        #expect(document.parsed.text != document.text)

        let html = controller.exporter(forPrint: forPrint).html()
        #expect(html.contains(">Current</h1>"))
        #expect(!html.contains(">Original</h1>"))
        #expect(document.text == "# Current\n")
    }
}
