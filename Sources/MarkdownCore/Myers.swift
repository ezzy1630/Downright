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

        let max = Swift.min(n + m, maxDistance)
        let offset = max
        var v = [Int](repeating: 0, count: 2 * max + 1)
        var trace: [[Int]] = []
        trace.reserveCapacity(max + 1)

        for d in 0...max {
            trace.append(v)
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
                    return backtrack(trace: trace, d: d, offset: offset, n: n, m: m)
                }
            }
        }
        return nil
    }

    private static func backtrack(
        trace: [[Int]], d finalD: Int, offset: Int, n: Int, m: Int
    ) -> [Step] {
        var steps: [Step] = []
        var x = n, y = m
        var d = finalD
        while d > 0 {
            let v = trace[d]
            let k = x - y
            let previousK: Int
            if k == -d || (k != d && v[k - 1 + offset] < v[k + 1 + offset]) {
                previousK = k + 1
            } else {
                previousK = k - 1
            }
            let previousX = v[previousK + offset]
            let previousY = previousX - previousK

            while x > previousX, y > previousY {
                x -= 1; y -= 1
                steps.append(.equal(oldIndex: x, newIndex: y))
            }
            if x > previousX {
                x -= 1
                steps.append(.delete(oldIndex: x))
            } else if y > previousY {
                y -= 1
                steps.append(.insert(newIndex: y))
            }
            d -= 1
        }
        while x > 0, y > 0 {
            x -= 1; y -= 1
            steps.append(.equal(oldIndex: x, newIndex: y))
        }
        return steps.reversed()
    }
}
