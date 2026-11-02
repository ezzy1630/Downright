import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@MainActor
@Suite(.serialized)
struct CodeSelectionTests {
    @Test func codeBackgroundDoesNotCoverNativeSelection() throws {
        let source = "```swift\nlet greeting = \"Hello\"\n```\n"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        let selected = (source as NSString).range(of: "let greeting")
        view.setSourceSelectedRanges([selected])
        view.prepareForDisplay()
        let manager = try #require(view.textLayoutManager)
        let content = try #require(manager.textContentManager)
        let offset = view.currentDisplayMap.textKitOffset(forSource: selected.location)
        let location = try #require(content.location(content.documentRange.location, offsetBy: offset))
        manager.ensureLayout(for: NSTextRange(location: location))
        let fragment = try #require(manager.textLayoutFragment(for: location) as? CodeBlockFragment)
        let size = CGSize(width: 800, height: 100)
        let image = NSImage(size: size, flipped: true) { _ in
            // AppKit paints selection beneath the fragment's rendering surface.
            view.styleSheet.selection.setFill()
            NSRect(origin: .zero, size: size).fill()
            fragment.draw(at: CGPoint(x: 30, y: 10), in: NSGraphicsContext.current!.cgContext)
            return true
        }
        let bitmap = try #require(NSBitmapImageRep(data: image.tiffRepresentation!))
        let expected = try #require(bitmap.colorAt(x: 700, y: 20))
        var visibleSelectionPixels = 0
        // Sample the selected code's line, away from the rule and outer band.
        for y in 12..<30 {
            for x in 32..<105 {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                let distance = abs(color.redComponent - expected.redComponent)
                    + abs(color.greenComponent - expected.greenComponent)
                    + abs(color.blueComponent - expected.blueComponent)
                if distance < 0.03 { visibleSelectionPixels += 1 }
            }
        }
        #expect(visibleSelectionPixels > 100)
        #expect(storage.string == source)
        #expect(view.sourceSelectedRange == selected)
    }

    @Test func selectedTextHasAnExplicitContrastingForeground() throws {
        let suite = "downright.tests.selection.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        for theme in ThemeStore(defaults: defaults).themes {
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                let sheet = StyleSheet(theme: theme, appearance: try #require(NSAppearance(named: appearance)))
                let view = MarkdownTextView(frame: .zero, storage: NSTextStorage(string: "```\ncode\n```\n"), styleSheet: sheet)
                let foreground = try #require(view.selectedTextAttributes[.foregroundColor] as? NSColor)
                #expect(StyleSheet.contrastRatio(foreground, sheet.selection) >= 4.5, "\(theme.name), \(appearance)")
            }
        }
    }
}
