import Foundation

// MARK: - Subtree hashing (§3.5)
//
// FNV-1a over the block kind, its source bytes and its children's hashes.  Not
// cryptographic and doesn't need to be: 64 bits over a document's worth of
// blocks makes a collision vanishingly unlikely.  It is chosen over SipHash
// because it is seedless and therefore stable across launches, which is what
// lets a hash be compared with one computed by the previous parse.
//
// Be honest about the failure mode if you touch this: equal hashes are read as
// "unchanged" by every consumer, so a collision does not cost redundant work —
// it *misses* a restyle (ASTDiff treats the pair as equal) or replays a stale
// attribute program (the decoration program cache keys on this hash). FNV-1a
// is linear and seedless, so collisions are constructible by an adversary who
// controls document bytes; accidental ones are not a realistic concern.

enum FNV {
    static let offsetBasis: UInt64 = 0xcbf2_9ce4_8422_2325
    static let prime: UInt64 = 0x100_0000_01b3

    @inline(__always)
    static func combine(_ hash: UInt64, byte: UInt8) -> UInt64 {
        (hash ^ UInt64(byte)) &* prime
    }

    @inline(__always)
    static func combine(_ hash: UInt64, _ value: UInt64) -> UInt64 {
        var h = hash
        var v = value
        for _ in 0..<8 {
            h = combine(h, byte: UInt8(truncatingIfNeeded: v))
            v >>= 8
        }
        return h
    }

    static func combine(_ hash: UInt64, _ string: String) -> UInt64 {
        var h = hash
        for byte in string.utf8 { h = combine(h, byte: byte) }
        return h
    }

    static func hash(_ string: String) -> UInt64 {
        combine(offsetBasis, string)
    }

    /// FNV-1a over a run of UTF-16 code units.  Hashing directly from the
    /// NSString never materialises an intermediate `String`, which is the
    /// dominant allocation in the per-keystroke reparse path (§3.5).
    @inline(__always)
    static func combine(_ hash: UInt64, utf16 units: UnsafePointer<unichar>, count: Int) -> UInt64 {
        var h = hash
        for i in 0..<count {
            let unit = units[i]
            h = combine(h, byte: UInt8(truncatingIfNeeded: unit))
            h = combine(h, byte: UInt8(unit >> 8))
        }
        return h
    }

    /// FNV-1a over a UTF-16 `NSRange` of `text`, in 256-unit chunks so no
    /// intermediate `String` or large scratch buffer is ever allocated.
    static func combine(_ hash: UInt64, _ text: NSString, range: NSRange) -> UInt64 {
        var h = hash
        var buffer = [unichar](repeating: 0, count: 256)
        var index = range.location
        let end = min(range.upperBound, text.length)
        while index < end {
            let chunk = Swift.min(256, end - index)
            text.getCharacters(&buffer, range: NSRange(location: index, length: chunk))
            h = combine(h, utf16: buffer, count: chunk)
            index += chunk
        }
        return h
    }

    static func hash(_ text: NSString, range: NSRange) -> UInt64 {
        combine(offsetBasis, text, range: range)
    }
}
