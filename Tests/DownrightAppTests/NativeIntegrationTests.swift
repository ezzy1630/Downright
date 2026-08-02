import Foundation
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct NativeIntegrationTests {
    @Test
    func policyAcceptsOnlyMarkdownFiles() {
        #expect(NativeIntegrationPolicy.accepts(URL(fileURLWithPath: "/tmp/readme.md")))
        #expect(NativeIntegrationPolicy.accepts(URL(fileURLWithPath: "/tmp/NOTE.MDX")))
        #expect(!NativeIntegrationPolicy.accepts(URL(fileURLWithPath: "/tmp/readme.txt")))
        #expect(!NativeIntegrationPolicy.accepts(URL(string: "https://example.com/readme.md")!))
    }

    @Test
    func registryNormalizesAndRoutesExistingFile() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-integration-\(UUID().uuidString).md")
        try Data("# Title\n".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        var routed: URL?
        let registry = IntegrationRegistry { routed = $0 }
        #expect(registry.open(url.standardizedFileURL))
        #expect(routed == url.standardizedFileURL)
        #expect(!registry.open(url.deletingPathExtension().appendingPathExtension("txt")))
    }

    @Test
    func spotlightMetadataUsesFrontMatterAndHeading() {
        let url = URL(fileURLWithPath: "/tmp/guide.md")
        let text = "---\ntags: [agents, markdown]\n---\n\n# Guide\n\nBody.\n"
        let metadata = SpotlightMetadataImporter.metadata(forText: text, url: url)
        #expect(metadata.title == "Guide")
        #expect(metadata.keywords == ["agents", "markdown"])
        #expect(metadata.attributes[SpotlightMetadataKey.kind] as? String == "Markdown document")
    }
}
