import AppKit
import Foundation
import Sparkle

/// What the user chose, in Downright's vocabulary.  `DownrightUpdateDriver` is
/// the only place that maps to/from Sparkle's `SPUUserUpdateChoice`.
enum UpdateUserChoice: Equatable {
    case install
    case later
    case skip
}

/// The coordinator (the only other object in the update stack) implements
/// this.  Every method corresponds to exactly one `SPUUserDriver` callback and
/// hands the coordinator the one-shot capability the callback carried.
@MainActor
protocol UpdateDriverHost: AnyObject {
    /// `showUserInitiatedUpdateCheck(cancellation:)` — a check the user asked for.
    func driverDidBeginUserCheck(cancellation: @escaping () -> Void)
    /// `showUpdateFound(_:state:reply:)` — an update is being offered.
    /// `userInitiated` comes straight from `SPUUserUpdateState.userInitiated`
    /// so the coordinator can keep automatic presentations off the panel.
    func driverDidFindUpdate(_ metadata: UpdateMetadata, stage: UpdateStage, userInitiated: Bool, reply: @escaping (UpdateUserChoice) -> Void)
    /// `showUpdateReleaseNotes(with:)` — inline/linked notes arrived.
    func driverDidReceiveReleaseNotes(_ data: Data)
    /// `showUpdateReleaseNotesFailedToDownloadWithError(_:)`.
    func driverDidFailToDownloadReleaseNotes(_ error: Error)
    /// `showUpdateNotFoundWithError(_:acknowledgement:)`.
    func driverDidFindNoUpdate(userInitiated: Bool, acknowledgement: @escaping () -> Void)
    /// `showUpdaterError(_:acknowledgement:)`.
    func driverDidEncounterError(_ error: Error, acknowledgement: @escaping () -> Void)
    /// `showDownloadInitiated(cancellation:)`.
    func driverDidBeginDownload(cancellation: @escaping () -> Void)
    /// `showDownloadDidReceiveExpectedContentLength(_:)`.
    func driverDidReceiveExpectedLength(_ length: UInt64)
    /// `showDownloadDidReceiveData(ofLength:)`.
    func driverDidReceiveData(_ length: UInt64)
    /// `showDownloadDidStartExtractingUpdate()`.
    func driverDidBeginExtraction()
    /// `showExtractionReceivedProgress(_:)`.
    func driverDidReceiveExtractionProgress(_ progress: Double)
    /// `showReady(toInstallAndRelaunch:)`.
    func driverDidBecomeReadyToRelaunch(reply: @escaping (UpdateUserChoice) -> Void)
    /// `showInstallingUpdate(withApplicationTerminated:retryTerminatingApplication:)`.
    func driverDidBeginInstallation(applicationTerminated: Bool, retryTermination: @escaping () -> Void)
    /// `showUpdateInstalledAndRelaunched(_:acknowledgement:)`.
    func driverDidFinishInstallation(relaunched: Bool, acknowledgement: @escaping () -> Void)
    /// `dismissUpdateInstallation()`.
    func driverDidDismiss()
    /// `showUpdateInFocus()`.
    func driverDidRequestFocus()
}

/// Downright's complete `SPUUserDriver`.  Sparkle owns download, validation,
/// extraction, authorization, replacement, and relaunch; every visible
/// interaction is routed through here to the coordinator, and no standard
/// Sparkle window ever appears.
///
/// Every callback carries a one-shot reply / cancellation / acknowledgement.
/// Each one is handed to the coordinator *exactly once*; if the coordinator is
/// torn down the driver simply stops forwarding, and Sparkle's
/// `dismissUpdateInstallation()` discards whatever is still pending.
@MainActor
final class DownrightUpdateDriver: NSObject, SPUUserDriver {
    weak var host: UpdateDriverHost?

    init(host: UpdateDriverHost? = nil) {
        self.host = host
        super.init()
    }

    // MARK: SPUUserDriver

    /// Never called in production: `SUEnableAutomaticChecks` is set in the
    /// Info.plist, which opts out of Sparkle's permission prompt entirely.
    /// If a dev bundle without that key ever reaches here, adopt the spec
    /// defaults: check automatically, download automatically, no profiling.
    func show(_ request: SPUUpdatePermissionRequest, reply: @escaping (SUUpdatePermissionResponse) -> Void) {
        reply(SUUpdatePermissionResponse(
            automaticUpdateChecks: true,
            automaticUpdateDownloading: nil,
            sendSystemProfile: false
        ))
    }

    func showUserInitiatedUpdateCheck(cancellation: @escaping () -> Void) {
        host?.driverDidBeginUserCheck(cancellation: cancellation)
    }

    func showUpdateFound(
        with appcastItem: SUAppcastItem,
        state: SPUUserUpdateState,
        reply: @escaping (SPUUserUpdateChoice) -> Void
    ) {
        let stage: UpdateStage = switch state.stage {
        case .notDownloaded: .notDownloaded
        case .downloaded: .downloaded
        case .installing: .installing
        @unknown default: .notDownloaded
        }
        host?.driverDidFindUpdate(
            UpdateMetadata(appcastItem: appcastItem),
            stage: stage,
            userInitiated: state.userInitiated,
            reply: { choice in reply(choice.sparkleValue) }
        )
    }

    func showUpdateReleaseNotes(with downloadData: SPUDownloadData) {
        host?.driverDidReceiveReleaseNotes(downloadData.data)
    }

    func showUpdateReleaseNotesFailedToDownloadWithError(_ error: Error) {
        host?.driverDidFailToDownloadReleaseNotes(error)
    }

    func showUpdateNotFoundWithError(_ error: Error, acknowledgement: @escaping () -> Void) {
        let nsError = error as NSError
        let userInitiated = (nsError.userInfo[SPUNoUpdateFoundUserInitiatedKey] as? NSNumber)?.boolValue ?? false
        host?.driverDidFindNoUpdate(userInitiated: userInitiated, acknowledgement: acknowledgement)
    }

    func showUpdaterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        host?.driverDidEncounterError(error, acknowledgement: acknowledgement)
    }

    func showDownloadInitiated(cancellation: @escaping () -> Void) {
        host?.driverDidBeginDownload(cancellation: cancellation)
    }

    func showDownloadDidReceiveExpectedContentLength(_ expectedContentLength: UInt64) {
        host?.driverDidReceiveExpectedLength(expectedContentLength)
    }

    func showDownloadDidReceiveData(ofLength length: UInt64) {
        host?.driverDidReceiveData(length)
    }

    func showDownloadDidStartExtractingUpdate() {
        host?.driverDidBeginExtraction()
    }

    func showExtractionReceivedProgress(_ progress: Double) {
        host?.driverDidReceiveExtractionProgress(progress)
    }

    func showReady(toInstallAndRelaunch reply: @escaping (SPUUserUpdateChoice) -> Void) {
        host?.driverDidBecomeReadyToRelaunch(reply: { choice in reply(choice.sparkleValue) })
    }

    func showInstallingUpdate(
        withApplicationTerminated applicationTerminated: Bool,
        retryTerminatingApplication: @escaping () -> Void
    ) {
        host?.driverDidBeginInstallation(
            applicationTerminated: applicationTerminated,
            retryTermination: retryTerminatingApplication
        )
    }

    func showUpdateInstalledAndRelaunched(_ relaunched: Bool, acknowledgement: @escaping () -> Void) {
        host?.driverDidFinishInstallation(relaunched: relaunched, acknowledgement: acknowledgement)
    }

    func dismissUpdateInstallation() {
        host?.driverDidDismiss()
    }

    func showUpdateInFocus() {
        host?.driverDidRequestFocus()
    }
}

// MARK: - Mapping

extension UpdateMetadata {
    /// Translate Sparkle's appcast item into the plain value type.  Release
    /// notes flow two ways: embedded Markdown in `itemDescription` (our
    /// release pipeline) or a linked HTML page delivered separately via
    /// `showUpdateReleaseNotes(with:)`.
    init(appcastItem: SUAppcastItem) {
        self.init(
            versionString: appcastItem.versionString,
            displayVersionString: appcastItem.displayVersionString,
            title: appcastItem.title,
            itemDescription: appcastItem.itemDescription,
            releaseNotesURL: appcastItem.releaseNotesURL,
            infoURL: appcastItem.infoURL,
            contentLength: appcastItem.contentLength,
            isInformationOnly: appcastItem.isInformationOnlyUpdate,
            isMajorUpgrade: appcastItem.isMajorUpgrade,
            isCritical: appcastItem.isCriticalUpdate,
            minimumSystemVersion: appcastItem.minimumSystemVersion
        )
    }
}

extension UpdateUserChoice {
    fileprivate var sparkleValue: SPUUserUpdateChoice {
        switch self {
        case .install: return .install
        case .later: return .dismiss
        case .skip: return .skip
        }
    }
}
