import Testing
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
}
