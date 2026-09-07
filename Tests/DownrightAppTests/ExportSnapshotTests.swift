import AppKit
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct ExportSnapshotTests {
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
