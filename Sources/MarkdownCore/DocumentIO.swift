import Foundation
import CryptoKit

// MARK: - Document IO (§3.1)
//
// "An agent-written file that passes through this app is unchanged, character
// for character, including its odd spacing and its trailing newline."
//
// The way that is achieved: `read` normalises line endings **only when the file
// uses one ending consistently**, and records exactly what it did in
// `ByteFidelity`.  A file with mixed endings is handed back verbatim with
// `.lf` recorded, so `write` does no conversion at all and the stray `\r`s
// survive as literal characters.  There is deliberately no `.mixed` case to
// get wrong: the invariant is that `write(read(x)) == x` for every input,
// including the ones nobody thought of.

public enum DocumentIOError: Error, LocalizedError {
    case undecodable(URL)
    case unencodable(TextEncodingKind)

    public var errorDescription: String? {
        switch self {
        case .undecodable(let url):
            return "Could not decode \(url.lastPathComponent) as text."
        case .unencodable(let encoding):
            return "The document contains characters that cannot be written as \(encoding.rawValue)."
        }
    }
}

public enum DocumentIO {
    public static func read(contentsOf url: URL) throws -> (text: String, fidelity: ByteFidelity) {
        let data = try Data(contentsOf: url)
        return try decode(data, from: url)
    }

    /// Reads at most `limit` bytes from the head of the file — a bounded read
    /// for surfaces that must never load a huge file whole (Quick Look under
    /// its kill ceiling, thumbnails).  A truncated read can split a multi-byte
    /// UTF-8 scalar, so trailing bytes are trimmed until the head decodes.
    /// Returns `nil` when the file cannot be opened or its head cannot be
    /// decoded at all.
    public static func readHead(contentsOf url: URL, limit: Int) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        if let text = String(data: data, encoding: .utf8) { return text }
        for drop in 1...3 where data.count > drop {
            if let text = String(data: data.dropLast(drop), encoding: .utf8) { return text }
        }
        return String(data: data, encoding: .isoLatin1)
    }

    public static func write(_ text: String, to url: URL, fidelity: ByteFidelity) throws {
        try encode(text, fidelity: fidelity).write(to: url, options: .atomic)
    }

    /// Hex SHA-256 of the text's UTF-8 bytes.  Content-addresses snapshots
    /// (§8.3) and answers "did the file change while I was away" (§8.2).
    public static func contentHash(_ text: String) -> String {
        contentHash(Data(text.utf8))
    }

    /// Hex SHA-256 of raw bytes.  Shared by snapshot objects and sibling
    /// fingerprinting so every content-addressed path uses one digester.
    public static func contentHash(_ data: Data) -> String {
        let hex = Array("0123456789abcdef".utf8)
        let digest = SHA256.hash(data: data)
        var out = ""
        out.reserveCapacity(64)
        for byte in digest {
            out.append(Character(UnicodeScalar(hex[Int(byte >> 4)])))
            out.append(Character(UnicodeScalar(hex[Int(byte & 0x0F)])))
        }
        return out
    }

    // MARK: Decoding

    static func decode(_ data: Data, from url: URL) throws -> (text: String, fidelity: ByteFidelity) {
        let bom = detectBOM(data)
        let hasBOM = bom != nil
        let body = data.dropFirst(bom?.length ?? 0)

        let encoding: TextEncodingKind
        if let bom {
            encoding = bom.encoding
        } else if let guessed = sniffBOMlessUTF16or32(body) {
            // A NUL-padded UTF-16/32 stream also happens to be *valid* UTF-8
            // (a NUL is a legal scalar), so it is checked before UTF-8.  The
            // heuristic only fires on a clearly NUL-structured body — a real
            // UTF-8 or Latin-1 markdown file has no reason to be half NULs —
            // so ordinary text still takes the UTF-8 path below.
            encoding = guessed
        } else if String(data: body, encoding: .utf8) != nil {
            encoding = .utf8
        } else {
            // Latin-1 never fails, which is precisely why it is the fallback
            // and never a guess we make ahead of UTF-8.
            encoding = .latin1
        }

        let raw: String
        if let decoded = String(data: body, encoding: encoding.stringEncoding) {
            raw = decoded
        } else if encoding.codeUnitWidth > 1 {
            // A file truncated mid-code-unit (odd byte count for UTF-16, a
            // byte count not divisible by four for UTF-32) is read up to the
            // last whole code unit rather than rejected outright.  Only trim
            // when the strict-stride decode above actually failed.
            let trimmed = adjustTruncation(body, encoding: encoding)
            guard let recovered = String(data: trimmed, encoding: encoding.stringEncoding) else {
                throw DocumentIOError.undecodable(url)
            }
            raw = recovered
        } else {
            throw DocumentIOError.undecodable(url)
        }

        let ending = dominantLineEnding(raw)
        let text: String
        switch ending {
        case .lf: text = raw
        case .crlf: text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        case .cr: text = raw.replacingOccurrences(of: "\r", with: "\n")
        }

        return (
            text,
            ByteFidelity(
                encoding: encoding,
                hasBOM: hasBOM,
                lineEnding: ending,
                hasTrailingNewline: text.hasSuffix("\n")
            )
        )
    }

    /// Drops the trailing bytes that made a multi-byte decode fail: for UTF-16
    /// a single torn stride byte, for UTF-32 anything up to a code-unit
    /// boundary.
    private static func adjustTruncation(
        _ body: Data, encoding: TextEncodingKind
    ) -> Data {
        let width = encoding.codeUnitWidth
        guard width > 1 else { return body }
        let excess = body.count % width
        guard excess > 0 else { return body }
        return Data(body.dropLast(excess))
    }

    /// Heuristic for a BOM-less UTF-16/32 file.  Any 8-bit file with enough
    /// NUL bytes to look like a packed UTF-16/32 code-unit stream is almost
    /// certainly not Latin-1 (which has no reason to be half NULs), and UTF-8
    /// has already failed.
    private static func sniffBOMlessUTF16or32(_ body: Data) -> TextEncodingKind? {
        guard body.count >= 4 else { return nil }
        let bytes = [UInt8](body.prefix(min(body.count, 256)))
        var even = 0, odd = 0
        for (index, byte) in bytes.enumerated() {
            if byte == 0 { if index % 2 == 0 { even += 1 } else { odd += 1 } }
        }
        let total = bytes.count
        let evenRatio = Double(even) / Double(total)
        let oddRatio = Double(odd) / Double(total)
        if evenRatio >= 0.3, evenRatio > oddRatio * 2 { return .utf16BE }
        if oddRatio >= 0.3, oddRatio > evenRatio * 2 { return .utf16LE }
        // A UTF-32 stream is densely NUL at both parities for ASCII content.
        // The first non-NUL byte's position in its 4-byte word tells the
        // byte order (LE: `XX 00 00 00`, BE: `00 00 00 XX`).
        if evenRatio >= 0.45, oddRatio >= 0.45,
           let firstNonZero = bytes.firstIndex(where: { $0 != 0 }) {
            return firstNonZero % 4 == 3 ? .utf32BE : .utf32LE
        }
        return nil
    }

    static func encode(_ text: String, fidelity: ByteFidelity) throws -> Data {
        var body = text
        if fidelity.hasTrailingNewline {
            if !body.hasSuffix("\n") { body += "\n" }
        } else if body.hasSuffix("\n") {
            body.removeLast()
        }
        switch fidelity.lineEnding {
        case .lf: break
        case .crlf: body = body.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: body = body.replacingOccurrences(of: "\n", with: "\r")
        }

        guard var data = body.data(using: fidelity.encoding.stringEncoding) else {
            throw DocumentIOError.unencodable(fidelity.encoding)
        }
        if fidelity.hasBOM, let bom = bomBytes(for: fidelity.encoding) {
            data = bom + data
        }
        return data
    }

    // MARK: Byte-level facts

    private struct BOM {
        var encoding: TextEncodingKind
        var length: Int
    }

    private static func detectBOM(_ data: Data) -> BOM? {
        let bytes = [UInt8](data.prefix(4))
        // 4-byte BOMs first: a UTF-32LE BOM starts `FF FE`, which a 2-byte
        // check would misread as UTF-16LE, and UTF-32BE is `00 00 FE FF`.
        if bytes.count >= 4, bytes[0] == 0xFF, bytes[1] == 0xFE, bytes[2] == 0x00, bytes[3] == 0x00 {
            return BOM(encoding: .utf32LE, length: 4)
        }
        if bytes.count >= 4, bytes[0] == 0x00, bytes[1] == 0x00, bytes[2] == 0xFE, bytes[3] == 0xFF {
            return BOM(encoding: .utf32BE, length: 4)
        }
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF {
            return BOM(encoding: .utf8, length: 3)
        }
        if bytes.count >= 2, bytes[0] == 0xFF, bytes[1] == 0xFE {
            return BOM(encoding: .utf16LE, length: 2)
        }
        if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] == 0xFF {
            return BOM(encoding: .utf16BE, length: 2)
        }
        return nil
    }

    private static func bomBytes(for encoding: TextEncodingKind) -> Data? {
        switch encoding {
        case .utf8: return Data([0xEF, 0xBB, 0xBF])
        case .utf16LE: return Data([0xFF, 0xFE])
        case .utf16BE: return Data([0xFE, 0xFF])
        case .utf32LE: return Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BE: return Data([0x00, 0x00, 0xFE, 0xFF])
        case .latin1: return nil
        }
    }

    /// `.crlf` or `.cr` only when *every* line break in the file agrees.  A
    /// mixed file reports `.lf`, which makes `write` a no-op on line endings
    /// and keeps the round trip byte-identical.
    static func dominantLineEnding(_ text: String) -> LineEnding {
        var sawLF = false, sawCRLF = false, sawCR = false
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if previousWasCR {
                if scalar == "\n" { sawCRLF = true } else { sawCR = true }
                previousWasCR = false
                if scalar == "\r" { previousWasCR = true }
                continue
            }
            if scalar == "\r" { previousWasCR = true } else if scalar == "\n" { sawLF = true }
        }
        if previousWasCR { sawCR = true }

        if sawCRLF && !sawLF && !sawCR { return .crlf }
        if sawCR && !sawLF && !sawCRLF { return .cr }
        return .lf
    }
}
