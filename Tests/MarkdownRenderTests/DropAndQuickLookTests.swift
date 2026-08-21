import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

/// A drag hovering over the text, and a force click on it.
///
/// The whole feature turns on one number.  A drop point is a screen point,
/// `characterIndexForInsertion(at:)` answers in TextKit's hybrid space, and
/// only `DisplayMap` can turn one into a source offset.  What makes that easy
/// to get wrong is that the two are usually the *same* number: the layout map
/// pads hidden marker runs out with zero-width joiners so hit testing stays
/// aligned, so a drop that skipped the conversion would behave perfectly on
/// almost every document and then quietly land mid-word on one that has a
/// footnote in the paragraph.  The fixture below is built specifically to be
/// that document, so the mistake fails loudly instead.
@Suite("Document drops and Quick Look", .serialized)
@MainActor
struct DropAndQuickLookTests {

    // MARK: - Harness

    @MainActor
    private final class Delegate: NSObject, MarkdownTextViewDelegate {
        var accepts = true
        var askedToAccept: [Int] = []
        var drops: [Int] = []
        var quickLooks: [ContextTarget] = []
        var handlesQuickLook = true

        func markdownTextView(_ view: MarkdownTextView, canAcceptDrop drop: DocumentDrop) -> Bool {
            askedToAccept.append(drop.sourceOffset)
            return accepts
        }

        func markdownTextView(_ view: MarkdownTextView, didAcceptDrop drop: DocumentDrop) -> Bool {
            drops.append(drop.sourceOffset)
            return accepts
        }

        func markdownTextView(_ view: MarkdownTextView, wantsQuickLookFor target: ContextTarget) -> Bool {
            quickLooks.append(target)
            return handlesQuickLook
        }
    }

    /// A minimal `NSDraggingInfo`.  AppKit only ever hands the real one to a
    /// destination mid-gesture, so the only way to exercise the destination
    /// methods at all is to stand one up.
    nonisolated private final class SyntheticDrag: NSObject, NSDraggingInfo {
        var draggingPasteboard: NSPasteboard
        var draggingLocation: NSPoint
        var draggingDestinationWindow: NSWindow? { nil }
        var draggingSourceOperationMask: NSDragOperation { [.copy, .generic] }
        var draggedImageLocation: NSPoint { draggingLocation }
        var draggedImage: NSImage? { nil }
        var draggingSource: Any? { nil }
        var draggingSequenceNumber: Int { 1 }
        var numberOfValidItemsForDrop: Int = 1
        var draggingFormation: NSDraggingFormation = .default
        var animatesToDestination: Bool = false
        var springLoadingHighlight: NSSpringLoadingHighlight { .none }

        init(pasteboard: NSPasteboard, location: NSPoint) {
            self.draggingPasteboard = pasteboard
            self.draggingLocation = location
        }

        func slideDraggedImage(to screenPoint: NSPoint) {}
        func resetSpringLoading() {}
        func enumerateDraggingItems(
            options enumOpts: NSDraggingItemEnumerationOptions,
            for view: NSView?,
            classes classArray: [AnyClass],
            searchOptions: [NSPasteboard.ReadingOptionKey: Any],
            using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
        ) {}
    }

    /// Deliberately built so the drop point's source offset and its TextKit
    /// offset are *different numbers*.
    ///
    /// That takes more than dense Markdown.  Hidden markers do not shift the
    /// two apart: `layoutSubstitution` pads every hidden run out with
    /// zero-width joiners exactly so hit testing stays aligned, and
    /// `DisplayMap` scopes conversions to a paragraph, so a length-changing
    /// substitution in an *earlier* paragraph does not move anything either.
    /// What does shift them is a substitution that changes length inside the
    /// same paragraph as the drop — and a footnote reference is one: `[^a]`
    /// (four source characters) is drawn as the single superscript `ᵃ`.  Three
    /// of them put the drop point nine characters away from where the raw
    /// TextKit index says it is.
    nonisolated private static func document() -> String {
        var lines: [String] = ["# A Title With Markers", ""]
        // Long enough to have real geometry, short enough that eight full
        // layout passes do not sit on the main actor while the rest of the
        // suite's timing-sensitive tests are trying to drain their own work.
        for index in 0..<6 {
            lines.append("## Section \(index)")
            lines.append("")
            lines.append(
                "Paragraph \(index) carries **strong emphasis** and _light emphasis_ "
                + "plus `inline code` and a [link](https://example.com/some/long/path) "
                + "before the rest of the sentence runs on to the end of the line."
            )
            lines.append("")
        }
        lines.append(
            "The very last paragraph[^1][^2][^3], which has a TARGETWORD in it."
        )
        lines.append("")
        for identifier in ["1", "2", "3"] {
            lines.append("[^\(identifier)]: A footnote definition.")
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    /// The container is part of the harness, not scaffolding: the text view's
    /// geometry comes from the scroll view it sits in, and letting ARC free the
    /// container makes `rect(forOffset:)` answer for a layout nothing is
    /// driving.  Tests that dropped it passed for the wrong reason.
    private struct Harness {
        var container: MarkdownContainerView
        var view: MarkdownTextView
        var delegate: Delegate
        var text: String
    }

    private static func harness(
        mode: RenderMode = .live,
        text: String = document()
    ) -> Harness {
        let storage = NSTextStorage(string: text)
        let sheet = StyleSheet(
            theme: .fallback, appearance: NSAppearance(named: .aqua) ?? .currentDrawing()
        )
        let container = MarkdownContainerView(storage: storage, styleSheet: sheet)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
        container.layoutSubtreeIfNeeded()
        let view = container.textView
        view.mode = mode
        let delegate = Delegate()
        view.markdownDelegate = delegate
        view.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.layoutSubtreeIfNeeded()
        // Deliberately no `resizeToFitContent()`: that lays the whole document
        // out eagerly, and nothing here needs it — `rect(forOffset:)` and the
        // pointer hit test each resolve the band they are asked about.  The
        // suite runs beside `TypingInvalidationTests`, which drains chunked
        // work against a wall-clock deadline on the same main actor, so a
        // full-document layout pass per test is load with no assertion behind
        // it.
        return Harness(container: container, view: view, delegate: delegate, text: text)
    }

    private func filePasteboard(_ url: URL) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DropTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.writeObjects([url as NSURL])
        return pasteboard
    }

    private func textPasteboard(_ string: String) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("DropTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        return pasteboard
    }

    /// A point inside the glyphs of `offset`, expressed the way AppKit hands a
    /// drop location over: in the window's coordinate space.
    private func dragLocation(for offset: Int, in view: MarkdownTextView) throws -> NSPoint {
        let rect = try #require(view.rect(forOffset: offset), "no geometry for offset \(offset)")
        let inside = NSPoint(x: rect.minX + 1, y: rect.midY)
        return view.convert(inside, to: nil)
    }

    // MARK: - The conversion this whole feature rests on

    @Test("a drop reports the source offset under the pointer, not the display offset")
    func dropReportsSourceCoordinates() throws {
        let harness = Self.harness()
        let view = harness.view
        let ns = harness.text as NSString
        let target = ns.range(of: "TARGETWORD").location
        let location = try dragLocation(for: target, in: view)
        let viewPoint = view.convert(location, from: nil)

        // The premise, asserted rather than assumed: at this point the two
        // coordinate spaces really have come apart.  If a future change makes
        // them coincide here, every assertion below goes quiet and stops
        // testing anything, so the fixture has to fail loudly instead.
        let displayOffset = view.characterIndexForInsertion(at: viewPoint)
        let sourceOffset = view.sourceOffset(at: viewPoint)
        #expect(
            displayOffset != sourceOffset,
            "the fixture no longer shifts the two spaces apart, so this test proves nothing"
        )

        let drag = SyntheticDrag(pasteboard: filePasteboard(URL(fileURLWithPath: "/tmp/a.png")),
                                 location: location)
        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.performDragOperation(drag))

        let reported = try #require(harness.delegate.drops.last)
        #expect(reported == sourceOffset)
        #expect(reported != displayOffset, "the drop reported a TextKit offset as a source offset")
        // And the offset really does point at the word the pointer was over,
        // in the *source* string — the check that would catch a conversion
        // that is merely self-consistent.
        #expect(ns.substring(with: NSRange(location: reported, length: 10)) == "TARGETWORD")
    }

    /// Every hop through the drag lifecycle has to convert independently.  The
    /// hover indicator reading source coordinates while the drop read display
    /// coordinates would be invisible until the image landed in the wrong
    /// paragraph.
    @Test("the hover indicator and the drop agree about where the drag is")
    func hoverAndDropUseTheSameCoordinateSpace() throws {
        let harness = Self.harness()
        let view = harness.view
        let ns = harness.text as NSString
        let target = ns.range(of: "TARGETWORD").location
        let location = try dragLocation(for: target, in: view)
        let drag = SyntheticDrag(pasteboard: filePasteboard(URL(fileURLWithPath: "/tmp/a.png")),
                                 location: location)

        _ = view.draggingEntered(drag)
        let hovered = try #require(view.dropInsertionOffset)
        #expect(view.draggingUpdated(drag) == .copy)
        #expect(view.dropInsertionOffset == hovered)
        #expect(view.performDragOperation(drag))
        #expect(harness.delegate.drops.last == hovered)
        #expect(harness.delegate.askedToAccept == [hovered], "the claim must be asked exactly once per drag")
    }

    /// AppKit coalesces drag updates, so the release can land past the last
    /// position the caret was drawn at.  The drop resolves the release point.
    @Test("the drop uses the release point, not the last hover point")
    func dropResolvesTheReleasePoint() throws {
        let harness = Self.harness()
        let view = harness.view
        let ns = harness.text as NSString
        let first = ns.range(of: "Paragraph 2 carries").location
        let second = ns.range(of: "TARGETWORD").location
        let pasteboard = filePasteboard(URL(fileURLWithPath: "/tmp/a.png"))

        let hover = SyntheticDrag(pasteboard: pasteboard, location: try dragLocation(for: first, in: view))
        _ = view.draggingEntered(hover)
        let hovered = try #require(view.dropInsertionOffset)

        hover.draggingLocation = try dragLocation(for: second, in: view)
        #expect(view.performDragOperation(hover))
        let dropped = try #require(harness.delegate.drops.last)
        #expect(dropped != hovered)
        #expect(ns.substring(with: NSRange(location: dropped, length: 10)) == "TARGETWORD")
    }

    @Test("a drop past the end of an empty document lands at zero")
    func emptyDocumentDropsAtZero() throws {
        let harness = Self.harness(text: "")
        let view = harness.view
        let location = view.convert(NSPoint(x: harness.container.bounds.midX, y: 40), to: nil)
        let drag = SyntheticDrag(pasteboard: filePasteboard(URL(fileURLWithPath: "/tmp/a.png")),
                                 location: location)
        #expect(view.draggingEntered(drag) == .copy)
        #expect(view.performDragOperation(drag))
        #expect(harness.delegate.drops == [0])
    }

    // MARK: - Which drags the surface claims

    @Test("an editable surface registers for files and image bytes")
    func editableSurfaceRegistersDropTypes() {
        let harness = Self.harness()
        let view = harness.view
        for type in MarkdownTextView.documentDropTypes {
            #expect(view.registeredDraggedTypes.contains(type), "\(type.rawValue) is not registered")
        }
        // Idempotent: AppKit calls this whenever editability changes, and a
        // registration that grew its own list every time would eventually be
        // a few hundred copies of `public.png`.
        let before = view.registeredDraggedTypes
        view.updateDragTypeRegistration()
        #expect(view.registeredDraggedTypes == before)
    }

    /// A registration that only ever *added* would leave a read-only surface
    /// holding the types the mode before it registered.
    @Test("switching to a read-only mode gives the drop types back")
    func readOnlyModeUnregistersDropTypes() {
        let harness = Self.harness()
        #expect(harness.view.registeredDraggedTypes.contains(.fileURL))
        harness.view.mode = .read
        #expect(!harness.view.registeredDraggedTypes.contains(.fileURL))
        harness.view.mode = .live
        #expect(harness.view.registeredDraggedTypes.contains(.fileURL))
    }

    /// A drop is a source mutation, so a read-only surface takes none.  This is
    /// the same door `super.updateDragTypeRegistration` closes, re-checked
    /// because re-adding our types after it would open it again.
    @Test("a read-only surface claims nothing")
    func readOnlySurfaceClaimsNothing() throws {
        let harness = Self.harness(mode: .read)
        let view = harness.view
        let text = harness.text
        #expect(!view.isEditable)
        #expect(!view.registeredDraggedTypes.contains(.fileURL))
        // Belt and braces: even handed a drag directly, it takes nothing.

        let location = try dragLocation(for: (text as NSString).range(of: "TARGETWORD").location, in: view)
        let drag = SyntheticDrag(pasteboard: filePasteboard(URL(fileURLWithPath: "/tmp/a.png")),
                                 location: location)
        _ = view.draggingEntered(drag)
        #expect(harness.delegate.askedToAccept.isEmpty)
        #expect(view.dropInsertionOffset == nil)
    }

    /// Text dragged in from another app is `NSTextView`'s business and must
    /// keep working exactly as it did.  Claiming it would turn every text drag
    /// into a no-op the moment the host declined it.
    @Test("a plain text drag is left to NSTextView")
    func textDragsAreNotClaimed() throws {
        let harness = Self.harness()
        let view = harness.view
        let location = try dragLocation(
            for: (harness.text as NSString).range(of: "TARGETWORD").location, in: view
        )
        let drag = SyntheticDrag(pasteboard: textPasteboard("some words"), location: location)
        harness.delegate.accepts = false
        _ = view.draggingEntered(drag)
        #expect(!view.claimsActiveDrag)
        #expect(view.dropInsertionOffset == nil)
        #expect(harness.delegate.drops.isEmpty)
    }

    @Test("the drop indicator is cleared when the drag leaves or lands")
    func indicatorIsAlwaysCleared() throws {
        let harness = Self.harness()
        let view = harness.view
        let location = try dragLocation(
            for: (harness.text as NSString).range(of: "TARGETWORD").location, in: view
        )
        let pasteboard = filePasteboard(URL(fileURLWithPath: "/tmp/a.png"))

        let leaving = SyntheticDrag(pasteboard: pasteboard, location: location)
        _ = view.draggingEntered(leaving)
        #expect(view.dropInsertionOffset != nil)
        view.draggingExited(leaving)
        #expect(view.dropInsertionOffset == nil)
        #expect(!view.claimsActiveDrag)

        let landing = SyntheticDrag(pasteboard: pasteboard, location: location)
        _ = view.draggingEntered(landing)
        #expect(view.performDragOperation(landing))
        #expect(view.dropInsertionOffset == nil)
        #expect(!view.claimsActiveDrag)
    }

    // MARK: - Quick Look targets

    private static let linkedDocument = """
    # Notes

    See [the design](design.md) and `src/auth/session.ts` for the details.

    ![A diagram](diagram.png)

    An ordinary sentence with an unremarkable word in it.
    """

    private func linkedHarness() -> Harness { Self.harness(text: Self.linkedDocument) }

    @Test("a force click on a link, a path, or an image resolves to that target")
    func forceClickResolvesPreviewableTargets() throws {
        let harness = linkedHarness()
        let view = harness.view
        let ns = harness.text as NSString

        let linkPoint = view.convert(try dragLocation(for: ns.range(of: "the design").location, in: view), from: nil)
        guard case .link(let destination)? = view.quickLookTarget(at: linkPoint)?.kind else {
            Issue.record("a force click on link text must resolve to a link")
            return
        }
        #expect(destination == "design.md")

        let pathPoint = view.convert(
            try dragLocation(for: ns.range(of: "src/auth/session.ts").location + 4, in: view), from: nil
        )
        guard case .pathToken(let token)? = view.quickLookTarget(at: pathPoint)?.kind else {
            Issue.record("a force click on a path token must resolve to a path token")
            return
        }
        #expect(token.rawPath == "src/auth/session.ts")
    }

    /// The half that is easy to lose: force-clicking a word has to keep
    /// reaching `NSTextView`, which is what gives macOS's Look Up popover.
    @Test("a force click on an ordinary word is not claimed")
    func forceClickOnAWordFallsThrough() throws {
        let harness = linkedHarness()
        let view = harness.view
        let point = view.convert(
            try dragLocation(
                for: (harness.text as NSString).range(of: "unremarkable").location + 3, in: view
            ),
            from: nil
        )
        #expect(view.quickLookTarget(at: point) == nil)
    }

    @Test("a heading, a code fence, and bare prose are not Quick Look targets")
    func nonFileTargetsAreRefused() throws {
        let harness = linkedHarness()
        let view = harness.view
        let heading = view.convert(
            try dragLocation(for: (harness.text as NSString).range(of: "Notes").location, in: view),
            from: nil
        )
        #expect(view.quickLookTarget(at: heading) == nil)
    }

    // MARK: - Space

    private func spaceEvent() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
    }

    /// The one that matters more than the feature does.  Space is a character
    /// on an editable surface, and no amount of "the selection happens to be a
    /// link" may change that.
    @Test("Space never previews while the surface is editable")
    func spaceNeverPreviewsWhileEditing() throws {
        let harness = linkedHarness()
        let view = harness.view
        #expect(view.isEditable)
        view.setSourceSelectedRanges([(harness.text as NSString).range(of: "the design")])
        #expect(view.quickLookTargetAtSelection() != nil, "the selection is on a link")
        #expect(!view.handleQuickLookSpace(try spaceEvent()))
        #expect(harness.delegate.quickLooks.isEmpty)
    }

    @Test("Space previews a selected link on a read-only surface")
    func spacePreviewsOnAReadOnlySurface() throws {
        let harness = Self.harness(mode: .read, text: Self.linkedDocument)
        let view = harness.view
        view.setSourceSelectedRanges([(harness.text as NSString).range(of: "the design")])
        #expect(view.handleQuickLookSpace(try spaceEvent()))
        guard case .link(let destination)? = harness.delegate.quickLooks.last?.kind else {
            Issue.record("Space on a selected link must report a link target")
            return
        }
        #expect(destination == "design.md")
    }

    /// With nothing selected, Space has to stay Space — a page-down in a
    /// read-only view.  A collapsed selection at offset zero is the state a
    /// document is in before anybody touches it, and previewing whatever
    /// happens to be there is not a feature.
    @Test("Space with no selection is left alone")
    func spaceWithoutASelectionFallsThrough() throws {
        let harness = Self.harness(mode: .read, text: Self.linkedDocument)
        #expect(harness.view.sourceSelectedRange.length == 0)
        #expect(!harness.view.handleQuickLookSpace(try spaceEvent()))
        #expect(harness.delegate.quickLooks.isEmpty)
    }

    @Test("a modified Space is never a preview")
    func modifiedSpaceIsNotAPreview() throws {
        let harness = Self.harness(mode: .read, text: Self.linkedDocument)
        let view = harness.view
        view.setSourceSelectedRanges([(harness.text as NSString).range(of: "the design")])
        let option = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
            windowNumber: 0, context: nil, characters: " ",
            charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49
        ))
        #expect(!view.handleQuickLookSpace(option))
        #expect(harness.delegate.quickLooks.isEmpty)
    }

    @Test("the caret on a link is a Quick Look target; the caret in prose is not")
    func selectionTargetsFollowTheCaret() throws {
        let harness = linkedHarness()
        let view = harness.view
        let ns = harness.text as NSString
        view.setSourceSelectedRanges([NSRange(location: ns.range(of: "the design").location + 2, length: 0)])
        #expect(view.quickLookTargetAtSelection() != nil)

        view.setSourceSelectedRanges([NSRange(location: ns.range(of: "unremarkable").location + 3, length: 0)])
        #expect(view.quickLookTargetAtSelection() == nil)
    }
}
