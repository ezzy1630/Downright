import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

/// Clicking must never move the document under the pointer.
///
/// A click in Live mode does two things behind AppKit's back: it re-hides the
/// markers in the paragraph the caret just left, and it reveals the markers in
/// the paragraph the caret landed in.  Both change how those paragraphs wrap,
/// and everything below a paragraph that changed height slides.  When the
/// paragraph that shrank is *above* the one the reader clicked, the line under
/// the pointer jumps — which is the "the camera teleports when I click" report.
@Suite("Click stability", .serialized)
@MainActor
struct ClickStabilityTests {

    /// A document long enough to scroll, whose paragraphs sit near the wrap
    /// boundary so revealing their markers changes their line count.
    private static func document() -> String {
        var lines: [String] = ["# Title", ""]
        for index in 0..<60 {
            lines.append(
                "Paragraph \(index) carries **strong emphasis** and _light emphasis_ "
                + "plus `inline code` and a [link](https://example.com/some/long/path) "
                + "so the line sits close to the wrap boundary when markers reveal."
            )
            lines.append("")
        }
        return lines.joined(separator: "\n")
    }

    private static func harness() -> (MarkdownContainerView, MarkdownTextView, String) {
        let text = document()
        let storage = NSTextStorage(string: text)
        let sheet = StyleSheet(
            theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing())
        let container = MarkdownContainerView(storage: storage, styleSheet: sheet)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.mode = .live
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        view.resizeToFitContent()
        container.layoutSubtreeIfNeeded()
        return (container, view, text)
    }

    /// Models what `mouseDown` does once AppKit has resolved the gesture into a
    /// caret: the selection is set, then the reveal is rebuilt.
    private func click(_ view: MarkdownTextView, at offset: Int) {
        view.setSourceSelectedRanges([NSRange(location: offset, length: 0)])
        view.handleSelectionChanged(allowTypewriterScrolling: false)
    }

    @Test("clicking a paragraph leaves it exactly where it was on screen")
    func clickKeepsTheClickedLineStill() throws {
        let (container, view, text) = Self.harness()
        let clip = container.scrollView.contentView

        // Put the caret somewhere early, so the click below has a previously
        // revealed paragraph to re-hide — the case that shifts the page.
        let ns = text as NSString
        let first = ns.range(of: "Paragraph 2 carries").location
        click(view, at: first + 4)

        // Scroll well down the document.
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 1200))
        container.scrollView.reflectScrolledClipView(clip)

        let target = ns.range(of: "Paragraph 30 carries").location + 4
        let before = try #require(view.rect(forOffset: target))
        let screenYBefore = before.minY - clip.bounds.origin.y

        click(view, at: target)

        let after = try #require(view.rect(forOffset: target))
        let screenYAfter = after.minY - clip.bounds.origin.y

        #expect(
            abs(screenYAfter - screenYBefore) < 1.0,
            "the clicked line moved \(screenYAfter - screenYBefore)pt on screen"
        )
    }

    /// The over-wide sweep also cleared `.drHidden` from every paragraph
    /// between the old caret and the new one, permanently — so exports and the
    /// rich-text pasteboard stopped agreeing with the screen about which
    /// markers were hidden, in a band of the document nobody had clicked.
    @Test("a click leaves untouched paragraphs' markers hidden")
    func clickDoesNotUnhideDistantMarkers() throws {
        let (_, view, text) = Self.harness()
        let storage = try #require(view.textStorage)
        let ns = text as NSString

        func hiddenCharacters() -> Int {
            var total = 0
            storage.enumerateAttribute(
                .drHidden, in: NSRange(location: 0, length: storage.length)
            ) { value, range, _ in if value != nil { total += range.length } }
            return total
        }

        let baseline = hiddenCharacters()
        #expect(baseline > 0, "nothing was hidden to begin with")

        // Two clicks far apart — the case that used to wipe everything between.
        click(view, at: ns.range(of: "Paragraph 2 carries").location + 4)
        click(view, at: ns.range(of: "Paragraph 30 carries").location + 4)

        // Neither click landed inside a marker span, so nothing should reveal.
        #expect(
            hiddenCharacters() == baseline,
            "a click unhid \(baseline - hiddenCharacters()) characters it never touched"
        )
    }

    /// The narrowing must not go so far that the reveal itself stops working:
    /// a caret inside a bold span still shows its markers, and moving away
    /// still puts them back.
    @Test("markers still reveal under the caret and re-hide when it leaves")
    func revealStillRoundTrips() throws {
        let (_, view, text) = Self.harness()
        let storage = try #require(view.textStorage)
        let ns = text as NSString

        let paragraph = ns.range(of: "Paragraph 30 carries")
        let rest = NSRange(location: paragraph.location, length: ns.length - paragraph.location)
        let marker = ns.range(of: "**", options: [], range: rest)
        let bold = ns.range(of: "strong emphasis", options: [], range: rest)
        func markerIsHidden() -> Bool {
            storage.attribute(.drHidden, at: marker.location, effectiveRange: nil) != nil
        }
        /// What the reader actually sees: the layout map decides whether the
        /// marker's glyphs are on screen at all.
        func markerIsLaidOut() -> Bool {
            view.currentDisplayMap.substitutions.contains {
                $0.sourceRange.location == marker.location && $0.isHidden
            }
        }

        #expect(markerIsHidden(), "the marker should start hidden")
        #expect(markerIsLaidOut(), "the marker should start out of the layout")
        click(view, at: bold.location + 2)
        #expect(!markerIsHidden(), "the marker under the caret did not reveal")
        #expect(!markerIsLaidOut(), "the marker under the caret did not reveal on screen")
        click(view, at: ns.range(of: "Paragraph 2 carries").location + 4)
        #expect(markerIsLaidOut(), "the marker stayed on screen after the caret left")
        #expect(markerIsHidden(), "the marker did not re-hide when the caret left")
    }

    @Test("clicking does not scroll the viewport")
    func clickDoesNotMoveTheViewport() throws {
        let (container, view, text) = Self.harness()
        let clip = container.scrollView.contentView
        let ns = text as NSString

        click(view, at: ns.range(of: "Paragraph 2 carries").location + 4)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: 1200))
        container.scrollView.reflectScrolledClipView(clip)
        let yBefore = clip.bounds.origin.y

        click(view, at: ns.range(of: "Paragraph 30 carries").location + 4)

        #expect(abs(clip.bounds.origin.y - yBefore) < 1.0, "the click scrolled the viewport")
    }

    @Test("point hit testing follows the rendered line")
    func pointHitTestingUsesTextKitTwoGeometry() throws {
        let (_, view, text) = Self.harness()
        let target = (text as NSString).range(of: "Paragraph 30 carries").location + 5
        let line = try #require(view.rect(forOffset: target))
        let textKitOffset = view.characterIndexForInsertion(
            at: NSPoint(x: line.minX + 2, y: line.midY)
        )
        let sourceOffset = view.currentDisplayMap.sourceOffset(forTextKit: textKitOffset)

        #expect(
            abs(sourceOffset - target) <= 8,
            "point resolved to source offset \(sourceOffset), expected near \(target)"
        )
    }

    @Test("point hit testing resolves a rendered link label")
    func pointHitTestingResolvesRenderedLink() throws {
        let text = "# Link\n\n[Jump to target](#target)\n\n## Target\n\nReached."
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.mode = .live
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        view.resizeToFitContent()
        container.layoutSubtreeIfNeeded()

        let link = (text as NSString).range(of: "Jump to target")
        let rect = try #require(view.rect(forOffset: link.location + 2))
        let hit = view.sourceOffset(at: NSPoint(x: rect.midX, y: rect.midY))

        #expect(
            NSLocationInRange(hit, link),
            "rendered link point resolved to source offset \(hit), expected \(link)"
        )
    }

}
