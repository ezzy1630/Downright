import Testing
@testable import DownrightQL

@Suite("Quick Look prefix limits")
@MainActor
struct QuickLookPolicyTests {
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
