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

/// The minimum configuration needed before Downright asks Sparkle to run.
/// Invalid release metadata must fail closed as a normal disabled-updater
/// state, not reach a partially configured Sparkle instance.
enum UpdateConfiguration {
    static func isValid(infoDictionary: [String: Any]) -> Bool {
        guard let feedString = infoDictionary["SUFeedURL"] as? String,
              let feedURL = URL(string: feedString),
              feedURL.scheme?.lowercased() == "https",
              feedURL.host?.isEmpty == false,
              let publicKey = infoDictionary["SUPublicEDKey"] as? String,
              let publicKeyData = Data(base64Encoded: publicKey),
              publicKeyData.count == 32
        else {
            return false
        }
        return true
    }
}

/// What the update status pill displays right now.
enum UpdatePillModel: Equatable {
    /// "Update Now" — one press installs.  `version` is the build on offer
    /// (carried in the tooltip, the accessibility label, and the hover notes
    /// rather than on the button, which says what pressing it *does*).
    ///
    /// `isReady` distinguishes an update already downloaded in the background
    /// — the usual case, because `SUAutomaticallyUpdate` is on, and the press
    /// is then effectively instant — from one that must be fetched first.  The
    /// label is the same either way: the difference is how long the press
    /// takes, not what it means.
    case updateNow(version: String, isReady: Bool)
    /// "Restart to Update" — installation has already begun and only a quit
    /// can finish it.  Distinct from `.updateNow` because pressing here
    /// retries termination; there is nothing left to install.
    case restartToUpdate
    /// Progress state: label plus an optional 0–1 fraction.
    case progress(String, Double?)
    /// "Update Failed" — warning treatment, opens the panel.
    case warning
    /// Informational update: show the version, open release info.
    case informational(String)

    /// Hidden when idle, up to date, or mid-silent-check.
    static let hidden: UpdatePillModel? = nil

    /// Whether pressing this pill starts an install (as opposed to opening a
    /// window).  The hover notes only appear over a pill that can act.
    var offersInstall: Bool {
        switch self {
        case .updateNow, .restartToUpdate: return true
        case .progress, .warning, .informational: return false
        }
    }
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

    /// Set while a press of "Update Now" is being carried out through a fresh
    /// Sparkle cycle.  The press already *is* the decision, so the cycle it
    /// starts must not stop to ask the same question in a window: every prompt
    /// Sparkle raises while this is set is answered `.install` immediately.
    /// A failure clears it and does open the panel — a press that could not be
    /// honoured owes the reader an explanation.
    private(set) var isExpeditedInstall = false

    /// Test seam: how often the release watch asked Sparkle to look.
    private(set) var releaseWatchTriggerCount = 0

    /// The update this cycle is about, kept past the phases that stop carrying
    /// it themselves.  `.downloading`, `.extracting`, and `.readyToRelaunch`
    /// have no metadata in them, and without this the pill's tooltip, its
    /// accessibility label, and the hover notes all go blank halfway through
    /// an install — naming a version at the start and not at the end reads as
    /// the app having lost track of what it is installing.
    private(set) var currentCycleUpdate: UpdateMetadata?

    var phase: UpdateStateMachine.UpdatePhase { machine.phase }

    var isRunning: Bool { engine?.isRunning ?? false }

    // MARK: - Settings (bound directly to Sparkle's persisted properties)

    var automaticallyChecksForUpdates: Bool {
        get { engine?.automaticallyChecksForUpdates ?? false }
        set {
            guard let engine else { return }
            engine.automaticallyChecksForUpdates = newValue
            // The watch is a second automatic check, so it answers to the same
            // switch. A setting that stopped Sparkle's schedule and left this
            // one polling would be a narrower promise than the one it makes.
            if newValue {
                startReleaseWatch()
            } else {
                releaseWatch?.stop()
                releaseWatch = nil
            }
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
    private var releaseWatch: ReleaseWatch?

    /// Whether this bundle carries the production Sparkle configuration.
    /// Dev/ad-hoc bundles omit `SUFeedURL` (and the whole Sparkle block) from
    /// their Info.plist, which disables the updater without a compile flag.
    private var isConfigured: Bool {
        UpdateConfiguration.isValid(infoDictionary: Bundle.main.infoDictionary ?? [:])
    }

    private init() {}

    /// Test seam: a coordinator wired to a deterministic fake engine.  The
    /// production singleton uses `start()` instead, which builds the Sparkle
    /// engine and driver itself.
    init(engine: (any UpdateEngine)?) {
        self.engine = engine
        engine?.onBackgroundDownloadCompleted = { [weak self] version in
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.backgroundDownloadCompleted(version) }
            } else {
                Task { @MainActor [weak self] in self?.backgroundDownloadCompleted(version) }
            }
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
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.backgroundDownloadCompleted(displayVersion) }
            } else {
                Task { @MainActor [weak self] in self?.backgroundDownloadCompleted(displayVersion) }
            }
        }
        do {
            try engine.start()
            if startupFailure != nil { machine.reduce(.dismissed) }
            startupFailure = nil
            startReleaseWatch()
            // MainMenu is built before Sparkle starts. Revalidate its command
            // now that the live updater can answer capability checks; without
            // this notification the menu can remain inert for the whole launch.
            notifyStateChanged()
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
        engine?.onBackgroundDownloadCompleted = nil
        releaseWatch?.stop()
        releaseWatch = nil
        machine = UpdateStateMachine()
        downloadedUpdate = nil
        currentCycleUpdate = nil
        panel = nil
        engine = nil
        driver = nil
        startupFailure = nil
        isExpeditedInstall = false
        releaseNotes = .none
        notifyStateChanged()
    }

    // MARK: - Release watch

    /// Starts watching the appcast so a build published while the app is open
    /// reaches the pill in about a minute rather than on the next scheduled
    /// check.  Only production bundles get here: `start()` has already refused
    /// to build an engine for a bundle without the Sparkle configuration.
    private func startReleaseWatch() {
        guard releaseWatch == nil else { return }
        guard engine?.automaticallyChecksForUpdates == true else { return }
        guard let feedString = Bundle.main.infoDictionary?["SUFeedURL"] as? String,
              let feed = URL(string: feedString)
        else {
            return
        }
        let watch = ReleaseWatch(feed: feed)
        watch.onFeedChanged = { [weak self] in self?.releaseFeedDidChange() }
        releaseWatch = watch
        watch.start()
    }

    /// The appcast moved.  All this does is ask Sparkle to look — the watch
    /// never parses the feed, so this is the full extent of its authority.
    ///
    /// A cycle already in flight is left alone: the reader is watching a
    /// download or reading a prompt, and restarting underneath them would
    /// replace what they are looking at with the same answer.
    func releaseFeedDidChange() {
        guard let engine, engine.isRunning, engine.automaticallyChecksForUpdates else { return }
        guard case .idle = machine.phase, downloadedUpdate == nil else { return }
        releaseWatchTriggerCount += 1
        engine.checkForUpdatesInBackground()
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

    /// The pill's one press.  Everything the panel's Update button does, minus
    /// the panel: a reader who clicked a control labelled "Update Now" has
    /// already answered the question the panel would ask them.
    ///
    /// Unsaved work is deliberately *not* handled here.  Sparkle's install
    /// asks the app to terminate, which runs `applicationShouldTerminate` and
    /// the one policy this app has for dirty buffers — ask, and cancel the
    /// quit if the reader cancels.  A second flush here would be a second
    /// policy for the same moment, and the state machine already carries
    /// `.waitingForTermination` for the cancelled case.
    func userDidPressUpdateNow() {
        switch machine.phase {
        case .waitingForTermination:
            // The install is underway; only the quit is outstanding.
            userDidRetryTermination()
        case .failed:
            showPanel()
        case .downloading, .extracting, .checking:
            // Already in flight. The panel is where the cancel button lives.
            showPanel()
        case .informational(let metadata):
            userDidRequestLearnMore(metadata)
        default:
            if readyReply?.isArmed == true || choiceReply?.isArmed == true {
                userDidChooseInstall()
            } else if pendingUpdate != nil, let engine, engine.isRunning {
                // A background cycle finished without leaving a prompt armed.
                // Re-entering Sparkle presents the same build for install, and
                // `isExpeditedInstall` keeps that cycle from opening a window
                // to ask what the press already answered.
                //
                // Straight to the engine rather than through `checkForUpdates`:
                // that path exists for the *menu*, and gates on the bundle's
                // updater configuration so it can explain a disabled updater.
                // A pill only exists when an update is already pending, so a
                // press can never be the case that alert is for.
                isExpeditedInstall = true
                engine.checkForUpdates()
            }
        }
        notifyStateChanged()
    }

    /// Update / Update & Relaunch — "do it now".
    func userDidChooseInstall() {
        if readyReply?.isArmed == true {
            consume(&readyReply, value: .install)
        } else if choiceReply?.isArmed == true {
            consume(&choiceReply, value: .install)
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
        consume(&acknowledgement, value: ())
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
            consume(&choiceReply, value: .later)
            machine.reduce(.dismissed)
            closePanel()
        } else if readyReply?.isArmed == true {
            // Already downloaded: it still installs on quit, so the pill keeps
            // its "Restart to Update" state and only the panel goes away.
            consume(&readyReply, value: .later)
            closePanel()
        } else if case .upToDate = machine.phase {
            // Keep the no-update result visible until the user has had a
            // chance to read it. This acknowledgement is deliberately delayed
            // until the explicit OK action, or until window dismissal handles
            // the close-button path below.
            userDidAcknowledge()
            closePanel()
        } else {
            closePanel()
        }
        notifyStateChanged()
    }

    func userDidChooseSkip() {
        consume(&choiceReply, value: .skip)
        machine.reduce(.dismissed)
        closePanel()
        notifyStateChanged()
    }

    func userDidCancelCheck() {
        consume(&checkCancellation, value: ())
        machine.reduce(.checkCancelled)
        closePanel()
        notifyStateChanged()
    }

    func userDidCancelDownload() {
        consume(&downloadCancellation, value: ())
        machine.reduce(.downloadCancelled)
        closePanel()
        notifyStateChanged()
    }

    func userDidRetryTermination() {
        consume(&retryTermination, value: ())
    }

    func userDidAcknowledge() {
        consume(&acknowledgement, value: ())
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
            consume(&choiceReply, value: .later)
            machine.reduce(.dismissed)
        } else if readyReply?.isArmed == true {
            consume(&readyReply, value: .later)
        } else if acknowledgement?.isArmed == true {
            consume(&acknowledgement, value: ())
        } else if retryTermination?.isArmed == true {
            // An install-in-progress keeps going; the panel can go away.
            discard(&retryTermination)
        } else if checkCancellation?.isArmed == true {
            // Closing the panel mid-check cancels it; Sparkle calls nothing
            // after a cancelled check, so the machine leaves `.checking` here.
            consume(&checkCancellation, value: ())
            machine.reduce(.checkCancelled)
        } else if downloadCancellation?.isArmed == true {
            // Closing the panel mid-download cancels it.
            consume(&downloadCancellation, value: ())
            machine.reduce(.downloadCancelled)
        } else {
            if case .readyToRelaunch = phase {
                // Keep background downloadedUpdate so the restart titlebar pill remains visible.
            } else {
                downloadedUpdate = nil
            }
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
        discard(&checkCancellation)
        discard(&downloadCancellation)
        discard(&choiceReply)
        discard(&readyReply)
        discard(&retryTermination)
        discard(&self.acknowledgement)
    }

    private func discard<T>(_ capability: inout Capability<T>?) {
        capability?.discard()
        capability = nil
    }

    private func consume<T>(_ capability: inout Capability<T>?, value: T) {
        let pending = capability
        capability = nil
        pending?.call(value)
    }

    // MARK: - UpdateDriverHost

    func driverDidBeginUserCheck(cancellation: @escaping () -> Void) {
        releaseNotes = .none
        currentCycleUpdate = nil
        currentCycleIsUserInitiated = true
        discard(&checkCancellation)
        checkCancellation = Capability(cancellation)
        machine.reduce(.userInitiatedCheckBegan)
        if !isExpeditedInstall { showPanel() }
        notifyStateChanged()
    }

    func driverDidFindUpdate(
        _ metadata: UpdateMetadata,
        stage: UpdateStage,
        userInitiated: Bool = true,
        reply: @escaping (UpdateUserChoice) -> Void
    ) {
        releaseNotes = .none
        discard(&checkCancellation)
        discard(&choiceReply)
        discard(&readyReply)
        choiceReply = Capability(reply)
        downloadedUpdate = nil
        currentCycleUpdate = metadata
        currentCycleIsUserInitiated = userInitiated
        machine.reduce(.updateFound(metadata, stage: stage))
        if isExpeditedInstall {
            // The press was the answer. Reply now rather than opening a window
            // to ask it again; `consume` keeps the exactly-once contract.
            consume(&choiceReply, value: .install)
        } else if userInitiated {
            // A scheduled/automatic presentation stays on the pill; the panel
            // opens only when the user asked for the update themselves.
            showPanel()
        }
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
        isExpeditedInstall = false
        currentCycleUpdate = nil
        discard(&checkCancellation)
        discard(&choiceReply)
        discard(&readyReply)
        currentCycleIsUserInitiated = false
        discard(&self.acknowledgement)
        self.acknowledgement = Capability(acknowledgement)
        machine.reduce(.updateNotFound(userInitiated: userInitiated))
        if userInitiated {
            showPanel()
            // Keep the result panel open until the user dismisses it. Sparkle
            // waits for this acknowledgement, which is exactly what lets the
            // custom UI communicate a useful no-update result.
        } else {
            // Quiet background check; nothing to show, acknowledge immediately.
            userDidAcknowledge()
        }
        notifyStateChanged()
    }

    func driverDidEncounterError(_ error: Error, acknowledgement: @escaping () -> Void) {
        releaseNotes = .none
        // A press that could not be honoured owes an explanation, so the
        // failure path deliberately drops back to the ordinary panel.
        isExpeditedInstall = false
        let userInitiated = currentCycleIsUserInitiated
        currentCycleIsUserInitiated = false
        discard(&self.acknowledgement)
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
        discard(&downloadCancellation)
        downloadCancellation = Capability(cancellation)
        machine.reduce(.downloadInitiated)
        // Automatic background downloads — and the one a press started —
        // proceed silently on the pill.
        if currentCycleIsUserInitiated && !isExpeditedInstall { showPanel() }
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
        discard(&downloadCancellation)
        discard(&choiceReply)
        discard(&readyReply)
        readyReply = Capability(reply)
        machine.reduce(.readyToInstallAndRelaunch)
        if isExpeditedInstall {
            consume(&readyReply, value: .install)
        } else if currentCycleIsUserInitiated {
            // A background download that became ready stays on the pill; the
            // panel opens when the pill is clicked.
            showPanel()
        }
        notifyStateChanged()
    }

    func driverDidBeginInstallation(applicationTerminated: Bool, retryTermination: @escaping () -> Void) {
        discard(&self.retryTermination)
        discard(&downloadCancellation)
        self.retryTermination = Capability(retryTermination)
        isExpeditedInstall = false
        machine.reduce(.installingUpdate(applicationTerminated: applicationTerminated))
        if !applicationTerminated {
            showPanel()  // give the user Retry / Later for a delayed quit
        }
        notifyStateChanged()
    }

    func driverDidFinishInstallation(relaunched: Bool, acknowledgement: @escaping () -> Void) {
        discard(&self.acknowledgement)
        self.acknowledgement = Capability(acknowledgement)
        machine.reduce(.updateInstalled(relaunched: relaunched))
        currentCycleIsUserInitiated = false
        isExpeditedInstall = false
        currentCycleUpdate = nil
        downloadedUpdate = nil
        userDidAcknowledge()
        closePanel()
        notifyStateChanged()
    }

    func driverDidDismiss() {
        discardAllCapabilities()
        currentCycleIsUserInitiated = false
        isExpeditedInstall = false
        currentCycleUpdate = nil
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

#if DEBUG
    /// Debug-only: put the pill into its offered state with synthetic
    /// metadata, so the "Update Now" surface — the arrival emphasis, the
    /// hover notes, the copy at both `isReady` values — can be exercised
    /// without waiting out a real ~35-minute release pipeline for every
    /// adjustment.
    ///
    /// It deliberately touches neither Sparkle, the feed, nor the trust
    /// model: it fills in exactly the `downloadedUpdate` a completed
    /// background download would leave behind, and nothing else.  Pressing
    /// the resulting pill in a dev bundle finds no running engine and does
    /// nothing, which is the correct outcome for a bundle that has no
    /// updater.  `#if DEBUG` keeps the whole thing out of the Release
    /// configuration the notarised archive is built with.
    func presentDemoUpdateForDebugging(version: String = "9.9.9") {
        downloadedUpdate = UpdateMetadata(
            versionString: "99999",
            displayVersionString: version,
            title: "Downright \(version)",
            itemDescription: """
            # Downright \(version)

            - Update Now installs from the titlebar, without a window in the way
            - Resting on the button unfurls these notes
            - The appcast is watched while the app is open, so a build lands here in about a minute
            """,
            releaseNotesURL: nil,
            infoURL: URL(string: "https://github.com/ezzy1630/Downright/releases"),
            contentLength: 18_400_000,
            isInformationOnly: false,
            isMajorUpgrade: false,
            isCritical: false,
            minimumSystemVersion: nil
        )
        notifyStateChanged()
    }
#endif

    // MARK: - Release notes state

    private(set) var releaseNotes: UpdateReleaseNotesState = .none

    // MARK: - Derived UI models

    /// The pill model across every document titlebar and the start window.
    var pillModel: UpdatePillModel? {
        switch machine.phase {
        case .idle:
            guard let downloadedUpdate else { return nil }
            return .updateNow(version: downloadedUpdate.displayVersionString, isReady: true)
        case .checking:
            return nil
        case .available(let metadata, let stage):
            return .updateNow(
                version: metadata.displayVersionString,
                isReady: stage == .downloaded || stage == .installing
            )
        case .downloading(let received, let expected):
            let fraction = expected.map { expected in Double(received) / Double(max(1, expected)) }
            return .progress(updateLabel, fraction)
        case .extracting(let progress):
            return .progress("Updating…", progress)
        case .readyToRelaunch:
            return .updateNow(version: readyVersionString, isReady: true)
        case .waitingForTermination:
            // The install has begun and the app has to quit to finish it.
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

    /// The update the pill is currently offering, for the hover notes.  Mirrors
    /// what the panel resolves so both surfaces describe the same build.
    var pendingUpdate: UpdateMetadata? {
        switch machine.phase {
        case .available(let metadata, _), .informational(let metadata):
            return metadata
        default:
            return downloadedUpdate ?? currentCycleUpdate
        }
    }

    /// The version to name once extraction has finished and the metadata is no
    /// longer carried by the phase itself.
    private var readyVersionString: String {
        pendingUpdate?.displayVersionString ?? ""
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
