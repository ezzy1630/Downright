//
//  MathResourceBundle.swift
//
//  DOWNRIGHT PATCH — not upstream.  See Vendor/SwiftMath/PATCHES.md.
//

import Foundation

/// The bundle that holds `mathFonts.bundle`; a drop-in for `Bundle.module` at
/// the three sites that reach for the math fonts.
///
/// SwiftPM's generated `Bundle.module` offers exactly two candidates: a path
/// beside `Bundle.main.bundleURL`, and an absolute path inside the build
/// directory that compiled the code.  Neither is right once the code ships.
/// `Bundle.main.bundleURL` is a macOS bundle's *root*, where codesign forbids
/// any entry other than `Contents` — so the copy shipped in `Contents/Resources`
/// is never seen — and the build directory exists on the build machine and
/// nowhere else.  What is left resolves only where it was compiled; everywhere
/// else the accessor calls `fatalError`, which inside a Quick Look extension
/// took the whole preview down.
///
/// So resolve against the layouts that actually ship before deferring to
/// `Bundle.module` for `swift run` and `swift test`.
enum MathResourceBundle {

    /// Resolved once, on first use.  A candidate is accepted only when
    /// `mathFonts.bundle` is really inside it: an incompletely copied bundle
    /// must fall through to the next candidate rather than become the answer.
    static let resources: Bundle = {
        let name = "SwiftMath_SwiftMath.bundle"
        let token = Bundle(for: BundleToken.self)
        let roots = [
            // A deep bundle's Contents/Resources — Downright.app, and an
            // .appex built by Xcode.
            Bundle.main.resourceURL,
            // The bundle this code was loaded from.  The important candidate:
            // it is correct for a framework, a deep .appex, and a flat .appex
            // alike, none of which `Bundle.main` describes.
            token.resourceURL,
            // `swift test`: Bundle.main is the xctest tool, so neither of the
            // above helps; the resource bundles sit beside the .xctest bundle.
            token.bundleURL.deletingLastPathComponent(),
            // A flat bundle root — `swift run`, and the .appex layout that
            // Scripts/bundle-quicklook.sh assembles.
            Bundle.main.bundleURL,
        ]
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent(name)),
               bundle.url(forResource: "mathFonts", withExtension: "bundle") != nil {
                return bundle
            }
        }
        return .module
    }()
}

/// Anchors `Bundle(for:)` to whichever bundle this module was loaded from.
private final class BundleToken {}
