import Foundation

// Two languages whose structure is the line, not the token.

/// ```` ```diff ```` fences get real diff colouring (§11.3) rather than being
/// lexed as arithmetic.
struct DiffLexer {
    private let units: [Unit]
    private let count: Int
    private var builder: RunBuilder

    init(units: [Unit]) {
        self.units = units
        self.count = units.count
        self.builder = RunBuilder(reservingFor: units.count)
    }

    static func highlight(_ units: [Unit]) -> [SyntaxRun] {
        var lexer = DiffLexer(units: units)
        return lexer.run()
    }

    /// Header prefixes, longest first: `---`/`+++` are file headers and must be
    /// tested before the `-`/`+` line markers they start with.
    private static let headers: [[UInt8]] = [
        "---", "+++", "@@", "diff ", "index ", "new file", "deleted file",
        "old mode", "new mode", "similarity index", "rename from", "rename to",
        "Binary files", "\\ No newline",
    ].map { Array($0.utf8) }

    mutating func run() -> [SyntaxRun] {
        var lineStart = 0
        while lineStart < count {
            var lineEnd = lineStart
            while lineEnd < count, !isNewlineUnit(units[lineEnd]) { lineEnd += 1 }
            classify(lineStart..<lineEnd)
            lineStart = lineEnd
            while lineStart < count, isNewlineUnit(units[lineStart]) { lineStart += 1 }
        }
        return builder.finish()
    }

    private mutating func classify(_ line: Range<Int>) {
        guard !line.isEmpty else { return }
        for header in DiffLexer.headers where matches(header, at: line.lowerBound, limit: line.upperBound) {
            builder.emit(.diffHeader, line)
            return
        }
        switch units[line.lowerBound] {
        case .of("+"): builder.emit(.diffAdded, line)
        case .of("-"): builder.emit(.diffRemoved, line)
        default: builder.emit(.plain, line)
        }
    }

    private func matches(_ bytes: [UInt8], at pos: Int, limit: Int) -> Bool {
        guard pos + bytes.count <= limit else { return false }
        for k in 0..<bytes.count where units[pos + k] != Unit(bytes[k]) { return false }
        return true
    }
}

/// Markdown inside markdown.  Agents emit ```` ```markdown ```` constantly, so
/// this is not a novelty language for this app.
///
/// Block structure is line-oriented; inline structure is a single forward pass
/// that colours delimiters and link destinations and leaves prose alone.
struct MarkdownLexer {
    private let units: [Unit]
    private let count: Int
    private var builder: RunBuilder

    init(units: [Unit]) {
        self.units = units
        self.count = units.count
        self.builder = RunBuilder(reservingFor: units.count)
    }

    static func highlight(_ units: [Unit]) -> [SyntaxRun] {
        var lexer = MarkdownLexer(units: units)
        return lexer.run()
    }

    mutating func run() -> [SyntaxRun] {
        var fence: (marker: Unit, length: Int)?
        var lineStart = 0
        while lineStart < count {
            var lineEnd = lineStart
            while lineEnd < count, !isNewlineUnit(units[lineEnd]) { lineEnd += 1 }
            let line = lineStart..<lineEnd
            if let open = fence {
                if let close = fenceRun(line), close.marker == open.marker, close.length >= open.length {
                    builder.emit(.attribute, line)
                    fence = nil
                } else {
                    builder.emit(.string, line)
                }
            } else if let open = fenceRun(line) {
                builder.emit(.attribute, line)
                fence = open
            } else {
                classifyBlock(line)
            }
            lineStart = lineEnd
            while lineStart < count, isNewlineUnit(units[lineStart]) { lineStart += 1 }
        }
        return builder.finish()
    }

    /// A run of three or more backticks or tildes with nothing but the info
    /// string after it.
    private func fenceRun(_ line: Range<Int>) -> (marker: Unit, length: Int)? {
        var j = line.lowerBound
        while j < line.upperBound, isBlankUnit(units[j]) { j += 1 }
        guard j < line.upperBound else { return nil }
        let marker = units[j]
        guard marker == .of("`") || marker == .of("~") else { return nil }
        var length = 0
        while j < line.upperBound, units[j] == marker { length += 1; j += 1 }
        return length >= 3 ? (marker, length) : nil
    }

    private mutating func classifyBlock(_ line: Range<Int>) {
        guard !line.isEmpty else { return }
        var j = line.lowerBound
        while j < line.upperBound, isBlankUnit(units[j]) { j += 1 }
        guard j < line.upperBound else { return }

        if units[j] == .of("#") {
            var k = j
            while k < line.upperBound, units[k] == .of("#") { k += 1 }
            if k - j <= 6, k >= line.upperBound || isBlankUnit(units[k]) {
                builder.emit(.keyword, j..<line.upperBound)
                return
            }
        }
        if isThematicBreak(j..<line.upperBound) {
            builder.emit(.operator, j..<line.upperBound)
            return
        }
        if units[j] == .of(">") {
            var k = j
            while k < line.upperBound, units[k] == .of(">") || isBlankUnit(units[k]) { k += 1 }
            builder.emit(.comment, j..<k)
            scanInline(k..<line.upperBound)
            return
        }
        if let marker = listMarker(j..<line.upperBound) {
            builder.emit(.operator, j..<marker)
            scanInline(marker..<line.upperBound)
            return
        }
        scanInline(j..<line.upperBound)
    }

    /// `---`, `***`, `___` — three or more of one character and nothing else.
    private func isThematicBreak(_ line: Range<Int>) -> Bool {
        guard let first = line.first.map({ units[$0] }) else { return false }
        guard first == .of("-") || first == .of("*") || first == .of("_") else { return false }
        var seen = 0
        for k in line {
            if units[k] == first { seen += 1; continue }
            if isBlankUnit(units[k]) { continue }
            return false
        }
        return seen >= 3
    }

    /// End index of a `-`/`*`/`+`/`1.` marker plus its trailing space, or nil.
    private func listMarker(_ line: Range<Int>) -> Int? {
        var j = line.lowerBound
        let first = units[j]
        if first == .of("-") || first == .of("*") || first == .of("+") {
            j += 1
        } else if isDigitUnit(first) {
            while j < line.upperBound, isDigitUnit(units[j]) { j += 1 }
            guard j < line.upperBound, units[j] == .of(".") || units[j] == .of(")") else { return nil }
            j += 1
        } else {
            return nil
        }
        guard j < line.upperBound, isBlankUnit(units[j]) else { return nil }
        while j < line.upperBound, isBlankUnit(units[j]) { j += 1 }
        return j
    }

    private static let emphasisUnits = asciiTable("*_~")

    private mutating func scanInline(_ range: Range<Int>) {
        var j = range.lowerBound
        var plainStart = j
        func flushPlain(upTo end: Int) {
            builder.emit(.plain, plainStart..<end)
        }
        while j < range.upperBound {
            let c = units[j]
            if c == .of("`") {
                flushPlain(upTo: j)
                j = scanCodeSpan(from: j, limit: range.upperBound)
                plainStart = j
                continue
            }
            if c == .of("[") || (c == .of("!") && j + 1 < range.upperBound && units[j + 1] == .of("[")) {
                flushPlain(upTo: j)
                j = scanLink(from: j, limit: range.upperBound)
                plainStart = j
                continue
            }
            if member(c, MarkdownLexer.emphasisUnits) {
                flushPlain(upTo: j)
                let start = j
                while j < range.upperBound, units[j] == c { j += 1 }
                builder.emit(.punctuation, start..<j)
                plainStart = j
                continue
            }
            j += 1
        }
        flushPlain(upTo: range.upperBound)
    }

    private mutating func scanCodeSpan(from start: Int, limit: Int) -> Int {
        var j = start
        var ticks = 0
        while j < limit, units[j] == .of("`") { ticks += 1; j += 1 }
        while j < limit {
            if units[j] == .of("`") {
                var closing = 0
                while j < limit, units[j] == .of("`") { closing += 1; j += 1 }
                if closing == ticks { break }
                continue
            }
            j += 1
        }
        builder.emit(.string, start..<j)
        return j
    }

    /// `[label](destination)` and `![alt](src)`.  The label stays prose; the
    /// destination is what the reader actually needs to pick out.
    private mutating func scanLink(from start: Int, limit: Int) -> Int {
        var j = start
        if units[j] == .of("!") { j += 1 }
        builder.emit(.punctuation, start..<(j + 1))
        j += 1
        let labelStart = j
        var depth = 1
        while j < limit, depth > 0 {
            if units[j] == .of("[") { depth += 1 }
            if units[j] == .of("]") { depth -= 1; if depth == 0 { break } }
            j += 1
        }
        builder.emit(.plain, labelStart..<j)
        guard j < limit else { return j }
        let closeBracket = j
        j += 1
        builder.emit(.punctuation, closeBracket..<j)
        guard j < limit, units[j] == .of("(") || units[j] == .of("[") else { return j }
        let opener = units[j]
        let closer: Unit = opener == .of("(") ? .of(")") : .of("]")
        let destinationStart = j
        j += 1
        while j < limit, units[j] != closer { j += 1 }
        j = min(limit, j + 1)
        builder.emit(.string, destinationStart..<j)
        return j
    }
}
