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
    static let isAvailable: Bool = {
        let fileManager = FileManager.default
        return candidateRoots.contains { root in
            fileManager.fileExists(
                atPath: root.appendingPathComponent(bundleName)
                    .appendingPathComponent(probePath).path)
        }
    }()

    private static let bundleName = "SwiftMath_SwiftMath.bundle"

    /// SwiftMath force-unwraps its way from the resource bundle to this file,
    /// so probing the `.otf` itself — rather than the bundle around it — also
    /// covers a bundle that was copied incompletely.  Latin Modern is the face
    /// every render starts from (`MTFontManager.latinModernFont`).
    private static let probePath = "mathFonts.bundle/latinmodern-math.otf"

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
