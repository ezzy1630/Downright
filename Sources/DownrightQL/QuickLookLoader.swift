import Foundation

/// The result of a bounded Quick Look load.  A file that was small when the
/// preview request began can grow before its handle is opened; in that case it
/// is treated exactly like the large-file path instead of being read whole.
enum QuickLookLoadedContent: Equatable, Sendable {
    case full(String)
    case prefix(String)
}

/// Reads preview input without ever materialising more than the policy allows.
///
/// The initial stat is only a hint.  The handle read is independently capped,
/// so replacing a small file with a large one between stat and open cannot
/// turn the full path into an unbounded allocation.
enum QuickLookLoader {
    static func load(
        contentsOf url: URL,
        hintedByteCount: Int,
        beforeRead: (@Sendable () -> Void)? = nil
    ) -> QuickLookLoadedContent? {
        let hintedPresentation = QuickLookPolicy.presentation(forByteCount: hintedByteCount)
        let limit: Int
        switch hintedPresentation {
        case .full:
            limit = QuickLookPolicy.fullReadLimitBytes
        case .prefix:
            limit = QuickLookPolicy.prefixReadLimitBytes
        }

        beforeRead?()
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        // One sentinel byte tells us whether the file exceeded the cap while
        // keeping the allocation strictly bounded (limit + 1 bytes).
        let boundedData: Data
        do { boundedData = try handle.read(upToCount: limit + 1) ?? Data() }
        catch { return nil }
        let didExceedLimit = boundedData.count > limit
        let data = didExceedLimit ? Data(boundedData.prefix(limit)) : boundedData
        guard let text = decode(data, nextByte: didExceedLimit ? boundedData.last : nil) else { return nil }

        switch hintedPresentation {
        case .prefix:
            return .prefix(text)
        case .full:
            return didExceedLimit ? .prefix(text) : .full(text)
        }
    }

    private static func decode(_ data: Data, nextByte: UInt8?) -> String? {
        let bytes = [UInt8](data.prefix(4))
        let bomLength: Int
        let encoding: String.Encoding
        let codeUnitWidth: Int

        if bytes.count >= 4, bytes == [0xFF, 0xFE, 0x00, 0x00] {
            bomLength = 4
            encoding = .utf32LittleEndian
            codeUnitWidth = 4
        } else if bytes.count >= 4, bytes == [0x00, 0x00, 0xFE, 0xFF] {
            bomLength = 4
            encoding = .utf32BigEndian
            codeUnitWidth = 4
        } else if bytes.count >= 3, bytes.prefix(3).elementsEqual([0xEF, 0xBB, 0xBF]) {
            bomLength = 3
            encoding = .utf8
            codeUnitWidth = 1
        } else if bytes.count >= 2, bytes.prefix(2).elementsEqual([0xFF, 0xFE]) {
            bomLength = 2
            encoding = .utf16LittleEndian
            codeUnitWidth = 2
        } else if bytes.count >= 2, bytes.prefix(2).elementsEqual([0xFE, 0xFF]) {
            bomLength = 2
            encoding = .utf16BigEndian
            codeUnitWidth = 2
        } else if let guessed = sniffBOMlessEncoding(data) {
            bomLength = 0
            encoding = guessed.encoding
            codeUnitWidth = guessed.width
        } else {
            // An otherwise UTF-8 prefix can end partway through a scalar.
            // Recover it before treating the whole file as Latin-1.
            return (decodeUTF8(data, nextByte: nextByte)
                ?? String(data: data, encoding: .isoLatin1)).map(normalizeLineEndings)
        }

        var body = Data(data.dropFirst(min(bomLength, data.count)))
        if codeUnitWidth > 1, body.count % codeUnitWidth != 0 {
            body = Data(body.prefix(body.count - (body.count % codeUnitWidth)))
        }

        if encoding == .utf8 {
            // The BOM settles the encoding, so a scalar torn at the end of the
            // file (not only at the cap) is trimmed rather than failing.
            return decodeUTF8(body, nextByte: nextByte, encodingIsKnown: true).map(normalizeLineEndings)
        }
        if let decoded = String(data: body, encoding: encoding) {
            return normalizeLineEndings(decoded)
        }
        // A UTF-16 cap can land on a whole code unit but leave its partner
        // surrogate unread. Remove the high surrogate only at a known cut.
        guard nextByte != nil, codeUnitWidth == 2,
              let highByte = encoding == .utf16LittleEndian ? body.last : body.suffix(2).first,
              (0xD8...0xDB).contains(highByte) else { return nil }
        return String(data: body.dropLast(2), encoding: encoding).map(normalizeLineEndings)
    }

    private static func decodeUTF8(_ data: Data, nextByte: UInt8?, encodingIsKnown: Bool = false) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        // Without a BOM, trim only at a known cut: the sentinel continues the
        // torn scalar.  Otherwise the bytes may simply be Latin-1.
        guard encodingIsKnown || nextByte.map({ (0x80...0xBF).contains($0) }) == true else { return nil }
        for count in 1...min(3, data.count) {
            let suffix = data.suffix(count)
            guard let lead = suffix.first, (0xC2...0xF4).contains(lead),
                  suffix.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { continue }
            let scalarWidth = lead < 0xE0 ? 2 : (lead < 0xF0 ? 3 : 4)
            if count < scalarWidth {
                return String(data: data.dropLast(count), encoding: .utf8)
            }
        }
        return nil
    }

    private static func sniffBOMlessEncoding(_ data: Data) -> (encoding: String.Encoding, width: Int)? {
        guard data.count >= 4 else { return nil }
        let bytes = [UInt8](data.prefix(min(data.count, 256)))
        var evenNULs = 0
        var oddNULs = 0
        for (index, byte) in bytes.enumerated() where byte == 0 {
            if index.isMultiple(of: 2) { evenNULs += 1 } else { oddNULs += 1 }
        }
        let count = Double(bytes.count)
        let evenRatio = Double(evenNULs) / count
        let oddRatio = Double(oddNULs) / count
        if evenRatio >= 0.3, evenRatio > oddRatio * 2 {
            return (.utf16BigEndian, 2)
        }
        if oddRatio >= 0.3, oddRatio > evenRatio * 2 {
            return (.utf16LittleEndian, 2)
        }
        if evenRatio >= 0.45, oddRatio >= 0.45,
           let firstNonZero = bytes.firstIndex(where: { $0 != 0 }) {
            return (firstNonZero.isMultiple(of: 4) ? .utf32LittleEndian : .utf32BigEndian, 4)
        }
        return nil
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        var sawLF = false
        var sawCRLF = false
        var sawCR = false
        var previousWasCR = false
        for scalar in text.unicodeScalars {
            if previousWasCR {
                if scalar == "\n" {
                    sawCRLF = true
                    previousWasCR = false
                    continue
                }
                sawCR = true
                previousWasCR = false
            }
            if scalar == "\r" {
                previousWasCR = true
            } else if scalar == "\n" {
                sawLF = true
            }
        }
        if previousWasCR { sawCR = true }
        if sawCRLF, !sawLF, !sawCR {
            return text.replacingOccurrences(of: "\r\n", with: "\n")
        }
        if sawCR, !sawLF, !sawCRLF {
            return text.replacingOccurrences(of: "\r", with: "\n")
        }
        return text
    }
}
