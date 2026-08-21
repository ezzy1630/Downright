import Testing
import Foundation
import MarkdownRender
@testable import DownrightQL

@Suite("Quick Look prefix limits")
@MainActor
struct QuickLookPolicyTests {
    @Test("Quick Look appearance defaults to native System and supports an override")
    func previewAppearanceContract() {
        #expect(PreviewAppearance.system.title == "System")
        #expect(PreviewAppearance.system.nsAppearance == nil)
        #expect(PreviewAppearance.light.nsAppearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua)
        #expect(PreviewAppearance.dark.nsAppearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(PreviewAppearance.allCases == [.system, .light, .dark])
    }

    @Test("Quick Look memory budget excludes its host-process baseline")
    func memoryBudgetIsIncremental() {
        #expect(QuickLookPolicy.memoryCeilingBytes == 60 * 1024 * 1024)
        #expect(PreviewViewController.previewMemoryBytes(
            current: 94 * 1024 * 1024,
            baseline: 88 * 1024 * 1024
        ) == 6 * 1024 * 1024)
        #expect(PreviewViewController.previewMemoryBytes(current: 80, baseline: 88) == 0)
    }

    @Test("A single oversized block cannot exceed the render cap")
    func oversizedBlockIsBounded() {
        let text = String(repeating: "x", count: 8 * 1024 * 1024)
        let prefix = PreviewViewController.boundedPrefix(
            text,
            utf16Limit: QuickLookPolicy.prefixRenderLimitUTF16,
            byteLimit: QuickLookPolicy.prefixRenderLimitBytes
        )

        #expect(prefix.utf16.count <= QuickLookPolicy.prefixRenderLimitUTF16)
        #expect(prefix.utf8.count <= QuickLookPolicy.prefixRenderLimitBytes)
        #expect(prefix.count < text.count)
    }

    @Test("Prefix limits never split a multibyte character")
    func multibyteCharacterRemainsWhole() {
        let text = String(repeating: "🌊", count: 2_000)
        let prefix = PreviewViewController.boundedPrefix(
            text,
            utf16Limit: 101,
            byteLimit: 101
        )

        #expect(prefix.utf16.count <= 101)
        #expect(prefix.utf8.count <= 101)
        #expect(prefix.utf16.count.isMultiple(of: 2))
        #expect(prefix.utf8.count.isMultiple(of: 4))
    }

    @Test("A small-file stat cannot turn a growth race into an unbounded read")
    func growthAfterInitialStatUsesPrefixPath() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("race.md")
        try Data("small\n".utf8).write(to: url)
        let large = Data(repeating: 0x61, count: QuickLookPolicy.fullReadLimitBytes + 1_024)

        let result = QuickLookLoader.load(
            contentsOf: url,
            hintedByteCount: 6,
            beforeRead: { try? large.write(to: url, options: .atomic) }
        )

        guard case .prefix(let text) = result else {
            Issue.record("A file that grows after stat must take the bounded prefix path")
            return
        }
        #expect(text.utf8.count <= QuickLookPolicy.fullReadLimitBytes)
    }

    @Test("Bounded loader preserves BOM encoded previews")
    func boundedLoaderPreservesUTF16AndUTF32() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("encoded.md")

        var utf16 = Data([0xFF, 0xFE])
        utf16 += "# UTF-16\n".data(using: .utf16LittleEndian)!
        try utf16.write(to: url)
        #expect(QuickLookLoader.load(contentsOf: url, hintedByteCount: utf16.count) == .full("# UTF-16\n"))

        var utf32 = Data([0x00, 0x00, 0xFE, 0xFF])
        utf32 += "# UTF-32\n".data(using: .utf32BigEndian)!
        try utf32.write(to: url)
        #expect(QuickLookLoader.load(contentsOf: url, hintedByteCount: utf32.count) == .full("# UTF-32\n"))
    }

    @Test("Bounded loader normalizes a pure CRLF document")
    func boundedLoaderNormalizesCRLF() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("crlf.md")
        let data = Data("# Heading\r\n\r\nBody\r\n".utf8)
        try data.write(to: url)

        #expect(
            QuickLookLoader.load(contentsOf: url, hintedByteCount: data.count)
                == .full("# Heading\n\nBody\n")
        )
    }

    @Test("Large-file loader reads a fixed prefix even when the file is replaced")
    func replacementDuringLargePreviewRemainsBounded() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large.md")
        try Data("old\n".utf8).write(to: url)
        let replacement = Data(repeating: 0x61, count: QuickLookPolicy.prefixReadLimitBytes + 5_000)

        let result = QuickLookLoader.load(
            contentsOf: url,
            hintedByteCount: QuickLookPolicy.largeFileThresholdBytes + 1,
            beforeRead: { try? replacement.write(to: url, options: .atomic) }
        )

        guard case .prefix(let text) = result else {
            Issue.record("Large-file previews must remain prefix loads")
            return
        }
        #expect(text.utf8.count <= QuickLookPolicy.prefixReadLimitBytes)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-ql-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
