import Foundation

/// HTML and XML.  Markup inverts the usual shape — text is the default and code
/// is the exception — so it gets its own scanner rather than a `LanguageSpec`
/// contorted into producing tag structure.
struct MarkupLexer {
    private let units: [Unit]
    private let count: Int
    private var i = 0
    private var builder: RunBuilder

    init(units: [Unit]) {
        self.units = units
        self.count = units.count
        self.builder = RunBuilder(reservingFor: units.count)
    }

    static func highlight(_ units: [Unit]) -> [SyntaxRun] {
        var lexer = MarkupLexer(units: units)
        return lexer.run()
    }

    mutating func run() -> [SyntaxRun] {
        while i < count {
            let c = units[i]
            if c == .of("<") {
                scanAngleConstruct()
                continue
            }
            if c == .of("&") {
                scanEntity()
                continue
            }
            let start = i
            while i < count, units[i] != .of("<"), units[i] != .of("&") { i += 1 }
            builder.emit(.plain, start..<i)
        }
        return builder.finish()
    }

    private static let commentOpen = Array("<!--".utf8)
    private static let commentClose = Array("-->".utf8)
    private static let cdataOpen = Array("<![CDATA[".utf8)
    private static let cdataClose = Array("]]>".utf8)
    private static let declarationOpen = Array("<!".utf8)
    private static let processingOpen = Array("<?".utf8)

    private mutating func scanAngleConstruct() {
        let start = i
        if matches(MarkupLexer.commentOpen) {
            i += MarkupLexer.commentOpen.count
            while i < count, !matches(MarkupLexer.commentClose) { i += 1 }
            i = min(count, i + MarkupLexer.commentClose.count)
            builder.emit(.comment, start..<i)
            return
        }
        if matches(MarkupLexer.cdataOpen) {
            i += MarkupLexer.cdataOpen.count
            while i < count, !matches(MarkupLexer.cdataClose) { i += 1 }
            i = min(count, i + MarkupLexer.cdataClose.count)
            builder.emit(.string, start..<i)
            return
        }
        // `<!DOCTYPE …>` and `<?xml …?>` are declarations, not elements.
        if matches(MarkupLexer.declarationOpen) || matches(MarkupLexer.processingOpen) {
            while i < count, units[i] != .of(">") { i += 1 }
            i = min(count, i + 1)
            builder.emit(.attribute, start..<i)
            return
        }
        i += 1
        if i < count, units[i] == .of("/") { i += 1 }
        builder.emit(.punctuation, start..<i)
        scanName(as: .type)
        scanAttributes()
    }

    private mutating func scanAttributes() {
        while i < count {
            let c = units[i]
            if isSpaceUnit(c) { i += 1; continue }
            if c == .of(">") || c == .of("/") {
                let start = i
                while i < count, units[i] == .of("/") || units[i] == .of(">") { i += 1 }
                builder.emit(.punctuation, start..<i)
                return
            }
            if c == .of("=") {
                i += 1
                builder.emit(.operator, (i - 1)..<i)
                continue
            }
            if c == .of("\"") || c == .of("'") {
                scanQuoted(delimiter: c)
                continue
            }
            if isNameUnit(c) {
                scanName(as: .attribute)
                continue
            }
            let start = i
            i += 1
            builder.emit(.plain, start..<i)
        }
    }

    private mutating func scanQuoted(delimiter: Unit) {
        let start = i
        i += 1
        while i < count, units[i] != delimiter { i += 1 }
        i = min(count, i + 1)
        builder.emit(.string, start..<i)
    }

    private mutating func scanName(as token: SyntaxToken) {
        let start = i
        while i < count, isNameUnit(units[i]) { i += 1 }
        builder.emit(token, start..<i)
    }

    private mutating func scanEntity() {
        let start = i
        var j = i + 1
        while j < count, isNameUnit(units[j]) || units[j] == .of("#") { j += 1 }
        guard j < count, units[j] == .of(";"), j > i + 1 else {
            i += 1
            builder.emit(.plain, start..<i)
            return
        }
        i = j + 1
        builder.emit(.constant, start..<i)
    }

    private static let nameUnits = asciiTable("-_:.")

    @inline(__always) private func isNameUnit(_ c: Unit) -> Bool {
        isWordUnit(c) || member(c, MarkupLexer.nameUnits)
    }

    @inline(__always) private func matches(_ bytes: [UInt8]) -> Bool {
        guard i + bytes.count <= count else { return false }
        for k in 0..<bytes.count where units[i + k] != Unit(bytes[k]) { return false }
        return true
    }
}
