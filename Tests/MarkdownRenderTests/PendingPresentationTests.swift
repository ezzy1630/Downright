import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@MainActor
@Suite(.serialized)
struct PendingPresentationTests {
    @Test func themeChangeWaitsForCurrentParseAndRestylesTheWholeDocument() throws {
        let original = "First paragraph has several words.\n\nSecond paragraph also has several words.\n"
        for replacement in [
            "Short.\n",
            "Changed first paragraph.\n\nUnchanged second paragraph.\n",
            original.replacingOccurrences(of: "First", with: "Other"),
        ] {
            let storage = NSTextStorage(string: original)
            let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
            view.update(document: MarkdownParser.parse(original), dirty: .wholesale)
            // Source edits land before their asynchronous semantic parse.
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: replacement)
            var sheet = view.styleSheet
            sheet.text = .systemPurple
            view.styleSheet = sheet
            #expect(storage.string == replacement)
            let document = MarkdownParser.parse(replacement)
            view.update(document: document, dirty: DirtySet(ranges: [NSRange(location: 0, length: 1)], isWholesale: false))
            for paragraph in replacement.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
                let offset = (replacement as NSString).range(of: paragraph).location
                let foreground = try #require(storage.attribute(.foregroundColor, at: offset, effectiveRange: nil) as? NSColor)
                #expect(foreground == sheet.text)
            }
            #expect(storage.string == replacement)
        }
    }

    @Test func deferredThemeRefreshPreservesSelectionAndCollapseChoice() throws {
        let original = "```swift\nlet value = 1\n```\n\nLast paragraph.\n"
        let replacement = original.replacingOccurrences(of: "Last", with: "Final")
        let storage = NSTextStorage(string: original)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        view.update(document: MarkdownParser.parse(original), dirty: .wholesale)
        view.setCodeBlockCollapsed(true, at: 0)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: replacement)
        let selection = (replacement as NSString).range(of: "value")
        view.setSourceSelectedRanges([selection])
        var sheet = view.styleSheet
        sheet.text = .systemPurple
        view.styleSheet = sheet
        let changed = (replacement as NSString).range(of: "Final")
        view.update(document: MarkdownParser.parse(replacement), dirty: DirtySet(ranges: [changed], isWholesale: false))
        let payload = try #require(storage.attribute(.drFragment, at: 0, effectiveRange: nil) as? FragmentPayload)
        #expect(view.isCollapsed(payload))
        #expect(view.sourceSelectedRange == selection)
        #expect(storage.string == replacement)
    }
}
