import Foundation
import CryptoKit
import Darwin

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
    case targetChanged(URL, displaced: [Data])
    /// The first swap succeeded, but the displaced generation could not be
    /// read back. `recoveryURL` is deliberately part of the error: the
    /// caller must never mistake the public path (which now contains our
    /// bytes) for the external generation that was preserved beside it.
    case displacedGenerationUnreadable(URL, recoveryURL: URL, underlying: Error)

    public var errorDescription: String? {
        switch self {
        case .undecodable(let url):
            return "Could not decode \(url.lastPathComponent) as text."
        case .unencodable(let encoding):
            return "The document contains characters that cannot be written as \(encoding.rawValue)."
        case .targetChanged(let url, _):
            return "\(url.lastPathComponent) changed while it was being saved. The external bytes were restored."
        case .displacedGenerationUnreadable(let url, let recoveryURL, _):
            return "\(url.lastPathComponent) could not be reconciled while it was being saved. The external bytes were preserved at \(recoveryURL.lastPathComponent)."
        }
    }
}

public enum DocumentIO {
    public static func read(contentsOf url: URL) throws -> (text: String, fidelity: ByteFidelity) {
        let snapshot = try readSnapshot(contentsOf: url)
        return (snapshot.text, snapshot.fidelity)
    }

    /// One read, used by save reconciliation so decoded text, byte fidelity,
    /// and the generation token always describe the same filesystem snapshot.
    public static func readSnapshot(
        contentsOf url: URL
    ) throws -> (text: String, fidelity: ByteFidelity, data: Data) {
        let data = try Data(contentsOf: url)
        let decoded = try decode(data, from: url)
        return (decoded.text, decoded.fidelity, data)
    }

    /// Decodes bytes already captured by the guarded save protocol without
    /// reopening a path that may now name a different generation.
    public static func decodeSnapshot(
        _ data: Data, sourceURL: URL
    ) throws -> (text: String, fidelity: ByteFidelity) {
        try decode(data, from: sourceURL)
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
        try encodedData(text, fidelity: fidelity).write(to: url, options: .atomic)
    }

    /// Replaces an existing path without a check/write gap. `RENAME_SWAP`
    /// moves the exact displaced generation to the temporary path atomically;
    /// if it is not the generation the caller inspected, a second swap puts
    /// those external bytes back and the save fails closed. A concurrently
    /// deleted target makes the first swap fail, so this operation never
    /// recreates a missing file.
    public static func replaceExistingAtomically(
        with data: Data,
        at url: URL,
        expected: Data
    ) throws {
        try replaceExistingAtomically(
            with: data, at: url, expected: expected,
            afterDisplacedRead: nil, afterSwap: nil
        )
    }

    /// Deterministic seam for the two-swap conflict rollback. Kept internal so
    /// production callers cannot insert work inside the atomic protocol.
    static func replaceExistingAtomicallyForTesting(
        with data: Data,
        at url: URL,
        expected: Data,
        afterDisplacedRead: @escaping () -> Void,
        afterSwap: ((URL) -> Void)? = nil
    ) throws {
        try replaceExistingAtomically(
            with: data, at: url, expected: expected,
            afterDisplacedRead: afterDisplacedRead,
            afterSwap: afterSwap
        )
    }

    private static func replaceExistingAtomically(
        with data: Data,
        at url: URL,
        expected: Data,
        afterDisplacedRead: (() -> Void)?,
        afterSwap: ((URL) -> Void)?
    ) throws {
        let directory = url.deletingLastPathComponent()
        let temporary = directory.appendingPathComponent(".downright-save-\(UUID().uuidString)")
        // Once the first swap succeeds, this path owns the displaced
        // generation. Keep it until that generation has been read and the
        // two-swap reconciliation has completed; a read failure must leave a
        // recoverable URL rather than silently deleting the only external
        // bytes.
        var mayRemoveTemporary = false
        defer {
            if mayRemoveTemporary { try? FileManager.default.removeItem(at: temporary) }
        }
        try data.write(to: temporary, options: .withoutOverwriting)

        if let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let permissions = attributes[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: permissions], ofItemAtPath: temporary.path)
        }

        guard renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
            throw posixRenameError(path: url.path)
        }
        afterSwap?(temporary)
        let displaced: Data
        do {
            displaced = try Data(contentsOf: temporary)
        } catch {
            throw DocumentIOError.displacedGenerationUnreadable(
                url, recoveryURL: temporary, underlying: error
            )
        }
        guard displaced == expected else {
            afterDisplacedRead?()
            // Swap, rather than replace, so a writer that landed after our
            // first swap is retained at `temporary` instead of being erased.
            guard renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
                throw posixRenameError(path: url.path)
            }
            let postSwapTemporary: Data
            do {
                postSwapTemporary = try Data(contentsOf: temporary)
            } catch {
                // The public path now contains the external generation and
                // the temporary path contains our attempted payload. Keep
                // the latter too so no generation is silently lost. The
                // recoverable external generation is the public path here.
                throw DocumentIOError.displacedGenerationUnreadable(
                    url, recoveryURL: url, underlying: error
                )
            }
            if postSwapTemporary != data {
                // Another writer replaced our payload between the two swaps.
                // Put that newest external generation back at the public path;
                // both external generations travel in the error so the caller
                // can persist history before releasing the temporary file.
                guard renamex_np(temporary.path, url.path, UInt32(RENAME_SWAP)) == 0 else {
                    throw posixRenameError(path: url.path)
                }
                mayRemoveTemporary = true
                throw DocumentIOError.targetChanged(
                    url, displaced: [displaced, postSwapTemporary]
                )
            }
            mayRemoveTemporary = true
            throw DocumentIOError.targetChanged(url, displaced: [displaced])
        }
        // The inspected generation matched. The displaced file has now been
        // read safely and no longer needs a recovery URL.
        mayRemoveTemporary = true
    }

    private static func posixRenameError(path: String) -> Error {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSFilePathErrorKey: path]
        )
    }

    /// The exact bytes `write` will place on disk. Callers that coordinate a
    /// filesystem watcher use this to reconcile their own atomic replacement
    /// by content rather than by a timing window.
    public static func encodedData(_ text: String, fidelity: ByteFidelity) throws -> Data {
        try encode(text, fidelity: fidelity)
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
        // The text buffer owns whether a final newline exists. Fidelity owns
        // how that newline is encoded, never whether a user's edit survives.
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
