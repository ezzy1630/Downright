import Foundation
import Testing
@testable import MarkdownCore

@Suite struct DbgCR {
    @Test func dump() {
        let s = "| A | B |\r\n|---|---|\r\n| one | two |\r\n| three | four |\r\n"
        let d = MarkdownParser.parse(s)
        let result = TableEditing.propose(d, operation: .moveRow(from: 2, to: 1))
        guard let p = result.proposal else { print("no proposal"); return }
        let applied = p.applying(to: s)!
        print("R=cnt(\(p.replacement.utf8.count)) A=cnt(\(applied.utf8.count)) S=cnt(\(s.utf8.count))")
        print("equal:", applied == p.replacement)
    }
}
