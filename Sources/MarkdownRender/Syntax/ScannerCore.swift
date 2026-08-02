import Foundation

// Shared scanning primitives.
//
// Every lexer here works directly over UTF-16 code units.  Two reasons, both
// load-bearing: `NSRange` is UTF-16-based so the offsets we emit are free, and
// no `String` is ever constructed per token — highlighting runs on every code
// block on every restyle and sits inside the §12 8ms keystroke budget.
//
// Every syntax-significant character in every supported language is ASCII.
// Units at or above 0x80 — including surrogate halves — are therefore treated
// uniformly as identifier characters, which also guarantees a surrogate pair is
// never split across two runs.

typealias Unit = UInt16

extension UInt16 {
    /// `Unit.of("#")` — an ASCII literal as a code unit, readably.
    @inline(__always) static func of(_ scalar: Unicode.Scalar) -> Unit {
        Unit(scalar.value)
    }
}

@inline(__always) func isDigitUnit(_ u: Unit) -> Bool { u >= 0x30 && u <= 0x39 }

@inline(__always) func isLetterUnit(_ u: Unit) -> Bool {
    let lower = u | 0x20
    return lower >= 0x61 && lower <= 0x7A
}

@inline(__always) func isUpperUnit(_ u: Unit) -> Bool { u >= 0x41 && u <= 0x5A }

@inline(__always) func isHexDigitUnit(_ u: Unit) -> Bool {
    if isDigitUnit(u) { return true }
    let lower = u | 0x20
    return lower >= 0x61 && lower <= 0x66
}

@inline(__always) func isNewlineUnit(_ u: Unit) -> Bool { u == 0x0A || u == 0x0D }

/// Space or tab — "blank" in the POSIX sense, i.e. horizontal only.
@inline(__always) func isBlankUnit(_ u: Unit) -> Bool { u == 0x20 || u == 0x09 }

@inline(__always) func isSpaceUnit(_ u: Unit) -> Bool {
    u == 0x20 || (u >= 0x09 && u <= 0x0D)
}

/// Non-ASCII units are letters as far as the lexers are concerned; see the
/// surrogate note above.
@inline(__always) func isWordUnit(_ u: Unit) -> Bool {
    isLetterUnit(u) || isDigitUnit(u) || u == 0x5F || u >= 0x80
}

/// A 128-entry membership table.  Cheaper than a `Set<Unit>` (no hashing) and
/// clearer than a `switch` over character literals.
func asciiTable(_ characters: String) -> [Bool] {
    var table = [Bool](repeating: false, count: 128)
    for scalar in characters.unicodeScalars where scalar.value < 128 {
        table[Int(scalar.value)] = true
    }
    return table
}

@inline(__always) func member(_ u: Unit, _ table: [Bool]) -> Bool {
    u < 128 && table[Int(u)]
}

// MARK: - Run accumulation

/// Collects runs while maintaining the three invariants `SyntaxHighlighter`
/// promises: ascending, non-overlapping, inside the input.  Adjacent runs of
/// the same token are merged, which keeps the attribute-run count down on code
/// that is mostly one class (a long comment, a `diff` hunk).
struct RunBuilder {
    private(set) var runs: [SyntaxRun] = []

    init(reservingFor unitCount: Int) {
        // Empirically ~1 run per 6 code units of source; over-reserving costs
        // one allocation, under-reserving costs log n of them.
        runs.reserveCapacity(max(8, unitCount / 6))
    }

    mutating func emit(_ token: SyntaxToken, _ range: Range<Int>) {
        guard range.lowerBound < range.upperBound else { return }
        if let last = runs.last, last.token == token, last.range.upperBound == range.lowerBound {
            runs[runs.count - 1].range.length += range.count
        } else {
            runs.append(SyntaxRun(range: NSRange(location: range.lowerBound, length: range.count), token: token))
        }
    }

    func finish() -> [SyntaxRun] { runs }
}
