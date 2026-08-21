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
        guard let boundedData = try? handle.read(upToCount: limit + 1) else { return nil }
        let didExceedLimit = boundedData.count > limit
        let data = didExceedLimit ? Data(boundedData.prefix(limit)) : boundedData
        guard let text = decode(data) else { return nil }

        switch hintedPresentation {
        case .prefix:
            return .prefix(text)
        case .full:
            return didExceedLimit ? .prefix(text) : .full(text)
        }
    }

    private static func decode(_ data: Data) -> String? {
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
        } else if String(data: data, encoding: .utf8) != nil {
            bomLength = 0
            encoding = .utf8
            codeUnitWidth = 1
        } else {
            bomLength = 0
            encoding = .isoLatin1
            codeUnitWidth = 1
        }

        var body = Data(data.dropFirst(min(bomLength, data.count)))
        if codeUnitWidth > 1, body.count % codeUnitWidth != 0 {
            body = Data(body.prefix(body.count - (body.count % codeUnitWidth)))
        }

        let text: String
        if let decoded = String(data: body, encoding: encoding) {
            text = decoded
        } else {
            // A UTF-8 head can end in a torn scalar.  Trim only the small
            // trailing suffix needed to recover a valid preview.
            guard encoding == .utf8 else { return nil }
            var recovered: String?
            for drop in 1...3 where body.count > drop {
                recovered = String(data: body.dropLast(drop), encoding: .utf8)
                if recovered != nil { break }
            }
            guard let recovered else { return nil }
            text = recovered
        }
        return normalizeLineEndings(text)
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
