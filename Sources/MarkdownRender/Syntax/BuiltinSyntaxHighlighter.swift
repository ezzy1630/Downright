import Foundation

/// The shipped `SyntaxHighlighter` (see `SyntaxContracts.swift` for why this is
/// a hand-written lexer rather than tree-sitter).
///
/// Stateless and therefore safe to share; `shared` exists so the decoration
/// engine does not rebuild language tables per code block.
public final class BuiltinSyntaxHighlighter: SyntaxHighlighter {
    public static let shared = BuiltinSyntaxHighlighter()

    public init() {}

    /// An unknown or absent language yields no runs — the code block still gets
    /// its mono font and tint, it is simply uncoloured.  That is the right
    /// failure: guessing a language colours the wrong words confidently.
    public func highlight(_ code: String, language: String?) -> [SyntaxRun] {
        guard
            let raw = language,
            let canonical = BuiltinSyntaxHighlighter.canonicalLanguage(raw),
            let scanner = LanguageCatalog.scanner(for: canonical),
            !code.isEmpty
        else { return [] }
        return scanner.highlight(Array(code.utf16))
    }

    public func supports(language: String) -> Bool {
        BuiltinSyntaxHighlighter.canonicalLanguage(language) != nil
    }

    /// Canonical name for an alias: "ts" -> "typescript", "sh" -> "bash".
    public static func canonicalLanguage(_ raw: String) -> String? {
        LanguageCatalog.canonical(raw)
    }

    public static var supportedLanguages: [String] { LanguageCatalog.canonicalNames }
}
