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
        let body = data.dropFirst(bom?.length ?? 0)

        let encoding: TextEncodingKind
        var decoded: String?
        if let bom {
            encoding = bom.encoding
            decoded = String(data: body, encoding: bom.encoding.stringEncoding)
        } else if let utf8 = String(data: body, encoding: .utf8) {
            encoding = .utf8
            decoded = utf8
        } else {
            // Latin-1 never fails, which is precisely why it is the fallback
            // and never a guess we make ahead of UTF-8.
            encoding = .latin1
            decoded = String(data: body, encoding: .isoLatin1)
        }
        guard let raw = decoded else { throw DocumentIOError.undecodable(url) }

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
                hasBOM: bom != nil,
                lineEnding: ending,
                hasTrailingNewline: text.hasSuffix("\n")
            )
        )
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
        let bytes = [UInt8](data.prefix(3))
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
