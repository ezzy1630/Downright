import Foundation

// MARK: - Path tokens (§8.4)
//
// Finds `src/foo.ts`, `src/foo.ts:42`, `./x/y.md` and anything path-shaped
// inside an inline code span.  It never touches the filesystem: resolution
// needs a document directory and a git root, neither of which belongs in a
// parser, so this emits `ResolvableToken` and the app decides what exists.
//
// §8.4 calls this a trust instrument — the red dotted underline on a file the
// agent claims to have written is the whole point.  That makes false positives
// expensive: underlining `and/or` would train the user to ignore the signal.
// Hence the shape rules below, which are deliberately conservative in prose and
// relaxed inside a code span, where the backticks are themselves strong
// evidence.

enum PathTokenScanner {
    /// Extensions common enough in agent output that seeing one is sufficient
    /// evidence on its own, even without a `/`.
    static let knownExtensions: Set<String> = [
        "ts", "tsx", "js", "jsx", "mjs", "cjs", "swift", "py", "rb", "go", "rs", "java", "kt", "kts",
        "c", "h", "cc", "cpp", "hpp", "m", "mm", "cs", "php", "pl", "lua", "r", "scala", "clj", "ex",
        "sh", "bash", "zsh", "fish", "ps1", "bat",
        "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "env", "lock", "properties",
        "md", "mdx", "mdc", "markdown", "rst", "txt", "adoc",
        "html", "htm", "css", "scss", "sass", "less", "vue", "svelte", "astro",
        "sql", "graphql", "gql", "proto", "xml", "plist", "entitlements", "pbxproj", "xcconfig",
        "gradle", "cmake", "mk", "dockerfile", "gitignore", "npmrc", "editorconfig",
        "png", "jpg", "jpeg", "gif", "svg", "webp", "pdf", "csv", "tsv",
    ]

    struct Match {
        var range: NSRange
        var token: PathToken
    }

    /// Scans prose.  Requires a clear path shape (see `isPathShaped`).
    static func matches(in text: NSString, range: NSRange) -> [Match] {
        var out: [Match] = []
        var i = range.location
        let end = range.upperBound
        while i < end {
            guard isTokenCharacter(text.character(at: i)) else { i += 1; continue }
            // Only start a token at a word boundary, so `abc/def` inside a
            // longer run is considered as a whole rather than from the middle.
            if i > range.location, isTokenCharacter(text.character(at: i - 1)) { i += 1; continue }

            var j = i
            while j < end, isTokenCharacter(text.character(at: j)) { j += 1 }
            let raw = NSRange(location: i, length: j - i)
            if let match = evaluate(text, raw: raw, relaxed: false) { out.append(match) }
            i = j
        }
        return out
    }

    /// Scans the contents of an inline code span, where a single `/` or a known
    /// extension is enough (§4.1: `` `path/to/file` ``).
    static func codeSpanMatch(in text: NSString, range: NSRange) -> Match? {
        evaluate(text, raw: range, relaxed: true)
    }

    private static func evaluate(_ text: NSString, raw: NSRange, relaxed: Bool) -> Match? {
        var range = raw
        // Trim sentence punctuation the token picked up on the way past.
        while range.length > 0, isTrailingPunctuation(text.character(at: range.upperBound - 1)) {
            range.length -= 1
        }
        guard range.length > 1 else { return nil }
        var body = text.substring(with: range)

        // `file.ts:42` and `file.ts:42:8` — split the location suffix off first
        // so the shape rules below see just the path.
        var line: Int?
        var column: Int?
        let segments = body.split(separator: ":", omittingEmptySubsequences: false)
        if segments.count >= 2, let last = Int(segments[segments.count - 1]), last > 0 {
            if segments.count >= 3, let middle = Int(segments[segments.count - 2]), middle > 0 {
                line = middle
                column = last
                body = segments.dropLast(2).joined(separator: ":")
            } else {
                line = last
                body = segments.dropLast().joined(separator: ":")
            }
            // `range` deliberately keeps the `:42` suffix: the app underlines
            // and opens the whole token, and only `rawPath` needs the path.
        }

        guard !body.isEmpty, !isURL(body) else { return nil }
        guard isPathShaped(body, relaxed: relaxed) else { return nil }
        return Match(range: range, token: PathToken(rawPath: body, line: line, column: column))
    }

    /// The conservative shape test.  A `/` alone is not enough — `and/or`,
    /// `read/write` and `he/him` all have one.
    private static func isPathShaped(_ path: String, relaxed: Bool) -> Bool {
        if path.hasPrefix("//") { return false }
        let slashes = path.filter { $0 == "/" }.count
        let hasExtension = knownExtensions.contains(fileExtension(of: path))

        if relaxed { return slashes > 0 || hasExtension }
        if hasExtension { return true }
        guard slashes > 0 else { return false }
        if path.hasPrefix("./") || path.hasPrefix("../") || path.hasPrefix("/") || path.hasPrefix("~/") {
            return true
        }
        if slashes >= 2 { return true }
        // One slash, no anchor: only accept when a segment carries a dot, which
        // is what separates `pkg/mod.go` from `and/or`.
        return path.split(separator: "/").contains { $0.contains(".") }
    }

    private static func fileExtension(of path: String) -> String {
        guard let dot = path.lastIndex(of: "."), dot != path.startIndex else { return "" }
        let ext = String(path[path.index(after: dot)...]).lowercased()
        return ext.contains("/") ? "" : ext
    }

    private static func isURL(_ path: String) -> Bool {
        if path.contains("://") { return true }
        if path.lowercased().hasPrefix("www.") { return true }
        // `mailto:x@y.com`, `http:` and friends — a scheme before any slash.
        if let colon = path.firstIndex(of: ":") {
            let scheme = path[path.startIndex..<colon]
            if !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter }), scheme.count > 1 { return true }
        }
        return false
    }

    private static func isTokenCharacter(_ ch: unichar) -> Bool {
        switch ch {
        case 0x2F, 0x2E, 0x2D, 0x5F, 0x7E, 0x40, 0x3A, 0x2B: return true  // / . - _ ~ @ : +
        default:
            return (ch >= 0x30 && ch <= 0x39) || (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
        }
    }

    private static func isTrailingPunctuation(_ ch: unichar) -> Bool {
        switch ch {
        case 0x2E, 0x2C, 0x3B, 0x3A, 0x21, 0x3F, 0x2D: return true  // . , ; : ! ? -
        default: return false
        }
    }
}
