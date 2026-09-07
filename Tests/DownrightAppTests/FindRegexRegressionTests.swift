import Foundation
import Testing
@testable import DownrightApp

struct FindRegexRegressionTests {
    @Test func replacementPreservesLookaroundCaptures() throws {
        let text = "foo bar foo baz"
        let query = FindQuery(text: #"(foo)(?= (bar|baz))"#, isRegex: true)
        let matches = FindEngine.matches(in: text, query: query)
        #expect(matches.count == 2)
        let first = try #require(matches.first)
        #expect(FindEngine.replacement(for: first, in: text, query: query, template: "$2:$1") == "bar:foo")
        let edits = FindEngine.replaceAllEdits(in: text, query: query, template: "$2:$1")
        #expect(edits.map(\.replacement) == ["bar:foo", "baz:foo"])
        #expect(edits.map(\.range) == matches)
    }

    @Test func replacementKeepsOriginalAnchorSemantics() throws {
        let text = "foo bar"
        let query = FindQuery(text: #"(foo$)|(foo)"#, isRegex: true)
        let match = try #require(FindEngine.matches(in: text, query: query).first)
        #expect(FindEngine.replacement(for: match, in: text, query: query, template: "$1/$2") == "/foo")
        #expect(FindEngine.replaceAllEdits(in: text, query: query, template: "$1/$2").first?.replacement == "/foo")
    }

    @Test func replacementPreservesSelectionScope() throws {
        let text = "outside foo bar outside"
        let query = FindQuery(text: #"^(foo)(?= bar$)"#, isRegex: true, scope: NSRange(location: 8, length: 7))
        let match = try #require(FindEngine.matches(in: text, query: query).first)
        #expect(FindEngine.replacement(for: match, in: text, query: query, template: "$1!") == "foo!")
        #expect(FindEngine.replaceAllEdits(in: text, query: query, template: "$1!").first?.replacement == "foo!")
    }

    @Test func wholeWordAppliesToEveryAlternativeWithoutShiftingCaptures() {
        let text = "foobar foo bar"
        let query = FindQuery(text: #"(foo)|(bar)"#, isRegex: true, wholeWord: true)
        #expect(FindEngine.matches(in: text, query: query) == [NSRange(location: 7, length: 3), NSRange(location: 11, length: 3)])
        #expect(FindEngine.replaceAllEdits(in: text, query: query, template: "$1/$2").map(\.replacement) == ["foo/", "/bar"])
    }

    @Test func literalReplacementLeavesDollarSignsAndBackslashesUntouched() {
        let query = FindQuery(text: "foo")
        #expect(FindEngine.replaceAllEdits(in: "foo foo", query: query, template: #"$1\bar"#).map(\.replacement) == [#"$1\bar"#, #"$1\bar"#])
    }
}
