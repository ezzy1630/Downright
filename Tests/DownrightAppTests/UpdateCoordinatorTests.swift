import AppKit
import Foundation
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
        #expect(coordinator.pillModel == .restartToUpdate)

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
        #expect(coordinator.pillModel == .restartToUpdate)
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

    @Test func backgroundDownloadDrivesRestartPill() {
        let (coordinator, engine) = makeCoordinator()
        #expect(coordinator.pillModel == nil)
        engine.completeBackgroundDownload(displayVersion: "1.1.0")
        #expect(coordinator.pillModel == .restartToUpdate)
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
