import Foundation

/// Whether SwiftMath can reach its own font resources — answered once, before
/// any formula is handed to it.
///
/// Every route into SwiftMath (`MTMathImage` → `MTFontManager` → `MTFont`)
/// loads `latinmodern-math.otf` from a resource bundle, and a miss is not a
/// failed formula: `BundleManager.onDemandRegistration` calls `fatalError`.
/// Inside the sandboxed Quick Look extension that trap is not a degraded
/// formula, it is the whole preview — any document containing math took the
/// extension down.
///
/// SwiftMath is vendored (`Vendor/SwiftMath`, see its PATCHES.md), so the
/// lookup itself is now correct in a shipped bundle: `MathResourceBundle`
/// replaced SwiftPM's generated `Bundle.module`, whose only resolvable
/// candidate was an absolute path inside the build directory.  This guard
/// stays as defence in depth, for the case the fonts are genuinely absent —
/// a bundle assembled wrong, or a copy that lost the `.otf`.
///
/// The candidates are chosen differently from `ThemeStore.resourceBundle`'s.
/// There we resolve a bundle for our own use, so any layout holding the file
/// will do.  Here we are predicting where *SwiftMath* will look, so this list
/// must mirror `MathResourceBundle.resources` exactly: a hit somewhere it does
/// not search is a false positive, and a false positive is the crash.
enum MathFontBundle {

    /// `true` when SwiftMath's resolver will find its fonts in this process.
    static let isAvailable: Bool = probe(roots: candidateRoots)

    /// The predicate itself, over an explicit list of roots.
    ///
    /// Separated from `isAvailable` so a test can hand it a materialised bundle
    /// in either layout and assert it agrees with what `Bundle` — which is how
    /// `MathResourceBundle` actually resolves the font — would have found. The
    /// bug this guards is a probe that is stricter than the resolver it
    /// predicts, whose only symptom is math quietly not rendering.
    static func probe(roots: [URL]) -> Bool {
        let fileManager = FileManager.default
        return roots.contains { root in
            let bundle = root.appendingPathComponent(bundleName)
            return probePaths.contains { probe in
                fileManager.fileExists(atPath: bundle.appendingPathComponent(probe).path)
            }
        }
    }

    /// What `MathResourceBundle` would resolve for the same roots.  A test pins
    /// the two together; nothing else should need this.
    static func resolverWouldFind(roots: [URL]) -> Bool {
        roots.contains { root in
            guard let bundle = Bundle(url: root.appendingPathComponent(bundleName)),
                  let fonts = bundle.url(forResource: "mathFonts", withExtension: "bundle")
            else { return false }
            // The font file itself, not the directory over it. SwiftMath
            // force-unwraps its way down to this `.otf`, so a bundle that lost
            // it in an incomplete copy must read as a miss on both sides —
            // otherwise the oracle cannot catch the false positive `probe` is
            // here to avoid.
            return FileManager.default.fileExists(
                atPath: fonts.appendingPathComponent("latinmodern-math.otf").path)
        }
    }

    private static let bundleName = "SwiftMath_SwiftMath.bundle"

    /// SwiftMath force-unwraps its way from the resource bundle to this file,
    /// so probing the `.otf` itself — rather than the bundle around it — also
    /// covers a bundle that was copied incompletely.  Latin Modern is the face
    /// every render starts from (`MTFontManager.latinModernFont`).
    ///
    /// Both layouts a resource bundle comes in have to be listed, because
    /// `MathResourceBundle` reaches the fonts through `Bundle`, which resolves
    /// either one.  SwiftPM has emitted a flat bundle and — from Swift 6.4's
    /// build layout — a deep one; the release pipeline flattens deep bundles
    /// before signing, so a flat-only probe agreed with SwiftMath in a shipped
    /// app while silently declining every formula under `swift test`.  A probe
    /// that is stricter than the resolver it predicts is a false negative, and
    /// a false negative here means math quietly stops rendering.
    private static let probePaths = [
        "mathFonts.bundle/latinmodern-math.otf",
        "Contents/Resources/mathFonts.bundle/latinmodern-math.otf",
    ]

    /// The roots `MathResourceBundle.resources` consults, in its order.
    ///
    /// `Bundle(for:)` here anchors to MarkdownRender rather than to SwiftMath,
    /// which is the same bundle in every configuration we ship: both modules
    /// are statically linked into whichever executable or framework loads
    /// them.
    ///
    /// The one candidate deliberately left out is the vendored resolver's last
    /// resort, `Bundle.module` — its absolute build-directory path resolves
    /// only on the machine that compiled the code, so predicting it would buy
    /// nothing anywhere else and reintroduce a build-machine-only answer here.
    /// Missing it can only make us decline a formula SwiftMath could have
    /// typeset, never the reverse.
    private static var candidateRoots: [URL] {
        let token = Bundle(for: BundleToken.self)
        return [
            // A deep bundle's Contents/Resources: Downright.app, and an
            // .appex built by Xcode.
            Bundle.main.resourceURL,
            // The bundle this code was loaded from — correct for a framework,
            // a deep .appex, and a flat .appex alike.
            token.resourceURL,
            // `swift test`: Bundle.main is the xctest tool, so the resource
            // bundles sit beside the .xctest bundle we were loaded from.
            token.bundleURL.deletingLastPathComponent(),
            // A flat bundle root: `swift run`, and the .appex layout that
            // Scripts/bundle-quicklook.sh assembles.
            Bundle.main.bundleURL,
        ].compactMap { $0 }
    }
}

/// Anchors `Bundle(for:)` to whichever bundle this module was loaded from.
private final class BundleToken {}
