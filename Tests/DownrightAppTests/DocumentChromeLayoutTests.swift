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

    @Test("The change toast stays in the window corner at every width",
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
        let barRect = bar.convert(bar.bounds, to: root)

        #expect(abs(barRect.maxX - (root.bounds.maxX - 16)) < 0.5)
        #expect(abs(barRect.maxY - (root.bounds.maxY - 14)) < 0.5)
    }

    @Test("Breadcrumb visibility does not move the corner toast")
    func changeToastIgnoresTheBreadcrumbLane() throws {
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

        #expect(withoutLane == withLane)
        #expect(withoutLane == 14)
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

    /// The document map is pinned to the window's leading wall.  It used to
    /// ride `textOrigin - gutter - width - gap`, so anything that recentred
    /// the measure — opening Tasks, closing it, a resize — slid the map
    /// sideways and left it there.  Pin it at the window level, through the
    /// actions that used to move it.
    @Test("The document map never leaves the leading wall",
          arguments: [1400.0, 1020.0, 760.0])
    func documentMapStaysOnLeadingWall(_ width: Double) throws {
        let (file, cleanup) = try makeDocument()
        defer { cleanup() }

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: width, height: 800), display: true)
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.layoutSubtreeIfNeeded()

        func railLeadingEdge() -> CGFloat {
            let rail = controller.densityGutterView
            return rail.convert(rail.bounds, to: nil).minX
        }
        #expect(abs(railLeadingEdge()) < 0.5)

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.layoutSubtreeIfNeeded()
        #expect(abs(railLeadingEdge()) < 0.5)

        controller.closeTaskPanel()
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.layoutSubtreeIfNeeded()
        #expect(abs(railLeadingEdge()) < 0.5)

        controller.window?.setFrame(
            NSRect(x: 0, y: 0, width: max(700, width - 240), height: 700), display: true)
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.layoutSubtreeIfNeeded()
        #expect(abs(railLeadingEdge()) < 0.5)
    }

    /// A panel that opens to a sliver is indistinguishable from one that failed
    /// to load, so the surface it arrives at is worth holding.
    @Test("The task panel opens as a usable floating surface with its rows in place")
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

        let surface = try #require(controller.floatingSurface)
        #expect(surface.window != nil)
        #expect(!surface.isHidden)
        surface.settleForTesting()
        controller.window?.layoutIfNeeded()
        #expect(surface.frame.width >= PanelMetrics.listWidth)
        #expect(surface.frame.height > 100)
        let panel = try #require(controller.taskPanel)
        #expect(panel.window != nil)
        #expect(panel.frame.width >= PanelMetrics.listWidth)
        // Two open tasks and a pile for the finished one — the document's own
        // three tasks, reaching the panel.
        #expect(panel.visibleTaskCountForTesting == 2)
        #expect(panel.pileRowCountForTesting == 1)
    }

    @Test("The floating surface has a drawable body and one shared header")
    func taskPanelRendersBodyAndHeader() throws {
        let (file, cleanup) = try makeDocument()
        defer { cleanup() }
        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: true)
        controller.window?.layoutIfNeeded()

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        let surface = try #require(controller.floatingSurface)
        #expect(surface.rendersBodyForTesting)
        let allDescendants = surface.subviews.flatMap { [$0] + descendants(of: $0) }
        #expect(allDescendants.contains { view in
            (view as? NSTextField)?.stringValue == "Tasks"
        })
        #expect(allDescendants.filter { ($0 as? NSTextField)?.stringValue == "Tasks" }.count == 1)
        #expect(!(surface.superview is NSSplitView))
    }

    @Test("The document still has rendered content under the floating surface")
    func floatingSurfaceLeavesDocumentRendered() throws {
        let (file, cleanup) = try makeDocument()
        defer { cleanup() }
        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.window?.setFrame(NSRect(x: 0, y: 0, width: 1200, height: 800), display: true)
        controller.window?.layoutIfNeeded()

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.layoutSubtreeIfNeeded()

        let layout = try #require(controller.primaryContainer.textView.textLayoutManager)
        layout.ensureLayout(for: layout.documentRange)
        #expect(controller.primaryContainer.frame.height > 0)
        #expect(layout.usageBoundsForTextContainer.width > 0)
        #expect(layout.usageBoundsForTextContainer.height > 0)
    }

    @Test("The View command and ring use the same floating entry point")
    func menuAndRingOpenTasks() throws {
        let (file, cleanup) = try makeDocument()
        defer { cleanup() }
        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.window?.layoutIfNeeded()

        let menuItem = MainMenu.commandItem(.taskPanel)
        menuItem.target = controller
        controller.performDownrightCommand(menuItem)
        #expect(controller.floatingSurface != nil)
        controller.closeTaskPanel()

        controller.progressRing.onActivate?()
        #expect(controller.floatingSurface != nil)
        #expect(controller.inspectorHost?.selectedSection == .tasks)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}

/// The floating Tasks panel (§8.5's floating clause): it pours out of the
/// toolbar edge and hangs over the document instead of docking in the split,
/// so its geometry — fit-to-content height with a window-relative ceiling,
/// one-axis descent, and dismissal — is the contract these tests hold.
@Suite(.serialized)
@MainActor
struct FloatingTaskPanelTests {
    private func makeDocument(tasks: Int = 3, windowHeight: CGFloat = 800)
        throws -> (URL, () -> Void, DocumentWindowController)
    {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-floating-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("plan.md")
        var body = "# Plan\n\n"
        for index in 0..<tasks {
            body += index == 0 ? "- [ ] Task \(index)\n" : (index % 5 == 0 ? "- [x] Done \(index)\n" : "- [ ] Task \(index)\n")
        }
        try Data(body.utf8).write(to: file)

        let controller = DocumentWindowController()
        try controller.open(file, mode: .live)
        controller.window?.setFrame(
            NSRect(x: 0, y: 0, width: 1200, height: windowHeight), display: true
        )
        controller.window?.layoutIfNeeded()
        return (file, { try? FileManager.default.removeItem(at: directory) }, controller)
    }

    private func surfaceRectInDocumentWindow(
        _ surface: FloatingPanelSurface,
        parent: NSWindow
    ) -> NSRect {
        guard let surfaceWindow = surface.window else { return .zero }
        let windowRect = surface.convert(surface.bounds, to: nil)
        if surfaceWindow === parent { return windowRect }
        return parent.convertFromScreen(surfaceWindow.convertToScreen(windowRect))
    }

    @Test("Attaching the floating panel keeps one continuous glass view")
    func attachmentDoesNotReplaceGlass() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        let surface = try #require(controller.floatingSurface)
        guard let identity = surface.glassIdentityForTesting else { return }

        surface.refreshGlassAfterWindowAttach()

        #expect(surface.glassIdentityForTesting == identity)
    }

    @Test("Native task glass never mounts the opaque fallback")
    func nativeGlassHasNoOpaqueFirstFrame() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        let surface = try #require(controller.floatingSurface)
        guard surface.glassIdentityForTesting != nil else { return }

        #expect(!surface.opaqueFallbackIsMountedForTesting)
    }

    @Test("Native task glass is translucent while controls stay fully opaque")
    func taskGlassAndContentHaveIndependentOpacity() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        let surface = try #require(controller.floatingSurface)
        guard surface.glassIdentityForTesting != nil else { return }
        let alpha = try #require(surface.glassAlphaForTesting)

        #expect(alpha > 0.7 && alpha < 0.9)
        #expect(!surface.contentSharesGlassOpacityForTesting)
        #expect(surface.content.alphaValue == 1)
    }

    @Test("Task glass is born in the document glass stage, not a child window")
    func taskGlassUsesDocumentCompositorFromFirstFrame() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        let surface = try #require(controller.floatingSurface)
        let window = try #require(controller.window)
        let host = try #require(surface.superview)

        #expect(surface.window === window)
        #expect(!(window.childWindows ?? []).contains { surface.window === $0 })
        let outside = NSPoint(x: host.bounds.midX, y: host.bounds.midY)
        if !surface.frame.contains(outside) {
            #expect(host.hitTest(outside) == nil)
        }
    }


    @Test("The floating surface sits inside the content margins")
    func surfaceFloatsInsideTheContentMargins() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        let surface = try #require(controller.floatingSurface)
        surface.settleForTesting()
        controller.window?.layoutIfNeeded()
        let inWindow = surfaceRectInDocumentWindow(surface, parent: controller.window!)
        let content = try #require(controller.window?.contentView)
        let contentInWindow = content.convert(content.bounds, to: nil)
        let safeTop = contentInWindow.maxY - content.safeAreaInsets.top
        #expect(abs(safeTop - inWindow.maxY - PanelMetrics.floatingMargin) < 0.5)
        #expect(abs(contentInWindow.maxX - inWindow.maxX - PanelMetrics.floatingMargin) < 0.5)
    }

    @Test("The surface fits its content up to the window's ceiling")
    func surfaceFitsItsContent() throws {
        let (_, cleanup, controller) = try makeDocument(tasks: 3)
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        let surface = try #require(controller.floatingSurface)
        surface.settleForTesting()
        controller.window?.layoutIfNeeded()
        let contentHeight = try #require(controller.window?.contentView).bounds.height
        let cap = contentHeight * FloatingPanelSurface.Top.windowHeightFraction
            - 2 * PanelMetrics.floatingMargin
        #expect(surface.frame.height > 100)
        #expect(surface.frame.height < cap + 0.5)
        #expect(surface.frame.height >= FloatingPanelSurface.Top.minimumContentHeight)
    }

    @Test("The floating height follows rows and caps only a long plan", arguments: [1, 3, 5, 40])
    func surfaceMeasurementIncludesEveryTaskRow(_ taskCount: Int) throws {
        let (_, cleanup, controller) = try makeDocument(tasks: taskCount)
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        let surface = try #require(controller.floatingSurface)
        surface.settleForTesting()
        controller.window?.layoutIfNeeded()
        let panel = try #require(controller.taskPanel)
        let host = try #require(controller.inspectorHost)
        let content = try #require(controller.window?.contentView)
        let cap = (content.bounds.height - content.safeAreaInsets.top)
            * FloatingPanelSurface.Top.windowHeightFraction
            - 2 * PanelMetrics.floatingMargin
        if taskCount == 40 {
            #expect(abs(surface.frame.height - cap) < 0.5)
        } else {
            let expected = max(
                FloatingPanelSurface.Top.minimumContentHeight,
                host.floatingFittingHeight
            )
            #expect(abs(surface.frame.height - expected) < 0.5)
        }
        #expect(surface.contentLayoutHeightForTesting >= min(host.floatingFittingHeight, cap))
        #expect(panel.contentDocumentHeightForTesting > 0)
        #expect(surface.rendersBodyForTesting)
    }

    @Test("The surface stays in the document glass lane")
    func documentGlassLaneOwnsSurface() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        let surface = try #require(controller.floatingSurface)
        let window = try #require(controller.window)
        #expect(surface.window === window)
        #expect(!(surface.superview is NSSplitView))
    }

    /// The surface fits its height to the measured content, so the last row
    /// must land inside the body — never below its bottom edge. This is the
    /// guarantee the row-sum measurement exists for.
    @Test("The fitted surface leaves its last row fully inside", arguments: [1, 3, 5])
    func fittedSurfaceNeverCutsItsLastRow(_ taskCount: Int) throws {
        let (_, cleanup, controller) = try makeDocument(tasks: taskCount)
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()
        let surface = try #require(controller.floatingSurface)
        surface.settleForTesting()
        surface.layoutSubtreeIfNeeded()
        controller.window?.layoutIfNeeded()
        let panel = try #require(controller.taskPanel)
        let scroll = try #require(panel.subviews.compactMap { $0 as? NSScrollView }.first)
        let table = try #require(scroll.documentView as? NSTableView)
        let last = table.numberOfRows - 1
        #expect(last >= 0)
        let rect = table.rect(ofRow: last)
        let bottom = table.convert(NSPoint(x: 0, y: rect.maxY), to: surface).y
        // Surface coordinates are bottom-up: the bottom edge is y == 0, so a
        // negative landing y means the row is cut off below the body.
        #expect(bottom >= -0.5)
        #expect(bottom <= surface.bounds.height + 0.5)
    }

    @Test("Arrival starts with final content laid out under a clipped sliver")
    func arrivalContentIsPresentBeforeTheBodyGrows() throws {
        let (_, cleanup, controller) = try makeDocument(tasks: 3)
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        let surface = try #require(controller.floatingSurface)
        let panel = try #require(controller.taskPanel)
        #expect(surface.frame.height > FloatingPanelSurface.Top.pourSliverHeight)
        #expect(surface.visibleBodyHeightForTesting == FloatingPanelSurface.Top.pourSliverHeight)
        #expect(surface.contentLayoutHeightForTesting >= panel.fittedContentHeight)
        #expect(surface.content.frame.height >= panel.fittedContentHeight)
        #expect(surface.rendersBodyForTesting)
    }

    @Test("Arrival keeps one glass view in one compositor")
    func arrivalKeepsOneGlassSurface() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        let surface = try #require(controller.floatingSurface)
        let window = try #require(controller.window)
        let glassIdentity = surface.glassIdentityForTesting
        for _ in 0..<8 {
            _ = surface.springTick(dt: 1.0 / 120.0)
            surface.springApply()
        }

        #expect(surface.window === window)
        #expect(surface.glassIdentityForTesting == glassIdentity)
        #expect(surface.visibleBodyHeightForTesting > FloatingPanelSurface.Top.pourSliverHeight)
        #expect(surface.visibleBodyHeightForTesting < surface.restingWindowFrameForMorph.height)
    }

    @Test("Undo pill stays inside the body and reserves scroll clearance")
    func undoPillReservesScrollClearance() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()
        let surface = try #require(controller.floatingSurface)
        surface.settleForTesting()
        controller.window?.layoutIfNeeded()

        let panel = try #require(controller.taskPanel)
        panel.presentUndoForTesting(title: "First open task")
        controller.window?.layoutIfNeeded()
        surface.settleForTesting()
        surface.layoutSubtreeIfNeeded()
        panel.layoutSubtreeIfNeeded()

        let pill = surface.convert(panel.undoPillFrameForTesting, from: panel)
        #expect(surface.visibleBodyBoundsForHitTesting.contains(pill))
        #expect(panel.undoBottomInsetForTesting == panel.undoRequiredBottomInsetForTesting)
    }

    @Test("An in-panel click is not routed to floating dismissal")
    func insideClickStaysInsideSurface() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()
        let surface = try #require(controller.floatingSurface)
        surface.settleForTesting()
        controller.window?.layoutIfNeeded()
        let content = try #require(controller.window?.contentView)
        let childPoint = surface.convert(
            NSPoint(x: surface.bounds.midX, y: surface.bounds.midY), to: nil
        )
        let childScreenPoint = surface.window!.convertToScreen(
            NSRect(origin: childPoint, size: .zero)
        ).origin
        let point = controller.window!.convertFromScreen(
            NSRect(origin: childScreenPoint, size: .zero)
        ).origin

        #expect(!DocumentWindow.shouldDismissFloatingClick(
            at: point, content: content, surface: surface
        ))
    }

    @Test("Refitting stays top-anchored and trailing-flush after both resize axes")
    func refitTracksWindowWidthAndHeight() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }
        controller.activeStyleSheet = StyleSheet(
            theme: ThemeStore.shared.current,
            appearance: NSApp.effectiveAppearance,
            reduceMotionOverride: true
        )

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()
        let surface = try #require(controller.floatingSurface)
        let window = try #require(controller.window)
        let content = try #require(window.contentView)

        window.setFrame(NSRect(x: 0, y: 0, width: 920, height: 680), display: true)
        window.layoutIfNeeded()
        controller.refitFloatingSurfaceAfterContentChange()
        surface.settleForTesting()
        surface.layoutSubtreeIfNeeded()

        let surfaceInWindow = surfaceRectInDocumentWindow(surface, parent: window)
        let contentInWindow = content.convert(content.bounds, to: nil)
        let safeTop = contentInWindow.maxY - content.safeAreaInsets.top
        #expect(abs(safeTop - surfaceInWindow.maxY - PanelMetrics.floatingMargin) < 0.5)
        #expect(abs(contentInWindow.maxX - surfaceInWindow.maxX - PanelMetrics.floatingMargin) < 0.5)
        #expect(surface.frame.width > 0)
        #expect(surface.frame.height > 0)
    }

    @Test("A plan taller than the ceiling scrolls instead of overflowing")
    func surfaceCapsItsHeightAtSixtyPercent() throws {
        // Sixteen rows must not push the surface past the window's ceiling.
        let (_, cleanup, controller) = try makeDocument(tasks: 30, windowHeight: 360)
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        let surface = try #require(controller.floatingSurface)
        surface.settleForTesting()
        controller.window?.layoutIfNeeded()
        let contentHeight = try #require(controller.window?.contentView).bounds.height
        let cap = contentHeight * FloatingPanelSurface.Top.windowHeightFraction
            - 2 * PanelMetrics.floatingMargin
        #expect(surface.frame.height <= cap + 0.5)
        #expect(surface.frame.height >= 40)
    }

    @Test("Closing pours the surface back and hands nothing to the docked pane")
    func closeDismissesTheSurface() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()
        #expect(controller.floatingSurface != nil)
        #expect(controller.progressRing.isActive)
        let surface = try #require(controller.floatingSurface)

        controller.closeTaskPanel()
        surface.settleForTesting()
        controller.window?.layoutIfNeeded()

        #expect(controller.floatingSurface == nil)
        #expect(!controller.progressRing.isActive)
    }

    @Test("A rapid open-close reversal lands cleanly and remains reusable")
    func rapidTaskPanelToggleRetargetsOneSurface() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }
        let window = try #require(controller.window)
        window.makeKeyAndOrderFront(nil)

        controller.toggleTaskPanel()
        let firstSurface = try #require(controller.floatingSurface)

        controller.closeTaskPanel()
        firstSurface.settleForTesting()
        #expect(controller.floatingSurface == nil)
        #expect(!controller.progressRing.isActive)

        controller.toggleTaskPanel()
        let reopened = try #require(controller.floatingSurface)
        reopened.settleForTesting()
        #expect(reopened.visibleBodyHeightForTesting == reopened.bounds.height)
        #expect(controller.progressRing.isActive)
    }

    @Test("A resign-key and become-key cycle preserves the floating panel")
    func panelSurvivesWindowActivationCycle() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()
        let surface = try #require(controller.floatingSurface)
        let panelWindow = try #require(surface.window)

        controller.windowDidResignKey(
            Notification(name: NSWindow.didResignKeyNotification, object: controller.window)
        )
        controller.windowDidBecomeKey(
            Notification(name: NSWindow.didBecomeKeyNotification, object: controller.window)
        )

        #expect(controller.floatingSurface === surface)
        #expect(controller.progressRing.isActive)
        #expect(panelWindow === controller.window)
        #expect(surface.superview != nil)
    }

    @Test("Reduce Motion presents the surface instantly, over no glass")
    func reduceMotionPresentsInstantly() throws {
        let (_, cleanup, controller) = try makeDocument()
        defer { cleanup(); controller.close() }

        controller.activeStyleSheet = StyleSheet(
            theme: ThemeStore.shared.current,
            appearance: NSApp.effectiveAppearance,
            reduceMotionOverride: true
        )
        controller.toggleTaskPanel()
        controller.window?.layoutIfNeeded()

        let surface = try #require(controller.floatingSurface)
        #expect(surface.window != nil)
        #expect(!surface.isHidden)
        controller.closeTaskPanel()
        #expect(controller.floatingSurface == nil)
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

    @Test("A partly finished plan reports the count and the remainder")
    func partialRingReportsRemainder() {
        let ring = TaskProgressRing()
        ring.progress = (done: 3, total: 7)
        #expect(ring.countTextForTesting == "4")
        #expect(ring.accessibilityLabel() == "3 of 7 tasks complete")
        #expect(ring.toolTip == "3 of 7 tasks complete, 4 left — Open Tasks")
    }

    @Test("One remaining task is not pluralised")
    func singleRemainderReadsNaturally() {
        let ring = TaskProgressRing()
        ring.progress = (done: 6, total: 7)
        #expect(ring.countTextForTesting == "1")
        #expect(ring.toolTip?.contains("1 left") == true)
    }

    @Test("An open panel gives the tally to the panel")
    func activeRingHidesDrawnCount() {
        let ring = TaskProgressRing()
        ring.progress = (done: 3, total: 7)
        ring.isActive = true
        #expect(ring.countTextForTesting.isEmpty)
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
