import Foundation

/// Hash each identifier once, then check its exact spelling. Entries and
/// collision buckets are built once with the language catalog; lookup never
/// allocates a String and preserves first-group precedence.
struct WordTable {
    private struct Entry {
        let word: [UInt8]
        let token: SyntaxToken
    }
    private let buckets: [UInt64: [Entry]]
    private let foldsCase: Bool

    static let empty = WordTable(foldsCase: false, [])

    init(foldsCase: Bool, _ groups: [(SyntaxToken, [String])]) {
        self.foldsCase = foldsCase
        var buckets: [UInt64: [Entry]] = [:]
        var seen = Set<[UInt8]>()
        for (token, spellings) in groups {
            for spelling in spellings {
                let bytes = spelling.utf8.map { foldsCase ? Self.lowered($0) : $0 }
                guard seen.insert(bytes).inserted else { continue }
                var hash: UInt64 = 0xcbf29ce484222325
                for byte in bytes { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
                buckets[hash, default: []].append(Entry(word: bytes, token: token))
            }
        }
        self.buckets = buckets
    }

    func lookup(_ units: [Unit], _ range: Range<Int>) -> SyntaxToken? {
        var hash: UInt64 = 0xcbf29ce484222325
        for index in range {
            let unit = units[index]
            guard unit < 128 else { return nil }
            let byte = foldsCase ? Self.lowered(UInt8(unit)) : UInt8(unit)
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        guard let entries = buckets[hash] else { return nil }
        for entry in entries where entry.word.count == range.count {
            var matches = true
            for offset in entry.word.indices {
                let unit = units[range.lowerBound + offset]
                let byte = foldsCase ? Self.lowered(UInt8(unit)) : UInt8(unit)
                if byte != entry.word[offset] { matches = false; break }
            }
            if matches { return entry.token }
        }
        return nil
    }

    @inline(__always) private static func lowered(_ byte: UInt8) -> UInt8 {
        (byte >= 0x41 && byte <= 0x5A) ? byte + 0x20 : byte
    }
}
