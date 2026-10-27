import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@Suite("Source-preserving inline images", .serialized)
@MainActor
struct InlineImageDisplayTests {
    final class Images: RemoteImageLoading {
        let image = NSImage(size: CGSize(width: 200, height: 40), flipped: false) { _ in true }
        var requests = 0
        func cachedImage(for url: URL, maxPixelDimension: Int) -> NSImage? { image }
        func hasFailed(_ url: URL) -> Bool { false }
        func loadImage(for url: URL, maxPixelDimension: Int, completion: @escaping @MainActor (NSImage?) -> Void) { requests += 1 }
    }

    @Test func linkedBadgeUsesAuthorDimensionsAndKeepsItsLink() throws {
        let source = #"<p><a href="https://example.com"><img src="https://img.example/badge.svg" width="100" height="20" alt="Build passing"></a></p>"#
        let document = MarkdownParser.parse(source)
        let items = InlineImageDisplay.items(in: document, includesRemoteHTML: true, joinsHTMLParagraphs: true)
        let item = try #require(items.first)
        #expect(item.link == "https://example.com")
        #expect(item.width == 100 && item.height == 20)
        let context = InlineImageContext()
        context.remoteImageLoader = Images()
        let replacement = try #require(InlineImageDisplay.substitutions(for: items, context: context, styleSheet: StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua)!)).first?.replacement)
        let attachment = try #require(replacement.attribute(.attachment, at: 0, effectiveRange: nil) as? NSTextAttachment)
        #expect(attachment.bounds.size == CGSize(width: 100, height: 20))
        #expect(replacement.attribute(.drLink, at: 0, effectiveRange: nil) as? String == item.link)
        #expect(document.text == source)
    }

    @Test func dimensionsDoNotComeFromAltTextOrCSS() {
        let tag = #"<img alt='width="9999" height="9999"' width="90px" height=18>"#
        #expect(InlineImageDisplay.dimension("width", in: tag) == 90)
        #expect(InlineImageDisplay.dimension("height", in: tag) == 18)
        #expect(InlineImageDisplay.dimension("width", in: #"<img width="50%">"#) == nil)
    }

    @Test func remoteImagesRequireAHostLoader() {
        let document = MarkdownParser.parse(#"<p><img src="https://img.example/a.svg" width="100"></p>"#)
        #expect(InlineImageDisplay.items(in: document, includesRemoteHTML: false, joinsHTMLParagraphs: true).isEmpty)
        #expect(InlineImageDisplay.items(in: document, includesRemoteHTML: true, joinsHTMLParagraphs: true).count == 1)
    }

    @Test func imageLayoutPreservesUTF16OffsetsAndExactSource() throws {
        let source = "Before 🐈 [![Build](https://img.example/badge.png)](https://example.com) after."
        let document = MarkdownParser.parse(source)
        let storage = NSTextStorage(string: source)
        let sheet = StyleSheet(theme: .fallback, appearance: NSAppearance(named: .aqua)!)
        let engine = DecorationEngine(styleSheet: sheet)
        engine.policy = RenderMode.read.policy
        engine.decorate(storage, document: document, dirty: .wholesale)
        let index = ParagraphIndex(text: source as NSString)
        let context = InlineImageContext()
        context.remoteImageLoader = Images()
        let maps = PresentationMaps.base(document: document, engine: engine, styleSheet: sheet, policy: engine.policy,
            excluding: nil, reflowHardWrappedParagraphs: true, text: source as NSString,
            paragraphIndex: index, inlineImages: context, joinsHTMLParagraphs: true)
        let layout = LayoutMapBuilder().layoutDisplayMap(from: maps.logical, paragraphs: index, storage: storage)
        let suffix = (source as NSString).range(of: "after")
        #expect(layout.textKitOffset(forSource: suffix.location) == suffix.location)
        #expect(layout.sourceOffset(forTextKit: suffix.location) == suffix.location)
        #expect(storage.string == source)
        let visible = try #require(layout.displayString(forSourceRange: NSRange(location: 0, length: storage.length), in: storage))
        #expect(visible.string.contains("\u{fffc}"))
        #expect(visible.string.hasSuffix(" after."))
    }

    @Test func quickLookIgnoresMalformedMeasuresAndRetainsFullWidth() {
        #expect(PreviewAppearanceStore.decodedMeasure(nil) == nil)
        #expect(PreviewAppearanceStore.decodedMeasure("1000") == nil)
        #expect(PreviewAppearanceStore.decodedMeasure(NSNumber(value: true)) == nil)
        #expect(PreviewAppearanceStore.decodedMeasure(NSNumber(value: Double.infinity)) == nil)
        #expect(PreviewAppearanceStore.decodedMeasure(NSNumber(value: 90)) == 90)
        #expect(PreviewAppearanceStore.decodedMeasure(NSNumber(value: 1000)) == TypographyConfig.fullWidthMeasure)
    }

    @Test func finiteAndFullWidthMeasuresRemainDistinct() throws {
        #expect(TypographyConfig.clampedMeasureCharacters(120) == 120)
        #expect(TypographyConfig.clampedMeasureCharacters(400) == 120)
        #expect(TypographyConfig.clampedMeasureCharacters(.infinity) == 70)
        #expect(TypographyConfig.clampedMeasureCharacters(.nan) == 70)
        #expect(TypographyConfig.clampedMeasureCharacters(TypographyConfig.fullWidthMeasure) == TypographyConfig.fullWidthMeasure)
        var typography = TypographyConfig.default
        typography.measureCharacters = TypographyConfig.fullWidthMeasure
        let restored = try JSONDecoder().decode(TypographyConfig.self, from: JSONEncoder().encode(typography))
        #expect(restored.measureCharacters == TypographyConfig.fullWidthMeasure)
        #expect(TypographyConfig.measureTitle(restored.measureCharacters) == "Full width")
    }
}
