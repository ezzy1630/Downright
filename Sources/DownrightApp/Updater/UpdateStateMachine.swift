import Foundation

/// What stage a presented update has reached inside Sparkle.  Mirrors
/// `SPUUserUpdateStage` without importing Sparkle.
enum UpdateStage: Equatable {
    /// Nothing has been downloaded yet.
    case notDownloaded
    /// Already downloaded in the background (automatic updates) but not begun installing.
    case downloaded
    /// Already downloaded and begun installing in the background.
    case installing
}

/// The complete update user flow, as a pure value type.  Nothing here touches
/// a view or a network; the UI layer reduces `UpdateEvent`s and renders the
/// resulting `UpdatePhase`, which is what makes every transition unit-testable
/// without Sparkle or AppKit in the loop.
///
/// The phases mirror the spec:
///   idle, checking(userInitiated, cancel), available(UpdateMetadata, choice),
///   downloading(received, expected, cancel), extracting(progress?),
///   readyToRelaunch(choice), waitingForTermination(retry), installing,
///   informational(UpdateMetadata), upToDate, failed(UpdateFailure, retry?)
///
/// Capabilities (reply / cancellation / acknowledgement / retry closures) are
/// *not* stored here: the coordinator keeps them in `ExactlyOnce` boxes so the
/// machine stays Equatable and the exactly-once contract lives in one place.
struct UpdateStateMachine: Equatable {
    private(set) var phase: UpdatePhase = .idle

    enum UpdatePhase: Equatable {
        case idle
        /// A check is running.  `userInitiated` decides whether the panel and
        /// pill are involved or the check is a quiet background cycle.
        case checking(userInitiated: Bool)
        /// An update was found and the user must choose.
        case available(UpdateMetadata, stage: UpdateStage)
        /// Downloading, with the last-known byte counts.  `expected` may be
        /// nil (server sent no content length) and may legitimately disagree
        /// with `received` (invalid or repeated length callbacks).
        case downloading(received: UInt64, expected: UInt64?)
        /// Extracting the downloaded archive.  `progress` is nil until Sparkle
        /// reports a 0.0–1.0 figure.
        case extracting(progress: Double?)
        /// Extraction finished; the update is ready to install and relaunch.
        case readyToRelaunch
        /// Installation began but the app is still running (termination was
        /// delayed or cancelled, e.g. a dirty-document save failed).  The user
        /// can retry termination or leave the update to install on quit.
        case waitingForTermination
        /// The app has terminated and the update is being installed.
        case installing
        /// An informational-only update: release info plus a "Learn More" URL.
        /// Never offers install.
        case informational(UpdateMetadata)
        /// A manual check found nothing new.
        case upToDate
        /// Something went wrong.  `retryable` says whether a Retry button is
        /// meaningful.
        case failed(UpdateFailure, retryable: Bool)
    }

    /// Events the driver translates Sparkle callbacks into.  Pure, so the
    /// machine can be exercised from tests without a driver at all.
    enum UpdateEvent: Equatable {
        case userInitiatedCheckBegan
        case automaticCheckBegan
        case updateFound(UpdateMetadata, stage: UpdateStage)
        case releaseNotesAvailable
        case releaseNotesFailed
        case updateNotFound(userInitiated: Bool)
        case updaterError(UpdateFailure)
        case downloadInitiated
        case expectedLength(UInt64)
        case dataReceived(UInt64)
        case extractionBegan
        case extractionProgress(Double)
        case readyToInstallAndRelaunch
        case installingUpdate(applicationTerminated: Bool)
        case updateInstalled(relaunched: Bool)
        /// Sparkle aborted or finished and told us to tear everything down.
        case dismissed
        /// The user cancelled a check (panel Cancel, or closing the panel
        /// while a check is running).  Sparkle calls nothing after a cancelled
        /// check, so the machine must leave `.checking` itself.
        case checkCancelled
        /// The user cancelled a download.  Sparkle follows a cancelled download
        /// with `dismissUpdateInstallation()`, but the machine transitions
        /// immediately so the UI never renders a stale progress state.
        case downloadCancelled
    }

    mutating func reduce(_ event: UpdateEvent) {
        switch event {
        case .userInitiatedCheckBegan:
            phase = .checking(userInitiated: true)

        case .automaticCheckBegan:
            phase = .checking(userInitiated: false)

        case .updateFound(let metadata, let stage):
            phase = metadata.isInformationOnly
                ? .informational(metadata)
                : .available(metadata, stage: stage)

        case .releaseNotesAvailable, .releaseNotesFailed:
            // Notes are a detail of the current phase; they never move the
            // machine out of it.  The panel listens separately.
            break

        case .updateNotFound(let userInitiated):
            phase = userInitiated ? .upToDate : .idle

        case .updaterError(let failure):
            phase = .failed(failure, retryable: failure.retryable)

        case .downloadInitiated:
            phase = .downloading(received: 0, expected: nil)

        case .expectedLength(let length):
            // May arrive more than once for the same download and may disagree
            // with what was previously reported; the latest value wins.
            if case .downloading(let received, _) = phase {
                phase = .downloading(received: received, expected: length)
            }

        case .dataReceived(let length):
            if case .downloading(let received, let expected) = phase {
                let total = received &+ length
                // Clamp at the expected size when one is known: a misbehaving
                // server can over-report, and progress must never exceed 100%.
                if let expected {
                    phase = .downloading(received: min(total, expected), expected: expected)
                } else {
                    phase = .downloading(received: total, expected: nil)
                }
            }

        case .extractionBegan:
            phase = .extracting(progress: nil)

        case .extractionProgress(let progress):
            if case .extracting = phase {
                phase = .extracting(progress: min(max(progress, 0), 1))
            }

        case .readyToInstallAndRelaunch:
            phase = .readyToRelaunch

        case .installingUpdate(let applicationTerminated):
            phase = applicationTerminated ? .installing : .waitingForTermination

        case .updateInstalled:
            phase = .idle

        case .dismissed:
            // A dismissal can arrive from *any* phase (Sparkle aborts cycles);
            // every pending capability is discarded by the coordinator.
            phase = .idle

        case .checkCancelled, .downloadCancelled:
            phase = .idle
        }
    }
}
