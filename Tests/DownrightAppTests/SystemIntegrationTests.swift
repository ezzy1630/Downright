import Foundation
import Testing
@testable import DownrightApp

// MARK: - pluginkit flag semantics
//
// The strings below are real `pluginkit -m -v -i …` output captured on macOS,
// not invented fixtures.  They exist because the flag column reads backwards
// from the obvious and the app got it wrong once: blank means *available*, and
// testing for a leading "+" reports every healthy install as broken.

/// A registered, working extension.  Five leading spaces, no flag.
private let availableListing = """
     com.ezzy.downright.quicklook(1.0)\t6DFDA989-A19F-510C-999F-175575BC16CF\t2026-07-23 03:00:13 +0000\t/Applications/Downright.app/Contents/PlugIns/DownrightQL.appex
 (1 plug-in)
"""

/// The user switched it on by hand in System Settings.
private let explicitlyEnabledListing = """
+    com.ezzy.downright.quicklook(1.0)\tUUID\t2026-07-23 03:00:13 +0000\t/Applications/Downright.app/Contents/PlugIns/DownrightQL.appex
 (1 plug-in)
"""

/// The user switched it off.
private let disabledListing = """
-    com.ezzy.downright.quicklook(1.0)\tUUID\t2026-07-23 03:00:13 +0000\t/Applications/Downright.app/Contents/PlugIns/DownrightQL.appex
 (1 plug-in)
"""

/// Never registered.  Note `pluginkit` exits 0 for this, so the status code
/// cannot be used to detect it.
private let noMatchesListing = "  (no matches)\n"

@Suite("Quick Look extension state")
struct QuickLookPluginKitTests {
    @Test("A blank flag means available, not unknown")
    func blankFlagIsEnabled() {
        #expect(SystemIntegration.isEnabled(
            inPluginKitListing: availableListing,
            identifier: SystemIntegration.previewExtensionIdentifier
        ))
    }

    @Test("An explicit + is enabled")
    func plusFlagIsEnabled() {
        #expect(SystemIntegration.isEnabled(
            inPluginKitListing: explicitlyEnabledListing,
            identifier: SystemIntegration.previewExtensionIdentifier
        ))
    }

    @Test("An explicit - is the only disabled state")
    func minusFlagIsDisabled() {
        #expect(!SystemIntegration.isEnabled(
            inPluginKitListing: disabledListing,
            identifier: SystemIntegration.previewExtensionIdentifier
        ))
    }

    @Test("An unregistered extension is not enabled")
    func noMatchesIsDisabled() {
        #expect(!SystemIntegration.isEnabled(
            inPluginKitListing: noMatchesListing,
            identifier: SystemIntegration.previewExtensionIdentifier
        ))
    }

    @Test("Another plug-in's line never answers for ours")
    func unrelatedListingIsDisabled() {
        let other = "     com.apple.HydraQLPreviewExtension(1.0)\tUUID\n (1 plug-in)"
        #expect(!SystemIntegration.isEnabled(
            inPluginKitListing: other,
            identifier: SystemIntegration.previewExtensionIdentifier
        ))
    }
}

// MARK: - What the app claims

@Suite("Default application claims")
struct DefaultApplicationClaimTests {
    /// `.mdx`, `.qmd`, and `.rmd` belong to VS Code, Quarto, and RStudio.  The
    /// bundle declares them so Downright shows up under Open With, but taking
    /// them as the default without being asked is the behaviour that makes an
    /// app feel like something to defend against.
    @Test("Only the plain-markdown family is claimed as a default")
    func claimsOnlyPlainMarkdown() {
        #expect(SystemIntegration.claimedExtensions == ["md", "markdown", "mdown", "mkd"])
        for owned in ["mdx", "mdc", "qmd", "rmd", "txt"] {
            #expect(!SystemIntegration.claimedExtensions.contains(owned))
        }
    }

    /// Every claimed extension still has to be one the app declares it opens,
    /// or the setup panel would set a default for a file type it then refuses.
    @Test("Everything claimed is a declared document type")
    func claimsAreDeclared() {
        for ext in SystemIntegration.claimedExtensions {
            #expect(DocumentTypes.fileExtensions.contains(ext))
        }
    }

    @Test("Claimed UTIs are deduplicated and non-empty")
    func claimedTypesAreUnique() {
        let types = SystemIntegration.claimedTypes
        #expect(!types.isEmpty)
        #expect(Set(types).count == types.count)
    }

    /// The whole file is gated on this: a `swift build` binary is not a bundle,
    /// and offering to move one into Applications is nonsense.
    @Test("A test runner is not mistaken for an app bundle")
    func testRunnerIsNotAnAppBundle() {
        #expect(!SystemIntegration.isAppBundle)
    }
}

// MARK: - Tour retirement

@Suite("Start window tour retirement")
@MainActor
struct TourRetirementTests {
    @Test("Offered on the first launches")
    func offeredEarly() {
        for launch in 1...AppDelegate.tourRetirementLaunch {
            #expect(AppDelegate.shouldOfferTour(hasTakenTour: false, launchCount: launch))
        }
    }

    @Test("Retired after the third launch even if never taken")
    func retiredByLaunchCount() {
        #expect(!AppDelegate.shouldOfferTour(
            hasTakenTour: false, launchCount: AppDelegate.tourRetirementLaunch + 1
        ))
        #expect(!AppDelegate.shouldOfferTour(hasTakenTour: false, launchCount: 40))
    }

    @Test("Taking it retires the button immediately")
    func retiredOnceTaken() {
        #expect(!AppDelegate.shouldOfferTour(hasTakenTour: true, launchCount: 1))
    }
}
