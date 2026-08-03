import Foundation

// MARK: - Fenced language flags (§4.1)
//
// The info string decides which fragment renderer a fence gets.  `mermaid`
// becomes a diagram and `math`/`latex` become a display formula; everything
// else stays a code block.  `diff` stays a code block deliberately — §11.3
// wants real diff colouring, which is a code-block treatment, not a separate
// node kind — so its language is preserved rather than consumed.

enum FenceLanguage {
    static let mermaidAliases: Set<String> = ["mermaid"]
    static let mathAliases: Set<String> = ["math", "latex", "tex", "katex"]

    enum Kind {
        case mermaid
        case math
        case code
    }

    static func kind(for language: String?) -> Kind {
        guard let language = language?
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
            .split(separator: " ").first.map(String.init)
        else { return .code }
        if mermaidAliases.contains(language) { return .mermaid }
        if mathAliases.contains(language) { return .math }
        return .code
    }

    /// Guesses a language for §9.1's `codeFenceLanguages` rule.  Deliberately a
    /// short list of high-precision signals: a wrong hint is worse than none,
    /// because it silently mis-highlights the block forever after.
    static func guess(from code: String) -> String? {
        let lines = code.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty else { return nil }
        let body = code

        if let first = lines.first, first.hasPrefix("#!") {
            let lower = first.lowercased()
            if lower.contains("python") { return "python" }
            if lower.contains("node") { return "javascript" }
            if lower.contains("ruby") { return "ruby" }
            if lower.contains("bash") || lower.contains("/sh") || lower.contains("zsh") { return "bash" }
        }

        // Every line a shell prompt is unambiguous; a lone `$` is not.
        let commandLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !commandLines.isEmpty, commandLines.allSatisfy({ $0.hasPrefix("$ ") || $0.hasPrefix("% ") }) {
            return "bash"
        }

        if contains(body, any: ["func ", "let ", "var ", "guard ", "@objc", "import Foundation"]),
           contains(body, any: ["func ", "guard ", "-> ", "@objc"]) {
            return "swift"
        }
        if contains(body, any: ["def ", "import ", "from "]),
           contains(body, any: ["def ", "self.", "elif ", "__init__"]) {
            return "python"
        }
        if contains(body, any: ["const ", "let ", "function ", "=> "]),
           contains(body, any: ["{", ";"]) {
            return "javascript"
        }
        if body.contains("<") && body.contains(">"),
           contains(body, any: ["<html", "<div", "<span", "<p>", "<!DOCTYPE", "</"]) {
            return "html"
        }
        // Leading whitespace is legal in JSON documents, so trim before
        // sniffing an opening brace or bracket.
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedBody.hasPrefix("{") || trimmedBody.hasPrefix("["),
           contains(body, any: ["\": ", "\":"]) {
            return "json"
        }
        return nil
    }

    private static func contains(_ haystack: String, any needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }
}
