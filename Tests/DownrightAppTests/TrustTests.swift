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
