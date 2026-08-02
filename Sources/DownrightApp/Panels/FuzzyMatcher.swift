import AppKit

/// Subsequence fuzzy matching for the outline quick-open panel (§7.2).
///
/// A `contains` filter is not enough: typing `dpl` should find "Document
/// **p**ipe**l**ine", and it should rank it above a heading where the same
/// letters happen to fall mid-word.  So this is a real alignment — a small
/// dynamic program over (needle × haystack) that scores word-boundary,
/// prefix, and consecutive-run matches highest, and reports the positions it
/// chose so the panel can highlight exactly the characters that matched.
enum FuzzyMatcher {
    struct Match {
        var score: Int
        /// Character (not UTF-16) offsets into the haystack.
        var positions: [Int]
    }

    // Weights.  Tuned so that, for a two-character query, a prefix match beats
    // a word-boundary match beats a consecutive mid-word run beats a scattered
    // match — which is the ordering people actually expect.
    private static let matchBase = 16
    private static let bonusBoundary = 10
    private static let bonusCamel = 8
    private static let bonusConsecutive = 8
    private static let bonusExactCase = 2
    private static let gapStart = -5
    private static let gapExtension = -1
    private static let leadingGapPenalty = -1
    private static let leadingGapFloor = -12
    private static let unreachable = Int.min / 4

    /// Nil when `needle` is not a subsequence of `haystack`.  An empty needle
    /// matches everything with score 0, so an empty query lists the document.
    static func match(needle: String, in haystack: String) -> Match? {
        let needleChars = Array(needle)
        guard !needleChars.isEmpty else { return Match(score: 0, positions: []) }
        let hayChars = Array(haystack)
        guard needleChars.count <= hayChars.count else { return nil }

        let lowerNeedle = needleChars.map { Character($0.lowercased()) }
        let lowerHay = hayChars.map { Character($0.lowercased()) }
        guard isSubsequence(lowerNeedle, of: lowerHay) else { return nil }

        let n = lowerNeedle.count
        let m = lowerHay.count
        let bonuses = positionBonuses(lowerHay, hayChars)

        // score[i][j] — best total with needle[i] aligned to haystack[j].
        var score = [[Int]](repeating: [Int](repeating: unreachable, count: m), count: n)

        for j in 0..<m where lowerHay[j] == lowerNeedle[0] {
            let leading = max(leadingGapFloor, leadingGapPenalty * j)
            score[0][j] = matchBase + bonuses[j] * 2 + caseBonus(needleChars[0], hayChars[j]) + leading
        }

        for i in 1..<n {
            for j in i..<m where lowerHay[j] == lowerNeedle[i] {
                var best = unreachable
                for k in (i - 1)..<j where score[i - 1][k] != unreachable {
                    let candidate = score[i - 1][k] + transition(gap: j - k - 1)
                    if candidate > best { best = candidate }
                }
                guard best != unreachable else { continue }
                score[i][j] = best + matchBase + bonuses[j] + caseBonus(needleChars[i], hayChars[j])
            }
        }

        guard let last = (0..<m).filter({ score[n - 1][$0] != unreachable })
            .max(by: { score[n - 1][$0] < score[n - 1][$1] })
        else { return nil }

        // Traceback inverts the recurrence rather than storing parents: at each
        // step the predecessor is whichever k maximises the same expression the
        // forward pass maximised.
        var positions = [Int](repeating: 0, count: n)
        positions[n - 1] = last
        var j = last
        for i in stride(from: n - 1, to: 0, by: -1) {
            var bestK = i - 1
            var bestValue = unreachable
            for k in (i - 1)..<j where score[i - 1][k] != unreachable {
                let candidate = score[i - 1][k] + transition(gap: j - k - 1)
                if candidate > bestValue { bestValue = candidate; bestK = k }
            }
            positions[i - 1] = bestK
            j = bestK
        }

        return Match(score: score[n - 1][last], positions: positions)
    }

    /// Highlights the matched characters.  Kept here so the character-offset →
    /// UTF-16 conversion exists in exactly one place.
    static func highlighted(
        _ haystack: String,
        positions: [Int],
        base: [NSAttributedString.Key: Any],
        highlight: [NSAttributedString.Key: Any]
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString(string: haystack, attributes: base)
        guard !positions.isEmpty else { return attributed }

        var utf16Offset = 0
        var characterIndex = 0
        let wanted = Set(positions)
        for character in haystack {
            let width = String(character).utf16.count
            if wanted.contains(characterIndex) {
                attributed.addAttributes(highlight, range: NSRange(location: utf16Offset, length: width))
            }
            utf16Offset += width
            characterIndex += 1
        }
        return attributed
    }

    // MARK: - Scoring pieces

    private static func transition(gap: Int) -> Int {
        gap == 0 ? bonusConsecutive : gapStart + gapExtension * (gap - 1)
    }

    private static func caseBonus(_ needle: Character, _ hay: Character) -> Int {
        needle == hay ? bonusExactCase : 0
    }

    /// Word-boundary and camelCase bonuses, precomputed per haystack position.
    private static func positionBonuses(_ lower: [Character], _ original: [Character]) -> [Int] {
        var bonuses = [Int](repeating: 0, count: lower.count)
        for j in 0..<lower.count {
            if j == 0 {
                bonuses[j] = bonusBoundary
            } else if isSeparator(original[j - 1]) {
                bonuses[j] = bonusBoundary
            } else if original[j - 1].isLowercase && original[j].isUppercase {
                bonuses[j] = bonusCamel
            }
        }
        return bonuses
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || "-_/.,:;()[]{}<>#*`\"'".contains(character)
    }

    private static func isSubsequence(_ needle: [Character], of hay: [Character]) -> Bool {
        var index = 0
        for character in hay where character == needle[index] {
            index += 1
            if index == needle.count { return true }
        }
        return false
    }
}
