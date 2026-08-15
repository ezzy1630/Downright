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
//
// This pass runs over every `.text` span on every parse, and most tokens are
// plain words that get rejected.  All shape decisions therefore happen on the
// raw UTF-16 buffer — no intermediate `String` — and the path String is only
// materialised for a token that actually matches.

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

        // `file.ts:42` and `file.ts:42:8` — split the location suffix off first
        // so the shape rules below see just the path.  All of this runs on the
        // UTF-16 buffer; only a real match pays for a `String`.
        let (pathRange, line, column) = stripLocationSuffix(text, range: range)
        guard pathRange.length > 0, !isURL(text, range: pathRange) else { return nil }
        guard isPathShaped(text, range: pathRange, relaxed: relaxed) else { return nil }

        // `range` deliberately keeps the `:42` suffix: the app underlines
        // and opens the whole token, and only `rawPath` needs the path.
        let body = text.substring(with: pathRange)
        return Match(range: range, token: PathToken(rawPath: body, line: line, column: column))
    }

    /// Splits a trailing `:line` or `:line:column` suffix off `range`, matching
    /// the original rule: only a suffix whose last colon-delimited segment is a
    /// positive integer is split, so inner colons in a path are preserved.
    private static func stripLocationSuffix(
        _ text: NSString, range: NSRange
    ) -> (pathRange: NSRange, line: Int?, column: Int?) {
        let start = range.location
        let end = range.upperBound
        var segStart = end - 1
        while segStart >= start, isDigit(text.character(at: segStart)) { segStart -= 1 }
        guard segStart >= start, text.character(at: segStart) == 0x3A,
              let line = parseDigits(text, from: segStart + 1, to: end), line > 0
        else { return (range, nil, nil) }

        var colStart = segStart - 1
        while colStart >= start, isDigit(text.character(at: colStart)) { colStart -= 1 }
        if colStart >= start, text.character(at: colStart) == 0x3A,
           let column = parseDigits(text, from: colStart + 1, to: segStart), column > 0 {
            return (NSRange(location: start, length: colStart - start), line, column)
        }
        return (NSRange(location: start, length: segStart - start), line, nil)
    }

    /// The conservative shape test.  A `/` alone is not enough — `and/or`,
    /// `read/write` and `he/him` all have one.
    private static func isPathShaped(_ text: NSString, range: NSRange, relaxed: Bool) -> Bool {
        let start = range.location
        let end = range.upperBound
        let length = range.length
        if length >= 2, text.character(at: start) == 0x2F, text.character(at: start + 1) == 0x2F {
            return false
        }

        var slashes = 0
        var lastDot = -1
        var index = start
        while index < end {
            let c = text.character(at: index)
            if c == 0x2F {
                slashes += 1
                lastDot = -1  // a `/` after the last dot kills an extension
            } else if c == 0x2E {
                lastDot = index
            }
            index += 1
        }
        var hasExtension = false
        if lastDot > start, lastDot + 1 < end, let ext = extensionAfter(text, dot: lastDot, end: end) {
            hasExtension = knownExtensions.contains(ext)
        }

        if relaxed { return slashes > 0 || hasExtension }
        if hasExtension { return true }
        guard slashes > 0 else { return false }
        if isAnchored(text, start: start, end: end) { return true }
        if slashes >= 2 { return true }
        // One slash, no anchor: only accept when a segment carries a dot, which
        // is what separates `pkg/mod.go` from `and/or`.
        return segmentContainsDot(text, start: start, end: end)
    }

    /// Lowercased file extension after the last dot, or `nil` when the dot is
    /// not the last one on the line or the extension is empty.
    private static func extensionAfter(_ text: NSString, dot: Int, end: Int) -> String? {
        var out = ""
        for index in (dot + 1)..<end {
            let c = text.character(at: index)
            if c == 0x2F { return nil }  // a later `/` means the dot isn't an extension separator
            // A surrogate half (a non-ASCII character such as an emoji arrives
            // here as two UTF-16 units) can't become a UnicodeScalar — guard so
            // the whole scan can't trap on `config.🚀`, where the surrogate is
            // neither a known extension nor a slash and must simply be skipped.
            guard let scalar = UnicodeScalar(asciiLower(c)) else { continue }
            out.append(Character(scalar))
        }
        return out.isEmpty ? nil : out
    }

    private static func isAnchored(_ text: NSString, start: Int, end: Int) -> Bool {
        guard start < end else { return false }
        switch text.character(at: start) {
        case 0x2E:  // ./
            if start + 1 < end, text.character(at: start + 1) == 0x2F { return true }
            // ../
            if start + 2 < end, text.character(at: start + 1) == 0x2E, text.character(at: start + 2) == 0x2F {
                return true
            }
            return false
        case 0x2F:  // absolute
            return true
        case 0x7E:  // ~/
            return start + 1 < end && text.character(at: start + 1) == 0x2F
        default:
            return false
        }
    }

    private static func segmentContainsDot(_ text: NSString, start: Int, end: Int) -> Bool {
        var segmentStart = start
        var index = start
        while index <= end {
            if index == end || text.character(at: index) == 0x2F {
                for probe in segmentStart..<index where text.character(at: probe) == 0x2E {
                    return true
                }
                segmentStart = index + 1
            }
            index += 1
        }
        return false
    }

    private static func isURL(_ text: NSString, range: NSRange) -> Bool {
        let start = range.location
        let end = range.upperBound
        // `://` anywhere in the token.  A one-unit path (`3:16` splits to the
        // path `3`) makes `end - 2` precede `start`; building that range
        // traps, so clamp it — there is nothing to scan.
        for index in start..<max(start, end - 2) where text.character(at: index) == 0x3A {
            if text.character(at: index + 1) == 0x2F, text.character(at: index + 2) == 0x2F {
                return true
            }
        }
        // `www.` prefix, case-insensitive.
        if end - start >= 4, asciiLower(text.character(at: start)) == 0x77 {
            var matches = true
            for (offset, expected) in [UInt16(0x77), 0x77, 0x77, 0x2E].enumerated() {
                if asciiLower(text.character(at: start + offset)) != expected { matches = false; break }
            }
            if matches { return true }
        }
        // A scheme is everything before the first colon; letters only, and more
        // than one character (`a:b` reads as a path, `mailto:` as a URL).
        for colon in start..<end where text.character(at: colon) == 0x3A {
            if colon - start > 1 {
                var allLetters = true
                for index in start..<colon where !isASCIILetter(text.character(at: index)) {
                    allLetters = false
                    break
                }
                if allLetters { return true }
            }
            break
        }
        return false
    }

    private static func parseDigits(_ text: NSString, from start: Int, to end: Int) -> Int? {
        var value = 0
        for index in start..<end {
            let digit = Int(text.character(at: index)) - 0x30
            if value > (Int.max - digit) / 10 { return nil }
            value = value * 10 + digit
        }
        return value
    }

    @inline(__always) private static func isDigit(_ ch: unichar) -> Bool { ch >= 0x30 && ch <= 0x39 }
    @inline(__always) private static func isASCIILetter(_ ch: unichar) -> Bool {
        (ch >= 0x41 && ch <= 0x5A) || (ch >= 0x61 && ch <= 0x7A)
    }
    /// Lowercases an ASCII letter; returns other units unchanged.
    @inline(__always) private static func asciiLower(_ ch: unichar) -> unichar {
        ch >= 0x41 && ch <= 0x5A ? ch + 0x20 : ch
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
