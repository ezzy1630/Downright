import Foundation

// MARK: - Subtree hashing (§3.5)
//
// FNV-1a over the block kind, its source bytes and its children's hashes.  Not
// cryptographic and doesn't need to be: a collision costs one redundant
// re-decoration, and 64 bits over a document's worth of blocks makes even that
// vanishingly unlikely.  It is chosen over SipHash because it is seedless and
// therefore stable across launches, which is what lets a hash be compared with
// one computed by the previous parse.

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
}
