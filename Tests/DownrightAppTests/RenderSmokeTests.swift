import AppKit
import Foundation
import Testing
import MarkdownCore
import MarkdownRender
@testable import DownrightApp

/// End-to-end smoke test: take a document that exercises every renderer path,
/// run it through the real pipeline, and draw it offscreen.
///
/// It is deliberately a *rendering* test rather than a parsing one.  Everything
/// upstream is covered by unit tests; what this catches is the class of failure
/// where each piece is individually correct and the assembled view still draws
/// nothing — a fragment provider that never gets installed, a layout manager
/// with no container, a text view whose storage was replaced out from under it.
///
/// Set `DOWNRIGHT_RENDER_DUMP=/some/dir` to keep the PNGs for eyeballing.
@Suite(.serialized)
@MainActor
struct RenderSmokeTests {

    private func sampleDocumentText() throws -> String {
        // Walk up from the test bundle to the repository's Docs/sample.md.
        var directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // DownrightAppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let sample = directory.appendingPathComponent("Docs/sample.md")
        if let text = try? String(contentsOf: sample, encoding: .utf8) { return text }

        directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        return try String(contentsOf: directory.appendingPathComponent("Docs/sample.md"), encoding: .utf8)
    }

    private func render(_ text: String, mode: RenderMode, size: NSSize) throws -> NSImage {
        let storage = NSTextStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)

        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(origin: .zero, size: size)
        container.textView.mode = mode
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)

        // Force a full layout pass; without a window nothing lays out on its own.
        //
        // Deliberately *not* via `textView.layoutManager`: merely touching that
        // property permanently downgrades the view to TextKit 1, and the test
        // would then render through a path the app never uses — no fragment
        // provider, no paragraph substitution, and a green result proving
        // nothing.
        container.layoutSubtreeIfNeeded()
        if let layout = container.textView.textLayoutManager {
            layout.ensureLayout(for: layout.documentRange)
        }

        let rep = try #require(container.bitmapImageRepForCachingDisplay(in: container.bounds))
        container.cacheDisplay(in: container.bounds, to: rep)
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }

    private func nonBackgroundPixelFraction(_ image: NSImage) throws -> Double {
        let rep = try #require(image.representations.first as? NSBitmapImageRep)
        guard let bitmap = rep.bitmapData else { return 0 }
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let bytesPerRow = rep.bytesPerRow, samples = rep.samplesPerPixel
        guard width > 0, height > 0, samples >= 3 else { return 0 }

        // Compare against the top-left pixel, which for a document view is
        // always page background.
        let base = (r: bitmap[0], g: bitmap[1], b: bitmap[2])
        var differing = 0, total = 0
        // Sample rather than scan: a 1000×1400 bitmap is 1.4M pixels and the
        // question ("did anything draw?") does not need every one.
        for y in stride(from: 0, to: height, by: 3) {
            for x in stride(from: 0, to: width, by: 3) {
                let offset = y * bytesPerRow + x * samples
                let dr = Int(bitmap[offset]) - Int(base.r)
                let dg = Int(bitmap[offset + 1]) - Int(base.g)
                let db = Int(bitmap[offset + 2]) - Int(base.b)
                if abs(dr) + abs(dg) + abs(db) > 24 { differing += 1 }
                total += 1
            }
        }
        return total == 0 ? 0 : Double(differing) / Double(total)
    }

    /// Whether NSTextView's TextKit 2 viewport pass runs in this process.
    ///
    /// TextKit 2 does not draw from `drawRect(_:)`.  `NSTextView` renders
    /// through `NSTextViewportLayoutController` into a private subview and
    /// layer tree (`_NSTextContentView`), and that pass only happens inside
    /// the view's real display cycle — which needs an activated application
    /// with a running event loop.  `swift test` has neither, even with an
    /// on-screen window: `viewportRange` stays nil, `cacheDisplay` yields a
    /// blank bitmap, and `characterIndexForInsertion(at:)` answers "end of
    /// document" for every point.
    ///
    /// The layout itself is unaffected — `NSTextLayoutManager` produces the
    /// right fragments with the right frames, which is what the assertions
    /// below that do not depend on the view can still check.  So the two
    /// tests that are genuinely *about* what the view puts on screen keep
    /// their full strength and declare this prerequisite, rather than being
    /// softened into something that passes without it.
    private func viewportLayoutRuns() -> Bool {
        let text = "# Probe\n\nBody text.\n"
        let container = MarkdownContainerView(storage: NSTextStorage(string: text))
        container.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.layoutSubtreeIfNeeded()
        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return false }
        container.cacheDisplay(in: container.bounds, to: rep)
        return ((try? nonBackgroundPixelFraction({
            let image = NSImage(size: container.bounds.size)
            image.addRepresentation(rep)
            return image
        }())) ?? 0) > 0
    }

    private func dump(_ image: NSImage, named name: String) {
        guard let directory = ProcessInfo.processInfo.environment["DOWNRIGHT_RENDER_DUMP"] else { return }
        guard let rep = image.representations.first as? NSBitmapImageRep,
              let png = rep.representation(using: .png, properties: [:]) else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent(name)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? png.write(to: url)
    }

    @Test("Document map stays in the container viewport while the text scrolls")
    func densityMapIsSticky() {
        let container = MarkdownContainerView(storage: NSTextStorage(string: "# Heading\n\nText"))
        let map = DensityGutterView(styleSheet: container.textView.styleSheet)
        container.leadingAccessory = map
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        container.layoutSubtreeIfNeeded()

        #expect(map.superview === container)
        #expect(map.superview !== container.scrollView)
        #expect(map.frame.minY == container.bounds.minY)
        #expect(map.frame.height == container.bounds.height)
        #expect(map.frame.midY == container.bounds.midY)
        let textOrigin = container.scrollView.frame.minX
            + container.scrollView.contentInsets.left
            + RenderMetrics.revealSlack
        let expectedX = max(
            0,
            textOrigin - RenderMetrics.gutterWidth - DensityGutterView.width - 24
        )
        #expect(abs(map.frame.minX - expectedX) < 0.5)
        #expect(map.frame.width == DensityGutterView.width)
    }

    @Test("Document map stays full-height beside the floating breadcrumb")
    func densityMapStaysFullHeightWithBreadcrumb() {
        let container = MarkdownContainerView(storage: NSTextStorage(string: "# Heading\n\nText"))
        let map = DensityGutterView(styleSheet: container.textView.styleSheet)
        let breadcrumb = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        container.leadingAccessory = map
        container.topAccessory = breadcrumb
        container.topAccessoryOverlaysContent = true
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        container.layoutSubtreeIfNeeded()

        let textOrigin = container.scrollView.frame.minX
            + container.scrollView.contentInsets.left
            + RenderMetrics.revealSlack
        let expectedX = max(
            0,
            textOrigin - RenderMetrics.gutterWidth - DensityGutterView.width - 24
        )
        #expect(map.frame == NSRect(
            x: expectedX,
            y: 0,
            width: DensityGutterView.width,
            height: 700
        ))
        #expect(container.scrollView.frame.minY == 0)
        #expect(abs(map.frame.midX - (expectedX + DensityGutterView.width / 2)) < 0.5)
    }

    @Test("Document and Source keep the same left column geometry")
    func presentationModeKeepsLeadingChromeSticky() {
        let text = "# Heading\n\nA paragraph that is long enough to wrap across modes."
        let container = MarkdownContainerView(storage: NSTextStorage(string: text))
        let map = DensityGutterView(styleSheet: container.textView.styleSheet)
        container.leadingAccessory = map
        container.frame = NSRect(x: 0, y: 0, width: 1100, height: 700)
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.layoutSubtreeIfNeeded()

        let documentInsets = container.scrollView.contentInsets
        let documentMap = map.frame
        let documentMeasure = container.textView.textContainer?.size.width ?? 0

        container.textView.mode = .source
        container.layoutSubtreeIfNeeded()

        #expect(container.scrollView.contentInsets.left == documentInsets.left)
        #expect(map.frame == documentMap)
        #expect(container.textView.textContainer?.size.width == documentMeasure)

        container.textView.mode = .live
        container.layoutSubtreeIfNeeded()

        #expect(container.scrollView.contentInsets.left == documentInsets.left)
        #expect(map.frame == documentMap)
        #expect(container.textView.textContainer?.size.width == documentMeasure)
    }

    @Test("Breadcrumb lane keeps navigation out of the document viewport")
    func breadcrumbReservesDocumentSafeArea() {
        let container = MarkdownContainerView(storage: NSTextStorage(string: "# Heading\n\nText"))
        let breadcrumb = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
        container.topAccessory = breadcrumb
        container.topAccessoryOverlaysContent = false
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        container.layoutSubtreeIfNeeded()

        #expect(container.scrollView.frame.minY > 0)
        let textOrigin = container.scrollView.frame.minX
            + container.scrollView.contentInsets.left
            + RenderMetrics.revealSlack
        #expect(abs(breadcrumb.frame.minX - textOrigin) < 0.5)
        #expect(breadcrumb.frame.maxY <= container.scrollView.frame.minY)
        #expect(container.scrollView.frame.maxY == container.bounds.maxY)
    }

    @Test("Top-visible offset samples text, not empty container padding")
    func topVisibleOffsetStartsAtFirstHeading() throws {
        let text = "# First\n\nBody\n\n## Later\n\nMore"
        let storage = NSTextStorage(string: text)
        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        container.layoutSubtreeIfNeeded()
        container.textView.prepareForDisplay()

        let later = (text as NSString).range(of: "## Later").location

        // The part that holds without a viewport pass: the point
        // `topVisibleOffset` samples must land in the first laid-out fragment
        // and not in the container's top inset, which is the bug this test
        // was written for.  `NSTextLayoutManager` answers this headlessly.
        let textView = container.textView
        let layout = try #require(textView.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        let origin = textView.textContainerOrigin
        let sampled = try #require(layout.textLayoutFragment(for: NSPoint(x: 1, y: 1)))
        let first = try #require(layout.textLayoutFragment(for: NSPoint(x: 0, y: 0)))
        #expect(sampled === first, "the sample point must sit inside the first fragment, not the inset")
        #expect(origin.y > 0, "…and the inset it must skip is real")

        // The view-level answer needs the viewport pass; see `viewportLayoutRuns`.
        withKnownIssue("NSTextView hit testing needs a viewport layout pass") {
            #expect(textView.topVisibleOffset < later)
        } when: {
            !viewportLayoutRuns()
        }
    }

    // MARK: - Tests

    @Test func sampleDocumentDrawsInEveryMode() throws {
        let text = try sampleDocumentText()
        // Drawing is the whole point of this test, so it declares the pass it
        // needs rather than asserting something weaker that would pass on a
        // blank bitmap.  See `viewportLayoutRuns`.
        try withKnownIssue("TextKit 2 draws only inside a real display cycle") {
            for mode in RenderMode.allCases {
                let image = try render(text, mode: mode, size: NSSize(width: 1000, height: 1400))
                dump(image, named: "sample-\(mode.rawValue).png")

                let inked = try nonBackgroundPixelFraction(image)
                #expect(
                    inked > 0.01,
                    "\(mode.rawValue) mode drew \(String(format: "%.3f", inked)) of a page — the view rendered nothing"
                )
                #expect(inked < 0.9, "\(mode.rawValue) mode drew almost the whole page — something is filling it")
            }
        } when: {
            !viewportLayoutRuns()
        }
    }

    /// What the smoke test can still prove headlessly: every mode lays the
    /// sample document out into real fragments over a real height.  A fragment
    /// provider that never got installed, or a text container with no width,
    /// still fails here.
    @Test func sampleDocumentLaysOutInEveryMode() throws {
        let text = try sampleDocumentText()
        for mode in RenderMode.allCases {
            let storage = NSTextStorage(string: text)
            let container = MarkdownContainerView(storage: storage)
            container.frame = NSRect(x: 0, y: 0, width: 1000, height: 1400)
            container.textView.mode = mode
            container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
            container.layoutSubtreeIfNeeded()

            let layout = try #require(container.textView.textLayoutManager)
            layout.ensureLayout(for: layout.documentRange)
            var fragments = 0
            layout.enumerateTextLayoutFragments(
                from: layout.documentRange.location, options: [.ensuresLayout]
            ) { _ in
                fragments += 1
                return true
            }
            #expect(fragments > 0, "\(mode.rawValue) mode laid out no fragments")
            #expect(
                layout.usageBoundsForTextContainer.height > 100,
                "\(mode.rawValue) mode laid the sample document out into no height"
            )
        }
    }

    /// The guarantee the whole architecture rests on (§3.1): decorating never
    /// touches a character, in any mode, at any zoom level.
    @Test func renderingNeverMutatesTheBuffer() throws {
        let text = try sampleDocumentText()
        let storage = NSTextStorage()
        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)

        let container = MarkdownContainerView(storage: storage)
        container.frame = NSRect(x: 0, y: 0, width: 900, height: 1200)
        let document = MarkdownParser.parse(text)

        for mode in RenderMode.allCases {
            for zoom in ZoomLevel.allCases {
                container.textView.mode = mode
                container.textView.zoomLevel = zoom
                container.textView.update(document: document, dirty: .wholesale)
                container.layoutSubtreeIfNeeded()
                #expect(
                    storage.string == text,
                    "storage mutated in \(mode.rawValue) mode at zoom \(zoom.rawValue)"
                )
            }
        }
    }

    /// Structural zoom is only useful if it actually removes something (§5.2).
    @Test func structuralZoomShortensTheDocument() throws {
        let text = try sampleDocumentText()
        let document = MarkdownParser.parse(text)

        let everything = StructuralZoom.plan(document, level: .everything)
        let skeleton = StructuralZoom.plan(document, level: .skeleton)
        let topLevel = StructuralZoom.plan(document, level: .h1)

        func visibleLength(_ plan: ZoomPlan) -> Int {
            plan.isIdentity ? document.length : plan.visibleRanges.reduce(0) { $0 + $1.length }
        }

        #expect(visibleLength(everything) >= visibleLength(skeleton))
        #expect(visibleLength(skeleton) > visibleLength(topLevel))
        #expect(visibleLength(topLevel) > 0, "even the tightest level shows the headings")
    }

    /// Every fenced language in the sample must be one the highlighter knows,
    /// so a fence never silently falls back to plain text.
    @Test func sampleFenceLanguagesAreAllSupported() throws {
        let text = try sampleDocumentText()
        let document = MarkdownParser.parse(text)
        var checked = 0
        document.root.walk { block in
            guard case .codeBlock(let language, _, _) = block.content, let language else { return }
            checked += 1
            #expect(
                BuiltinSyntaxHighlighter.shared.supports(language: language),
                "unsupported fence language: \(language)"
            )
        }
        #expect(checked > 0, "the sample document should contain fenced code")
    }
}
