import Foundation

// The code-highlighting surface (§11.3).
//
// §12 names SwiftTreeSitter + Neon.  Taken literally that is one SPM grammar
// package per language — twenty-plus large C targets — to colour code *blocks*
// inside prose.  That is a bad trade for this app: the grammars dominate build
// time and binary size, and the Quick Look extension (§10, <400ms, <60MB) has
// to pay for them too.  So the shipped implementation is a hand-written
// single-pass lexer.
//
// `SyntaxHighlighter` is the seam that keeps the decision reversible: a
// tree-sitter backend conforms to this protocol and is swapped in at the one
// place the decoration engine reads a highlighter from, with no other change.

/// A highlight class.  Deliberately small — a themeable palette, not a grammar
/// taxonomy — because `CodeTheme` has exactly these slots and VS Code / Shiki
/// themes have to map onto it (§11.2).
public enum SyntaxToken: String, Sendable, CaseIterable {
    case plain, keyword, string, number, comment, type, function, variable
    case constant, `operator`, punctuation, attribute
    case diffAdded, diffRemoved, diffHeader
}

/// One classified span.  `range` is in UTF-16 units of the code string handed
/// to `highlight`, so it can be applied to text storage without conversion.
public struct SyntaxRun: Sendable, Equatable {
    public var range: NSRange
    public var token: SyntaxToken

    public init(range: NSRange, token: SyntaxToken) {
        self.range = range
        self.token = token
    }
}

/// Pluggable so a tree-sitter backend can replace the built-in one later
/// without touching the decoration engine.
///
/// Implementations must return runs that are ascending, non-overlapping, and
/// entirely inside the input.  The decoration engine applies them in order and
/// does not sort or clamp.
public protocol SyntaxHighlighter: AnyObject {
    func highlight(_ code: String, language: String?) -> [SyntaxRun]
    func supports(language: String) -> Bool
}
