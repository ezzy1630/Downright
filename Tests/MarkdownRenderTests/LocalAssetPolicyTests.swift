import Foundation
import Testing
@testable import MarkdownRender

@Suite("Local image asset policy")
struct LocalAssetPolicyTests {
    @Test("Safe relative assets stay inside the document directory")
    func safeRelativeAsset() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("notes.md")
        let request = LocalAssetPolicy.request(
            raw: "images/diagram.png", documentURL: document
        )

        #expect(request?.isSafeRelative == true)
        #expect(request?.url.path == directory.appendingPathComponent("images/diagram.png").path)
        #expect(LocalAssetPolicy.allows(request!))
    }

    @Test("Traversal, absolute, and file URLs need injected trust")
    func unsafeDestinationsRequireTrust() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = directory.appendingPathComponent("notes.md")
        let outside = directory.deletingLastPathComponent().appendingPathComponent("secret.png")

        for raw in ["../secret.png", outside.path, outside.absoluteString] {
            guard let request = LocalAssetPolicy.request(raw: raw, documentURL: document) else {
                Issue.record("expected a local request for \(raw)")
                continue
            }
            #expect(!request.isSafeRelative)
            #expect(!LocalAssetPolicy.allows(request))
            #expect(LocalAssetPolicy.allows(request) { $0 == request.url })
        }
    }

    @Test("Symlinks escaping the document directory are blocked")
    func symlinkEscapeIsBlocked() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let outside = directory.deletingLastPathComponent().appendingPathComponent("outside.png")
        let link = directory.appendingPathComponent("linked.png")
        try Data("not an image".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let request = LocalAssetPolicy.request(
            raw: "linked.png", documentURL: directory.appendingPathComponent("notes.md")
        )

        #expect(request?.isSafeRelative == false)
        #expect(request.map { !LocalAssetPolicy.allows($0) } == true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-image-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
