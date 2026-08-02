import Foundation

enum ReviewAnchorResolver {
    static func makeAnchor(in text: String, range: NSRange, contextLength: Int = 48) -> ReviewAnchor? {
        let source = text as NSString
        guard range.location >= 0, range.length > 0, range.upperBound <= source.length else { return nil }
        let beforeStart = max(0, range.location - contextLength)
        let before = source.substring(with: NSRange(location: beforeStart, length: range.location - beforeStart))
        let afterEnd = min(source.length, range.upperBound + contextLength)
        let after = source.substring(with: NSRange(location: range.upperBound, length: afterEnd - range.upperBound))
        return ReviewAnchor(
            range: range,
            selectedText: source.substring(with: range),
            beforeFingerprint: fingerprint(before),
            afterFingerprint: fingerprint(after)
        )
    }

    static func resolve(_ anchor: ReviewAnchor, in text: String, contextLength: Int = 48) -> ReviewResolution {
        let source = text as NSString
        guard !anchor.selectedText.isEmpty else { return ReviewResolution(status: .orphan, range: nil) }

        if matches(anchor, at: anchor.range.location, in: source, contextLength: contextLength) {
            return ReviewResolution(status: .exact, range: anchor.range)
        }

        var cursor = 0
        var foundSelected = false
        while cursor < source.length {
            let match = source.range(of: anchor.selectedText, options: [], range: NSRange(location: cursor, length: source.length - cursor))
            guard match.location != NSNotFound else { break }
            foundSelected = true
            if matches(anchor, at: match.location, in: source, contextLength: contextLength) {
                return ReviewResolution(status: .shifted, range: match)
            }
            cursor = match.location + max(1, match.length)
        }
        return ReviewResolution(status: foundSelected ? .stale : .orphan, range: nil)
    }

    static func fingerprint(_ value: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in value.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func matches(_ anchor: ReviewAnchor, at location: Int, in source: NSString, contextLength: Int) -> Bool {
        guard location >= 0, location + (anchor.selectedText as NSString).length <= source.length else { return false }
        let selectedLength = (anchor.selectedText as NSString).length
        guard source.substring(with: NSRange(location: location, length: selectedLength)) == anchor.selectedText else { return false }
        let beforeStart = max(0, location - contextLength)
        let before = source.substring(with: NSRange(location: beforeStart, length: location - beforeStart))
        let afterLocation = location + selectedLength
        let afterEnd = min(source.length, afterLocation + contextLength)
        let after = source.substring(with: NSRange(location: afterLocation, length: afterEnd - afterLocation))
        return fingerprint(before) == anchor.beforeFingerprint && fingerprint(after) == anchor.afterFingerprint
    }
}
