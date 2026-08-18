import AppKit
import Foundation

// The `Sparkle` framework is imported only in this file's production engine.
// Everything upstream of the engine boundary (coordinator, state machine, UI,
// tests) speaks the protocol and never sees Sparkle.
import Sparkle

/// The updater behind the coordinator.  Production is `SparkleUpdateEngine`;
/// tests inject `FakeUpdateEngine` so the coordinator's logic — every state
/// transition, every exactly-once reply, every settings read — runs without
/// the framework or the network.
@MainActor
protocol UpdateEngine: AnyObject {
    /// True once `start()` has succeeded and the engine is live.
    var isRunning: Bool { get }

    func start() throws
    func checkForUpdates()
    func checkForUpdatesInBackground()

    /// Whether a user-initiated check is currently allowed (menu validation).
    var canCheckForUpdates: Bool { get }

    // Settings.  The production engine reads/writes Sparkle's *own* persisted
    // properties — Downright's JSON preferences never duplicate them.
    var automaticallyChecksForUpdates: Bool { get set }
    var automaticallyDownloadsUpdates: Bool { get set }
    var allowsAutomaticUpdates: Bool { get }
    var updateCheckInterval: TimeInterval { get set }
    var lastUpdateCheckDate: Date? { get }

    // Delegate callbacks the coordinator needs to surface.
    /// A background (automatic) download finished.  Argument is the display version.
    var onBackgroundDownloadCompleted: ((String) -> Void)? { get set }
}

// MARK: - Production

/// Owns an `SPUUpdater` configured with the app's Info.plist feed settings and
/// Downright's custom user driver.  All calls must be made on the main thread,
/// which the `@MainActor` annotation on the protocol enforces.
final class SparkleUpdateEngine: UpdateEngine {
    private let updater: SPUUpdater
    private let driver: DownrightUpdateDriver
    private(set) var isRunning = false

    var onBackgroundDownloadCompleted: ((String) -> Void)?

    init?(userDriver: DownrightUpdateDriver) {
        self.driver = userDriver
        let host = Bundle.main
        // A dev/ad-hoc bundle, or a release bundle with incomplete updater
        // metadata, cannot be constructed usefully. Refuse to hand partial
        // configuration to Sparkle; the coordinator stays in its normal
        // disabled state and the production bundle gate catches the release
        // mistake before users ever receive it.
        guard UpdateConfiguration.isValid(infoDictionary: host.infoDictionary ?? [:]) else {
            return nil
        }
        let updater = SPUUpdater(
            hostBundle: host,
            applicationBundle: host,
            userDriver: userDriver,
            delegate: nil
        )
        self.updater = updater
    }

    func start() throws {
        guard !isRunning else { return }
        updater.clearFeedURLFromUserDefaults()  // never override the Info.plist feed
        try updater.start()
        isRunning = true
    }

    func checkForUpdates() {
        guard isRunning else { return }
        updater.checkForUpdates()
    }

    func checkForUpdatesInBackground() {
        guard isRunning else { return }
        updater.checkForUpdatesInBackground()
    }

    var canCheckForUpdates: Bool { updater.canCheckForUpdates }

    var automaticallyChecksForUpdates: Bool {
        get { updater.automaticallyChecksForUpdates }
        set { updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { updater.automaticallyDownloadsUpdates }
        set { updater.automaticallyDownloadsUpdates = newValue }
    }

    var allowsAutomaticUpdates: Bool { updater.allowsAutomaticUpdates }

    var updateCheckInterval: TimeInterval {
        get { updater.updateCheckInterval }
        set { updater.updateCheckInterval = newValue }
    }

    var lastUpdateCheckDate: Date? { updater.lastUpdateCheckDate }
}

enum UpdateStartError: Error {
    case updaterRefusedToStart
}

// MARK: - Test fake

/// Deterministic stand-in for Sparkle.  The coordinator is tested against this:
/// scripts emit driver callbacks and settings reads/writes exactly like the
/// framework would, with no network and no binary framework in the loop.
@MainActor
final class FakeUpdateEngine: UpdateEngine {
    private(set) var isRunning = false
    var startThrows = false

    var onBackgroundDownloadCompleted: ((String) -> Void)?

    var _canCheckForUpdates = true
    var canCheckForUpdates: Bool { _canCheckForUpdates }

    var automaticallyChecksForUpdates = true
    var automaticallyDownloadsUpdates = true
    var allowsAutomaticUpdates = true
    var updateCheckInterval: TimeInterval = 86_400
    var lastUpdateCheckDate: Date?

    private(set) var backgroundCheckCount = 0
    private(set) var foregroundCheckCount = 0

    func start() throws {
        if startThrows { throw UpdateStartError.updaterRefusedToStart }
        isRunning = true
    }

    func checkForUpdates() {
        guard isRunning else { return }
        foregroundCheckCount += 1
    }

    func checkForUpdatesInBackground() {
        guard isRunning else { return }
        backgroundCheckCount += 1
    }

    // Test scripting helpers.

    func completeBackgroundDownload(displayVersion: String) {
        onBackgroundDownloadCompleted?(displayVersion)
    }
}
