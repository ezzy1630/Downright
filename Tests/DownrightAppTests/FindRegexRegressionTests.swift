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

struct FindSessionReplacementTests {
    @Test func selectedReplacementUsesOriginalLookaroundCaptures() throws {
        let session = FindSession()
        let text = "foo bar foo baz"
        session.update(query: FindQuery(text: #"(foo)(?= (bar|baz))"#, isRegex: true), in: text, caret: 0)
        let first = try #require(session.replacementEdit(in: text, template: "$2:$1"))
        #expect(first.range == NSRange(location: 0, length: 3))
        #expect(first.replacement == "bar:foo")
        session.advance(forward: true)
        let second = try #require(session.replacementEdit(in: text, template: "$2:$1"))
        #expect(second.range == NSRange(location: 8, length: 3))
        #expect(second.replacement == "baz:foo")
    }

    @Test func selectedReplacementPreservesAnchoredSelectionScope() throws {
        let session = FindSession()
        let text = "outside foo bar outside"
        let query = FindQuery(text: #"^(foo)(?= bar$)"#, isRegex: true, scope: NSRange(location: 8, length: 7))
        session.update(query: query, in: text, caret: 0)
        let edit = try #require(session.replacementEdit(in: text, template: "$1!"))
        #expect(edit.range == NSRange(location: 8, length: 3))
        #expect(edit.replacement == "foo!")
    }

    @Test func sameLengthEditRefreshesCapturesBeforeReplacement() throws {
        let session = FindSession()
        session.update(query: FindQuery(text: #"(foo)(?= (bar|baz))"#, isRegex: true), in: "foo bar", caret: 0)
        let edit = try #require(session.replacementEdit(in: "foo baz", template: "$2:$1"))
        #expect(edit.range == NSRange(location: 0, length: 3))
        #expect(edit.replacement == "baz:foo")
    }

    @Test func canonicalUnicodeEqualityDoesNotReuseStaleSourceRanges() throws {
        let session = FindSession()
        let original = "[\u{e9}] tail"
        let edited = "[e\u{301}] tail"
        #expect(original == edited)
        session.update(query: FindQuery(text: #"\[(.*?)\]"#, isRegex: true), in: original, caret: 0)
        let edit = try #require(session.replacementEdit(in: edited, template: "$1"))
        #expect(edit.range == NSRange(location: 0, length: 4))
        #expect(Array(edit.replacement.utf16) == Array("e\u{301}".utf16))
    }

    @Test func removedMatchAndClearedSessionProduceNoReplacement() {
        let session = FindSession()
        session.update(query: FindQuery(text: "foo"), in: "foo", caret: 0)
        #expect(session.replacementEdit(in: "bar", template: "new") == nil)
        #expect(session.matches.isEmpty)
        session.update(query: FindQuery(text: "foo"), in: "foo", caret: 0)
        session.clear()
        #expect(session.replacementEdit(in: "foo", template: "new") == nil)
    }

    @Test func changingQueryReplacesCachedMatchesAndKeepsLiteralTemplate() throws {
        let session = FindSession()
        session.update(query: FindQuery(text: "foo", isRegex: true), in: "foo bar", caret: 0)
        session.update(query: FindQuery(text: "bar"), in: "foo bar", caret: 0)
        let edit = try #require(session.replacementEdit(in: "foo bar", template: #"$1\tail"#))
        #expect(edit.range == NSRange(location: 4, length: 3))
        #expect(edit.replacement == #"$1\tail"#)
    }
}
