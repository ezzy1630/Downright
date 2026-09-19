import Foundation
import Testing
@testable import MarkdownRender

/// `MathFontBundle` exists to predict whether SwiftMath's own resolver will
/// find `latinmodern-math.otf`, because a miss inside SwiftMath is a
/// `fatalError` rather than a failed formula.  A probe that is *stricter* than
/// the resolver is therefore not safe-by-default: it declines formulas SwiftMath
/// could have typeset, and the only symptom is math quietly not rendering.
///
/// That is not hypothetical. The probe checked one hardcoded flat-bundle path
/// while the resolver reaches the font through `Bundle`, which resolves a deep
/// bundle too. When the toolchain started emitting the deep layout, every
/// formula silently declined. These tests pin the two together in both layouts.
@Suite("Math font bundle probe")
struct MathFontBundleTests {
    private let bundleName = "SwiftMath_SwiftMath.bundle"

    /// Where `mathFonts.bundle` sits under `root` in each of the two layouts
    /// SwiftPM has emitted.  Defined once: this suite exists to pin these paths
    /// against drift, so a second copy of the strings would be the very
    /// divergence it is guarding.
    private func fontsDirectory(deep: Bool, in root: URL) -> URL {
        root.appendingPathComponent(bundleName)
            .appendingPathComponent(deep ? "Contents/Resources" : "")
            .appendingPathComponent("mathFonts.bundle")
    }

    /// Materialises a complete `SwiftMath_SwiftMath.bundle` under `root`.
    @discardableResult
    private func makeBundle(deep: Bool, in root: URL) throws -> URL {
        let fonts = fontsDirectory(deep: deep, in: root)
        try FileManager.default.createDirectory(at: fonts, withIntermediateDirectories: true)
        try Data().write(to: fonts.appendingPathComponent("latinmodern-math.otf"))
        return root
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-mathfonts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    @Test(arguments: [false, true])
    func theProbeAgreesWithTheResolverInBothBundleLayouts(deep: Bool) throws {
        try withTemporaryDirectory { root in
            _ = try makeBundle(deep: deep, in: root)
            #expect(MathFontBundle.probe(roots: [root]))
            // The claim that matters: whatever `Bundle` can resolve, the probe
            // must also accept. A future layout change breaks this test rather
            // than silently turning math off.
            #expect(MathFontBundle.resolverWouldFind(roots: [root]))
        }
    }

    @Test func aRootWithoutTheFontIsDeclinedByBoth() throws {
        try withTemporaryDirectory { root in
            #expect(!MathFontBundle.probe(roots: [root]))
            #expect(!MathFontBundle.resolverWouldFind(roots: [root]))
        }
    }

    /// A bundle whose `.otf` was lost in an incomplete copy must not count: the
    /// probe deliberately looks for the font file, not the directory over it.
    @Test(arguments: [false, true])
    func aBundleMissingTheFontFileIsDeclinedByBoth(deep: Bool) throws {
        try withTemporaryDirectory { root in
            // Build the complete bundle, then take away only the font, so this
            // case cannot drift from the layout the tests above assert.
            try makeBundle(deep: deep, in: root)
            try FileManager.default.removeItem(
                at: fontsDirectory(deep: deep, in: root)
                    .appendingPathComponent("latinmodern-math.otf"))
            #expect(!MathFontBundle.probe(roots: [root]))
            // The oracle has to agree, or it cannot witness the incomplete-copy
            // false positive the probe exists to rule out.
            #expect(!MathFontBundle.resolverWouldFind(roots: [root]))
        }
    }

    /// The shipped process has to be able to render math at all: if this fails,
    /// the resource bundle did not reach the test runner and every math test
    /// below it is passing vacuously.
    @Test func theRunningProcessCanReachTheMathFonts() {
        #expect(MathFontBundle.isAvailable)
    }
}
