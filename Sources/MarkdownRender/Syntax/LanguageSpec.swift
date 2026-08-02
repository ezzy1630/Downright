import Foundation

// A language is *described*, not hand-coded.  One scanner (`GenericLexer`)
// reads these descriptions, so adding a language is data and fixing a scanning
// bug fixes it everywhere.  Only genuinely different shapes — markup, diff,
// markdown — get their own scanner.

struct BlockCommentSpec {
    var open: [UInt8]
    var close: [UInt8]
    /// Swift and Rust nest `/* /* */ */`; C does not.
    var nests: Bool
    /// Ruby's `=begin`/`=end` are only comments in column zero.
    var mustStartLine: Bool

    init(_ open: String, _ close: String, nests: Bool = false, mustStartLine: Bool = false) {
        self.open = Array(open.utf8)
        self.close = Array(close.utf8)
        self.nests = nests
        self.mustStartLine = mustStartLine
    }
}

struct StringSpec {
    var open: [UInt8]
    var close: [UInt8]
    /// `nil` for delimiters where backslash is literal (shell `'…'`, Go `` `…` ``).
    var escape: UInt8?
    /// When false an unescaped newline terminates the literal, so one stray
    /// quote cannot swallow the rest of the file.
    var spansLines: Bool

    init(_ open: String, _ close: String? = nil, escape: Character? = "\\", spansLines: Bool = false) {
        self.open = Array(open.utf8)
        self.close = Array((close ?? open).utf8)
        self.escape = escape.flatMap { $0.asciiValue }
        self.spansLines = spansLines
    }

    func escaping(_ enabled: Bool) -> StringSpec {
        var copy = self
        if !enabled { copy.escape = nil }
        return copy
    }
}

/// An identifier that turns an immediately following quote into a literal:
/// Python's `f"…"` and `r"…"`, Rust's `b"…"`.
struct StringPrefixSpec {
    /// Lowercased; matching is case-insensitive because Python accepts `F"…"`.
    var bytes: [UInt8]
    /// Python's `r` prefix makes backslash literal.
    var escapes: Bool

    init(_ text: String, escapes: Bool = true) {
        bytes = Array(text.lowercased().utf8)
        self.escapes = escapes
    }
}

enum RawStringStyle {
    /// `#"…"#`, `##"…"##`, `#"""…"""#`
    case swiftHash
    /// `r"…"`, `r#"…"#`, `br#"…"#`
    case rustHash
    /// `R"tag(…)tag"`
    case cppDelimited
}

struct LanguageSpec {
    var name: String

    // Words
    /// Built with `foldsCase: true` where the language is conventionally
    /// written in caps — SQL — so `SELECT` and `select` both highlight.
    var words: WordTable = .empty
    /// `MAX_RETRIES` — a convention shared by C, Python, Java, JS and Ruby.
    var allCapsAreConstants: Bool = false
    /// `Foo` — true where the language's own style guide reserves initial caps
    /// for types (Swift, Rust, Go, TS, Java, Ruby); false where it does not (C).
    var capitalisedAreTypes: Bool = false
    /// `foo(` reads as a call site.
    var callsAreFunctions: Bool = false

    // Trivia
    var lineComments: [[UInt8]] = []
    /// Bash only starts a comment at `#` when it begins a word, so `${x#y}` and
    /// `foo#bar` stay code.
    var lineCommentNeedsWordStart: Bool = false
    var blockComments: [BlockCommentSpec] = []

    // Literals
    /// Ordered longest-open-first so `"""` is tried before `"`.
    var strings: [StringSpec] = []
    var stringPrefixes: [StringPrefixSpec] = []
    var rawStrings: [RawStringStyle] = []

    // Identifiers
    /// Extra characters that may begin an identifier — CSS `--custom-prop`.
    /// Only honoured when followed by a letter or another extra-start, so
    /// `-5px` still lexes as a number.
    var identifierExtraStarts: [Unit] = []
    /// Extra characters that may continue one — YAML/TOML `my-key.sub`.
    var identifierExtraContinues: [Unit] = []

    // Sigils
    /// `@objc`, `@Override`, `@decorator`.
    var attributeSigils: [Unit] = []
    /// Objective-C `@"…"` — the sigil is part of the literal, not an attribute.
    var objcStringSigil: Bool = false
    /// Rust `#[derive(…)]` / `#![…]`, taken whole.
    var hashAttributes: Bool = false
    /// What `#name` means: a preprocessor directive in C, a compiler directive
    /// in Swift, a colour or id selector in CSS.  `nil` where `#` is not a sigil.
    var hashDirectiveToken: SyntaxToken?
    /// `$var`, `${var}`, Ruby's `@ivar` / `@@cvar`.
    var variableSigils: [Unit] = []
    /// Ruby `:symbol`.
    var hasSymbols: Bool = false
    /// Rust `'a` — a leading quote that is a lifetime, not a character literal.
    var hasLifetimes: Bool = false

    // Key/value shapes
    /// `:` for YAML/JSON/CSS, `=` for TOML.
    var keyTerminators: [Unit] = []
    var keysFromStrings: Bool = false
    var keysFromIdentifiers: Bool = false
    /// Requiring whitespace after the terminator is what separates a CSS
    /// declaration (`color: red`) from a pseudo-class (`a:hover`), and it is
    /// also YAML's own rule.
    var keyTerminatorNeedsSpace: Bool = false
    /// TOML `[section]` / `[[array.of.tables]]`.
    var bracketSectionHeaders: Bool = false
}
