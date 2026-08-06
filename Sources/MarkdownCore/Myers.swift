import Foundation

// MARK: - Myers diff
//
// One O(ND) implementation, shared by the AST diff (over subtree hashes) and
// the text diff (over line and word hashes).  §12's keystroke budget is 8ms
// p95 on a 5k-line document, so this has to stay linear in the *edit distance*
// rather than in the document size — which it is, and which a naive LCS DP
// would not be.
//
// `maxDistance` is the escape hatch: two completely unrelated documents have an
// edit distance near N+M, and the caller would rather have "everything
// changed" instantly than an exact script eventually.
//
// The worst case is bounded twice over, because the classic Myers trace is
// O(D²) memory and an agent rewrite can otherwise spike hundreds of MB:
//
//  1. **Edge trimming.** Shared leading and trailing runs are peeled off before
//     the grid is built.  The common agent-edit shapes — a tail change, a
//     middle hunk, an append — shrink the working distance to a handful of
//     steps, which is where the 8ms budget actually lives.
//  2. **Provable lower-bound bail.** When both sides are large we count how
//     many new elements can possibly match (presence in the old set).  That
//     yields a lower bound on the edit distance; when it already exceeds
//     `maxDistance` the search is doomed, so we return nil *before* allocating
//     the trace.  Two unrelated 5k-line documents never build a 4096×8193
//     ladder.

enum Myers {
    enum Step {
        case equal(oldIndex: Int, newIndex: Int)
        case delete(oldIndex: Int)
        case insert(newIndex: Int)
    }

    /// Edit script transforming `old` into `new`, or `nil` when the distance
    /// exceeds `maxDistance`.
    static func diff(
        _ old: [UInt64], _ new: [UInt64], maxDistance: Int = 4096
    ) -> [Step]? {
        let n = old.count, m = new.count
        if n == 0 { return (0..<m).map { .insert(newIndex: $0) } }
        if m == 0 { return (0..<n).map { .delete(oldIndex: $0) } }

        // Shared edges are free.  Peel them off so the grid only spans the
        // genuinely different middle; the script below is reassembled around it.
        var prefix = 0
        while prefix < n, prefix < m, old[prefix] == new[prefix] { prefix += 1 }
        var hiOld = n, hiNew = m
        while hiOld > prefix, hiNew > prefix, old[hiOld - 1] == new[hiNew - 1] {
            hiOld -= 1
            hiNew -= 1
        }

        // With the edges gone, a lower bound on the distance is N+M-2K where K
        // is the number of elements one side can match in the other.  If that
        // bound already blows the cap the search is provably doomed; the only
        // correct outcome is nil, and reaching it without the trace is the
        // whole point.  (Cheap O(N+M) scan — the Set is built from the smaller
        // side — and we stop counting as soon as the bound drops under the
        // cap.  The `n + m > maxDistance` gate covers the N+M ≈ cap boundary,
        // where a disjoint pair would otherwise build the full ladder.  It
        // uses a small margin so a pair that sits just under the cap is caught
        // too: that band is exactly where a large-but-dissimilar document
        // would otherwise allocate the full O(D²) trace.)
        let smaller = Swift.min(n, m)
        if smaller >= 256, n + m >= maxDistance - 4 {
            let small = n <= m ? old : new
            let large = n <= m ? new : old
            var present = Set<UInt64>()
            present.reserveCapacity(smaller)
            for hash in small { present.insert(hash) }
            // Enough matches that N+M-2K ≤ maxDistance proves success is still
            // possible; below that the search is provably doomed.
            let matchTarget = (n + m - maxDistance + 1) / 2
            var matched = 0
            for hash in large {
                if present.contains(hash) {
                    matched += 1
                    if matched >= matchTarget { break }
                }
            }
            if matched < matchTarget { return nil }
        }

        var steps: [Step] = []
        steps.reserveCapacity(n + m)
        if prefix > 0 {
            steps.append(contentsOf: (0..<prefix).map { .equal(oldIndex: $0, newIndex: $0) })
        }

        let midOld = hiOld - prefix
        let midNew = hiNew - prefix
        if midOld == 0 {
            steps.append(contentsOf: (prefix..<hiNew).map { .insert(newIndex: $0) })
        } else if midNew == 0 {
            steps.append(contentsOf: (prefix..<hiOld).map { .delete(oldIndex: $0) })
        } else if let middle = diffCore(
            old: Array(old[prefix..<hiOld]),
            new: Array(new[prefix..<hiNew]),
            base: prefix,
            maxDistance: maxDistance
        ) {
            steps.append(contentsOf: middle)
        } else {
            return nil
        }

        let suffixLength = n - hiOld   // == m - hiNew after the trim loop
        for offset in 0..<suffixLength {
            steps.append(.equal(oldIndex: hiOld + offset, newIndex: hiNew + offset))
        }
        return steps
    }

    /// Myers over the trimmed middle, returning steps whose indices are offset
    /// back into the original arrays by `base`.
    private static func diffCore(
        old: [UInt64], new: [UInt64], base: Int, maxDistance: Int
    ) -> [Step]? {
        let n = old.count, m = new.count

        let max = Swift.min(n + m, maxDistance)
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 1)
        // The trace is Myers' O(D²) memory.  Each row is stored compactly, at
        // only the width the level actually touches (k ∈ [-d, d]) instead of
        // the full 2·max+1 stride, which keeps a deep but *solved* search from
        // allocating max Distance rows all at full width — the near-cap memory
        // spike.  The total footprint stays O(D_final²) rather than
        // O(D_final · max).
        var trace: [[Int]] = []

        for d in 0...max {
            let used = offset - d
            trace.append(Array(v[used...used + 2 * d]))
            var k = -d
            while k <= d {
                defer { k += 2 }
                var x: Int
                if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                    x = v[k + 1 + offset]
                } else {
                    x = v[k - 1 + offset] + 1
                }
                var y = x - k
                while x < n, y < m, old[x] == new[y] { x += 1; y += 1 }
                v[k + offset] = x
                if x >= n && y >= m {
                    return backtrack(trace: trace, d: d, n: n, m: m, base: base)
                }
            }
        }
        return nil
    }

    private static func backtrack(
        trace: [[Int]], d finalD: Int, n: Int, m: Int, base: Int
    ) -> [Step] {
        var steps: [Step] = []
        var x = n, y = m
        var d = finalD
        while d > 0 {
            // Row indexing is compact: row `d` holds k ∈ [-d, d] at local
            // index k + d.
            let row = trace[d]
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && row[k - 1 + d] < row[k + 1 + d]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = row[previousK + d]
            let previousY = previousX - previousK

            while x > previousX, y > previousY {
                x -= 1; y -= 1
                steps.append(.equal(oldIndex: x + base, newIndex: y + base))
            }
            if x > previousX {
                x -= 1
                steps.append(.delete(oldIndex: x + base))
            } else if y > previousY {
                y -= 1
                steps.append(.insert(newIndex: y + base))
            }
            d -= 1
        }
        while x > 0, y > 0 {
            x -= 1; y -= 1
            steps.append(.equal(oldIndex: x + base, newIndex: y + base))
        }
        return steps.reversed()
    }
}
