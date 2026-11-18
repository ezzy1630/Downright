import MarkdownCore
import Testing
@testable import DownrightThumb

@Suite("Finder thumbnail content")
struct ThumbnailProviderTests {
    @Test("Thumbnail uses readable prose after an image-only badge")
    func thumbnailSkipsBadgesAndMarkdownMarkers() {
        let document = MarkdownParser.parse("""
        ---
        title: Example project
        ---

        [![Build status](status.svg)](https://example.test/build)

        **Install** the [sample project](docs/install.md) with `down`.
        Continue with the instructions below.
        """, options: .structureOnly)
        #expect(ThumbnailProvider.firstProseLine(in: document) == "Install the sample project with down. Continue with the instructions below.")
    }
}
