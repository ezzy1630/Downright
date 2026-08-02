import Foundation

/// The shared scanner.  One pass, no backtracking beyond a fixed lookahead, no
/// regular expressions.
///
/// Order of attempts inside the loop is the whole correctness story: trivia
/// before literals means a comment marker inside a string is never a comment
/// and a quote inside a comment is never a string, because whichever construct
/// opened first consumes to its own terminator.
struct GenericLexer {
    private let spec: LanguageSpec
    private let units: [Unit]
    private let count: Int
    private var i = 0
    private var builder: RunBuilder

    init(spec: LanguageSpec, units: [Unit]) {
        self.spec = spec
        self.units = units
        self.count = units.count
        self.builder = RunBuilder(reservingFor: units.count)
    }

    static func highlight(_ units: [Unit], spec: LanguageSpec) -> [SyntaxRun] {
        var lexer = GenericLexer(spec: spec, units: units)
        return lexer.run()
    }

    mutating func run() -> [SyntaxRun] {
        while i < count {
            let c = units[i]
            if isSpaceUnit(c) { i += 1; continue }
            let start = i

            if scanTrivia() { builder.emit(.comment, start..<i); continue }
            if scanRawString() { builder.emit(.string, start..<i); continue }
            if scanSigil(start: start) { continue }
            if let string = matchStringOpen(at: i) {
                scanString(string)
                // `"key": value` — a quoted key is an attribute, not a value.
                let isKey = spec.keysFromStrings && isFollowedByKeyTerminator()
                builder.emit(isKey ? .attribute : .string, start..<i)
                continue
            }
            if isNumberStart() { scanNumber(); builder.emit(.number, start..<i); continue }
            if isIdentifierStart(at: i) { scanIdentifierToken(start: start); continue }
            if spec.bracketSectionHeaders, c == .of("["), isAtLineStart(i) {
                scanBalanced(open: .of("["), close: .of("]"))
                builder.emit(.type, start..<i)
                continue
            }
            if isOperatorUnit(c) {
                while i < count, isOperatorUnit(units[i]) { i += 1 }
                builder.emit(.operator, start..<i)
                continue
            }
            i += 1
            builder.emit(isPunctuationUnit(c) ? .punctuation : .plain, start..<i)
        }
        return builder.finish()
    }

    // MARK: - Primitives

    @inline(__always) private func matches(_ bytes: [UInt8], at pos: Int) -> Bool {
        guard pos >= 0, pos + bytes.count <= count else { return false }
        for k in 0..<bytes.count where units[pos + k] != Unit(bytes[k]) { return false }
        return true
    }

    @inline(__always) private func unit(_ offset: Int) -> Unit {
        let index = i + offset
        return index < count && index >= 0 ? units[index] : 0
    }

    /// Only blanks precede `pos` on its line.
    private func isAtLineStart(_ pos: Int) -> Bool {
        var j = pos - 1
        while j >= 0, isBlankUnit(units[j]) { j -= 1 }
        return j < 0 || isNewlineUnit(units[j])
    }

    /// Bash's rule for `#`: it opens a comment only at the start of a word.
    private func isAtWordStart(_ pos: Int) -> Bool {
        guard pos > 0 else { return true }
        let previous = units[pos - 1]
        if isSpaceUnit(previous) { return true }
        return previous == .of(";") || previous == .of("&") || previous == .of("|")
            || previous == .of("(") || previous == .of(")") || previous == .of("`")
    }

    // MARK: - Trivia

    private mutating func scanTrivia() -> Bool {
        for marker in spec.lineComments where matches(marker, at: i) {
            if spec.lineCommentNeedsWordStart, !isAtWordStart(i) { continue }
            i += marker.count
            while i < count, !isNewlineUnit(units[i]) { i += 1 }
            return true
        }
        for comment in spec.blockComments where matches(comment.open, at: i) {
            if comment.mustStartLine, !isAtLineStart(i) { continue }
            i += comment.open.count
            var depth = 1
            while i < count {
                if comment.nests, matches(comment.open, at: i) {
                    depth += 1
                    i += comment.open.count
                    continue
                }
                if matches(comment.close, at: i) {
                    i += comment.close.count
                    depth -= 1
                    if depth == 0 { break }
                    continue
                }
                i += 1
            }
            return true
        }
        return false
    }

    // MARK: - Strings

    private func matchStringOpen(at pos: Int) -> StringSpec? {
        for string in spec.strings where matches(string.open, at: pos) { return string }
        return nil
    }

    private mutating func scanString(_ string: StringSpec) {
        i += string.open.count
        while i < count {
            let c = units[i]
            if let escape = string.escape, c == Unit(escape) {
                i += min(2, count - i)
                continue
            }
            if !string.spansLines, isNewlineUnit(c) { return }
            if matches(string.close, at: i) {
                i += string.close.count
                return
            }
            i += 1
        }
    }

    /// Raw-string forms are checked before identifiers because their prefixes
    /// (`r`, `br`, `R`) are identifier characters.  The main loop only reaches
    /// here at a token boundary, so a trailing `r` in a longer identifier has
    /// already been consumed and cannot be mistaken for a prefix.
    private mutating func scanRawString() -> Bool {
        for style in spec.rawStrings {
            switch style {
            case .swiftHash: if scanSwiftRawString() { return true }
            case .rustHash: if scanRustRawString() { return true }
            case .cppDelimited: if scanCppRawString() { return true }
            }
        }
        return false
    }

    /// `#"…"#`, `##"…"##`, `#"""…"""#`.  Escapes need no handling: in a raw
    /// string the terminator is `"` followed by exactly the opening run of `#`,
    /// and no escape sequence can produce that.
    private mutating func scanSwiftRawString() -> Bool {
        let save = i
        var hashes = 0
        while i < count, units[i] == .of("#") { hashes += 1; i += 1 }
        guard hashes > 0 else { i = save; return false }
        let quotes = matches([0x22, 0x22, 0x22], at: i) ? 3 : (unit(0) == .of("\"") ? 1 : 0)
        guard quotes > 0 else { i = save; return false }
        i += quotes
        scanToRawTerminator(quotes: quotes, hashes: hashes)
        return true
    }

    /// `r"…"`, `r#"…"#`, `br"…"`, `br#"…"#`.
    private mutating func scanRustRawString() -> Bool {
        let save = i
        var j = i
        if j < count, units[j] == .of("b") { j += 1 }
        guard j < count, units[j] == .of("r") else { i = save; return false }
        j += 1
        var hashes = 0
        while j < count, units[j] == .of("#") { hashes += 1; j += 1 }
        guard j < count, units[j] == .of("\"") else { i = save; return false }
        i = j + 1
        scanToRawTerminator(quotes: 1, hashes: hashes)
        return true
    }

    /// `R"tag(…)tag"` — the tag makes the terminator unambiguous, which is the
    /// whole point of the form.
    private mutating func scanCppRawString() -> Bool {
        guard unit(0) == .of("R"), unit(1) == .of("\"") else { return false }
        i += 2
        var tag: [Unit] = []
        while i < count, units[i] != .of("("), !isNewlineUnit(units[i]) {
            tag.append(units[i])
            i += 1
        }
        guard i < count, units[i] == .of("(") else { return true }
        i += 1
        while i < count {
            if units[i] == .of(")"), matchesTerminator(tag, at: i + 1) {
                i += 1 + tag.count + 1
                return true
            }
            i += 1
        }
        return true
    }

    private func matchesTerminator(_ tag: [Unit], at pos: Int) -> Bool {
        guard pos + tag.count < count else { return false }
        for k in 0..<tag.count where units[pos + k] != tag[k] { return false }
        return units[pos + tag.count] == .of("\"")
    }

    private mutating func scanToRawTerminator(quotes: Int, hashes: Int) {
        while i < count {
            if units[i] == .of("\"") {
                var k = 0
                while k < quotes, i + k < count, units[i + k] == .of("\"") { k += 1 }
                if k == quotes {
                    var h = 0
                    while h < hashes, i + quotes + h < count, units[i + quotes + h] == .of("#") { h += 1 }
                    if h == hashes {
                        i += quotes + hashes
                        return
                    }
                }
                i += max(1, k)
                continue
            }
            i += 1
        }
    }

    // MARK: - Sigils

    private mutating func scanSigil(start: Int) -> Bool {
        let c = units[i]

        // Objective-C `@"…"`: the sigil belongs to the literal.
        if spec.objcStringSigil, c == .of("@"), let string = matchStringOpen(at: i + 1) {
            i += 1
            scanString(string)
            builder.emit(.string, start..<i)
            return true
        }
        if spec.variableSigils.contains(c) {
            var j = i + 1
            while j < count, units[j] == c { j += 1 }  // `$$`, Ruby `@@ivar`
            if j < count, isWordUnit(units[j]) || units[j] == .of("{") {
                i = j
                if units[i] == .of("{") {
                    scanBalanced(open: .of("{"), close: .of("}"))
                } else {
                    while i < count, isIdentifierContinue(units[i]) { i += 1 }
                }
                builder.emit(.variable, start..<i)
                return true
            }
        }
        if spec.attributeSigils.contains(c), isIdentifierStart(at: i + 1) {
            i += 1
            while i < count, isIdentifierContinue(units[i]) { i += 1 }
            builder.emit(.attribute, start..<i)
            return true
        }
        // Rust attributes read as one unit; splitting `#[derive(Debug)]` into
        // punctuation and calls makes the annotation compete with the code.
        if spec.hashAttributes, c == .of("#"), unit(1) == .of("[") || unit(1) == .of("!") {
            i += 1
            if i < count, units[i] == .of("!") { i += 1 }
            if i < count, units[i] == .of("[") { scanBalanced(open: .of("["), close: .of("]")) }
            builder.emit(.attribute, start..<i)
            return true
        }
        if let token = spec.hashDirectiveToken, c == .of("#") {
            i += 1
            while i < count, isIdentifierContinue(units[i]) { i += 1 }
            builder.emit(token, start..<i)
            return true
        }
        if spec.hasSymbols, c == .of(":"), isIdentifierStart(at: i + 1), unit(-1) != .of(":") {
            i += 1
            while i < count, isIdentifierContinue(units[i]) { i += 1 }
            builder.emit(.constant, start..<i)
            return true
        }
        if spec.hasLifetimes, c == .of("'"), !isCharacterLiteral(at: i) {
            i += 1
            while i < count, isIdentifierContinue(units[i]) { i += 1 }
            builder.emit(.keyword, start..<i)
            return true
        }
        return false
    }

    /// `'a'`, `'\n'`, `'😀'` — anything else after a quote is a Rust lifetime.
    private func isCharacterLiteral(at pos: Int) -> Bool {
        guard pos + 2 < count else { return false }
        if units[pos + 1] == .of("\\") { return true }
        if units[pos + 2] == .of("'") { return true }
        // A surrogate pair is two units wide.
        if units[pos + 1] >= 0xD800, units[pos + 1] <= 0xDBFF, pos + 3 < count, units[pos + 3] == .of("'") {
            return true
        }
        return false
    }

    private mutating func scanBalanced(open: Unit, close: Unit) {
        var depth = 0
        repeat {
            let c = units[i]
            if c == open { depth += 1 }
            if c == close { depth -= 1 }
            i += 1
        } while i < count && depth > 0
    }

    // MARK: - Numbers

    private func isNumberStart() -> Bool {
        let c = units[i]
        if isDigitUnit(c) { return true }
        return c == .of(".") && isDigitUnit(unit(1))
    }

    /// Deliberately permissive about suffixes (`1u8`, `1.0f`, `2px`, `10n`) and
    /// strict about the decimal point: `.` is only consumed when a digit
    /// follows, so Rust's `1..5` and `1.foo()` still split correctly.
    private mutating func scanNumber() {
        if units[i] == .of("0"), i + 1 < count {
            let kind = units[i + 1] | 0x20
            if kind == .of("x") {
                i += 2
                while i < count, isHexDigitUnit(units[i]) || units[i] == .of("_") { i += 1 }
                scanExponent(marker: .of("p"))
                scanNumericSuffix()
                return
            }
            if kind == .of("b") || kind == .of("o") {
                i += 2
                while i < count, isDigitUnit(units[i]) || units[i] == .of("_") { i += 1 }
                scanNumericSuffix()
                return
            }
        }
        while i < count, isDigitUnit(units[i]) || units[i] == .of("_") { i += 1 }
        if i < count, units[i] == .of("."), isDigitUnit(unit(1)) {
            i += 1
            while i < count, isDigitUnit(units[i]) || units[i] == .of("_") { i += 1 }
        }
        scanExponent(marker: .of("e"))
        scanNumericSuffix()
    }

    private mutating func scanExponent(marker: Unit) {
        guard i < count, (units[i] | 0x20) == marker else { return }
        var j = i + 1
        if j < count, units[j] == .of("+") || units[j] == .of("-") { j += 1 }
        guard j < count, isDigitUnit(units[j]) else { return }
        i = j
        while i < count, isDigitUnit(units[i]) { i += 1 }
    }

    private mutating func scanNumericSuffix() {
        while i < count, isLetterUnit(units[i]) || isDigitUnit(units[i]) || units[i] == .of("_") { i += 1 }
    }

    // MARK: - Identifiers

    private func isIdentifierStart(at pos: Int) -> Bool {
        guard pos >= 0, pos < count else { return false }
        let c = units[pos]
        if isLetterUnit(c) || c == .of("_") || c >= 0x80 { return true }
        guard spec.identifierExtraStarts.contains(c) else { return false }
        // An extra start only counts when a real identifier character follows,
        // so CSS `-5px` is a number and `--main` is a custom property.
        let next = pos + 1 < count ? units[pos + 1] : 0
        return isLetterUnit(next) || next == .of("_") || spec.identifierExtraStarts.contains(next)
    }

    @inline(__always) private func isIdentifierContinue(_ c: Unit) -> Bool {
        isWordUnit(c) || spec.identifierExtraContinues.contains(c) || spec.identifierExtraStarts.contains(c)
    }

    private mutating func scanIdentifierToken(start: Int) {
        while i < count, isIdentifierContinue(units[i]) { i += 1 }
        let word = start..<i

        // `f"…"`, `r'…'`, `b"…"`: the identifier is the literal's prefix.
        if let prefix = matchStringPrefix(word), let string = matchStringOpen(at: i) {
            scanString(string.escaping(prefix.escapes))
            builder.emit(.string, start..<i)
            return
        }
        if let token = spec.words.lookup(units, word) { builder.emit(token, word); return }
        if spec.allCapsAreConstants, isScreamingCase(word) { builder.emit(.constant, word); return }
        if spec.callsAreFunctions, nextNonBlank() == .of("(") { builder.emit(.function, word); return }
        if spec.keysFromIdentifiers, isFollowedByKeyTerminator() { builder.emit(.attribute, word); return }
        if spec.capitalisedAreTypes, isUpperUnit(units[start]) { builder.emit(.type, word); return }
        builder.emit(.plain, word)
    }

    private func matchStringPrefix(_ word: Range<Int>) -> StringPrefixSpec? {
        guard i < count, !spec.stringPrefixes.isEmpty else { return nil }
        for prefix in spec.stringPrefixes where prefix.bytes.count == word.count {
            var matched = true
            for k in 0..<prefix.bytes.count {
                let unit = units[word.lowerBound + k]
                let lowered = unit < 0x80 && unit >= 0x41 && unit <= 0x5A ? unit + 0x20 : unit
                if lowered != Unit(prefix.bytes[k]) { matched = false; break }
            }
            if matched { return prefix }
        }
        return nil
    }

    /// `MAX_RETRIES` but not `X`, `_`, or `HTTPResponse`.
    private func isScreamingCase(_ word: Range<Int>) -> Bool {
        guard word.count >= 2 else { return false }
        var sawLetter = false
        for k in word {
            let c = units[k]
            if isUpperUnit(c) { sawLetter = true; continue }
            if isDigitUnit(c) || c == .of("_") { continue }
            return false
        }
        return sawLetter
    }

    private func nextNonBlank() -> Unit {
        var j = i
        while j < count, isBlankUnit(units[j]) { j += 1 }
        return j < count ? units[j] : 0
    }

    private func isFollowedByKeyTerminator() -> Bool {
        var j = i
        while j < count, isBlankUnit(units[j]) { j += 1 }
        guard j < count, spec.keyTerminators.contains(units[j]) else { return false }
        guard spec.keyTerminatorNeedsSpace else { return true }
        let after = j + 1
        return after >= count || isSpaceUnit(units[after])
    }

    // MARK: - Punctuation

    private static let operatorUnits = asciiTable("+-*/%=<>!&|^~?")
    private static let punctuationUnits = asciiTable("()[]{},;.:")

    @inline(__always) private func isOperatorUnit(_ c: Unit) -> Bool {
        member(c, GenericLexer.operatorUnits)
    }

    @inline(__always) private func isPunctuationUnit(_ c: Unit) -> Bool {
        member(c, GenericLexer.punctuationUnits)
    }
}
