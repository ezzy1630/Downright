import Foundation

/// Which scanner a canonical language name uses.
enum LanguageScanner {
    case generic(LanguageSpec)
    case markup
    case diff
    case markdown
    /// A known language we deliberately do not colour.
    case unstyled

    func highlight(_ units: [Unit]) -> [SyntaxRun] {
        switch self {
        case .generic(let spec): return GenericLexer.highlight(units, spec: spec)
        case .markup: return MarkupLexer.highlight(units)
        case .diff: return DiffLexer.highlight(units)
        case .markdown: return MarkdownLexer.highlight(units)
        case .unstyled: return []
        }
    }
}

/// The language table.  Specs are built on first use and cached: constructing
/// twenty `WordTable`s eagerly would cost the launch budget (§12) for languages
/// a given document never mentions.
enum LanguageCatalog {
    static let canonicalNames: [String] = [
        "bash", "c", "cpp", "css", "diff", "go", "html", "java", "javascript",
        "json", "jsx", "markdown", "objc", "plaintext", "python", "ruby", "rust",
        "sql", "swift", "toml", "tsx", "typescript", "xml", "yaml",
    ]

    /// Alias → canonical.  Agents label fences with whatever the ecosystem calls
    /// the language, so this has to be generous.
    static let aliases: [String: String] = [
        "sh": "bash", "shell": "bash", "zsh": "bash", "console": "bash", "shell-session": "bash",
        "c++": "cpp", "cxx": "cpp", "cc": "cpp", "hpp": "cpp", "h": "c",
        "objective-c": "objc", "objectivec": "objc", "obj-c": "objc", "m": "objc", "mm": "objc",
        "js": "javascript", "mjs": "javascript", "cjs": "javascript", "node": "javascript",
        "ts": "typescript", "mts": "typescript", "cts": "typescript",
        "py": "python", "python3": "python",
        "rs": "rust", "rb": "ruby", "golang": "go",
        "yml": "yaml", "jsonc": "json", "json5": "json",
        "htm": "html", "svg": "xml", "xhtml": "html", "plist": "xml",
        "md": "markdown", "mdown": "markdown", "mkd": "markdown",
        "patch": "diff", "udiff": "diff",
        "text": "plaintext", "txt": "plaintext", "plain": "plaintext", "none": "plaintext",
        "postgres": "sql", "postgresql": "sql", "mysql": "sql", "sqlite": "sql",
        "scss": "css", "less": "css",
    ]

    private static let lock = NSLock()
    private nonisolated(unsafe) static var cache: [String: LanguageScanner] = [:]

    static func canonical(_ raw: String) -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        if canonicalNames.contains(key) { return key }
        return aliases[key]
    }

    static func scanner(for canonicalName: String) -> LanguageScanner? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[canonicalName] { return cached }
        guard let built = build(canonicalName) else { return nil }
        cache[canonicalName] = built
        return built
    }

    private static func build(_ name: String) -> LanguageScanner? {
        switch name {
        case "html", "xml": return .markup
        case "diff": return .diff
        case "markdown": return .markdown
        case "plaintext": return LanguageScanner.unstyled
        default: return LanguageDefinitions.spec(for: name).map(LanguageScanner.generic)
        }
    }
}
