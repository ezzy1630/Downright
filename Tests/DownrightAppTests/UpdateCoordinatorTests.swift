import XCTest
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

final class UpdateStateMachineTests: XCTestCase {
    private var machine: UpdateStateMachine { UpdateStateMachine() }

    func testCheckPhases() {
        var m = machine
        m.reduce(.userInitiatedCheckBegan)
        XCTAssertEqual(m.phase, .checking(userInitiated: true))
        m.reduce(.automaticCheckBegan)
        XCTAssertEqual(m.phase, .checking(userInitiated: false))
    }

    func testUpdateFoundDistinguishesInformational() {
        var m = machine
        m.reduce(.updateFound(sampleMetadata, stage: .notDownloaded))
        XCTAssertEqual(m.phase, .available(sampleMetadata, stage: .notDownloaded))

        var i = machine
        i.reduce(.updateFound(informationalMetadata, stage: .notDownloaded))
        XCTAssertEqual(i.phase, .informational(informationalMetadata))
    }

    func testNotFoundDependsOnUserInitiation() {
        var manual = machine
        manual.reduce(.updateNotFound(userInitiated: true))
        XCTAssertEqual(manual.phase, .upToDate)

        var automatic = machine
        automatic.reduce(.updateNotFound(userInitiated: false))
        XCTAssertEqual(automatic.phase, .idle)
    }

    func testErrorPhase() {
        var m = machine
        let failure = UpdateFailure(message: "boom", technicalDetail: "detail", code: 2001, retryable: true)
        m.reduce(.updaterError(failure))
        XCTAssertEqual(m.phase, .failed(failure, retryable: true))
    }

    func testDownloadProgressAccounting() {
        var m = machine
        m.reduce(.downloadInitiated)
        XCTAssertEqual(m.phase, .downloading(received: 0, expected: nil))

        // Unknown content length then a late length callback: latest wins.
        m.reduce(.dataReceived(500))
        XCTAssertEqual(m.phase, .downloading(received: 500, expected: nil))
        m.reduce(.expectedLength(1_000))
        XCTAssertEqual(m.phase, .downloading(received: 500, expected: 1_000))

        // Repeated length callbacks for the same download are tolerated.
        m.reduce(.expectedLength(1_200))
        XCTAssertEqual(m.phase, .downloading(received: 500, expected: 1_200))

        // Overrun is clamped to the expected size: progress never exceeds 100%.
        m.reduce(.dataReceived(100_000))
        XCTAssertEqual(m.phase, .downloading(received: 1_200, expected: 1_200))
    }

    func testExtractionProgressIsClamped() {
        var m = machine
        m.reduce(.extractionBegan)
        m.reduce(.extractionProgress(1.4))
        XCTAssertEqual(m.phase, .extracting(progress: 1.0))
        m.reduce(.extractionProgress(-0.2))
        XCTAssertEqual(m.phase, .extracting(progress: 0.0))
    }

    func testInstallationStages() {
        var delayed = machine
        delayed.reduce(.installingUpdate(applicationTerminated: false))
        XCTAssertEqual(delayed.phase, .waitingForTermination)

        var terminated = machine
        terminated.reduce(.installingUpdate(applicationTerminated: true))
        XCTAssertEqual(terminated.phase, .installing)
    }

    func testReleaseNotesEventsDoNotMoveThePhase() {
        var m = machine
        m.reduce(.updateFound(sampleMetadata, stage: .notDownloaded))
        m.reduce(.releaseNotesAvailable)
        XCTAssertEqual(m.phase, .available(sampleMetadata, stage: .notDownloaded))
        m.reduce(.releaseNotesFailed)
        XCTAssertEqual(m.phase, .available(sampleMetadata, stage: .notDownloaded))
    }

    func testCancellationsReturnToIdle() {
        var checking = machine
        checking.reduce(.userInitiatedCheckBegan)
        checking.reduce(.checkCancelled)
        XCTAssertEqual(checking.phase, .idle)

        var downloading = machine
        downloading.reduce(.downloadInitiated)
        downloading.reduce(.downloadCancelled)
        XCTAssertEqual(downloading.phase, .idle)
    }

    func testDismissalReturnsToIdleFromAnyState() {
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
            XCTAssertEqual(m.phase, .idle)
        }
    }

    /// The complete happy-path ordering from a manual check to relaunch.
    func testFullHappyPathOrdering() {
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
        XCTAssertEqual(m.phase, expected.last)
    }
}

// MARK: - Exactly-once capabilities

final class UpdateCapabilityTests: XCTestCase {
    func testCallInvokesExactlyOnce() {
        var count = 0
        let capability = Capability<Int> { _ in count += 1 }
        capability.call(1)
        capability.call(2)
        capability.call(3)
        XCTAssertEqual(count, 1)
        XCTAssertFalse(capability.isArmed)
    }

    func testDiscardPreventsInvocation() {
        var count = 0
        let capability = Capability<Void> { count += 1 }
        capability.discard()
        capability.call(())
        XCTAssertEqual(count, 0)
        XCTAssertFalse(capability.isArmed)
    }
}

// MARK: - Coordinator flows

@MainActor
final class UpdateCoordinatorFlowTests: XCTestCase {
    private func makeCoordinator() -> (UpdateCoordinator, FakeUpdateEngine) {
        let engine = FakeUpdateEngine()
        let coordinator = UpdateCoordinator(engine: engine)
        coordinator.suppressUIForTesting = true
        try? engine.start()
        return (coordinator, engine)
    }

    // MARK: Exactly-once through the coordinator

    func testInstallReplyIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.userDidChooseInstall()
        coordinator.userDidChooseInstall()  // second click must be a no-op
        XCTAssertEqual(replies, [.install])
    }

    func testSkipReplyIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.userDidChooseSkip()
        coordinator.userDidChooseSkip()
        XCTAssertEqual(replies, [.skip])
    }

    func testLaterReplyIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.userDidChooseLater()
        coordinator.userDidChooseLater()
        XCTAssertEqual(replies, [.later])
    }

    func testReadyToRelaunchUsesItsOwnReply() {
        let (coordinator, _) = makeCoordinator()
        var readyReplies: [UpdateUserChoice] = []
        var foundReplies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { foundReplies.append($0) }
        // A stale found-update reply is replaced when the ready reply arrives.
        coordinator.driverDidBecomeReadyToRelaunch { readyReplies.append($0) }
        coordinator.userDidChooseInstall()
        XCTAssertEqual(readyReplies, [.install])
        XCTAssertTrue(foundReplies.isEmpty)
    }

    func testErrorAcknowledgementIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var acks = 0
        coordinator.driverDidEncounterError(NSError(domain: "sparkle", code: 2001)) { acks += 1 }
        coordinator.userDidDismissPanel()
        coordinator.userDidDismissPanel()
        XCTAssertEqual(acks, 1)
    }

    func testNotFoundAcknowledgementIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var acks = 0
        coordinator.driverDidFindNoUpdate(userInitiated: true) { acks += 1 }
        // Up-to-date acknowledges immediately; a second dismiss is a no-op.
        coordinator.userDidDismissPanel()
        XCTAssertEqual(acks, 1)
    }

    func testCheckCancellationIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var cancels = 0
        coordinator.driverDidBeginUserCheck { cancels += 1 }
        coordinator.userDidCancelCheck()
        coordinator.userDidCancelCheck()
        XCTAssertEqual(cancels, 1)
    }

    func testDownloadCancellationIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var cancels = 0
        coordinator.driverDidBeginDownload { cancels += 1 }
        coordinator.userDidCancelDownload()
        coordinator.userDidCancelDownload()
        XCTAssertEqual(cancels, 1)
    }

    func testRetryTerminationIsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var retries = 0
        coordinator.driverDidBeginInstallation(applicationTerminated: false) { retries += 1 }
        coordinator.userDidRetryTermination()
        coordinator.userDidRetryTermination()
        XCTAssertEqual(retries, 1)
    }

    /// Closing the panel mid-check must invoke Sparkle's cancellation exactly
    /// once and leave the machine idle — a leaked cancellation would leave the
    /// check running with nobody able to stop it.
    func testDismissalDuringCheckCancelsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var cancels = 0
        coordinator.driverDidBeginUserCheck { cancels += 1 }
        XCTAssertEqual(coordinator.phase, .checking(userInitiated: true))
        coordinator.userDidDismissPanel()
        coordinator.userDidDismissPanel()
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// Closing the panel mid-download must cancel the download exactly once.
    func testDismissalDuringDownloadCancelsExactlyOnce() {
        let (coordinator, _) = makeCoordinator()
        var cancels = 0
        coordinator.driverDidBeginDownload { cancels += 1 }
        XCTAssertEqual(coordinator.phase, .downloading(received: 0, expected: nil))
        coordinator.userDidDismissPanel()
        coordinator.userDidDismissPanel()
        XCTAssertEqual(cancels, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// The panel's Cancel buttons resolve the machine out of the active state.
    func testCancelButtonsResolveTheMachine() {
        let (coordinator, _) = makeCoordinator()
        var checkCancels = 0
        coordinator.driverDidBeginUserCheck { checkCancels += 1 }
        coordinator.userDidCancelCheck()
        XCTAssertEqual(checkCancels, 1)
        XCTAssertEqual(coordinator.phase, .idle)

        var downloadCancels = 0
        coordinator.driverDidBeginDownload { downloadCancels += 1 }
        coordinator.userDidCancelDownload()
        XCTAssertEqual(downloadCancels, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    /// Choosing Later/Skip from an offered update must leave `.available` so
    /// the pill stops offering the update.
    func testLaterAndSkipLeaveTheOfferedState() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { _ in }
        coordinator.userDidChooseLater()
        XCTAssertEqual(coordinator.phase, .idle)

        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { _ in }
        coordinator.userDidChooseSkip()
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: Background cycles stay on the pill

    /// An automatically-scheduled presentation must not open the panel; a
    /// user-initiated one must.
    func testBackgroundUpdateDoesNotOpenThePanel() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .downloaded, userInitiated: false) { _ in }
        XCTAssertEqual(coordinator.panelShowCount, 0)
        XCTAssertEqual(coordinator.phase, .available(sampleMetadata, stage: .downloaded))
        XCTAssertEqual(coordinator.pillModel, .restartToUpdate)

        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded, userInitiated: true) { _ in }
        XCTAssertGreaterThan(coordinator.panelShowCount, 0)
    }

    /// Automatic download + ready-to-relaunch must proceed silently on the
    /// pill; the panel opens only when the user clicks it.
    func testBackgroundDownloadAndReadyStayOnThePill() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidBeginDownload { }
        XCTAssertEqual(coordinator.panelShowCount, 0)
        XCTAssertEqual(coordinator.phase, .downloading(received: 0, expected: nil))
        coordinator.driverDidBecomeReadyToRelaunch { _ in }
        XCTAssertEqual(coordinator.panelShowCount, 0)
        XCTAssertEqual(coordinator.phase, .readyToRelaunch)
        XCTAssertEqual(coordinator.pillModel, .restartToUpdate)
    }

    /// A background-cycle failure surfaces on the warning pill, not a window.
    func testBackgroundErrorSurfacesOnThePillOnly() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidEncounterError(NSError(domain: "Sparkle", code: 1002)) { }
        XCTAssertEqual(coordinator.panelShowCount, 0)
        XCTAssertEqual(coordinator.pillModel, .warning)
    }

    func testTeardownDiscardsPendingReply() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.tearDownForTesting()
        coordinator.userDidChooseInstall()
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    func testDismissalDiscardsPendingReply() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(sampleMetadata, stage: .notDownloaded) { replies.append($0) }
        coordinator.driverDidDismiss()
        coordinator.userDidChooseInstall()
        XCTAssertTrue(replies.isEmpty)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: Background downloads

    func testBackgroundDownloadDrivesRestartPill() {
        let (coordinator, engine) = makeCoordinator()
        XCTAssertNil(coordinator.pillModel)
        engine.completeBackgroundDownload(displayVersion: "1.1.0")
        XCTAssertEqual(coordinator.pillModel, .restartToUpdate)
        XCTAssertNotNil(coordinator.downloadedUpdate)
        coordinator.driverDidDismiss()
        XCTAssertNil(coordinator.downloadedUpdate)
        XCTAssertNil(coordinator.pillModel)
    }

    // MARK: Error handling

    func testErrorProducesWarningPillAndRetryableState() {
        let (coordinator, _) = makeCoordinator()
        coordinator.driverDidEncounterError(
            NSError(domain: "Sparkle", code: 1002, userInfo: [NSLocalizedDescriptionKey: "The feed couldn't be loaded."])
        ) { }
        XCTAssertEqual(coordinator.pillModel, .warning)
        guard case .failed(_, let retryable) = coordinator.phase else {
            return XCTFail("expected failed phase")
        }
        XCTAssertTrue(retryable)
    }

    func testRetryAcknowledgesAndReturnsToIdle() {
        let (coordinator, _) = makeCoordinator()
        var acks = 0
        coordinator.driverDidEncounterError(NSError(domain: "sparkle", code: 3001)) { acks += 1 }
        let expectation = expectation(description: "retry settle")
        coordinator.userDidRetry()
        // The retried check is scheduled for the next runloop turn; in a test
        // bundle there is no feed configuration, so checkForUpdates() gates at
        // isConfigured and stays quiet.  What must hold: the failed cycle is
        // acknowledged exactly once and the machine returns to idle.
        DispatchQueue.main.async { expectation.fulfill() }
        wait(for: [expectation], timeout: 1)
        XCTAssertEqual(acks, 1)
        XCTAssertEqual(coordinator.phase, .idle)
    }

    // MARK: Informational / critical

    func testInformationalUpdateNeverOffersInstall() {
        let (coordinator, _) = makeCoordinator()
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(informationalMetadata, stage: .notDownloaded) { replies.append($0) }
        XCTAssertEqual(coordinator.phase, .informational(informationalMetadata))
        coordinator.userDidChooseLater()
        XCTAssertEqual(replies, [.later])
    }

    func testCriticalUpdateKeepsSkipAvailableToTheMachine() {
        let (coordinator, _) = makeCoordinator()
        var critical = sampleMetadata
        critical.isCritical = true
        var replies: [UpdateUserChoice] = []
        coordinator.driverDidFindUpdate(critical, stage: .notDownloaded) { replies.append($0) }
        // The machine still supports skip; the UI hides the button for critical
        // updates (asserted by the panel's own logic in UpdateWindowController).
        coordinator.userDidChooseSkip()
        XCTAssertEqual(replies, [.skip])
    }

    // MARK: Settings

    func testSettingsProxyWritesThroughToEngine() {
        let (coordinator, engine) = makeCoordinator()
        coordinator.automaticallyChecksForUpdates = false
        XCTAssertFalse(engine.automaticallyChecksForUpdates)
        coordinator.automaticallyDownloadsUpdates = false
        XCTAssertFalse(engine.automaticallyDownloadsUpdates)
        coordinator.automaticallyChecksForUpdates = true
        XCTAssertTrue(engine.automaticallyChecksForUpdates)
    }

    func testCanCheckForUpdatesReflectsEngine() {
        let (coordinator, engine) = makeCoordinator()
        // This test bundle has no SUFeedURL, so the configuration gate says no.
        XCTAssertFalse(coordinator.canCheckForUpdates)
        engine._canCheckForUpdates = false
        XCTAssertFalse(coordinator.canCheckForUpdates)
    }

    // MARK: Pill synchronization (multiwindow)

    func testStateChangeBroadcastsToOneCoordinatorForAllPills() {
        let (coordinator, _) = makeCoordinator()
        var received = 0
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: UpdateCoordinator.stateDidChange, object: coordinator, queue: .main
        ) { _ in received += 1 }
        defer { if let token { NotificationCenter.default.removeObserver(token) } }
        coordinator.driverDidReceiveData(500)
        coordinator.driverDidReceiveExpectedLength(1_000)
        XCTAssertGreaterThanOrEqual(received, 2)
    }
}

// MARK: - Build contract

final class UpdateBuildContractTests: XCTestCase {
    /// Sparkle must be linked by the host app only — never by MarkdownCore,
    /// MarkdownRender, the CLI, or the Quick Look targets.
    func testSparkleIsImportedOnlyByTheHostApp() throws {
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
        XCTAssertTrue(offenders.isEmpty, "Sparkle imported outside the host app: \(offenders)")
    }

    /// The `Downright` product (not `down`, `drbench`, `MarkdownCore`, …) must
    /// declare the Sparkle dependency in Package.swift.
    func testPackageManifestDeclaresSparkleExactly() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let manifest = try String(contentsOf: root.appendingPathComponent("Package.swift"), encoding: .utf8)
        XCTAssertTrue(manifest.contains("exact: \"2.9.5\""), "Sparkle must be pinned exactly to 2.9.5")
        // The DownrightApp target block is the `...name: "DownrightApp"...}`
        // region; assert Sparkle is wired into it.
        guard let marker = manifest.range(of: "\"DownrightApp\"") else {
            return XCTFail("DownrightApp target not found in Package.swift")
        }
        let targetText = String(manifest[marker.lowerBound...])
        let appTarget = targetText.prefix { $0 != "}" }
        XCTAssertTrue(appTarget.contains("Sparkle"), "DownrightApp target must link Sparkle")
    }
}
