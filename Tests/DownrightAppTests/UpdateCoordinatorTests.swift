import AppKit
import Foundation
import MarkdownRender
import Testing
@testable import DownrightApp

// MARK: - Fixtures

private let sampleMetadata = UpdateMetadata(
    versionString: "47",
    displayVersionString: "1.1.0",
    title: "Downright 1.1.0",
    itemDescription: "## What's new\n- Faster parsing",
    releaseNotesURL: nil,
    infoURL: URL(string: "https://github.com/ezzy1630/Downright/releases/tag/v1.1.0"),
    contentLength: 4_000_000,
    isInformationOnly: false,
    isMajorUpgrade: false,
    isCritical: false,
    minimumSystemVersion: nil
)

private let informationalMetadata = UpdateMetadata(
    versionString: "50",
    displayVersionString: "1.2.0",
    title: nil,
    itemDescription: nil,
    releaseNotesURL: nil,
    infoURL: URL(string: "https://github.com/ezzy1630/Downright/releases/tag/v1.2.0"),
    contentLength: 0,
    isInformationOnly: true,
    isMajorUpgrade: false,
    isCritical: false,
    minimumSystemVersion: nil
)

// MARK: - State machine transitions

@Suite(.serialized)
struct UpdateStateMachineTests {
    private var machine: UpdateStateMachine { UpdateStateMachine() }

    @Test func checkPhases() {
        var m = machine
        m.reduce(.userInitiatedCheckBegan)
        #expect(m.phase == .checking(userInitiated: true))
        m.reduce(.automaticCheckBegan)
        #expect(m.phase == .checking(userInitiated: false))
    }

    @Test func updateFoundDistinguishesInformational() {
        var m = machine
        m.reduce(.updateFound(sampleMetadata, stage: .notDownloaded))
        #expect(m.phase == .available(sampleMetadata, stage: .notDownloaded))

        var i = machine
        i.reduce(.updateFound(informationalMetadata, stage: .notDownloaded))
        #expect(i.phase == .informational(informationalMetadata))
    }

    @Test func notFoundDependsOnUserInitiation() {
        var manual = machine
        manual.reduce(.updateNotFound(userInitiated: true))
        #expect(manual.phase == .upToDate)

        var automatic = machine
        automatic.reduce(.updateNotFound(userInitiated: false))
        #expect(automatic.phase == .idle)
    }

    @Test func errorPhase() {
        var m = machine
        let failure = UpdateFailure(message: "boom", technicalDetail: "detail", code: 2001, retryable: true)
        m.reduce(.updaterError(failure))
        #expect(m.phase == .failed(failure, retryable: true))
    }

    @Test func downloadProgressAccounting() {
        var m = machine
        m.reduce(.downloadInitiated)
        #expect(m.phase == .downloading(received: 0, expected: nil))

        // Unknown content length then a late length callback: latest wins.
        m.reduce(.dataReceived(500))
        #expect(m.phase == .downloading(received: 500, expected: nil))
        m.reduce(.expectedLength(1_000))
        #expect(m.phase == .downloading(received: 500, expected: 1_000))

        // Repeated length callbacks for the same download are tolerated.
        m.reduce(.expectedLength(1_200))
        #expect(m.phase == .downloading(received: 500, expected: 1_200))

        // Overrun is clamped to the expected size: progress never exceeds 100%.
        m.reduce(.dataReceived(100_000))
        #expect(m.phase == .downloading(received: 1_200, expected: 1_200))
    }

    @Test func extractionProgressIsClamped() {
        var m = machine
        m.reduce(.extractionBegan)
        m.reduce(.extractionProgress(1.4))
        #expect(m.phase == .extracting(progress: 1.0))
        m.reduce(.extractionProgress(-0.2))
        #expect(m.phase == .extracting(progress: 0.0))
    }

    @Test func installationStages() {
        var delayed = machine
        delayed.reduce(.installingUpdate(applicationTerminated: false))
        #expect(delayed.phase == .waitingForTermination)

        var terminated = machine
        terminated.reduce(.installingUpdate(applicationTerminated: true))
        #expect(terminated.phase == .installing)
    }

    @Test func releaseNotesEventsDoNotMoveThePhase() {
        var m = machine
        m.reduce(.updateFound(sampleMetadata, stage: .notDownloaded))
        m.reduce(.releaseNotesAvailable)
        #expect(m.phase == .available(sampleMetadata, stage: .notDownloaded))
        m.reduce(.releaseNotesFailed)
        #expect(m.phase == .available(sampleMetadata, stage: .notDownloaded))
    }

    @Test func cancellationsReturnToIdle() {
        var checking = machine
        checking.reduce(.userInitiatedCheckBegan)
        checking.reduce(.checkCancelled)
        #expect(checking.phase == .idle)

        var downloading = machine
        downloading.reduce(.downloadInitiated)
        downloading.reduce(.downloadCancelled)
        #expect(downloading.phase == .idle)
    }

    @Test func dismissalReturnsToIdleFromAnyState() {
        for setup in [machine, {
            var m = UpdateStateMachine()
            m.reduce(.updateFound(sampleMetadata, stage: .notDownloaded))
            return m
        }(), {
            var m = UpdateStateMachine()
            m.reduce(.downloadInitiated)
            m.reduce(.expectedLength(10))
            m.reduce(.dataReceived(5))
            return m
        }(), {
            var m = UpdateStateMachine()
            m.reduce(.updaterError(.generic))
            return m
        }()] {
            var m = setup
            m.reduce(.dismissed)
            #expect(m.phase == .idle)
        }
    }

    /// The complete happy-path ordering from a manual check to relaunch.
    @Test func fullHappyPathOrdering() {
        var m = machine
        let expected: [UpdateStateMachine.UpdatePhase] = [
            .checking(userInitiated: true),
            .available(sampleMetadata, stage: .notDownloaded),
            .downloading(received: 0, expected: nil),
            .downloading(received: 100, expected: 1_000),
            .extracting(progress: nil),
            .extracting(progress: 0.5),
            .readyToRelaunch,
            .waitingForTermination,
            .installing,
            .idle,
        ]
        for event in [
            UpdateStateMachine.UpdateEvent.userInitiatedCheckBegan,
            .updateFound(sampleMetadata, stage: .notDownloaded),
            .downloadInitiated,
            .expectedLength(1_000),
            .dataReceived(100),
            .extractionBegan,
            .extractionProgress(0.5),
            .readyToInstallAndRelaunch,
            .installingUpdate(applicationTerminated: false),
            .installingUpdate(applicationTerminated: true),
            .updateInstalled(relaunched: true),
        ] {
            m.reduce(event)
        }
        #expect(m.phase == expected.last)
    }
}

// MARK: - Exactly-once capabilities

@Suite(.serialized)
struct UpdateCapabilityTests {
    @Test func callInvokesExactlyOnce() {
        var count = 0
        let capability = Capability<Int> { _ in count += 1 }
        capability.call(1)
        capability.call(2)
        capability.call(3)
        #expect(count == 1)
        #expect(!capability.isArmed)
    }

    @Test func discardPreventsInvocation() {
        var count = 0
        let capability = Capability<Void> { count += 1 }
        capability.discard()
        capability.call(())
        #expect(count == 0)
        #expect(!capability.isArmed)
    }
}

// MARK: - Production configuration

@Suite
struct UpdateConfigurationTests {
    @Test func acceptsValidHTTPSFeedAndEd25519Key() {
        let info: [String: Any] = [
            "SUFeedURL": "https://updates.example.test/appcast.xml",
            "SUPublicEDKey": Data(repeating: 0, count: 32).base64EncodedString(),
        ]

        #expect(UpdateConfiguration.isValid(infoDictionary: info))
    }

    @Test(arguments: [
        "https://updates.example.test/appcast.xml",
        "http://updates.example.test/appcast.xml",
        "not a URL",
    ])
    func rejectsInvalidFeedOrKey(feed: String) {
        let info: [String: Any] = [
            "SUFeedURL": feed,
            "SUPublicEDKey": "PLACEHOLDER_DOWNRIGHT_ED25519_PUBLIC_KEY",
        ]

        #expect(!UpdateConfiguration.isValid(infoDictionary: info))
    }
}

// MARK: - Coordinator flows

@Suite(.serialized)
@MainActor
struct UpdateCoordinatorFlowTests {
    private func makeCoordinator() -> (UpdateCoordinator, FakeUpdateEngine) {
        let engine = FakeUpdateEngine()
        let coordinator = UpdateCoordinator(engine: engine)
        coordinator.suppressUIForTesting = true
        try? engine.start()
        return (coordinator, engine)
    }

    // MARK: Exactly-once through the coordinator

    @Test func installReplyIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.userDidChooseInstall()
        coordinator.userDidChooseInstall()  // second click must be a no-op
        #expect(replies == [.install])
    }

    @Test func skipReplyIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.userDidChooseSkip()
        coordinator.userDidChooseSkip()
        #expect(replies == [.skip])
    }

    @Test func laterReplyIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.userDidChooseLater()
        coordinator.userDidChooseLater()
        #expect(replies == [.later])
    }

    @Test func readyToRelaunchUsesItsOwnReply() {
        let (coordinator, _) = makeCoordinator()
        var readyReplies: [UpdateUserChoice] = []
        var foundReplies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { foundReplies.append($0) }
        // A stale found-update reply is replaced when the ready reply arrives.
        coordinator.driverDidBecomeReadyToRelaunch { readyReplies.append($0) }
        coordinator.userDidChooseInstall()
        #expect(readyReplies == [.install])
        #expect(foundReplies.isEmpty)
    }

    @Test func errorAcknowledgementIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var acks = 0
        coordinator.driverDidEncounterError(NSError(domain: "sparkle", code: 2001)) { acks += 1 }
        coordinator.userDidDismissPanel()
        coordinator.userDidDismissPanel()
        #expect(acks == 1)
    }

    @Test func notFoundAcknowledgementIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var acks = 0
        coordinator.driverDidFindNoUpdate(userInitiated: true) { acks += 1 }
        // The result stays visible until the user dismisses it; a second
        // dismissal must not acknowledge Sparkle twice.
        #expect(acks == 0)
        coordinator.userDidChooseLater()
        coordinator.userDidDismissPanel()
        #expect(acks == 1)
    }

    @Test func checkCancellationIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var cancels = 0
        coordinator.driverDidBeginUserCheck { cancels += 1 }
        coordinator.userDidCancelCheck()
        coordinator.userDidCancelCheck()
        #expect(cancels == 1)
    }

    @Test func downloadCancellationIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var cancels = 0
        coordinator.driverDidBeginDownload { cancels += 1 }
        coordinator.userDidCancelDownload()
        coordinator.userDidCancelDownload()
        #expect(cancels == 1)
    }

    @Test func retryTerminationIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var retries = 0
        coordinator.driverDidBeginInstallation(applicationTerminated: false) { retries += 1 }
        coordinator.userDidRetryTermination()
        coordinator.userDidRetryTermination()
        #expect(retries == 1)
    }

    /// Closing the panel mid-check must invoke Sparkle's cancellation exactly
    /// once and leave the machine idle — a leaked cancellation would leave the
    /// check running with nobody able to stop it.
    @Test func dismissalDuringCheckCancelsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var cancels = 0
        coordinator.driverDidBeginUserCheck { cancels += 1 }
        #expect(coordinator.phase == .checking(userInitiated: true))
        coordinator.userDidDismissPanel()
        coordinator.userDidDismissPanel()
        #expect(cancels == 1)
        #expect(coordinator.phase == .idle)
    }

    /// Closing the panel mid-download must cancel the download exactly once.
    @Test func dismissalDuringDownloadCancelsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var cancels = 0
        coordinator.driverDidBeginDownload { cancels += 1 }
        #expect(coordinator.phase == .downloading(received: 0, expected: nil))
        coordinator.userDidDismissPanel()
        coordinator.userDidDismissPanel()
        #expect(cancels == 1)
        #expect(coordinator.phase == .idle)
    }

    /// The panel's Cancel buttons resolve the machine out of the active state.
    @Test func cancelButtonsResolveTheMachine() {
        let (coordinator, _) = makeCoordinator()
        var checkCancels = 0
        coordinator.driverDidBeginUserCheck { checkCancels += 1 }
        coordinator.userDidCancelCheck()
        #expect(checkCancels == 1)
        #expect(coordinator.phase == .idle)

        var downloadCancels = 0
        coordinator.driverDidBeginDownload { downloadCancels += 1 }
        coordinator.userDidCancelDownload()
        #expect(downloadCancels == 1)
        #expect(coordinator.phase == .idle)
    }

    /// Choosing Later/Skip from an offered update must leave `.available` so
    /// the pill stops offering the update.
    @Test func laterAndSkipLeaveTheOfferedState() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { _ in }
        coordinator.userDidChooseLater()
        #expect(coordinator.phase == .idle)

        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { _ in }
        coordinator.userDidChooseSkip()
        #expect(coordinator.phase == .idle)
    }

    // MARK: Background cycles stay on the pill

    /// An automatically-scheduled presentation must not open the panel; a
    /// user-initiated one must.
    @Test func backgroundUpdateDoesNotOpenThePanel() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .downloaded, userInitiated: false) { _ in }
        #expect(coordinator.panelShowCount == 0)
        #expect(coordinator.phase == .available(sampleMetadata, stage: .downloaded))
        #expect(coordinator.pillModel == .updateNow(version: "1.1.0", isReady: true))

        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded, userInitiated: true) { _ in }
        #expect(coordinator.panelShowCount > 0)
    }

    /// Automatic download + ready-to-relaunch must proceed silently on the
    /// pill; the panel opens only when the user clicks it.
    @Test func backgroundDownloadAndReadyStayOnThePill() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidBeginDownload { }
        #expect(coordinator.panelShowCount == 0)
        #expect(coordinator.phase == .downloading(received: 0, expected: nil))
        coordinator.driverDidBecomeReadyToRelaunch { _ in }
        #expect(coordinator.panelShowCount == 0)
        #expect(coordinator.phase == .readyToRelaunch)
        #expect(coordinator.pillModel?.offersInstall == true)
    }

    /// A background-cycle failure is a non-event: no window, and no warning
    /// pill either.  It used to leave an orange badge on every window because
    /// a laptop was opened without wifi, which is the alarm DESIGN.md rules
    /// out; the coordinator now acknowledges and finishes the cycle instead.
    @Test func backgroundErrorIsSilentAndFinishesTheCycle() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidEncounterError(NSError(domain: "Sparkle", code: 1002)) { }
        #expect(coordinator.panelShowCount == 0)
        #expect(coordinator.pillModel == nil)
        #expect(coordinator.phase == .idle, "the cycle must end, or the next check can never start")
    }

    @Test func teardownDiscardsPendingReply() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.tearDownForTesting()
        coordinator.userDidChooseInstall()
        #expect(replies.isEmpty)
        #expect(coordinator.phase == .idle)
    }

    @Test func dismissalDiscardsPendingReply() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.driverDidDismiss()
        coordinator.userDidChooseInstall()
        #expect(replies.isEmpty)
        #expect(coordinator.phase == .idle)
    }

    @Test func releaseNotesNeverLeakIntoTheNextUpdateCycle() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { _ in }
        coordinator.driverDidReceiveReleaseNotes(Data("v1 notes".utf8))
        #expect(coordinator.releaseNotes == .loaded(Data("v1 notes".utf8)))

        coordinator.driverDidDismiss()
        #expect(coordinator.releaseNotes == .none)
        coordinator.driverDidFindUpdate(
            UpdateMetadata(
                versionString: "48",
                displayVersionString: "1.1.1",
                title: nil,
                itemDescription: nil,
                releaseNotesURL: nil,
                infoURL: nil,
                contentLength: 0,
                isInformationOnly: false,
                isMajorUpgrade: false,
                isCritical: false,
                minimumSystemVersion: nil
            ),
            stage: .notDownloaded
        ) { _ in }
        #expect(coordinator.releaseNotes == .none)
    }

    // MARK: Background downloads

    @Test func backgroundDownloadDrivesUpdateNowPill() {
        let (coordinator, engine) = makeCoordinator()
        #expect(coordinator.pillModel == nil)
        engine.completeBackgroundDownload(displayVersion: "1.1.0")
        #expect(coordinator.pillModel == .updateNow(version: "1.1.0", isReady: true))
        #expect(coordinator.downloadedUpdate != nil)
        coordinator.driverDidDismiss()
        #expect(coordinator.downloadedUpdate == nil)
        #expect(coordinator.pillModel == nil)
    }

    // MARK: Error handling

    /// Only a check the user asked for reports its failure.  The begin call is
    /// what marks the cycle user-initiated, exactly as Sparkle drives it.
    @Test func userInitiatedErrorProducesWarningPillAndRetryableState() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidBeginUserCheck { }
        coordinator.driverDidEncounterError(
            NSError(domain: "Sparkle", code: 1002, userInfo: [NSLocalizedDescriptionKey: "The feed couldn't be loaded."])
        ) { }
        #expect(coordinator.pillModel == .warning)
        guard case .failed(_, let retryable) = coordinator.phase else {
            Issue.record("expected failed phase")
            return
        }
        #expect(retryable)
    }

    @Test func retryAcknowledgesAndReturnsToIdle() async {
        let (coordinator, _) = makeCoordinator()
        var acks = 0
        coordinator.driverDidEncounterError(NSError(domain: "sparkle", code: 3001)) { acks += 1 }
        coordinator.userDidRetry()
        // The retried check is scheduled for the next runloop turn; in a test
        // bundle there is no feed configuration, so checkForUpdates() gates at
        // isConfigured and stays quiet.  Hopping through the main queue lets
        // that turn happen — the queue is FIFO, so our block runs after the
        // retry's.  What must hold: the failed cycle is acknowledged exactly
        // once and the machine returns to idle.
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(acks == 1)
        #expect(coordinator.phase == .idle)
    }

    // MARK: Informational / critical

    @Test func informationalUpdateNeverOffersInstall() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(informationalMetadata, stage: .notDownloaded) { replies.append($0) }
        #expect(coordinator.phase == .informational(informationalMetadata))
        coordinator.userDidChooseLater()
        #expect(replies == [.later])
    }

    @Test func criticalUpdateKeepsSkipAvailableToTheMachine() {
        let (coordinator, _) = makeCoordinator()
        var critical = sampleMetadata
        critical.isCritical = true
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(critical, stage: .notDownloaded) { replies.append($0) }
        // The machine still supports skip; the UI hides the button for critical
        // updates (asserted by the panel's own logic in UpdateWindowController).
        coordinator.userDidChooseSkip()
        #expect(replies == [.skip])
    }

    // MARK: Settings

    @Test func settingsProxyWritesThroughToEngine() {
        let (coordinator, engine) = makeCoordinator()
        coordinator.automaticallyChecksForUpdates = false
        #expect(!engine.automaticallyChecksForUpdates)
        coordinator.automaticallyDownloadsUpdates = false
        #expect(!engine.automaticallyDownloadsUpdates)
        coordinator.automaticallyChecksForUpdates = true
        #expect(engine.automaticallyChecksForUpdates)
    }

    @Test func canCheckForUpdatesReflectsEngine() {
        let (coordinator, engine) = makeCoordinator()
        // This test bundle has no SUFeedURL, so the configuration gate says no.
        #expect(!coordinator.canCheckForUpdates)
        engine._canCheckForUpdates = false
        #expect(!coordinator.canCheckForUpdates)
    }

    // MARK: Pill synchronization (multiwindow)

    @Test func stateChangeBroadcastsToOneCoordinatorForAllPills() {
        let (coordinator, _) = makeCoordinator()
        var received = 0
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: UpdateCoordinator.stateDidChange, object: coordinator, queue: .main
        ) { _ in received += 1 }
        defer { if let token { NotificationCenter.default.removeObserver(token) } }
        coordinator.driverDidReceiveData(500)
        coordinator.driverDidReceiveExpectedLength(1_000)
        #expect(received >= 2)
    }
}

@Suite(.serialized)
@MainActor
struct UpdatePanelFooterTests {
    /// Sparkle first presents the checking state, then replaces its Cancel
    /// button with the result actions. The footer has two columns, so this
    /// transition must remove each button from its owning stack only.
    @Test func rebuildsAfterCheckIntoAvailableState() {
        _ = NSApplication.shared
        let engine = FakeUpdateEngine()
        let coordinator = UpdateCoordinator(engine: engine)
        coordinator.suppressUIForTesting = true
        try? engine.start()

        let footer = UpdatePanelFooter(
            frame: NSRect(x: 0, y: 0, width: 540, height: 34)
        )
        coordinator.driverDidBeginUserCheck(cancellation: {})
        footer.update(coordinator: coordinator)

        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { _ in }
        footer.update(coordinator: coordinator)

        #expect(coordinator.phase == .available(sampleMetadata, stage: .notDownloaded))
    }
}

@Suite(.serialized)
@MainActor
struct UpdatePanelTransitionTests {
    /// Every Sparkle callback can rebuild the panel. Keep this smoke test on
    /// the real AppKit view tree so a future state-specific layout regression
    /// fails in CI before a release can ship it.
    @Test func rendersEveryUpdaterPhaseWithoutThrowing() {
        _ = NSApplication.shared
        let engine = FakeUpdateEngine()
        let coordinator = UpdateCoordinator(engine: engine)
        coordinator.suppressUIForTesting = true
        try? engine.start()

        let panel = UpdatePanelView(coordinator: coordinator)
        let render = { panel.refresh() }

        coordinator.driverDidBeginUserCheck(cancellation: {})
        render()

        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { _ in }
        render()

        coordinator.driverDidBeginDownload(cancellation: {})
        coordinator.driverDidReceiveExpectedLength(1_000)
        coordinator.driverDidReceiveData(250)
        render()

        coordinator.driverDidBeginExtraction()
        coordinator.driverDidReceiveExtractionProgress(0.5)
        render()

        coordinator.driverDidBecomeReadyToRelaunch { _ in }
        render()

        coordinator.driverDidBeginInstallation(applicationTerminated: false) { }
        render()

        coordinator.driverDidBeginInstallation(applicationTerminated: true) { }
        render()

        coordinator.driverDidBeginUserCheck(cancellation: {})
        coordinator.driverDidFindNoUpdate(userInitiated: true) { }
        render()

        coordinator.driverDidBeginUserCheck(cancellation: {})
        coordinator.driverDidEncounterError(NSError(domain: "sparkle", code: 2001)) { }
        render()

        coordinator.driverDidFindUpdate(informationalMetadata, stage: .notDownloaded) { _ in }
        render()
    }
}

// MARK: - Build contract

@Suite(.serialized)
struct UpdateBuildContractTests {
    /// Sparkle must be linked by the host app only — never by MarkdownCore,
    /// MarkdownRender, the CLI, or the Quick Look targets.
    @Test func sparkleIsImportedOnlyByTheHostApp() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // DownrightAppTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
        let enumerator = FileManager.default.enumerator(
            at: root.appendingPathComponent("Sources"),
            includingPropertiesForKeys: nil
        )!
        var offenders: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard text.contains("import Sparkle") else { continue }
            let relative = url.path.replacingOccurrences(of: root.path + "/", with: "")
            if !relative.hasPrefix("Sources/DownrightApp") {
                offenders.append(relative)
            }
        }
        #expect(offenders.isEmpty, "Sparkle imported outside the host app: \(offenders)")
    }

    /// The `Downright` product (not `down`, `drbench`, `MarkdownCore`, …) must
    /// declare the Sparkle dependency in Package.swift.
    @Test func packageManifestDeclaresSparkleExactly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        #expect(manifest.contains("exact: \"2.9.5\""), "Sparkle must be pinned exactly to 2.9.5")
        // The DownrightApp target block is the `...name: "DownrightApp"...}`
        // region; assert Sparkle is wired into it.
        guard let marker = manifest.range(of: "\"DownrightApp\"") else {
            Issue.record("DownrightApp target not found in Package.swift")
            return
        }
        let targetText = String(manifest[marker.lowerBound...])
        let appTarget = targetText.prefix { $0 != "}" }
        #expect(appTarget.contains("Sparkle"), "DownrightApp target must link Sparkle")
    }
}

// MARK: - Release watch policy

@Suite
struct ReleaseWatchPolicyTests {
    @Test func frontmostChecksFarMoreOftenThanBackgrounded() {
        var policy = ReleaseWatchPolicy()
        policy.isAppActive = true
        #expect(policy.interval == ReleaseWatchPolicy.activeInterval)
        policy.isAppActive = false
        #expect(policy.interval == ReleaseWatchPolicy.backgroundInterval)
    }

    /// No network is not a failure state; it is simply nothing to do.
    @Test func noNetworkSuspendsEntirely() {
        var policy = ReleaseWatchPolicy(isAppActive: true, isLowPower: false, hasNetwork: false)
        #expect(policy.interval == nil)
        policy.hasNetwork = true
        #expect(policy.interval != nil)
    }

    /// Low Power Mode is an explicit request to stop doing optional work, and
    /// polling for a build nobody asked for is exactly that.
    @Test func lowPowerBacksOffInFrontAndStopsBehind() {
        var policy = ReleaseWatchPolicy(isAppActive: true, isLowPower: true, hasNetwork: true)
        #expect(policy.interval == ReleaseWatchPolicy.backgroundInterval)
        policy.isAppActive = false
        #expect(policy.interval == nil)
    }
}

// MARK: - Release watch

@MainActor
private final class FakeReleaseFeedProbe: ReleaseFeedProbe {
    private var results: [ReleaseFeedProbeResult]
    /// Every validator the watch offered, in order — the evidence that a
    /// conditional request is actually conditional.
    private(set) var validators: [String?] = []

    init(_ results: [ReleaseFeedProbeResult]) { self.results = results }

    func probe(feed: URL, validator: String?) async -> ReleaseFeedProbeResult {
        validators.append(validator)
        return results.isEmpty ? .unchanged : results.removeFirst()
    }
}

@Suite(.serialized)
@MainActor
struct ReleaseWatchTests {
    private let feed = URL(string: "https://example.invalid/appcast.xml")!

    /// The watch hands its work to a `Task`; yield until it has landed rather
    /// than sleeping for a duration that would only ever be a guess.
    private func settle(_ watch: ReleaseWatch, probes: Int) async {
        for _ in 0..<500 where watch.completedProbeCount < probes {
            await Task.yield()
        }
    }

    private func makeWatch(
        _ results: [ReleaseFeedProbeResult]
    ) -> (ReleaseWatch, FakeReleaseFeedProbe) {
        let probe = FakeReleaseFeedProbe(results)
        return (ReleaseWatch(feed: feed, prober: probe), probe)
    }

    /// Sparkle's own post-launch check already answers "was something waiting
    /// when I opened the app". The first probe only learns where to start.
    @Test func firstProbeEstablishesTheBaselineWithoutFiring() async {
        let (watch, _) = makeWatch([.changed(validator: "etag:a")])
        var fired = 0
        watch.onFeedChanged = { fired += 1 }
        watch.start(observingSystemEvents: false)
        await settle(watch, probes: 1)
        #expect(watch.hasBaseline)
        #expect(fired == 0)
        watch.stop()
    }

    @Test func aMovedFeedFiresOnce() async {
        let (watch, probe) = makeWatch([.changed(validator: "etag:a"), .changed(validator: "etag:b")])
        var fired = 0
        watch.onFeedChanged = { fired += 1 }
        watch.start(observingSystemEvents: false)
        await settle(watch, probes: 1)
        watch.probeNow()
        await settle(watch, probes: 2)
        #expect(fired == 1)
        // The second request carried the first response's validator back.
        #expect(probe.validators == [nil, "etag:a"])
        watch.stop()
    }

    @Test func anUnchangedFeedIsSilent() async {
        let (watch, _) = makeWatch([.changed(validator: "etag:a"), .unchanged, .unchanged])
        var fired = 0
        watch.onFeedChanged = { fired += 1 }
        watch.start(observingSystemEvents: false)
        await settle(watch, probes: 1)
        watch.probeNow()
        await settle(watch, probes: 2)
        watch.probeNow()
        await settle(watch, probes: 3)
        #expect(fired == 0)
        watch.stop()
    }

    /// An unreachable feed must not be mistaken for a baseline, or the first
    /// successful probe after a flight would look like a brand-new release.
    @Test func anUnreachableFeedDoesNotEstablishTheBaseline() async {
        let (watch, _) = makeWatch([.unreachable, .changed(validator: "etag:a")])
        var fired = 0
        watch.onFeedChanged = { fired += 1 }
        watch.start(observingSystemEvents: false)
        await settle(watch, probes: 1)
        #expect(!watch.hasBaseline)
        watch.probeNow()
        await settle(watch, probes: 2)
        #expect(watch.hasBaseline)
        #expect(fired == 0)
        watch.stop()
    }

    /// Wake fires activation too, and a held Cmd-Tab flaps it several times a
    /// second. Without a floor each of those becomes its own request.
    @Test func coincidingEventsCollapseIntoOneProbe() async {
        let (watch, _) = makeWatch([.changed(validator: "etag:a")])
        watch.start(observingSystemEvents: false)
        await settle(watch, probes: 1)
        watch.systemDidWake()
        watch.applicationDidChangeActivation(isActive: true)
        watch.networkAvailabilityDidChange(hasNetwork: true)
        await Task.yield()
        #expect(watch.completedProbeCount == 1)
        watch.stop()
    }

    @Test func losingTheNetworkStopsProbing() async {
        let (watch, _) = makeWatch([.changed(validator: "etag:a")])
        watch.start(observingSystemEvents: false)
        await settle(watch, probes: 1)
        watch.networkAvailabilityDidChange(hasNetwork: false)
        watch.probeNow()
        await Task.yield()
        #expect(watch.completedProbeCount == 1)
        watch.stop()
    }
}

// MARK: - Notes summary

@Suite
struct UpdateNotesSummaryTests {
    /// The panel header already names the version, so a leading title line
    /// would be the same sentence twice.
    @Test func dropsTheLeadingTitle() {
        let summary = UpdateNotesSummary.summary(from: "# Downright 1.1.0\n\n- Faster parsing")
        #expect(!summary.contains("Downright 1.1.0"))
        #expect(summary.contains("Faster parsing"))
    }

    @Test func stopsWellShortOfAWallOfText() {
        let long = (1...60).map { "- change number \($0)" }.joined(separator: "\n")
        let summary = UpdateNotesSummary.summary(from: long)
        #expect(summary.contains("change number 1"))
        #expect(!summary.contains("change number 40"))
        #expect(summary.hasSuffix("…"), "a trimmed summary has to say that it was trimmed")
    }

    @Test func handlesNoNotesAtAll() {
        #expect(UpdateNotesSummary.summary(from: nil).isEmpty)
        #expect(UpdateNotesSummary.summary(from: "   \n\n  ").isEmpty)
    }

    @Test func keepsShortNotesWhole() {
        let summary = UpdateNotesSummary.summary(from: "- one\n- two")
        #expect(summary == "- one\n- two")
    }
}

// MARK: - Update Now (one press installs)

@Suite(.serialized)
@MainActor
struct UpdateNowPressTests {
    private func makeCoordinator() -> (UpdateCoordinator, FakeUpdateEngine) {
        let engine = FakeUpdateEngine()
        let coordinator = UpdateCoordinator(engine: engine)
        coordinator.suppressUIForTesting = true
        try? engine.start()
        return (coordinator, engine)
    }

    @Test func onlyActionableStatesOfferAnInstall() {
        #expect(UpdatePillModel.updateNow(version: "1.1.0", isReady: false).offersInstall)
        #expect(UpdatePillModel.restartToUpdate.offersInstall)
        #expect(!UpdatePillModel.warning.offersInstall)
        #expect(!UpdatePillModel.progress("Updating…", nil).offersInstall)
        #expect(!UpdatePillModel.informational("1.2.0").offersInstall)
    }

    /// The whole point of the control: the press is the decision, so no window
    /// opens to ask it again.
    @Test func pressInstallsWithoutOpeningThePanel() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded, userInitiated: false) {
            replies.append($0)
        }
        #expect(coordinator.pillModel == .updateNow(version: "1.1.0", isReady: false))
        coordinator.userDidPressUpdateNow()
        #expect(replies == [.install])
        #expect(coordinator.panelShowCount == 0)
    }

    /// A background download leaves no prompt armed, so the press has to
    /// re-enter Sparkle — and that cycle must stay as silent as the press.
    @Test func pressOnABackgroundDownloadReentersSparkleSilently() {
        let (coordinator, engine) = makeCoordinator()
        engine.completeBackgroundDownload(displayVersion: "1.1.0")
        coordinator.userDidPressUpdateNow()
        #expect(engine.foregroundCheckCount == 1)
        #expect(coordinator.isExpeditedInstall)

        coordinator.driverDidBeginUserCheck { }
        #expect(coordinator.panelShowCount == 0, "a press must not open the panel it replaced")

        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .downloaded, userInitiated: true) {
            replies.append($0)
        }
        #expect(replies == [.install])
        #expect(coordinator.panelShowCount == 0)
    }

    @Test func anExpeditedReadyToRelaunchInstallsImmediately() {
        let (coordinator, engine) = makeCoordinator()
        engine.completeBackgroundDownload(displayVersion: "1.1.0")
        coordinator.userDidPressUpdateNow()
        coordinator.driverDidBeginUserCheck { }
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded, userInitiated: true) { _ in }
        coordinator.driverDidBeginDownload { }
        #expect(coordinator.panelShowCount == 0, "progress belongs on the pill during a press")

        var replies: [UpdateUserChoice] = []
        coordinator.driverDidBecomeReadyToRelaunch { replies.append($0) }
        #expect(replies == [.install])
        #expect(coordinator.panelShowCount == 0)
    }

    /// A press that could not be honoured owes an explanation, so the failure
    /// path deliberately drops back to the ordinary panel.
    @Test func anExpeditedFailureFallsBackToThePanel() {
        let (coordinator, engine) = makeCoordinator()
        engine.completeBackgroundDownload(displayVersion: "1.1.0")
        coordinator.userDidPressUpdateNow()
        coordinator.driverDidBeginUserCheck { }
        coordinator.driverDidEncounterError(
            NSError(domain: "Sparkle", code: 2001, userInfo: [NSLocalizedDescriptionKey: "no"])
        ) { }
        #expect(!coordinator.isExpeditedInstall)
        #expect(coordinator.panelShowCount > 0)
        #expect(coordinator.pillModel == .warning)
    }

    /// Once installation has begun only the quit is outstanding, so the pill
    /// says so and the press retries the quit rather than starting again.
    @Test func pressWhileWaitingForTerminationRetriesTheQuit() {
        let (coordinator, _) = makeCoordinator()
        var retries = 0
        coordinator.driverDidBeginInstallation(applicationTerminated: false) { retries += 1 }
        #expect(coordinator.pillModel == .restartToUpdate)
        coordinator.userDidPressUpdateNow()
        #expect(retries == 1)
    }

    /// The phases after `.available` carry no metadata of their own; without
    /// the cycle keeping hold of it, the tooltip and hover notes go blank
    /// halfway through the install they are describing.
    @Test func theVersionSurvivesToReadyToRelaunch() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded, userInitiated: false) { _ in }
        coordinator.driverDidBeginDownload { }
        coordinator.driverDidBecomeReadyToRelaunch { _ in }
        #expect(coordinator.pendingUpdate?.displayVersionString == "1.1.0")
        #expect(coordinator.pillModel == .updateNow(version: "1.1.0", isReady: true))
        coordinator.driverDidDismiss()
        #expect(coordinator.pendingUpdate == nil)
    }
}

// MARK: - Release watch → coordinator

@Suite(.serialized)
@MainActor
struct ReleaseWatchTriggerTests {
    private func makeCoordinator() -> (UpdateCoordinator, FakeUpdateEngine) {
        let engine = FakeUpdateEngine()
        let coordinator = UpdateCoordinator(engine: engine)
        coordinator.suppressUIForTesting = true
        try? engine.start()
        return (coordinator, engine)
    }

    /// The full extent of the watch's authority: it asks Sparkle to look.
    @Test func aMovedFeedAsksSparkleToLook() {
        let (coordinator, engine) = makeCoordinator()
        #expect(engine.backgroundCheckCount == 0)
        coordinator.releaseFeedDidChange()
        #expect(engine.backgroundCheckCount == 1)
        #expect(coordinator.releaseWatchTriggerCount == 1)
    }

    /// The reader is watching a download or reading a prompt; restarting
    /// underneath them replaces what they are looking at with the same answer.
    @Test func aLiveCycleIsLeftAlone() {
        let (coordinator, engine) = makeCoordinator()
        coordinator.driverDidBeginUserCheck { }
        coordinator.releaseFeedDidChange()
        #expect(engine.backgroundCheckCount == 0)
    }

    @Test func anAlreadyWaitingUpdateIsNotRechecked() {
        let (coordinator, engine) = makeCoordinator()
        engine.completeBackgroundDownload(displayVersion: "1.1.0")
        coordinator.releaseFeedDidChange()
        #expect(engine.backgroundCheckCount == 0)
    }

    /// A bundle with no updater has nothing to trigger.
    @Test func aStoppedEngineIsNeverTriggered() {
        let engine = FakeUpdateEngine()
        let coordinator = UpdateCoordinator(engine: engine)
        coordinator.suppressUIForTesting = true
        coordinator.releaseFeedDidChange()
        #expect(engine.backgroundCheckCount == 0)
        #expect(coordinator.releaseWatchTriggerCount == 0)
    }
}

// MARK: - The automatic-check setting governs the watch too

@Suite(.serialized)
@MainActor
struct ReleaseWatchSettingTests {
    /// "Check for updates automatically" has to mean every automatic check.
    /// A setting that stopped Sparkle's schedule and left the watch polling
    /// would be a narrower promise than the one the settings pane makes.
    @Test func turningAutomaticChecksOffSilencesTheWatch() {
        let engine = FakeUpdateEngine()
        let coordinator = UpdateCoordinator(engine: engine)
        coordinator.suppressUIForTesting = true
        try? engine.start()

        coordinator.releaseFeedDidChange()
        #expect(engine.backgroundCheckCount == 1)

        coordinator.automaticallyChecksForUpdates = false
        coordinator.releaseFeedDidChange()
        #expect(engine.backgroundCheckCount == 1, "the watch must not outlive the setting")

        coordinator.automaticallyChecksForUpdates = true
        coordinator.releaseFeedDidChange()
        #expect(engine.backgroundCheckCount == 2)
    }
}

/// Linked release notes must never reach the WebKit-backed html document
/// type: the update channel's host is outside the app's documented network
/// surface, and a web engine would fetch remote subresources. The reduction
/// keeps the text, drops the machinery.
@Suite struct UpdateReleaseNotesReductionTests {
    @Test @MainActor func stripsTagsAndKeepsReadableText() {
        let html = """
        <html><head><style>body { color: red }</style>​<script>alert(1)</script></head>
        <body><h1>Downright 1.0.17</h1><p>First &amp; second &#8212; line</p>
        <ul><li>one</li><li>two</li></ul><p>Bye<br/>now</p></body></html>
        """
        let text = UpdateNotesView.textFromHTML(Data(html.utf8))
        #expect(text.contains("Downright 1.0.17"))
        #expect(text.contains("First & second — line"))
        #expect(text.contains("one") && text.contains("two"))
        #expect(text.contains("Bye\nnow"))
        #expect(!text.lowercased().contains("alert"), "script content is dropped whole")
        #expect(!text.contains("{ color"), "style content is dropped whole")
        #expect(!text.contains("<"), "no tags survive")
    }

    @Test @MainActor func nonHTMLDataPassesThroughAsText() {
        let markdown = "## Notes\n- plain"
        let view = UpdateNotesView.releaseNotesTextView(
            for: Data(markdown.utf8),
            sheet: StyleSheet(
                theme: ThemeStore.shared.current,
                appearance: NSAppearance.current,
                reduceMotionOverride: false
            )
        )
        #expect(view.string.contains("Notes"))
    }
}
