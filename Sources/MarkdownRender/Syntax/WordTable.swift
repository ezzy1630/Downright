import Foundation

/// Keyword lookup that allocates nothing at scan time.
///
/// Every keyword in every supported language is ASCII, so a sorted byte table
/// plus a binary search is exact.  The alternative — a `Set<String>` — costs a
/// `String` construction per identifier, on every identifier, on every code
/// block, on every restyle.  That is the one allocation the hot path cannot
/// afford, so it is designed out rather than optimised later.
struct WordTable {
    /// Sorted ascending by `words` so `lookup` can binary-search.
    private let words: [[UInt8]]
    private let tokens: [SyntaxToken]
    private let foldsCase: Bool

    static let empty = WordTable(foldsCase: false, [])

    /// - Parameter groups: `(classification, spellings)`.  Earlier groups win a
    ///   collision, so a word listed as both a keyword and a type resolves to
    ///   whichever group is listed first.
    init(foldsCase: Bool, _ groups: [(SyntaxToken, [String])]) {
        self.foldsCase = foldsCase
        var pairs: [(word: [UInt8], token: SyntaxToken)] = []
        var seen = Set<[UInt8]>()
        for (token, spellings) in groups {
            for spelling in spellings {
                let bytes = Array(spelling.utf8).map { foldsCase ? WordTable.lowered($0) : $0 }
                guard seen.insert(bytes).inserted else { continue }
                pairs.append((bytes, token))
            }
        }
        pairs.sort { WordTable.less($0.word, $1.word) }
        words = pairs.map(\.word)
        tokens = pairs.map(\.token)
    }

    /// Classification of `units[range]`, or `nil` when the word is not a
    /// reserved spelling in this language.
    func lookup(_ units: [Unit], _ range: Range<Int>) -> SyntaxToken? {
        var low = 0
        var high = words.count
        while low < high {
            let mid = (low + high) / 2
            switch compare(words[mid], units, range) {
            case .orderedSame: return tokens[mid]
            case .orderedAscending: low = mid + 1
            case .orderedDescending: high = mid
            }
        }
        return nil
    }

    // MARK: - Ordering

    @inline(__always) private static func lowered(_ b: UInt8) -> UInt8 {
        (b >= 0x41 && b <= 0x5A) ? b + 0x20 : b
    }

    private static func less(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        for i in 0..<Swift.min(a.count, b.count) where a[i] != b[i] { return a[i] < b[i] }
        return a.count < b.count
    }

    /// Orders a table entry against a slice of scanned units.  Units above 0x7F
    /// cannot equal any ASCII byte and sort after all of them, which keeps the
    /// comparison a total order — required for the binary search to be correct.
    private func compare(_ word: [UInt8], _ units: [Unit], _ range: Range<Int>) -> ComparisonResult {
        let length = range.count
        let shared = Swift.min(word.count, length)
        for i in 0..<shared {
            let raw = units[range.lowerBound + i]
            let unit = foldsCase && raw < 0x80 ? Unit(WordTable.lowered(UInt8(raw))) : raw
            let byte = Unit(word[i])
            if byte != unit { return byte < unit ? .orderedAscending : .orderedDescending }
        }
        if word.count == length { return .orderedSame }
        return word.count < length ? .orderedAscending : .orderedDescending
    }
}
