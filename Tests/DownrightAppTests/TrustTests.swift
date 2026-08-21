import AppKit
import Foundation
import Testing
@testable import DownrightApp

@Suite(.serialized)
struct DocumentTrustTests {
    @Test
    func standardAsksAndRawSourceDeniesEveryEffect() {
        let request = TrustRequest(
            effect: .openExternalLink,
            target: TrustTarget(displayName: "https://example.com", externalURL: "https://example.com"),
            documentURL: URL(fileURLWithPath: "/tmp/notes.md")
        )
        #expect(DocumentTrust().decision(for: request) == .ask)
        #expect(DocumentTrust(state: .rawSource).decision(for: request) == .deny)
    }

    @Test
    func folderAndFileGrantsMatchCanonicalPathsOnly() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-trust-\(UUID().uuidString)", isDirectory: true)
        let folder = root.appendingPathComponent("workspace", isDirectory: true)
        let child = folder.appendingPathComponent("assets/image.png")
        let sibling = root.appendingPathComponent("workspace-other/image.png")
        try FileManager.default.createDirectory(at: child.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("image".utf8).write(to: child)
        defer { try? FileManager.default.removeItem(at: root) }

        let persistence = InMemoryTrustStorePersistence()
        let store = TrustStore(persistence: persistence)
        #expect(store.grant(scope: .folder, path: folder, effects: [.readLocalAsset]))
        #expect(store.state(for: root.appendingPathComponent("notes.md")) == .standard)
        #expect(store.state(for: folder.appendingPathComponent("notes.md")) == .trustedFolder)
        let allowed = TrustRequest(
            effect: .readLocalAsset,
            target: TrustTarget(displayName: child.path, canonicalPath: child.path),
            documentURL: root.appendingPathComponent("notes.md")
        )
        let blocked = TrustRequest(
            effect: .readLocalAsset,
            target: TrustTarget(displayName: sibling.path, canonicalPath: sibling.path),
            documentURL: root.appendingPathComponent("notes.md")
        )
        #expect(store.policy().decision(for: allowed) == .allow)
        #expect(store.policy().decision(for: blocked) == .ask)

        #expect(store.grant(scope: .file, path: child, effects: [.launchPathOrEditor]))
        let fileRequest = TrustRequest(
            effect: .launchPathOrEditor,
            target: TrustTarget(displayName: child.path, canonicalPath: child.path),
            documentURL: nil
        )
        #expect(store.policy().decision(for: fileRequest) == .allow)
        store.revoke(scope: .file, path: child)
        #expect(store.policy().decision(for: fileRequest) == .ask)
    }

    @Test
    func webLinkPermissionDoesNotAuthorizeRemoteImageLoading() {
        let document = URL(fileURLWithPath: "/workspace/README.md")
        let grant = TrustGrant(
            scope: .file,
            canonicalPath: document.path,
            effects: [.openExternalLink]
        )
        let remoteImage = TrustRequest(
            effect: .loadRemoteAsset,
            target: TrustTarget(
                displayName: "https://tracker.example/pixel.png",
                externalURL: "https://tracker.example/pixel.png"
            ),
            documentURL: document
        )

        #expect(DocumentTrust(grants: [grant]).decision(for: remoteImage) == .ask)
    }

    /// One folder-scope approval of an external effect must answer only for
    /// the exact URL that was approved — never for every future URL of that
    /// effect under the folder, or a single "always allow" on a vscode:// link
    /// would silently authorize a later shortcuts:// automation.
    @Test
    func folderGrantForAnExternalURLAuthorizesOnlyThatURL() {
        let document = URL(fileURLWithPath: "/workspace/README.md")
        let approved = "vscode://file/tmp/note.md"
        let otherScheme = "shortcuts://run-shortcut?name=Deploy"

        let persistence = InMemoryTrustStorePersistence()
        let store = TrustStore(persistence: persistence)
        #expect(store.grant(
            scope: .folder,
            path: URL(fileURLWithPath: "/workspace"),
            effects: [.automationAppIntent],
            externalURL: approved
        ))

        let sameURL = TrustRequest(
            effect: .automationAppIntent,
            target: TrustTarget(displayName: approved, externalURL: approved),
            documentURL: document
        )
        let differentURL = TrustRequest(
            effect: .automationAppIntent,
            target: TrustTarget(displayName: otherScheme, externalURL: otherScheme),
            documentURL: document
        )
        #expect(store.policy().decision(for: sameURL) == .allow)
        #expect(store.policy().decision(for: differentURL) == .ask)
    }

    /// Grants persisted before external grants carried their URL must not
    /// start answering for arbitrary URLs after an upgrade: they fail closed
    /// for external effects (the next prompt re-records them with their URL)
    /// while continuing to authorize the local effects they were created for.
    @Test
    func legacyExternalGrantFailsClosedForExternalEffectsButKeepsLocalOnes() throws {
        let document = try #require(DocumentTrust.canonicalFilePath(
            URL(fileURLWithPath: "/tmp/downright-trust-legacy/notes.md")
        ))
        let legacy = TrustGrant(
            scope: .folder,
            canonicalPath: document.deletingLastPathComponent().path,
            effects: [.openExternalLink]
        )
        let external = TrustRequest(
            effect: .openExternalLink,
            target: TrustTarget(
                displayName: "https://example.com",
                externalURL: "https://example.com"
            ),
            documentURL: document
        )
        let local = TrustRequest(
            effect: .launchPathOrEditor,
            target: TrustTarget(
                displayName: "/tmp/downright-trust-legacy/notes.md",
                canonicalPath: document.path
            ),
            documentURL: document
        )
        #expect(DocumentTrust(grants: [legacy]).decision(for: external) == .ask)

        let persistence = InMemoryTrustStorePersistence([legacy])
        let store = TrustStore(persistence: persistence)
        #expect(store.grant(
            scope: .file,
            path: document,
            effects: [.launchPathOrEditor]
        ))
        #expect(store.policy().decision(for: local) == .allow)
    }

    @Test
    func persistedGrantsWithoutTheURLEntryStillDecode() throws {
        let json = """
        [
          {
            "scope" : "file",
            "canonicalPath" : "/tmp/downright-trust-decode/notes.md",
            "effects" : ["readLocalAsset"]
          }
        ]
        """
        let grants = try JSONDecoder().decode([TrustGrant].self, from: Data(json.utf8))
        #expect(grants.count == 1)
        #expect(grants.first?.externalURL == nil)
        #expect(grants.first?.effects == [.readLocalAsset])
    }

    @Test
    func symlinkResolvesToRealPathAndTraversalStaysOutside() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-trust-symlink-\(UUID().uuidString)", isDirectory: true)
        let real = root.appendingPathComponent("real", isDirectory: true)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(DocumentTrust.canonicalFilePath(link)?.path == real.path)
        let escaped = root.appendingPathComponent("real/../outside", isDirectory: true)
        #expect(!DocumentTrust.isWithin(escaped, real))
    }

    @Test
    func concurrentMutationsPersistInMemoryOrder() {
        let persistence = DelayedFirstSaveTrustPersistence()
        let store = TrustStore(persistence: persistence)
        let group = DispatchGroup()
        let first = URL(fileURLWithPath: "/tmp/downright-trust-first")
        let second = URL(fileURLWithPath: "/tmp/downright-trust-second")

        group.enter()
        DispatchQueue.global().async {
            _ = store.grant(scope: .file, path: first, effects: [.readLocalAsset])
            group.leave()
        }
        #expect(persistence.firstSaveStarted.wait(timeout: .now() + 1) == .success)
        group.enter()
        DispatchQueue.global().async {
            _ = store.grant(scope: .file, path: second, effects: [.launchPathOrEditor])
            group.leave()
        }
        #expect(group.wait(timeout: .now() + 2) == .success)

        #expect(Set(persistence.persisted()) == Set(store.grants()))
    }

    @Test
    func failedPersistenceNeverClaimsAGrantAndRevocationStaysFailClosed() throws {
        let path = URL(fileURLWithPath: "/tmp/downright-trust-failure")
        let existing = TrustGrant(
            scope: .file,
            canonicalPath: try #require(DocumentTrust.canonicalFilePath(path)).path,
            effects: [.readLocalAsset]
        )
        let persistence = FailingSaveTrustPersistence([existing])
        let store = TrustStore(persistence: persistence)

        #expect(!store.grant(scope: .file, path: path, effects: [.launchPathOrEditor]))
        #expect(store.grants() == [existing])
        #expect(!store.revoke(scope: .file, path: path))
        #expect(store.grants().isEmpty)
    }

    @Test
    func corruptPersistenceCannotBeOverwrittenByANewGrant() {
        let store = TrustStore(persistence: FailingLoadTrustPersistence())
        #expect(!store.grant(
            scope: .folder,
            path: URL(fileURLWithPath: "/tmp/downright-corrupt-trust"),
            effects: [.readLocalAsset]
        ))
        #expect(store.grants().isEmpty)
    }

    /// "Allow for Folder" on a directory must grant that directory, not its
    /// parent — granting the parent authorizes every sibling the user never
    /// consented to.
    @Test
    func folderScopeGrantsADirectoryItselfButAParentForAFile() {
        let directory = URL(fileURLWithPath: "/workspace/assets")
        let file = directory.appendingPathComponent("logo.png")
        // `deletingLastPathComponent` keeps a trailing slash, so compare the
        // path — both spellings name the same directory.
        #expect(DocumentTrust.folderScope(for: file, isDirectory: false).path == directory.path)
        #expect(DocumentTrust.folderScope(for: directory, isDirectory: true).path == directory.path)
    }

    /// A second grant for the same path extends the earlier one; it must not
    /// wipe the first effect, which is how folder-read and editor-launch kept
    /// ping-ponging (granting one silently blocked the other).
    @Test
    func grantingASecondEffectExtendsTheExistingGrant() {
        let store = TrustStore(persistence: InMemoryTrustStorePersistence())
        let path = URL(fileURLWithPath: "/tmp/downright-trust-effects")
        #expect(store.grant(scope: .file, path: path, effects: [.readLocalAsset]))
        #expect(store.grant(scope: .file, path: path, effects: [.launchPathOrEditor]))
        let grants = store.grants()
        #expect(grants.count == 1)
        #expect(grants.first?.effects == Set([.readLocalAsset, .launchPathOrEditor]))
    }
}

private enum TrustPersistenceFailure: Error { case unavailable }

private final class FailingSaveTrustPersistence: TrustStorePersistence {
    let initial: [TrustGrant]
    init(_ initial: [TrustGrant]) { self.initial = initial }
    func load() throws -> [TrustGrant] { initial }
    func save(_ grants: [TrustGrant]) throws { throw TrustPersistenceFailure.unavailable }
}

private final class FailingLoadTrustPersistence: TrustStorePersistence {
    func load() throws -> [TrustGrant] { throw TrustPersistenceFailure.unavailable }
    func save(_ grants: [TrustGrant]) throws { Issue.record("save must not follow a failed load") }
}

/// Delays the first save long enough for a second caller to expose reversed
/// persistence. Without TrustStore's ordered mutation/save boundary, the
/// older snapshot lands last and silently drops the second grant.
private final class DelayedFirstSaveTrustPersistence: TrustStorePersistence, @unchecked Sendable {
    let firstSaveStarted = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var saveCount = 0
    private var stored: [TrustGrant] = []

    func load() throws -> [TrustGrant] { [] }

    func save(_ grants: [TrustGrant]) throws {
        let call = lock.withLock {
            saveCount += 1
            return saveCount
        }
        if call == 1 {
            firstSaveStarted.signal()
            Thread.sleep(forTimeInterval: 0.2)
        }
        lock.withLock { stored = grants }
    }

    func persisted() -> [TrustGrant] {
        lock.withLock { stored }
    }
}

@MainActor
@Suite(.serialized)
struct TrustPromptViewTests {
    @Test
    func promptReportsExactTypedDecisionAndVoiceOverLabels() {
        let view = TrustPromptView()
        let request = TrustRequest(
            effect: .launchPathOrEditor,
            target: TrustTarget(displayName: "/workspace/scripts/build.sh", canonicalPath: "/workspace/scripts/build.sh"),
            documentURL: URL(fileURLWithPath: "/workspace/README.md")
        )
        let delegate = RecordingTrustDelegate()
        view.delegate = delegate
        view.request = request
        view.chooseForTesting(.deny)

        #expect(delegate.decision == .deny)
        #expect(delegate.request == request)
        #expect(view.accessibilityLabel() == "Permission Needed")
    }

    @Test
    func promptNamesTheFileItsGrantWillPersist() {
        let local = TrustRequest(
            effect: .launchPathOrEditor,
            target: TrustTarget(
                displayName: "/workspace/scripts/build.sh",
                canonicalPath: "/workspace/scripts/build.sh"
            ),
            documentURL: URL(fileURLWithPath: "/workspace/README.md")
        )
        let web = TrustRequest(
            effect: .openExternalLink,
            target: TrustTarget(displayName: "https://example.com", externalURL: "https://example.com"),
            documentURL: URL(fileURLWithPath: "/workspace/README.md")
        )

        #expect(TrustPromptView.fileGrantName(for: local) == "build.sh")
        #expect(TrustPromptView.fileGrantName(for: web) == "README.md")
    }

    @Test
    func linkClassificationSeparatesWebFilesAndAutomationSchemes() {
        #expect(MarkdownLinkDestination.classify("#intro") == .anchor("intro"))
        #expect(MarkdownLinkDestination.classify("notes/plan.md") == .relative("notes/plan.md"))
        #expect(MarkdownLinkDestination.classify("https://example.com")
            == .web(URL(string: "https://example.com")!))
        #expect(MarkdownLinkDestination.classify("mailto:review@example.com")
            == .web(URL(string: "mailto:review@example.com")!))
        #expect(MarkdownLinkDestination.classify("file:///private/etc/hosts")
            == .localFile(URL(string: "file:///private/etc/hosts")!))
        #expect(MarkdownLinkDestination.classify("vscode://file/tmp/note.md")
            == .automation(URL(string: "vscode://file/tmp/note.md")!))
    }
}

@MainActor
private final class RecordingTrustDelegate: TrustPromptViewDelegate {
    var decision: TrustPromptDecision?
    var request: TrustRequest?

    func trustPrompt(_ view: TrustPromptView, didChoose decision: TrustPromptDecision, request: TrustRequest) {
        self.decision = decision
        self.request = request
    }
}
