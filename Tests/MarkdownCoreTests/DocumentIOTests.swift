import Foundation
import Testing
@testable import MarkdownCore

// §3.1 is the app's central guarantee, so it is tested against real files on
// disk rather than against an in-memory shortcut: read → parse → write must
// return the identical bytes.

@Suite struct DocumentIOTests {

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("MarkdownCoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The complete pipeline: bytes → read → parse → write → bytes.
    private func assertRoundTrip(_ data: Data, _ label: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try data.write(to: url)

        let (text, fidelity) = try DocumentIO.read(contentsOf: url)
        let parsed = MarkdownParser.parse(text)
        #expect(parsed.text == text, "\(label): parse must not touch the text")

        let output = directory.appendingPathComponent("out.md")
        try DocumentIO.write(parsed.text, to: output, fidelity: fidelity)
        let written = try Data(contentsOf: output)
        #expect(written == data, "\(label): round trip changed \(data.count) bytes into \(written.count)")
    }

    @Test func roundTripsEveryCorpusDocument() throws {
        for entry in Corpus.all {
            try assertRoundTrip(Data(entry.text.utf8), entry.name)
        }
    }

    @Test func roundTripsCRLFAndCRFiles() throws {
        try assertRoundTrip(Data("# A\r\n\r\nB\r\n".utf8), "crlf")
        try assertRoundTrip(Data("# A\rB\r".utf8), "cr")
        // Mixed endings are left alone on purpose — there is no `.mixed` case,
        // so the parser must not normalise what it cannot faithfully restore.
        try assertRoundTrip(Data("a\nb\r\nc\rd\n".utf8), "mixed")
    }

    @Test func roundTripsWithoutTrailingNewline() throws {
        try assertRoundTrip(Data(Corpus.noTrailingNewline.utf8), "noTrailingNewline")
        try assertRoundTrip(Data("x".utf8), "single character")
    }

    @Test func roundTripsBOMAndUTF16() throws {
        let bom = Data([0xEF, 0xBB, 0xBF])
        try assertRoundTrip(bom + Data("# Title\n\nBody.\n".utf8), "utf8 BOM")

        var utf16 = Data([0xFF, 0xFE])
        utf16 += "# Title\n\nBody with ü.\n".data(using: .utf16LittleEndian)!
        try assertRoundTrip(utf16, "utf16 LE BOM")
    }

    @Test func roundTripsTabsAndTrailingSpaces() throws {
        try assertRoundTrip(Data("\t\tdeep\n  \n trailing   \n\n\n".utf8), "whitespace")
    }

    @Test func fidelityRecordsWhatItSaw() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        try Data("a\r\nb\r\n".utf8).write(to: url)

        let (text, fidelity) = try DocumentIO.read(contentsOf: url)
        #expect(text == "a\nb\n")
        #expect(fidelity.lineEnding == .crlf)
        #expect(fidelity.hasTrailingNewline)
        #expect(!fidelity.hasBOM)
        #expect(fidelity.encoding == .utf8)
    }

    @Test func mixedEndingsAreNotNormalised() throws {
        #expect(DocumentIO.dominantLineEnding("a\nb\r\n") == .lf)
        #expect(DocumentIO.dominantLineEnding("a\r\nb\r\n") == .crlf)
        #expect(DocumentIO.dominantLineEnding("a\rb\r") == .cr)
        #expect(DocumentIO.dominantLineEnding("no breaks") == .lf)
    }

    @Test func latin1FallsBackWhenUTF8Fails() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        // 0xE9 is `é` in Latin-1 and an invalid lone byte in UTF-8.
        let data = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])
        try data.write(to: url)

        let (text, fidelity) = try DocumentIO.read(contentsOf: url)
        #expect(fidelity.encoding == .latin1)
        #expect(text == "café\n")
        try assertRoundTrip(data, "latin1")
    }

    @Test func contentHashIsStableAndSensitive() {
        let a = DocumentIO.contentHash("hello")
        #expect(a == DocumentIO.contentHash("hello"))
        #expect(a != DocumentIO.contentHash("hello "))
        #expect(a.count == 64)
        #expect(a.allSatisfy { $0.isHexDigit })
        // Known SHA-256 of "hello", so a change of algorithm is caught rather
        // than merely a change of output.
        #expect(a == "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824")
    }

    @Test func readHeadReadsOnlyTheRequestedBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("big.md")
        // 4MB, far beyond the thumbnail's 64KB head — a whole-file read here
        // would be the exact memory spike the bounded read exists to prevent.
        let body = Data(repeating: 0x61 /* "a" */, count: 4 * 1024 * 1024)
        try body.write(to: url)

        let head = DocumentIO.readHead(contentsOf: url, limit: 64 * 1024)
        #expect(head != nil)
        #expect(head!.utf8.count <= 64 * 1024)
        #expect(head! == String(repeating: "a", count: 64 * 1024))
    }

    @Test func readHeadTrimsASplitMultibyteScalar() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("split.md")
        // "🌊" is four UTF-8 bytes; a limit that splits it mid-scalar must not
        // return an undecodable head.
        let text = String(repeating: "🌊", count: 20) + "tail"
        try Data(text.utf8).write(to: url)

        let head = DocumentIO.readHead(contentsOf: url, limit: 30)
        let expected = String(repeating: "🌊", count: 7)  // 28 bytes
        #expect(head == expected)
        #expect(head?.utf8.count == 28)
    }

    @Test func readHeadReturnsNilForMissingFile() {
        #expect(DocumentIO.readHead(
            contentsOf: URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).md"),
            limit: 1024
        ) == nil)
    }

    @Test func roundTripsUTF32BOM() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")

        var le = Data([0xFF, 0xFE, 0x00, 0x00])
        le += "# Title\n\nBody.\n".data(using: .utf32LittleEndian)!
        try le.write(to: url)
        let (textLE, fidelityLE) = try DocumentIO.read(contentsOf: url)
        #expect(textLE == "# Title\n\nBody.\n")
        #expect(fidelityLE.encoding == .utf32LE)
        #expect(fidelityLE.hasBOM)
        try assertRoundTrip(le, "utf32 LE BOM")

        var be = Data([0x00, 0x00, 0xFE, 0xFF])
        be += "# Title\n".data(using: .utf32BigEndian)!
        try be.write(to: url)
        let (textBE, _) = try DocumentIO.read(contentsOf: url)
        #expect(textBE == "# Title\n")
        try assertRoundTrip(be, "utf32 BE BOM")
    }

    @Test func readsTruncatedUTF16And32() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")

        // UTF-16 LE body with one torn trailing byte: must decode up to the
        // last whole code unit instead of throwing.
        let le = Data([0xFF, 0xFE]) + "# Abc\n".data(using: .utf16LittleEndian)! + Data([0x41])
        try le.write(to: url)
        let (text, _) = try DocumentIO.read(contentsOf: url)
        #expect(text == "# Abc\n")

        // UTF-32 LE body with three stray trailing bytes.
        var ut32 = Data([0xFF, 0xFE, 0x00, 0x00])
        ut32 += "Hi\n".data(using: .utf32LittleEndian)!
        ut32 += Data([0x01, 0x02])
        try ut32.write(to: url)
        let (text32, _) = try DocumentIO.read(contentsOf: url)
        #expect(text32 == "Hi\n")
    }

    @Test func readsBOMlessUTF16() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")

        let leBody = "one\ntwo\n".data(using: .utf16LittleEndian)!
        try leBody.write(to: url)
        let (textLE, fidelityLE) = try DocumentIO.read(contentsOf: url)
        #expect(textLE == "one\ntwo\n")
        #expect(fidelityLE.encoding == .utf16LE)
        #expect(!fidelityLE.hasBOM)
        try assertRoundTrip(leBody, "utf16 LE no BOM")

        let beBody = "one\n".data(using: .utf16BigEndian)!
        try beBody.write(to: url)
        let (textBE, fidelityBE) = try DocumentIO.read(contentsOf: url)
        #expect(textBE == "one\n")
        #expect(fidelityBE.encoding == .utf16BE)
        try assertRoundTrip(beBody, "utf16 BE no BOM")
    }

    @Test func guardedReplaceRestoresRacingGeneration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        let opened = Data("opened\n".utf8)
        let firstExternal = Data("external-one\n".utf8)
        let newestExternal = Data("external-two\n".utf8)
        try firstExternal.write(to: url)

        do {
            try DocumentIO.replaceExistingAtomicallyForTesting(
                with: Data("mine\n".utf8), at: url, expected: opened
            ) {
                try! newestExternal.write(to: url, options: .atomic)
            }
            Issue.record("a mismatched generation must fail closed")
        } catch let DocumentIOError.targetChanged(_, displaced) {
            #expect(displaced.contains(firstExternal))
            #expect(displaced.contains(newestExternal))
        }
        #expect(try Data(contentsOf: url) == newestExternal)
    }

    @Test func failedRollbackNeverDeletesDisplacedExternalBytes() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        let external = Data("external\n".utf8)
        try external.write(to: url)

        #expect(throws: (any Error).self) {
            try DocumentIO.replaceExistingAtomicallyForTesting(
                with: Data("mine\n".utf8), at: url,
                expected: Data("opened\n".utf8)
            ) {
                try! FileManager.default.removeItem(at: url)
            }
        }
        let recoveryFiles = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ).filter { $0.lastPathComponent.hasPrefix(".downright-save-") }
        #expect(recoveryFiles.count == 1)
        #expect(try Data(contentsOf: recoveryFiles[0]) == external)
    }

    @Test func displacedReadFailureLeavesRecoverableExternalGeneration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.md")
        let external = Data("external-before-read-failure\n".utf8)
        let mine = Data("mine\n".utf8)
        try external.write(to: url)

        do {
            try DocumentIO.replaceExistingAtomicallyForTesting(
                with: mine, at: url, expected: external,
                afterDisplacedRead: {},
                afterSwap: { temporary in
                    try! FileManager.default.setAttributes(
                        [.posixPermissions: NSNumber(value: 0o000)],
                        ofItemAtPath: temporary.path
                    )
                }
            )
            Issue.record("a displaced-generation read failure must fail closed")
        } catch let DocumentIOError.displacedGenerationUnreadable(_, recoveryURL, _) {
            #expect(FileManager.default.fileExists(atPath: recoveryURL.path))
            try FileManager.default.setAttributes(
                [.posixPermissions: NSNumber(value: 0o600)],
                ofItemAtPath: recoveryURL.path
            )
            #expect(try Data(contentsOf: recoveryURL) == external)
        }

        // The public path contains Downright's candidate, while the external
        // generation remains available at the recovery URL from the error.
        #expect(try Data(contentsOf: url) == mine)
    }
}
