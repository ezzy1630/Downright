import AppKit
import MarkdownRender
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct WindowChromeTests {
    @discardableResult
    private func pumpMainRunLoop(
        until condition: () -> Bool,
        timeout: TimeInterval = 1
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(mode: .common, before: min(
                deadline, Date().addingTimeInterval(0.01)))
        }
        return condition()
    }

    @Test
    func toolbarChromePolicyKeepsFeedbackSubtleAndContrastAware() {
        #expect(ToolbarChromePolicy.feedbackOpacity(for: .idle, increaseContrast: false) == 0)
        #expect(
            ToolbarChromePolicy.feedbackOpacity(for: .hover, increaseContrast: false)
                < ToolbarChromePolicy.feedbackOpacity(for: .pressed, increaseContrast: false)
        )
        #expect(
            ToolbarChromePolicy.feedbackOpacity(for: .hover, increaseContrast: true)
                > ToolbarChromePolicy.feedbackOpacity(for: .hover, increaseContrast: false)
        )
        #expect(
            ToolbarChromePolicy.indicatorOpacity(isWindowActive: true, increaseContrast: false)
                > ToolbarChromePolicy.indicatorOpacity(isWindowActive: false, increaseContrast: false)
        )
        #expect(ToolbarChromePolicy.selectionDuration < 0.2)
    }

    @Test
    func documentIdentityNamesEveryNonNeutralStateAccessibly() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }
        let identity = try #require(controller.toolbarDocumentIdentityView)
        let cases: [(MarkdownDocument.PresentationState.Phase, String)] = [
            (.edited, "Edited"),
            (.saving, "Saving"),
            (.saved, "Saved"),
            (.changedOnDisk, "Changed on disk"),
            (.conflict, "Conflict"),
            (.saveFailed, "Save failed"),
        ]
        for (phase, label) in cases {
            identity.documentState = .init(
                phase: phase, provenance: "Paste", detail: "Example"
            )
            #expect(identity.accessibilityLabel()?.contains(label) == true)
            #expect(identity.accessibilityLabel()?.contains("Paste") == true)
            #expect(identity.toolTip?.contains(label) == true)
        }
        identity.documentState = .neutral
        #expect(identity.accessibilityLabel()?.contains("Edited") == false)
        #expect(identity.toolTip == nil)
    }

    @Test
    func missingFileRecoveryOffersOnlyExplicitNativeChoices() throws {
        let controller = DocumentWindowController()
        controller.presentSaveError(SaveError.fileMissing(URL(fileURLWithPath: "/tmp/missing.md")))
        let alert = try #require(controller.saveRecoveryAlert)
        #expect(alert.buttons.map(\.title) == [
            "Save a Copy…", "Recreate File", "Discard Changes", "Cancel",
        ])
        #expect(alert.buttons.allSatisfy { $0.toolTip?.isEmpty == false })
        if let window = controller.window, window.attachedSheet != nil {
            window.endSheet(alert.window, returnCode: .cancel)
        }
        controller.close()
    }

    @Test
    func toolbarScrubPolicyClampsMovementAndCrossesAtTheMidpoint() {
        #expect(
            ToolbarChromePolicy.scrubState(pointerX: -20, leftCenterX: 44, rightCenterX: 132)
                == .init(indicatorCenterX: 44, segment: 0)
        )
        #expect(
            ToolbarChromePolicy.scrubState(pointerX: 87, leftCenterX: 44, rightCenterX: 132)
                == .init(indicatorCenterX: 87, segment: 0)
        )
        #expect(
            ToolbarChromePolicy.scrubState(pointerX: 88, leftCenterX: 44, rightCenterX: 132)
                == .init(indicatorCenterX: 88, segment: 1)
        )
        #expect(
            ToolbarChromePolicy.scrubState(pointerX: 240, leftCenterX: 44, rightCenterX: 132)
                == .init(indicatorCenterX: 132, segment: 1)
        )
    }

    @Test
    func toolbarScrubCommitsOnceOnRelease() {
        var changes: [Int] = []
        var hapticCount = 0
        let control = ToolbarPresentationControl(
            onChange: { changes.append($0) },
            performHapticFeedback: { hapticCount += 1 }
        )
        control.frame = NSRect(x: 0, y: 0, width: 184, height: 34)
        control.layoutSubtreeIfNeeded()

        control.updateScrub(at: 44, phase: .began)
        control.updateScrub(at: 132, phase: .changed)
        #expect(control.selectedSegment == 0)
        #expect(changes.isEmpty)
        #expect(hapticCount == 1)

        control.updateScrub(at: 132, phase: .ended)
        #expect(control.selectedSegment == 1)
        #expect(changes == [1])
    }

    @Test
    func toolbarIndicatorIsCenteredUnderTheSelectedLabelAfterLayout() {
        let control = ToolbarPresentationControl(onChange: { _ in })
        control.frame = NSRect(x: 0, y: 0, width: 184, height: 34)
        control.layoutSubtreeIfNeeded()

        #expect(abs(
            control.selectionIndicatorFrameForTesting.midX
                - control.selectedSegmentCenterForTesting
        ) < 0.01)
        #expect(control.selectionIndicatorFrameForTesting.width == 34)
        #expect(control.selectionIndicatorFrameForTesting.minX > 1)

        control.setSelectedSegment(1)
        #expect(abs(
            control.selectionIndicatorFrameForTesting.midX
                - control.selectedSegmentCenterForTesting
        ) < 0.01)
        #expect(control.selectionIndicatorFrameForTesting.maxX < 183)
    }

    @Test
    func breadcrumbReservesAStableTextSafeLane() {
        let container = MarkdownContainerView(storage: NSTextStorage(string: "Hello"))
        let crumb = BreadcrumbView()
        crumb.trail = [(0, "Root", 1), (1, "Section", 2)]
        container.topAccessory = crumb
        container.topAccessoryOverlaysContent = false
        container.setFrameSize(NSSize(width: 900, height: 600))
        container.layout()
        #expect(container.scrollView.frame.minY > 0)
        #expect(crumb.frame.maxY <= container.scrollView.frame.minY)
    }

    @Test
    func breadcrumbAppearsOnlyWhenPresented() {
        let container = MarkdownContainerView(storage: NSTextStorage(string: "Hello"))
        let crumb = BreadcrumbView()
        container.topAccessory = crumb
        container.topAccessoryOverlaysContent = false
        container.setFrameSize(NSSize(width: 900, height: 600))
        container.layout()
        #expect(!crumb.isPresentedForTesting)

        crumb.trail = [(0, "Section", 1)]
        crumb.showCurrentSection()
        container.layout()
        #expect(crumb.isPresentedForTesting)
        let documentOrigin = container.scrollView.frame.minY
        #expect(documentOrigin > 0)

        crumb.hideCurrentSection()
        #expect(!crumb.isPresentedForTesting)
        container.layout()
        #expect(container.scrollView.frame.minY == documentOrigin)
    }

    @Test
    func breadcrumbShowsOnlyTheCurrentSection() throws {
        let crumb = BreadcrumbView()
        crumb.trail = [(0, "Downright Design", 1), (1, "Typography and colour", 2)]
        crumb.setFrameSize(NSSize(width: 720, height: 28))
        crumb.layout()

        let button = try #require(crumb.subviews.compactMap { $0 as? NSButton }.first)
        #expect(button.attributedTitle.string == "Typography and colour")
        #expect(button.accessibilityLabel() == "Current section: Typography and colour")
        #expect(!button.isHidden)
        #expect(crumb.currentTitleOrigin == 0)

        let menu = crumb.makePathMenu()
        #expect(menu.items.map(\.title) == ["Downright Design", "Typography and colour"])
        #expect(menu.items.map(\.indentationLevel) == [0, 1])
        #expect(menu.items.map(\.state) == [.off, .on])
    }

    @Test
    func breadcrumbPathComparisonAvoidsScrollTimeRebuilds() {
        let path = [(index: 0, title: "Root", level: 1), (index: 4, title: "Section", level: 2)]
        #expect(BreadcrumbView.sameTrail(path, path))
        #expect(!BreadcrumbView.sameTrail(path, [(index: 0, title: "Root", level: 1)]))
        #expect(!BreadcrumbView.sameTrail(
            path,
            [(index: 0, title: "Root", level: 1), (index: 5, title: "Next", level: 2)]
        ))
    }

    @Test
    func toolbarUsesNativeCenteredModeAndTrailingMenu() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }
        let toolbar = try #require(controller.window?.toolbar)

        #expect(controller.window?.isRestorable == false)
        #expect(controller.window?.delegate === controller)
        #expect(controller.window?.titlebarAppearsTransparent == true)
        #expect(controller.window?.styleMask.contains(.fullSizeContentView) == true)
        #expect(controller.window?.titlebarSeparatorStyle == NSTitlebarSeparatorStyle.none)
        #expect(controller.toolbarGlassBand != nil)
        #expect(controller.window?.toolbarStyle == .unified)
        #expect(controller.primaryContainer.leadingAccessory === controller.densityGutterView)
        #expect(controller.primaryContainer.trailingAccessory == nil)
        #expect(toolbar.displayMode == .iconOnly)
        #expect(toolbar.identifier == "DownrightToolbar.v11")
        #expect(toolbar.centeredItemIdentifier?.rawValue == "presentation-mode")
        let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace.rawValue
        #expect(controller.toolbarDefaultItemIdentifiers(toolbar).map(\.rawValue) == [
            "document-identity", flexibleSpace,
            "presentation-mode", flexibleSpace,
            "trailing-cluster",
        ])

        let identity = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "document-identity" }?.view
                as? ToolbarDocumentIdentityView
        )
        #expect(identity.intrinsicContentSize.width == 220)
        #expect(identity.intrinsicContentSize.height == 36)
        #expect(controller.window?.titleVisibility == .hidden)

        let modeItem = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "presentation-mode" }
        )
        let mode = try #require(modeItem.view as? ToolbarPresentationControl)
        #expect(!mode.isHidden)
        #expect(mode.segmentTitles == ["Document", "Source"])
        #expect(mode.selectedSegment == 0)
        #expect(mode.intrinsicContentSize.width == 184)
        #expect(mode.intrinsicContentSize.height == 34)

        controller.primaryContainer.textView.focusEntireSource()
        controller.refreshSourceFocusToolbar()
        #expect(mode.selectedSegment == 1)
        controller.primaryContainer.textView.clearSourceFocus()
        controller.refreshSourceFocusToolbar()
        #expect(mode.selectedSegment == 0)

        // The trailing controls ship as one cluster item rather than five
        // separate ones: AppKit pads every custom-view item by its own
        // margin — a tax even a hidden placeholder pays — which scattered the
        // row with uneven gaps and stretched the button plates to 36pt beside
        // the ring's 30pt one.  The stack owns the spacing now, so the row
        // reads as one tight unit against the trailing edge.
        let cluster = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "trailing-cluster" }?.view
                as? ToolbarTrailingCluster,
            "the trailing cluster is not a toolbar item"
        )
        #expect(cluster.spacing == 8)
        #expect(cluster.alignment == .centerY)
        // Find is in the cluster, not inside the `···` overflow.  The overflow
        // used to be the only interactive control on the trailing edge, which
        // put every panel in the app behind one unlabelled glyph and a menu —
        // in a window with room for more buttons.
        let find = try #require(
            cluster.arrangedSubviews.first {
                ($0 as? ToolbarActionButton)?.accessibilityLabel() == "Find"
            } as? ToolbarActionButton,
            "find is not in the trailing cluster"
        )
        #expect(find.intrinsicContentSize.width == 34)
        #expect(find.intrinsicContentSize.height == 34)
        #expect(find.usesGlassSurfaceForTesting)
        #expect(find.feedbackInsetX == 0)
        #expect(find.feedbackInsetY == 0)
        #expect(find.feedbackCornerRadius == 17)
        #expect(!find.isOn, "find should rest unlit with its panel closed")
        #expect(!cluster.arrangedSubviews.contains {
            ($0 as? ToolbarActionButton)?.accessibilityLabel() == Command.documentLens.title
        }, "Contents / Outline belongs in menus, not the permanent toolbar")
        #expect(cluster.arrangedSubviews.contains { $0 is ActivityIndicatorView })
        #expect(cluster.arrangedSubviews.contains { $0 is TaskProgressRing })
        let updatePill = try #require(
            cluster.arrangedSubviews.first { $0 is UpdateStatusPill } as? UpdateStatusPill,
            "update status pill is not in the trailing cluster"
        )
        #expect(updatePill.title.isEmpty, "the custom pill must not draw NSButton's title")
        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "contents" })
        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "inspector" })
        let overflow = try #require(
            cluster.arrangedSubviews.first { $0 is ToolbarMenuButton } as? ToolbarMenuButton,
            "the overflow menu is not in the trailing cluster"
        )
        #expect(overflow.popupMenuItems.contains { MainMenu.command(for: $0) == .documentLens })
        #expect(overflow.intrinsicContentSize.width == 34)
        #expect(overflow.intrinsicContentSize.height == 34)
        #expect(overflow.popupMenuItems.contains { $0.title == "Document Detail" })
        #expect(overflow.popupMenuItems.contains { $0.title == "Source Focus" || $0.title == "Exit Source Focus" })
        // The cluster leads with the spinner and ends at the menu: activity,
        // find, ring, pill, overflow — each hidden view costs nothing.
        #expect(cluster.arrangedSubviews.first is ActivityIndicatorView)
        #expect(cluster.arrangedSubviews.last is ToolbarMenuButton)
    }

    @Test
    func splitViewUsesTwoVisibleSideBySideDocumentPanes() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.toggleSplitView()
        let split = try #require(controller.splitViewContainer)
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(split.isVertical)
        #expect(split.arrangedSubviews.count == 2)
        #expect(split.arrangedSubviews.allSatisfy { $0.frame.width > 0 })
        #expect(controller.primaryContainer.textView.mode == .live)
        #expect(controller.splitContainer?.textView.mode == .live)
    }

    @Test
    func splitDividerIsThemedChromeRatherThanSystemGrey() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.toggleSplitView()
        let split = try #require(controller.splitViewContainer)

        // The seam between two panes of prose is a rule like any other, and
        // AppKit's default grey reads as nothing against a themed page.
        #expect(split.dividerColor == controller.activeStyleSheet.rule)

        // It also has to keep up: a theme change that repaints the panes but
        // leaves the hairline behind is the same bug one repaint later.
        let dark = try #require(ThemeStore.shared.themes.first { $0.name == "Warm Dark" })
        let sheet = StyleSheet(theme: dark, appearance: NSAppearance(named: .darkAqua) ?? .currentDrawing())
        split.styleSheet = sheet
        #expect(split.dividerColor == sheet.rule)
    }

    @Test
    func documentBarsReserveSpaceAboveTheDocument() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.showChangeSummary("Updated on disk")
        controller.showConflictBar("Changed on disk")
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(controller.barStack.arrangedSubviews.count == 1)
        #expect(controller.changeSummaryBar?.superview !== controller.barStack)
        #expect(controller.barStack.frame.height > 0)
        #expect(controller.primaryContainer.frame.minY >= controller.barStack.frame.maxY - 0.5)
        let root = try #require(controller.barStack.superview)
        let stackTop = root.isFlipped
            ? controller.barStack.frame.minY
            : controller.barStack.frame.maxY
        let safeTop = root.isFlipped
            ? root.bounds.minY + root.safeAreaInsets.top
            : root.bounds.maxY - root.safeAreaInsets.top
        #expect(abs(stackTop - safeTop) < 0.5)
    }

    @Test
    func changeSummaryUsesCompactCountedNavigation() {
        let bar = ChangeSummaryBarView()
        bar.configure(message: "Updated on disk", changeCount: 4)
        #expect(bar.intrinsicContentSize.height == ChangeSummaryBarView.toastHeight)
        #expect(bar.positionStatusForTesting.isEmpty)
    }

    @Test
    func splitViewMirrorsPresentationState() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.toggleSplitView()
        #expect(controller.perform(.sourceMode))
        #expect(controller.primaryContainer.textView.mode == .source)
        #expect(controller.splitContainer?.textView.mode == .source)

        #expect(controller.perform(.zoomLevel1))
        #expect(controller.primaryContainer.textView.zoomLevel == .h1)
        #expect(controller.splitContainer?.textView.zoomLevel == .h1)
    }

    @Test
    func inspectorHostShowsExactlyOneOwnedSection() {
        let host = InspectorHostView()
        let search = NSView()
        let tasks = NSView()

        host.setContent(search, section: .search)
        #expect(host.selectedSection == .search)
        #expect(!search.isHidden)

        host.setContent(tasks, section: .tasks)
        #expect(host.selectedSection == .tasks)
        #expect(search.isHidden)
        #expect(!tasks.isHidden)

        host.select(.search)
        #expect(host.selectedSection == .search)
        #expect(!search.isHidden)
        #expect(tasks.isHidden)
    }

    @Test
    func floatingTaskPanelFitsItsFooterRow() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-task-fit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("plan.md")
        try Data("# Plan\n\n- [ ] First\n- [ ] Second\n- [x] Done\n".utf8).write(to: file)

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.toggleTaskPanel()
        controller.floatingSurface?.settleForTesting()
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let panel = try #require(controller.taskPanel)
        let surface = try #require(controller.floatingSurface)
        let footer = try #require(panel.lastRowFrameForTesting)
        let visibleFooter = surface.convert(footer, from: panel)
        let visibleBody = surface.visibleBodyBoundsForHitTesting
        #expect(visibleBody.contains(visibleFooter))
    }

    @Test
    func inspectorSelectionAndCloseStayInSyncWithToolbar() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }
        let toolbar = try #require(controller.window?.toolbar)
        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "inspector" })

        // History shares the same floating host as Tasks; switching sections
        // must not resurrect the old width-reserving inspector lane.
        controller.showInInspector(NSView(), section: .history)
        #expect(controller.floatingSurface != nil)
        #expect(controller.inspectorHost?.selectedSection == .history)

        controller.showInInspector(NSView(), section: .context)
        #expect(controller.floatingSurface != nil)
        #expect(controller.inspectorHost?.selectedSection == .context)

        controller.showInInspector(NSView(), section: .search)
        #expect(controller.floatingSurface != nil)
        #expect(controller.inspectorHost?.selectedSection == .search)

        controller.closeInspector()
        controller.floatingSurface?.settleForTesting()
        #expect(controller.floatingSurface == nil)
    }

    @Test
    func searchInspectorKeepsFindAndReplaceInOneSurface() {
        let inspector = SearchInspectorView()
        #expect(!inspector.showsReplace)
        inspector.showsReplace = true
        #expect(inspector.findBar.showsReplace)
    }

    @Test
    func searchInspectorLaysOutItsFindFieldInsideTheVisibleHeader() throws {
        let inspector = SearchInspectorView()
        inspector.frame = NSRect(x: 0, y: 0, width: PanelMetrics.detailWidth, height: 600)
        inspector.layoutSubtreeIfNeeded()

        #expect(inspector.findBar.wantsLayer)

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }

        let field = try #require(
            descendants(of: inspector).first { $0 is NSSearchField } as? NSSearchField
        )
        let fieldFrame = inspector.convert(field.bounds, from: field)
        #expect(fieldFrame.width > 100)
        #expect(fieldFrame.height > 0)
        #expect(inspector.bounds.intersects(fieldFrame))
    }

    @Test
    func localFindUsesCompactDocumentBar() {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.showFindBar(replace: false)

        #expect(controller.findBar?.superview != nil)
        #expect(controller.findBar?.superview !== controller.barStack)
        #expect(controller.findBar?.intrinsicContentSize.height == FindBarDensity.barHeight)
        #expect(controller.findBar?.dividerCountForTesting == 2)
        #expect(controller.findBar?.hasCloseButtonForTesting == true)
        #expect(controller.findBar?.searchFieldIsBezeledForTesting == false)

        controller.toolbarFindButton?.performClick(nil)
        #expect(controller.findBar == nil)
        controller.toolbarFindButton?.performClick(nil)
        #expect(controller.findBar != nil)

        controller.dismissFindBar()
        #expect(controller.findBar == nil)
    }

    @Test("Replace mode preserves the active query and match state")
    func replaceModePreservesActiveQuery() {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.showFindBar(replace: false)
        controller.findBar?.setQueryText("table")
        controller.showFindBar(replace: true)

        #expect(controller.findBar?.currentQuery.text == "table")
        #expect(controller.findBar?.showsReplace == true)
    }

    @Test("Replace settles as two non-overlapping rows on denser native glass")
    func replaceBarSettledLayout() throws {
        let style = StyleSheet(
            theme: ThemeStore.shared.current,
            appearance: NSAppearance(named: .darkAqua)!,
            reduceMotionOverride: true
        )
        let bar = FindBarView(styleSheet: style)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 140))
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.addSubview(bar)
        bar.frame = NSRect(x: 40, y: 30, width: FindBarDensity.barWidth, height: FindBarDensity.replaceHeight)

        bar.showsReplace = true
        bar.layoutSubtreeIfNeeded()

        let find = bar.findRowFrameForTesting
        let replace = bar.replaceRowFrameForTesting
        #expect(bar.intrinsicContentSize.height == FindBarDensity.replaceHeight)
        #expect(!bar.replaceRowIsHiddenForTesting)
        #expect(bar.replaceRowAlphaForTesting == 1)
        #expect(bar.usesDenseReplaceMaterialForTesting)
        #expect(find.height > 0)
        #expect(replace.height > 0)
        #expect(!find.intersects(replace))
        #expect(bar.bounds.contains(find))
        #expect(bar.bounds.contains(replace))
    }

    @Test("Rapid Replace toggles cannot leave a faded ghost row")
    func replaceBarRapidToggleSettlesVisible() async throws {
        let style = StyleSheet(
            theme: ThemeStore.shared.current,
            appearance: NSAppearance(named: .darkAqua)!,
            reduceMotionOverride: false
        )
        let bar = FindBarView(styleSheet: style)
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 140))
        let window = NSWindow(contentRect: host.bounds, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.addSubview(bar)
        bar.frame = NSRect(x: 40, y: 30, width: FindBarDensity.barWidth, height: FindBarDensity.replaceHeight)

        bar.showsReplace = true
        bar.showsReplace = false
        bar.showsReplace = true
        try await Task.sleep(for: .milliseconds(350))
        bar.layoutSubtreeIfNeeded()

        #expect(bar.showsReplace)
        #expect(!bar.replaceRowIsHiddenForTesting)
        #expect(abs(bar.replaceRowAlphaForTesting - 1) < 0.001)
        #expect(bar.usesDenseReplaceMaterialForTesting)
        #expect(!bar.findRowFrameForTesting.intersects(bar.replaceRowFrameForTesting))
    }

    @Test("Reduce Motion toggles Replace synchronously")
    func replaceBarReducedMotionToggleIsAtomic() {
        let style = StyleSheet(
            theme: ThemeStore.shared.current,
            appearance: NSAppearance(named: .darkAqua)!,
            reduceMotionOverride: true
        )
        let bar = FindBarView(styleSheet: style)

        bar.showsReplace = true
        #expect(!bar.replaceRowIsHiddenForTesting)
        #expect(bar.replaceRowAlphaForTesting == 1)
        #expect(bar.usesDenseReplaceMaterialForTesting)

        bar.showsReplace = false
        #expect(bar.replaceRowIsHiddenForTesting)
        #expect(bar.replaceRowAlphaForTesting == 1)
        #expect(!bar.usesDenseReplaceMaterialForTesting)
        #expect(bar.intrinsicContentSize.height == FindBarDensity.barHeight)
    }

    @Test("opening local Find preserves the document camera")
    func localFindPreservesViewport() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-find-camera-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        let text = (0..<100).map { "## Section \($0)\n\nParagraph \($0)" }.joined(separator: "\n\n")
        try Data(text.utf8).write(to: file)

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.window?.setContentSize(NSSize(width: 900, height: 500))
        controller.window?.layoutIfNeeded()
        controller.primaryContainer.textView.resizeToFitContent()
        let clip = controller.primaryContainer.scrollView.contentView
        clip.scroll(to: NSPoint(x: 0, y: 420))
        controller.primaryContainer.scrollView.reflectScrolledClipView(clip)

        controller.showFindBar(replace: false)

        #expect(abs(clip.bounds.origin.y - 420) < 0.5)
    }

    @Test("Find entrance and exit keep the document geometry fixed")
    func findMotionDoesNotShiftDocument() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-find-motion-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        let text = (0..<80).map {
            "## Section \($0)\n\nStable prose \($0)."
        }.joined(separator: "\n\n")
        try Data(text.utf8).write(to: file)
        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.window?.setContentSize(NSSize(width: 900, height: 500))
        controller.window?.layoutIfNeeded()
        let container = try #require(controller.primaryContainer)
        container.textView.resizeToFitContent()
        let beforeFrame = container.frame
        let clip = container.scrollView.contentView
        let requestedBounds = NSRect(
            x: clip.bounds.origin.x,
            y: 900,
            width: clip.bounds.width,
            height: clip.bounds.height
        )
        let constrainedBounds = clip.constrainBoundsRect(requestedBounds)
        clip.scroll(to: constrainedBounds.origin)
        container.scrollView.reflectScrolledClipView(clip)
        let beforeBounds = clip.bounds

        controller.showFindBar(replace: false)
        controller.window?.layoutIfNeeded()
        controller.dismissFindBar()
        #expect(pumpMainRunLoop {
            container.frame == beforeFrame
                && abs(clip.bounds.origin.y - beforeBounds.origin.y) < 0.5
        })
        controller.window?.layoutIfNeeded()

        #expect(container.frame == beforeFrame)
        #expect(abs(clip.bounds.origin.x - beforeBounds.origin.x) < 0.5)
        #expect(abs(clip.bounds.origin.y - beforeBounds.origin.y) < 0.5)
        #expect(clip.bounds.size == beforeBounds.size)
    }

    @Test
    func inspectorFindKeepsTheSameRhythmWithoutADuplicateClose() {
        let bar = FindBarView(styleSheet: .current, presentation: .inspector)
        #expect(bar.dividerCountForTesting == 2)
        #expect(!bar.hasCloseButtonForTesting)
        #expect(!bar.searchFieldIsBezeledForTesting)
    }

    @Test
    func chromeGlassAccessibilityFallbackPolicyIsExplicit() {
        #expect(!ChromeGlass.supportsGlass(
            osSupportsGlass: true,
            reduceTransparency: true,
            increaseContrast: false
        ))
        #expect(!ChromeGlass.supportsGlass(
            osSupportsGlass: true,
            reduceTransparency: false,
            increaseContrast: true
        ))
        #expect(!ChromeGlass.supportsGlass(
            osSupportsGlass: false,
            reduceTransparency: false,
            increaseContrast: false
        ))
    }

    @Test
    func ordinaryFindDoesNotReplaceItsQueryWithDocumentSelection() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-find-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        try Data("alpha beta alpha\n".utf8).write(to: file)

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        var query = FindQuery()
        query.text = "beta"
        controller.applyFindQuery(query)
        controller.primaryContainer.textView.setSourceSelectedRanges([
            NSRange(location: 0, length: 5),
        ])

        controller.showFindBar(replace: false)

        #expect(controller.findBar?.currentQuery.text.isEmpty == true)
    }

    @Test
    func selectionFindIgnoresAnEmptySelection() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-find-empty-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        try Data("alpha beta alpha\n".utf8).write(to: file)

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.primaryContainer.textView.setSourceSelectedRanges([
            NSRange(location: 0, length: 0),
        ])

        _ = controller.perform(.useSelectionForFind)

        #expect(controller.findBar == nil)
    }

    /// The find bar's exit used to call `removeFromSuperview()` and *then*
    /// `removeArrangedSubview(_:)`.  The first call already un-arranges the
    /// view, so the second raised out of `-[NSStackView _removeView:…]` and
    /// aborted the process — closing the find bar crashed the app every time
    /// the fade completed.  Closing repeatedly has to be harmless too, because
    /// Escape repeats faster than the 0.16 s exit.
    @Test
    func closingTheFindBarRetiresItsOverlayWithoutRaising() {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.showFindBar(replace: false)
        let bar = controller.findBar
        #expect(bar != nil)
        #expect(bar?.superview != nil)
        #expect(bar?.superview !== controller.barStack)

        controller.dismissFindBar()
        controller.dismissFindBar()
        #expect(controller.findBar == nil)

        // Reduce Motion retires the pill synchronously; with motion on, the
        // fade owns the removal and only the state has to have settled.
        if controller.activeStyleSheet.reduceMotion {
            #expect(bar?.superview == nil)
        }

        controller.showFindBar(replace: false)
        #expect(controller.findBar != nil)
        controller.dismissFindBar()
    }

    @Test
    func findOptionsLiveInOneCompactMenu() {
        let bar = FindBarView()
        let menu = bar.makeOptionsMenuForTesting()
        #expect(menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
            "Regular Expression", "Match Case", "Whole Word", "In Selection",
        ])
        #expect(menu.items.last?.isEnabled == false)
    }

    @Test
    func everyFindBarControlDispatchesItsDocumentAction() throws {
        let bar = FindBarView()
        let delegate = FindBarDelegateRecorder()
        bar.delegate = delegate
        bar.statusText = "1 of 2"
        bar.showsReplace = true

        bar.setQueryText("alpha")
        try findButton("Previous match", in: bar).performClick(nil)
        try findButton("Next match", in: bar).performClick(nil)

        let replacement = try findTextField("Replace with", in: bar)
        replacement.stringValue = "omega"
        try findButton("Replace", in: bar).performClick(nil)
        try findButton("All", in: bar).performClick(nil)

        #expect(delegate.queries.last?.text == "alpha")
        #expect(delegate.advances == [false, true])
        #expect(delegate.replacements.count == 2)
        #expect(delegate.replacements[0].text == "omega")
        #expect(delegate.replacements[0].all == false)
        #expect(delegate.replacements[1].all == true)

        let options = bar.makeOptionsMenuForTesting()
        let regex = try #require(options.item(withTitle: "Regular Expression"))
        let regexAction = try #require(regex.action)
        _ = NSApp.sendAction(regexAction, to: regex.target, from: regex)
        #expect(bar.currentQuery.isRegex)

        bar.selectionScope = NSRange(location: 0, length: 5)
        let scopedOptions = bar.makeOptionsMenuForTesting()
        let inSelection = try #require(scopedOptions.item(withTitle: "In Selection"))
        #expect(inSelection.isEnabled)
        let scopeAction = try #require(inSelection.action)
        _ = NSApp.sendAction(scopeAction, to: inSelection.target, from: inSelection)
        #expect(bar.currentQuery.scope == NSRange(location: 0, length: 5))

        try findButton("Close find bar", in: bar).performClick(nil)
        #expect(delegate.closeCount == 1)
    }

    @Test
    func findBarParksItsMatchActionsUntilThereIsSomethingToWalk() throws {
        let bar = FindBarView()
        let previous = try findButton("Previous match", in: bar)
        let next = try findButton("Next match", in: bar)

        // An empty field parks the walk — a click there could only land nowhere.
        #expect(!previous.isEnabled)
        #expect(!next.isEnabled)

        bar.setQueryText("alpha")
        #expect(previous.isEnabled)
        #expect(next.isEnabled)

        // A settled "No matches" parks them again; editing re-arms at once.
        bar.statusText = "No matches"
        #expect(!previous.isEnabled)
        #expect(!next.isEnabled)
        bar.statusText = "2 of 4"
        #expect(previous.isEnabled)
        #expect(next.isEnabled)

        bar.showsReplace = true
        let replace = try findButton("Replace", in: bar)
        let replaceAll = try findButton("All", in: bar)
        #expect(replace.isEnabled)
        #expect(replaceAll.isEnabled)
        bar.setQueryText("")
        #expect(!replace.isEnabled)
        #expect(!replaceAll.isEnabled)
    }

    @Test
    func findActionFlushesTheVisibleQueryBeforeTheDebounceFires() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-find-action-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.md")
        try Data("alpha beta alpha\n".utf8).write(to: file)

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        controller.showFindBar(replace: false)
        let bar = try #require(controller.findBar)

        bar.setQueryText("alpha")
        try findButton("Next match", in: bar).performClick(nil)

        #expect(controller.currentFindQuery.text == "alpha")
        #expect(bar.statusText == "2 of 2")

        bar.showsReplace = true
        let replacement = try findTextField("Replace with", in: bar)
        bar.setQueryText("beta")
        replacement.stringValue = "gamma"
        try findButton("Replace", in: bar).performClick(nil)
        #expect(controller.markdownDocument.text == "alpha gamma alpha\n")

        bar.setQueryText("alpha")
        replacement.stringValue = "omega"
        try findButton("All", in: bar).performClick(nil)
        #expect(controller.markdownDocument.text == "omega gamma omega\n")
    }

    /// DESIGN.md's "Avoid" list names a permanent status bar outright, so the
    /// bar ships hidden and costs no height until View ▸ Status Bar asks for
    /// it.  It shipped visible and unconditional, with no toggle anywhere.
    @Test
    func statusBarIsOffByDefaultAndCostsNoHeightWhenHidden() {
        #expect(Preferences.Values().showStatusBar == false)
        let original = Preferences.shared.values
        defer { Preferences.shared.update { $0 = original } }
        Preferences.shared.update { $0.showStatusBar = false }

        let controller = DocumentWindowController()
        defer { controller.close() }
        _ = controller.window

        #expect(controller.statusBarView.isVisible == false)

        controller.statusBarView.isVisible = false
        #expect(controller.statusBarView.isHidden)
        #expect(controller.statusBarView.intrinsicContentSize.height == 0)

        controller.statusBarView.isVisible = true
        #expect(!controller.statusBarView.isHidden)
        #expect(controller.statusBarView.intrinsicContentSize.height > 0)
    }

}

@MainActor
private final class FindBarDelegateRecorder: FindBarDelegate {
    struct Replacement: Equatable {
        let text: String
        let all: Bool
    }

    var queries: [FindQuery] = []
    var advances: [Bool] = []
    var replacements: [Replacement] = []
    var closeCount = 0

    func findBar(_ bar: FindBarView, didChange query: FindQuery) {
        queries.append(query)
    }

    func findBar(_ bar: FindBarView, didRequestAdvance forward: Bool) {
        advances.append(forward)
    }

    func findBar(_ bar: FindBarView, didRequestReplace replacement: String, all: Bool) {
        replacements.append(Replacement(text: replacement, all: all))
    }

    func findBarDidRequestClose(_ bar: FindBarView) {
        closeCount += 1
    }
}

@MainActor
private func findButton(_ label: String, in root: NSView) throws -> NSButton {
    try #require(descendants(of: root).compactMap { $0 as? NSButton }.first {
        $0.accessibilityLabel() == label
    })
}

@MainActor
private func findTextField(_ label: String, in root: NSView) throws -> NSTextField {
    try #require(descendants(of: root).compactMap { $0 as? NSTextField }.first {
        $0.accessibilityLabel() == label
    })
}

@MainActor
private func descendants(of root: NSView) -> [NSView] {
    root.subviews.flatMap { [$0] + descendants(of: $0) }
}
