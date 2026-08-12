import AppKit
import Foundation

/// One-shot Sparkle capability (reply, acknowledgement, cancellation, or
/// retry closure).  The entire contract of the update UI lives here: call it
/// or discard it, but never twice, and never leak it past dismissal.
final class Capability<T> {
    private var body: ((T) -> Void)?
    init(_ body: @escaping (T) -> Void) { self.body = body }
    var isArmed: Bool { body != nil }
    /// Invoke exactly once.  A second call is a no-op (and a bug).
    func call(_ value: T) {
        let body = self.body
        self.body = nil
        body?(value)
    }
    /// Drops the capability without invoking Sparkle's block.
    func discard() { body = nil }
}

/// What the update status pill displays right now.
enum UpdatePillModel: Equatable {
    /// "Update 1.1" — an update is available for the user to act on.
    case available(String)
    /// "Restart to Update" — downloaded (or ready) and will install on quit.
    case restartToUpdate
    /// Progress state: label plus an optional 0–1 fraction.
    case progress(String, Double?)
    /// "Update Failed" — warning treatment, opens the panel.
    case warning
    /// Informational update: show the version, open release info.
    case informational(String)

    /// Hidden when idle, up to date, or mid-silent-check.
    static let hidden: UpdatePillModel? = nil
}

/// The single owner of the updater: `SPUUpdater` lifecycle, the user driver,
/// the state machine, every one-shot capability, the settings proxy, and the
/// windows (the panel) and pills (the document titlebars and start window).
///
/// Not a standard Sparkle setup and not a thin wrapper: Sparkle owns the
/// machinery and Downright owns every visible interaction, which is exactly
/// the architecture the spec calls for.
@MainActor
final class UpdateCoordinator: UpdateDriverHost {
    static let shared = UpdateCoordinator()
    /// Fired whenever the machine phase, pill model, or release-notes state
    /// changes.  Pills and the panel observe this; nothing polls.
    static let stateDidChange = Notification.Name("Downright.UpdateCoordinator.stateDidChange")

    // MARK: - State

    private(set) var machine = UpdateStateMachine()
    /// Set when a *background* (automatic) download completes and the machine
    /// itself stays idle; drives the "Restart to Update" pill until the
    /// update is installed, dismissed, or superseded.
    private(set) var downloadedUpdate: UpdateMetadata?

    /// Whether the current update cycle began from a user action (menu check,
    /// palette, settings, or the pill).  Automatic (scheduled) cycles keep
    /// this false so background downloads stay quiet: only the pill appears,
    /// never the panel — the panel opens when the user asks for it.
    private(set) var currentCycleIsUserInitiated = false

    /// Test seam: how often `showPanel()` was reached, so tests can assert
    /// that background flows never open the panel while user flows always do.
    private(set) var panelShowCount = 0

    var phase: UpdateStateMachine.UpdatePhase { machine.phase }

    var isRunning: Bool { engine?.isRunning ?? false }

    // MARK: - Settings (bound directly to Sparkle's persisted properties)

    var automaticallyChecksForUpdates: Bool {
        get { engine?.automaticallyChecksForUpdates ?? false }
        set {
            guard let engine else { return }
            engine.automaticallyChecksForUpdates = newValue
            notifyStateChanged()
        }
    }

    var automaticallyDownloadsUpdates: Bool {
        get { engine?.automaticallyDownloadsUpdates ?? false }
        set {
            guard let engine else { return }
            engine.automaticallyDownloadsUpdates = newValue
            notifyStateChanged()
        }
    }

    var allowsAutomaticUpdates: Bool { engine?.allowsAutomaticUpdates ?? false }

    var lastUpdateCheckDate: Date? { engine?.lastUpdateCheckDate }

    var canCheckForUpdates: Bool {
        guard isConfigured else { return false }
        return engine?.canCheckForUpdates ?? (startupFailure != nil)
    }

    /// Whether this bundle carries the production Sparkle configuration at all
    /// (used by the Updates settings pane to explain a disabled updater).
    var isUpdateConfigurationPresent: Bool { isConfigured }

    // MARK: - Infrastructure

    private var engine: (any UpdateEngine)?
    private var driver: DownrightUpdateDriver?
    private var panel: UpdateWindowController?
    private var startupFailure: UpdateFailure?

    /// Whether this bundle carries the production Sparkle configuration.
    /// Dev/ad-hoc bundles omit `SUFeedURL` (and the whole Sparkle block) from
    /// their Info.plist, which disables the updater without a compile flag.
    private var isConfigured: Bool {
        guard let feed = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
              !feed.isEmpty,
              let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
              !key.isEmpty,
              !key.hasPrefix("PLACEHOLDER_")
        else { return false }
        return true
    }

    private init() {}

    /// Test seam: a coordinator wired to a deterministic fake engine.  The
    /// production singleton uses `start()` instead, which builds the Sparkle
    /// engine and driver itself.
    init(engine: (any UpdateEngine)?) {
        self.engine = engine
        engine?.onBackgroundDownloadCompleted = { [weak self] version in
            MainActor.assumeIsolated { self?.backgroundDownloadCompleted(version) }
        }
    }

    /// Tests set this to keep the coordinator logic window-free.
    var suppressUIForTesting = false

    // MARK: - Lifecycle

    /// Called from `applicationDidFinishLaunching`.  A dev bundle, or a
    /// production bundle whose configuration is still missing, simply stays
    /// quiet — the pill, panel, menu, and palette all report "not available".
    func start() {
        guard engine == nil else { return }
        guard isConfigured else {
            // Updater disabled for this bundle.  Nothing to tear down later.
            return
        }
        let driver = DownrightUpdateDriver()
        self.driver = driver
        driver.host = self
        guard let engine = SparkleUpdateEngine(userDriver: driver) else {
            // Misconfigured in a way the plist check missed; stay disabled.
            self.driver = nil
            return
        }
        self.engine = engine
        engine.onBackgroundDownloadCompleted = { [weak self] displayVersion in
            MainActor.assumeIsolated { self?.backgroundDownloadCompleted(displayVersion) }
        }
        do {
            try engine.start()
            if startupFailure != nil { machine.reduce(.dismissed) }
            startupFailure = nil
        } catch {
            // Startup failure (bad feed, missing signing key): surface once,
            // quietly — the pill carries the warning until the app restarts.
            self.engine = nil
            self.driver = nil
            let failure = UpdateFailure(error: error)
            startupFailure = failure
            machine.reduce(.updaterError(failure))
            notifyStateChanged()
        }
    }

    /// Shuts the coordinator down cleanly (used by tests; in production the
    /// process lives for the app's lifetime).  Any pending capability is
    /// discarded, which is the only acceptable way for a teardown to happen.
    func tearDownForTesting() {
        discardAllCapabilities()
        machine = UpdateStateMachine()
        downloadedUpdate = nil
        panel = nil
        engine = nil
        driver = nil
        startupFailure = nil
        releaseNotes = .none
        notifyStateChanged()
    }

    // MARK: - User actions

    /// "Check for Updates…" from the menu, palette, settings, or the pill.
    func checkForUpdates() {
        guard isConfigured else {
            presentDisabledAlert()
            return
        }
        if engine == nil { start() }
        guard let engine else {
            if startupFailure != nil { showPanel() }
            return
        }
        engine.checkForUpdates()
    }

    func showPanel() {
        panelShowCount += 1
        guard !suppressUIForTesting else { return }
        panel = panel ?? UpdateWindowController(coordinator: self)
        panel?.showWindow(nil)
        panel?.window?.makeKeyAndOrderFront(nil)
    }

    func closePanel() {
        guard !suppressUIForTesting else { return }
        panel?.window?.performClose(nil)
    }

    // MARK: Update panel actions (routed to the armed capability)

    /// Update / Update & Relaunch — "do it now".
    func userDidChooseInstall() {
        if readyReply?.isArmed == true {
            readyReply?.call(.install)
        } else if choiceReply?.isArmed == true {
            choiceReply?.call(.install)
        } else if downloadedUpdate != nil {
            // A background download with no pending prompt: asking Sparkle to
            // check again presents the already-downloaded update for install.
            checkForUpdates()
        }
    }

    /// Retry after a failed check/download.  The failed cycle must finish
    /// (acknowledge) before Sparkle will allow a new one, so the new check is
    /// scheduled for the next runloop turn.
    func userDidRetry() {
        guard case .failed = machine.phase else { return }
        acknowledgement?.call(())
        discardAllCapabilities()
        machine.reduce(.dismissed)
        downloadedUpdate = nil
        DispatchQueue.main.async { [weak self] in
            self?.checkForUpdates()
        }
    }

    func userDidChooseLater() {
        if choiceReply?.isArmed == true {
            // The update is dismissed until Sparkle reminds the user later;
            // the machine leaves `.available` so the pill stops offering it.
            choiceReply?.call(.later)
            machine.reduce(.dismissed)
            closePanel()
        } else if readyReply?.isArmed == true {
            // Already downloaded: it still installs on quit, so the pill keeps
            // its "Restart to Update" state and only the panel goes away.
            readyReply?.call(.later)
            closePanel()
        } else {
            closePanel()
        }
        notifyStateChanged()
    }

    func userDidChooseSkip() {
        choiceReply?.call(.skip)
        machine.reduce(.dismissed)
        closePanel()
        notifyStateChanged()
    }

    func userDidCancelCheck() {
        checkCancellation?.call(())
        machine.reduce(.checkCancelled)
        closePanel()
        notifyStateChanged()
    }

    func userDidCancelDownload() {
        downloadCancellation?.call(())
        machine.reduce(.downloadCancelled)
        closePanel()
        notifyStateChanged()
    }

    func userDidRetryTermination() {
        retryTermination?.call(())
    }

    func userDidAcknowledge() {
        acknowledgement?.call(())
    }

    func userDidRequestLearnMore(_ metadata: UpdateMetadata) {
        guard let url = metadata.infoURL, url.scheme == "https" else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }

    /// Panel closed by the user without a button.  Where a choice is pending,
    /// closing means "later"; otherwise it is a pure dismissal.  A pending
    /// check or download cancellation is invoked so Sparkle's cycle is never
    /// left with a capability it will wait on forever.
    func userDidDismissPanel() {
        if choiceReply?.isArmed == true {
            choiceReply?.call(.later)
            machine.reduce(.dismissed)
        } else if readyReply?.isArmed == true {
            readyReply?.call(.later)
        } else if acknowledgement?.isArmed == true {
            acknowledgement?.call(())
        } else if retryTermination?.isArmed == true {
            // An install-in-progress keeps going; the panel can go away.
            retryTermination?.discard()
        } else if checkCancellation?.isArmed == true {
            // Closing the panel mid-check cancels it; Sparkle calls nothing
            // after a cancelled check, so the machine leaves `.checking` here.
            checkCancellation?.call(())
            machine.reduce(.checkCancelled)
        } else if downloadCancellation?.isArmed == true {
            // Closing the panel mid-download cancels it.
            downloadCancellation?.call(())
            machine.reduce(.downloadCancelled)
        } else {
            downloadedUpdate = nil
        }
        notifyStateChanged()
    }

    // MARK: - Capabilities

    private var checkCancellation: Capability<Void>?
    private var downloadCancellation: Capability<Void>?
    private var choiceReply: Capability<UpdateUserChoice>?
    private var readyReply: Capability<UpdateUserChoice>?
    private var retryTermination: Capability<Void>?
    private var acknowledgement: Capability<Void>?

    private func discardAllCapabilities() {
        checkCancellation?.discard()
        downloadCancellation?.discard()
        choiceReply?.discard()
        readyReply?.discard()
        retryTermination?.discard()
        acknowledgement?.discard()
        checkCancellation = nil
        downloadCancellation = nil
        choiceReply = nil
        readyReply = nil
        retryTermination = nil
        acknowledgement = nil
    }

    // MARK: - UpdateDriverHost

    func driverDidBeginUserCheck(cancellation: @escaping () -> Void) {
        releaseNotes = .none
        currentCycleIsUserInitiated = true
        checkCancellation?.discard()
        checkCancellation = Capability(cancellation)
        machine.reduce(.userInitiatedCheckBegan)
        showPanel()
        notifyStateChanged()
    }

    func driverDidFindUpdate(
        _ metadata: UpdateMetadata,
        stage: UpdateStage,
        userInitiated: Bool = true,
        reply: @escaping (UpdateUserChoice) -> Void
    ) {
        releaseNotes = .none
        checkCancellation?.discard()
        checkCancellation = nil
        choiceReply?.discard()
        choiceReply = Capability(reply)
        downloadedUpdate = nil
        currentCycleIsUserInitiated = userInitiated
        machine.reduce(.updateFound(metadata, stage: stage))
        // A scheduled/automatic presentation stays on the pill; the panel
        // opens only when the user asked for the update themselves.
        if userInitiated { showPanel() }
        notifyStateChanged()
    }

    func driverDidReceiveReleaseNotes(_ data: Data) {
        releaseNotes = .loaded(data)
        notifyStateChanged()
    }

    func driverDidFailToDownloadReleaseNotes(_ error: Error) {
        releaseNotes = .failed
        notifyStateChanged()
    }

    func driverDidFindNoUpdate(userInitiated: Bool, acknowledgement: @escaping () -> Void) {
        releaseNotes = .none
        checkCancellation?.discard()
        checkCancellation = nil
        currentCycleIsUserInitiated = false
        self.acknowledgement?.discard()
        self.acknowledgement = Capability(acknowledgement)
        machine.reduce(.updateNotFound(userInitiated: userInitiated))
        if userInitiated {
            showPanel()
            // Up-to-date is a terminal display state: acknowledge once shown.
            userDidAcknowledge()
        } else {
            // Quiet background check; nothing to show, acknowledge immediately.
            userDidAcknowledge()
        }
        notifyStateChanged()
    }

    func driverDidEncounterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        releaseNotes = .none
        let userInitiated = currentCycleIsUserInitiated
        currentCycleIsUserInitiated = false
        self.acknowledgement?.discard()
        self.acknowledgement = Capability(acknowledgement)
        guard userInitiated else {
            // A background check that could not reach the feed is a non-event.
            // Sparkle's cycle has to be finished here, or `canCheckForUpdates`
            // stays false until relaunch and every window carries an orange
            // alarm badge because a laptop was opened without wifi — which is
            // exactly the alarm DESIGN.md says not to raise.
            userDidAcknowledge()
            discardAllCapabilities()
            machine.reduce(.dismissed)
            notifyStateChanged()
            return
        }
        machine.reduce(.updaterError(UpdateFailure(error: error)))
        showPanel()
        notifyStateChanged()
    }

    func driverDidBeginDownload(cancellation: @escaping () -> Void) {
        downloadCancellation?.discard()
        downloadCancellation = Capability(cancellation)
        machine.reduce(.downloadInitiated)
        // Automatic background downloads proceed silently on the pill.
        if currentCycleIsUserInitiated { showPanel() }
        notifyStateChanged()
    }

    func driverDidReceiveExpectedLength(_ length: UInt64) {
        machine.reduce(.expectedLength(length))
        notifyStateChanged()
    }

    func driverDidReceiveData(_ length: UInt64) {
        machine.reduce(.dataReceived(length))
        notifyStateChanged()
    }

    func driverDidBeginExtraction() {
        machine.reduce(.extractionBegan)
        notifyStateChanged()
    }

    func driverDidReceiveExtractionProgress(_ progress: Double) {
        machine.reduce(.extractionProgress(progress))
        notifyStateChanged()
    }

    func driverDidBecomeReadyToRelaunch(reply: @escaping (UpdateUserChoice) -> Void) {
        readyReply?.discard()
        readyReply = Capability(reply)
        machine.reduce(.readyToInstallAndRelaunch)
        // A background download that became ready stays on the "Restart to
        // Update" pill; the panel opens when the pill is clicked.
        if currentCycleIsUserInitiated { showPanel() }
        notifyStateChanged()
    }

    func driverDidBeginInstallation(applicationTerminated: Bool, retryTermination: @escaping () -> Void) {
        self.retryTermination?.discard()
        self.retryTermination = Capability(retryTermination)
        machine.reduce(.installingUpdate(applicationTerminated: applicationTerminated))
        if !applicationTerminated {
            showPanel()  // give the user Retry / Later for a delayed quit
        }
        notifyStateChanged()
    }

    func driverDidFinishInstallation(relaunched: Bool, acknowledgement: @escaping () -> Void) {
        self.acknowledgement?.discard()
        self.acknowledgement = Capability(acknowledgement)
        machine.reduce(.updateInstalled(relaunched: relaunched))
        currentCycleIsUserInitiated = false
        downloadedUpdate = nil
        userDidAcknowledge()
        closePanel()
        notifyStateChanged()
    }

    func driverDidDismiss() {
        discardAllCapabilities()
        currentCycleIsUserInitiated = false
        machine.reduce(.dismissed)
        downloadedUpdate = nil
        releaseNotes = .none
        closePanel()
        notifyStateChanged()
    }

    func driverDidRequestFocus() {
        showPanel()
    }

    // MARK: - Background downloads

    private func backgroundDownloadCompleted(_ displayVersion: String) {
        // The machine stays idle; remember the download so the pill can offer
        // "Restart to Update" until the update is installed or dismissed.
        if downloadedUpdate?.displayVersionString != displayVersion {
            downloadedUpdate = UpdateMetadata(
                versionString: displayVersion,
                displayVersionString: displayVersion,
                title: nil,
                itemDescription: nil,
                releaseNotesURL: nil,
                infoURL: nil,
                contentLength: 0,
                isInformationOnly: false,
                isMajorUpgrade: false,
                isCritical: false,
                minimumSystemVersion: nil
            )
        }
        notifyStateChanged()
    }

    // MARK: - Release notes state

    private(set) var releaseNotes: UpdateReleaseNotesState = .none

    // MARK: - Derived UI models

    /// The pill model across every document titlebar and the start window.
    var pillModel: UpdatePillModel? {
        switch machine.phase {
        case .idle:
            return downloadedUpdate != nil ? .restartToUpdate : nil
        case .checking:
            return nil
        case .available(let metadata, let stage):
            return stage == .downloaded || stage == .installing
                ? .restartToUpdate
                : .available(metadata.displayVersionString)
        case .downloading(let received, let expected):
            let fraction = expected.map { expected in Double(received) / Double(max(1, expected)) }
            return .progress(updateLabel, fraction)
        case .extracting(let progress):
            return .progress("Updating…", progress)
        case .readyToRelaunch:
            return .restartToUpdate
        case .waitingForTermination:
            return .restartToUpdate
        case .installing:
            return .hidden  // the app is quitting; nothing to click
        case .informational(let metadata):
            return .informational(metadata.displayVersionString)
        case .upToDate:
            return .hidden
        case .failed:
            return .warning
        }
    }

    /// Short label for progress states: the target version once known, else
    /// a generic "Updating…".
    private var updateLabel: String {
        if case .available(let metadata, _) = machine.phase {
            return "Update \(metadata.displayVersionString)"
        }
        if let downloadedUpdate {
            return "Update \(downloadedUpdate.displayVersionString)"
        }
        return "Updating…"
    }

    /// "Version 1.0.0 (42) · Last check: …" for the Updates settings pane.
    func statusLine() -> String {
        let bundle = Bundle.main
        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "—"
        let check = lastUpdateCheckDate.map { date in
            DateFormatter.localizedString(from: date, dateStyle: .medium, timeStyle: .short)
        } ?? "never"
        return "Version \(version) (\(build)) · Last check: \(check)"
    }

    private func notifyStateChanged() {
        NotificationCenter.default.post(name: UpdateCoordinator.stateDidChange, object: self)
    }

    private func presentDisabledAlert() {
        guard !suppressUIForTesting else { return }
        let alert = NSAlert()
        alert.messageText = "Updates aren't available for this build."
        alert.informativeText = "This copy of Downright doesn't carry the production update configuration."
        alert.alertStyle = .informational
        alert.runModal()
    }
}

/// How release notes are presented in the update panel.
enum UpdateReleaseNotesState: Equatable {
    case none
    case loaded(Data)
    case failed
}
