import Foundation
import Markdown

// MARK: - Source positions
//
// swift-markdown reports positions as `SourceLocation(line:column:)` where the
// line is 1-based and the column is a **1-based UTF-8 byte offset** from the
// start of the line.  (Its doc comment says "bytes"; `SourcePositionTests`
// pins the behaviour down empirically, including the multi-byte and tab cases,
// because everything downstream depends on it.)
//
// Every range this module publishes is an `NSRange` of UTF-16 offsets, per the
// contract at the top of `Model.swift`.  `SourceMap` is the only place that
// conversion happens.

/// Line index over a document plus the line/column → UTF-16 conversion.
///
/// Lines are split on LF, CRLF and lone CR, matching CommonMark's definition of
/// a line ending, so the index agrees with cmark's line numbering even for the
/// mixed-ending files `DocumentIO` deliberately leaves un-normalised.
struct SourceMap {
    let text: NSString
    let length: Int
    /// UTF-16 offset of the first character of each line.
    let lineStarts: [Int]
    /// UTF-16 offset just past each line's last character, terminator excluded.
    let lineEnds: [Int]
    /// A pure-ASCII line lets a UTF-8 byte offset be used directly as a UTF-16
    /// offset.  This is the overwhelmingly common case and worth the fast path.
    private let lineIsASCII: [Bool]
    private struct ColumnCheckpoint {
        let byteOffset: Int
        let utf16Offset: Int
    }
    /// Sparse checkpoints bound conversion work on long Unicode lines. Short
    /// lines and ASCII lines allocate none; a per-byte map would cost more
    /// memory than the source. The index lives only for this parse.
    private let columnCheckpoints: [Int: [ColumnCheckpoint]]
    private static let checkpointStride = 128
    /// True when the source contains at least one `<`.  `SafeHTMLParser` can
    /// only ever annotate a range that holds one, and the per-block search for
    /// it went through Foundation's Unicode-aware comparison machinery — 6% of
    /// a full parse on a document with no HTML at all.  The line scan below
    /// already visits every scalar, so answering the question once is free.
    let mayContainHTML: Bool

    var lineCount: Int { lineStarts.count }

    init(_ string: String) {
        let ns = string as NSString
        text = ns
        length = ns.length

        var starts: [Int] = [0]
        var ends: [Int] = []
        var ascii: [Bool] = []
        var offset = 0
        var lineASCII = true
        var sawCR = false
        var sawAngleBracket = false
        var lineBytes = 0
        var checkpoints: [Int: [ColumnCheckpoint]] = [:]
        var currentCheckpoints: [ColumnCheckpoint] = []

        for scalar in string.unicodeScalars {
            let width = scalar.value > 0xFFFF ? 2 : 1
            if sawCR {
                sawCR = false
                if scalar == "\n" {
                    // CRLF: the line already ended at the CR; the next one
                    // starts after the LF.
                    starts.append(offset + width)
                    offset += width
                    continue
                }
                starts.append(offset)  // a lone CR ended the previous line
            }
            switch scalar {
            case "\n":
                if !currentCheckpoints.isEmpty {
                    checkpoints[starts.count - 1] = currentCheckpoints
                    currentCheckpoints = []
                }
                ends.append(offset)
                ascii.append(lineASCII)
                lineASCII = true
                lineBytes = 0
                starts.append(offset + width)
            case "\r":
                if !currentCheckpoints.isEmpty {
                    checkpoints[starts.count - 1] = currentCheckpoints
                    currentCheckpoints = []
                }
                ends.append(offset)
                ascii.append(lineASCII)
                lineASCII = true
                lineBytes = 0
                sawCR = true
            default:
                if scalar == "<" { sawAngleBracket = true }
                if !scalar.isASCII { lineASCII = false }
                if !lineASCII,
                   lineBytes - (currentCheckpoints.last?.byteOffset ?? 0) >= Self.checkpointStride {
                    currentCheckpoints.append(ColumnCheckpoint(byteOffset: lineBytes, utf16Offset: offset))
                }
                lineBytes += Self.utf8Width(scalar)
            }
            offset += width
        }
        if sawCR { starts.append(offset) }
        if !currentCheckpoints.isEmpty { checkpoints[starts.count - 1] = currentCheckpoints }
        ends.append(offset)
        ascii.append(lineASCII)

        lineStarts = starts
        lineEnds = ends
        lineIsASCII = ascii
        columnCheckpoints = checkpoints
        mayContainHTML = sawAngleBracket
    }

    /// 0-based index of the line containing `offset`.
    func line(containing offset: Int) -> Int {
        var lo = 0, hi = lineStarts.count - 1, best = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lineStarts[mid] <= offset { best = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return best
    }

    /// UTF-16 offset for a 1-based line and 1-based UTF-8 byte column.
    func offset(line: Int, column: Int) -> Int {
        let index = line - 1
        guard index >= 0 else { return 0 }
        guard index < lineStarts.count else { return length }
        let start = lineStarts[index]
        let end = lineEnds[index]
        let byteOffset = max(0, column - 1)
        if byteOffset == 0 { return start }
        if lineIsASCII[index] { return min(end, start + byteOffset) }

        var utf16 = start
        var bytes = 0
        if let checkpoints = columnCheckpoints[index] {
            var lo = 0, hi = checkpoints.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if checkpoints[mid].byteOffset <= byteOffset { lo = mid + 1 } else { hi = mid }
            }
            if lo > 0 {
                let checkpoint = checkpoints[lo - 1]
                bytes = checkpoint.byteOffset
                utf16 = checkpoint.utf16Offset
            }
        }
        // Read the existing UTF-16 buffer rather than copying the line for
        // every endpoint. A column inside a scalar still rounds up as before.
        while utf16 < end, bytes < byteOffset {
            let unit = text.character(at: utf16)
            switch unit {
            case 0..<0x80: bytes += 1
            case 0x80..<0x800: bytes += 2
            case 0xD800..<0xDC00:
                bytes += 4
                utf16 += 1
            default: bytes += 3
            }
            utf16 += 1
        }
        return min(end, utf16)
    }

    /// Converts a swift-markdown range, shifting line numbers by `lineOffset`
    /// (non-zero when the body was parsed without its front matter, §4.1).
    func range(_ source: SourceRange?, lineOffset: Int = 0) -> NSRange? {
        guard let source else { return nil }
        let lower = offset(line: source.lowerBound.line + lineOffset, column: source.lowerBound.column)
        let upper = offset(line: source.upperBound.line + lineOffset, column: source.upperBound.column)
        guard upper >= lower else { return NSRange(location: lower, length: 0) }
        return NSRange(location: lower, length: upper - lower)
    }

    /// Range of line `index` (0-based), terminator excluded.
    func contentRange(ofLine index: Int) -> NSRange {
        guard index >= 0, index < lineStarts.count else { return NSRange(location: length, length: 0) }
        return NSRange(location: lineStarts[index], length: lineEnds[index] - lineStarts[index])
    }

    /// Range of line `index` (0-based) including its terminator, which is what
    /// whole-line operations (zoom elision, section moves) need.
    func fullRange(ofLine index: Int) -> NSRange {
        guard index >= 0, index < lineStarts.count else { return NSRange(location: length, length: 0) }
        let end = index + 1 < lineStarts.count ? lineStarts[index + 1] : length
        return NSRange(location: lineStarts[index], length: end - lineStarts[index])
    }

    func string(ofLine index: Int) -> String {
        text.substring(with: contentRange(ofLine: index))
    }

    static func utf8Width(_ scalar: Unicode.Scalar) -> Int {
        switch scalar.value {
        case 0..<0x80: return 1
        case 0x80..<0x800: return 2
        case 0x800..<0x1_0000: return 3
        default: return 4
        }
    }
}

// MARK: - Small string helpers shared across the module

extension NSString {
    func character(safeAt index: Int) -> unichar? {
        guard index >= 0, index < length else { return nil }
        return character(at: index)
    }

    /// Offset of the start of the line containing `offset`.
    func lineStart(before offset: Int) -> Int {
        var i = min(offset, length)
        while i > 0 {
            let c = character(at: i - 1)
            if c == 0x0A || c == 0x0D { break }
            i -= 1
        }
        return i
    }

    /// Offset just past the terminator of the line containing `offset`.
    func lineEnd(after offset: Int) -> Int {
        var i = max(0, offset)
        while i < length {
            let c = character(at: i)
            i += 1
            if c == 0x0A { break }
            if c == 0x0D {
                if i < length, character(at: i) == 0x0A { i += 1 }
                break
            }
        }
        return i
    }
}

extension String {
    /// Leading run of spaces and tabs.
    var leadingIndent: String {
        String(prefix { $0 == " " || $0 == "\t" })
    }

    /// Visual width of the leading indent, tabs counted as four columns —
    /// the width CommonMark uses when deciding list nesting.
    var indentColumns: Int {
        var columns = 0
        for ch in self {
            if ch == " " { columns += 1 }
            else if ch == "\t" { columns += 4 - (columns % 4) }
            else { break }
        }
        return columns
    }

    var isBlankLine: Bool { allSatisfy { $0 == " " || $0 == "\t" } }
}
