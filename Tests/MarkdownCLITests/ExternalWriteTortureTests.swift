import Foundation
import Testing

/// Exercises the write shapes used by editors and coding agents without
/// depending on a running app or a particular file-watcher implementation.
/// The app-level watcher tests consume the same guarantees: complete bytes,
/// atomic replacement, and the newest write winning after a burst.
struct ExternalWriteTortureTests {
    @Test func atomicRenameNeverExposesAStagingFileAsTheDocument() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("plan.md")
        let staging = root.appendingPathComponent(".plan.md.tmp")
        let expected = "# Agent plan\n\n- [ ] Review the changed section\n"

        try Data(expected.utf8).write(to: staging)
        try FileManager.default.moveItem(at: staging, to: document)

        #expect(FileManager.default.fileExists(atPath: document.path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(try String(contentsOf: document, encoding: .utf8) == expected)
    }

    @Test func rapidAtomicRewritesLeaveTheLastCompleteDocument() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("notes.md")

        for revision in 0..<40 {
            let staging = root.appendingPathComponent(".notes-\(revision).tmp")
            let content = "# Revision \(revision)\n\nagent-write-\(revision) ✅\n"
            try Data(content.utf8).write(to: staging)
            if FileManager.default.fileExists(atPath: document.path) {
                try FileManager.default.removeItem(at: document)
            }
            try FileManager.default.moveItem(at: staging, to: document)
        }

        #expect(try String(contentsOf: document, encoding: .utf8) == "# Revision 39\n\nagent-write-39 ✅\n")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".tmp") }
        #expect(leftovers.isEmpty)
    }

    @Test func rewritePreservesUtf8AndIntentionalLineEndings() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let document = root.appendingPathComponent("mixed.md")
        let expected = "# Café\r\n\r\n- [x] shipped\n- [ ] next — 日本語\r\n"

        try Data(expected.utf8).write(to: document, options: .atomic)
        #expect(try Data(contentsOf: document) == Data(expected.utf8))
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("down-external-write-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
