import Foundation
import Testing
@testable import MarkdownRender

@Suite struct IndexingOptimizationTests {
    @Test(arguments: ["\n", "\r", "\r\n", "\u{85}", "\u{2028}", "\u{2029}"])
    func paragraphSeparatorsAcrossScanBoundaries(_ separator: String) {
        for prefixLength in [0, 15, 16, 8191, 8192] {
            let prefix = String(repeating: "a", count: prefixLength)
            let text = prefix + separator + "café 😀\0tail" + separator
            let first = prefixLength + separator.utf16.count
            let expected = [0, first, text.utf16.count]
            #expect(ParagraphIndex(text: text as NSString).starts == expected)
            #expect(ParagraphIndex(text: NSMutableString(string: text)).starts == expected)
        }
    }

    @Test func asciiNULDoesNotTerminateParagraphIndex() {
        let text = "abc\0def\r\nghi\0jkl\nmno\r"
        #expect(ParagraphIndex(text: text as NSString).starts == [0, 9, 17, 21])
        #expect(ParagraphIndex(text: NSMutableString(string: text)).starts == [0, 9, 17, 21])
    }

    @Test func keywordLookupPreservesPrecedenceAndExactSpelling() {
        let table = WordTable(foldsCase: true, [
            (.keyword, ["IF", "class", "long_reserved_word"]),
            (.type, ["if", "Class", "Integer"]),
        ])
        for spelling in ["if", "IF", "Class", "LONG_RESERVED_WORD"] {
            let units = Array(spelling.utf16)
            #expect(table.lookup(units, units.indices) == .keyword)
        }
        let units = Array("Integer café 😀 iffy".utf16)
        #expect(table.lookup(units, 0..<7) == .type)
        #expect(table.lookup(units, 8..<12) == nil)
        #expect(table.lookup(units, 13..<15) == nil)
        #expect(table.lookup(units, 16..<20) == nil)
    }
}
