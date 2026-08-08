import AppKit
import MarkdownCore
import MarkdownRender
import Testing

@testable import DownrightApp

/// Chrome the window floats over the document has to coexist with chrome the
/// document container reserves space for.  These are the collisions that only
/// appear at a window size nobody happened to test at.
@Suite(.serialized)
@MainActor
struct DocumentChromeLayoutTests {
    private func makeDocument() throws -> (URL, () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-chrome-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("plan.md")
        try Data("""
        # A Fairly Long Document Title Here

        ## An Equally Long Second Level Heading

        ### And A Third Level Heading To Fill The Trail

        - [ ] First open task
        - [ ] Second open task
        - [x] A finished one

        Prose under the deepest heading so the breadcrumb has a full trail.
        """.utf8).write(to: file)
        return (file, { try? FileManager.default.removeItem(at: directory) })
    }

    /// The change bar used to be pinned to the window's top, which is the same
    /// band the breadcrumb's reserved lane occupies.  On a wide window the two
    /// happened to miss each other horizontally; at 640pt the bar sat across
    /// 227pt of the trail.  Narrow widths are therefore the ones worth holding.
    @Test("The change bar clears the breadcrumb's lane at every window width",
          arguments: [1400.0, 1100.0, 900.0, 760.0, 640.0])
    func changeBarClearsBreadcrumbLane(_ width: Double) throws {
        let (file, cleanup) = try makeDocument()
        defer { cleanup() }

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: width, height: 800), display: true)
        controller.window?.layoutIfNeeded()
        controller.showChangeSummary()
        controller.window?.layoutIfNeeded()

        let bar = try #require(controller.changeSummaryBar)
        let root = try #require(controller.window?.contentView)
        let crumb = controller.breadcrumbView
        let crumbRect = crumb.convert(crumb.bounds, to: root)
        let barRect = bar.convert(bar.bounds, to: root)

        #expect(!crumbRect.intersects(barRect), "the change bar overlaps the breadcrumb at \(Int(width))pt")
        // Below the lane, not off the top of the window.
        #expect(barRect.maxY <= crumbRect.minY)
        #expect(barRect.minY > 0)
    }

    /// Hiding the breadcrumb collapses its lane, so the offset is a constant
    /// that has to be refreshed rather than one set once at creation.
    @Test("Hiding the breadcrumb moves the change bar up into the freed lane")
    func changeBarFollowsTheLane() throws {
        let (file, cleanup) = try makeDocument()
        defer { cleanup() }

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 900, height: 800), display: true)
        controller.window?.layoutIfNeeded()
        controller.showChangeSummary()
        controller.window?.layoutIfNeeded()

        let withLane = try #require(controller.changeSummaryTopConstraint).constant
        controller.breadcrumbView.isHidden = true
        controller.primaryContainer.layoutSubtreeIfNeeded()
        controller.refreshChangeSummaryTopInset()
        let withoutLane = try #require(controller.changeSummaryTopConstraint).constant

        #expect(withoutLane < withLane)
        #expect(withoutLane == 8)
    }

    /// One formula for the lane, shared by the container that reserves it and
    /// the chrome that has to clear it.
    @Test("An overlaying accessory reserves no lane")
    func overlayingAccessoryReservesNothing() {
        let container = MarkdownContainerView(storage: NSTextStorage(), styleSheet: .current)
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
        container.topAccessory = accessory

        container.topAccessoryOverlaysContent = true
        #expect(container.topLaneHeight == 0)

        container.topAccessoryOverlaysContent = false
        #expect(container.topLaneHeight > 0)

        accessory.isHidden = true
        #expect(container.topLaneHeight == 0)
    }

    @Test("No accessory reserves no lane")
    func noAccessoryReservesNothing() {
        let container = MarkdownContainerView(storage: NSTextStorage(), styleSheet: .current)
        container.topAccessoryOverlaysContent = false
        #expect(container.topLaneHeight == 0)
    }

    /// A panel that opens to a sliver is indistinguishable from one that failed
    /// to load, so the width it arrives at is worth holding.
    @Test("The task panel opens at a usable width with its rows in place")
    func taskPanelOpensUsable() throws {
        let (file, cleanup) = try makeDocument()
        defer { cleanup() }

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: true)
        controller.window?.layoutIfNeeded()

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        #expect(!controller.inspectorItem.isCollapsed)
        let panel = try #require(controller.taskPanel)
        #expect(panel.window != nil)
        #expect(panel.frame.width >= DocumentWindowController.InspectorWidth.minimum)
        #expect(panel.frame.height > 100)
        // Two open tasks and a pile for the finished one — the document's own
        // three tasks, reaching the panel.
        #expect(panel.visibleTaskCountForTesting == 2)
        #expect(panel.pileRowCountForTesting == 1)
    }
}

/// The toolbar ring is a button in every state, including the state where the
/// document has no tasks — so it has to say what it is in every state too.
@Suite(.serialized)
@MainActor
struct TaskProgressRingAccessibilityTests {
    @Test("An empty plan still names itself")
    func emptyRingIsLabelled() {
        let ring = TaskProgressRing()
        ring.progress = (done: 0, total: 0)
        #expect(ring.accessibilityLabel() == "No tasks")
        #expect(ring.toolTip == "No tasks — Open Tasks")
        #expect(ring.accessibilityRole() == .button)
        #expect(!ring.mouseDownCanMoveWindow)
    }

    /// The glyph draws no numeral below ten, so the figure has to live in words
    /// or it is not anywhere.
    @Test("A partly finished plan reports the count and the remainder")
    func partialRingReportsRemainder() {
        let ring = TaskProgressRing()
        ring.progress = (done: 3, total: 7)
        #expect(ring.accessibilityLabel() == "3 of 7 tasks complete")
        #expect(ring.toolTip == "3 of 7 tasks complete, 4 left — Open Tasks")
    }

    @Test("One remaining task is not pluralised")
    func singleRemainderReadsNaturally() {
        let ring = TaskProgressRing()
        ring.progress = (done: 6, total: 7)
        #expect(ring.toolTip?.contains("1 left") == true)
    }

    @Test("A finished plan says so rather than saying nothing")
    func completeRingReportsCompletion() {
        let ring = TaskProgressRing()
        ring.progress = (done: 5, total: 5)
        #expect(ring.accessibilityLabel() == "5 of 5 tasks complete")
        #expect(ring.toolTip?.contains("all done") == true)
    }

    /// A long plan truncates the drawn numeral to "99+", so the exact figure has
    /// to survive somewhere.
    @Test("A very long plan keeps its exact figure in words")
    func longPlanKeepsExactFigure() {
        let ring = TaskProgressRing()
        ring.progress = (done: 5, total: 400)
        #expect(ring.accessibilityLabel() == "5 of 400 tasks complete")
        #expect(ring.toolTip?.contains("395 left") == true)
    }
}
