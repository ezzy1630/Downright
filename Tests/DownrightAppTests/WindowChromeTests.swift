import AppKit
import MarkdownRender
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct WindowChromeTests {
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
        control.frame = NSRect(x: 0, y: 0, width: 176, height: 32)
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
    func breadcrumbFloatsWithoutTakingDocumentSpace() {
        let container = MarkdownContainerView(storage: NSTextStorage(string: "Hello"))
        let crumb = BreadcrumbView()
        crumb.trail = [(0, "Root", 1), (1, "Section", 2)]
        container.topAccessory = crumb
        container.topAccessoryOverlaysContent = true
        container.setFrameSize(NSSize(width: 900, height: 600))
        container.layout()
        #expect(container.scrollView.frame.minY == 0)
        #expect(crumb.frame.minY > container.scrollView.frame.minY)
    }

    @Test
    func breadcrumbAppearsOnlyWhenPresented() {
        let container = MarkdownContainerView(storage: NSTextStorage(string: "Hello"))
        let crumb = BreadcrumbView()
        container.topAccessory = crumb
        container.topAccessoryOverlaysContent = true
        container.setFrameSize(NSSize(width: 900, height: 600))
        container.layout()
        #expect(!crumb.isPresentedForTesting)

        crumb.trail = [(0, "Section", 1)]
        crumb.presentTransiently()
        container.layout()
        #expect(crumb.isPresentedForTesting)
        #expect(container.scrollView.frame.minY == 0)

        crumb.hideImmediately()
        #expect(!crumb.isPresentedForTesting)
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
        #expect(abs(crumb.currentTitleOrigin) < 0.5)

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
        #expect(controller.window?.titlebarAppearsTransparent == false)
        #expect(controller.window?.toolbarStyle == .unified)
        #expect(controller.primaryContainer.leadingAccessory === controller.densityGutterView)
        #expect(controller.primaryContainer.trailingAccessory == nil)
        #expect(toolbar.displayMode == .iconOnly)
        #expect(toolbar.identifier == "DownrightToolbar.v10")
        #expect(toolbar.centeredItemIdentifier?.rawValue == "presentation-mode")
        let flexibleSpace = NSToolbarItem.Identifier.flexibleSpace.rawValue
        #expect(controller.toolbarDefaultItemIdentifiers(toolbar).map(\.rawValue) == [
            "document-identity", flexibleSpace,
            "presentation-mode", flexibleSpace,
            "activity", "tasks-progress", "overflow",
        ])

        let identity = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "document-identity" }?.view
                as? ToolbarDocumentIdentityView
        )
        #expect(identity.intrinsicContentSize.width == 220)
        #expect(identity.intrinsicContentSize.height == 32)
        #expect(controller.window?.titleVisibility == .hidden)

        let modeItem = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "presentation-mode" }
        )
        let mode = try #require(modeItem.view as? ToolbarPresentationControl)
        #expect(!mode.isHidden)
        #expect(mode.segmentTitles == ["Document", "Source"])
        #expect(mode.selectedSegment == 0)
        #expect(mode.intrinsicContentSize.width == 176)
        #expect(mode.intrinsicContentSize.height == 32)

        controller.primaryContainer.textView.focusEntireSource()
        controller.refreshSourceFocusToolbar()
        #expect(mode.selectedSegment == 1)
        controller.primaryContainer.textView.clearSourceFocus()
        controller.refreshSourceFocusToolbar()
        #expect(mode.selectedSegment == 0)

        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "find" })
        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "contents" })
        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "inspector" })
        let overflow = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "overflow" }?.view as? ToolbarMenuButton
        )
        #expect(overflow.intrinsicContentSize.width == 30)
        #expect(overflow.intrinsicContentSize.height == 30)
        #expect(overflow.popupMenuItems.contains { $0.title == "Structural Zoom" })
        #expect(overflow.popupMenuItems.contains { $0.title == "Source Focus" || $0.title == "Exit Source Focus" })
        #expect(toolbar.items.contains { $0.itemIdentifier.rawValue == "activity" })
        #expect(toolbar.items.contains { $0.itemIdentifier.rawValue == "tasks-progress" })
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
    func documentBarsReserveSpaceAboveTheDocument() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.showChangeSummary("Updated on disk")
        controller.showConflictBar("Changed on disk")
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        #expect(controller.barStack.arrangedSubviews.count == 2)
        #expect(controller.barStack.frame.height > 0)
        #expect(controller.primaryContainer.frame.minY >= controller.barStack.frame.maxY - 0.5)
    }

    @Test
    func changeSummaryUsesCompactCountedNavigation() {
        let bar = ChangeSummaryBarView()
        bar.configure(message: "Updated on disk", changeCount: 4)
        #expect(bar.intrinsicContentSize.height == 32)
        #expect(bar.positionStatusForTesting == "4 unread")
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
    func inspectorSelectionAndCloseStayInSyncWithToolbar() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }
        let toolbar = try #require(controller.window?.toolbar)
        #expect(!toolbar.items.contains { $0.itemIdentifier.rawValue == "inspector" })

        controller.showInInspector(NSView(), section: .tasks)
        #expect(!controller.inspectorItem.isCollapsed)

        controller.closeInspector()
        #expect(controller.inspectorItem.isCollapsed)
    }

    @Test
    func transientContentsDismissalObserversEndWhenPinned() {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.openNavigationOverlay(focusSearch: false)
        #expect(controller.navigationClickMonitor != nil)
        #expect(controller.navigationDeactivationObserver != nil)

        controller.pinNavigationPanel()
        #expect(controller.navigationClickMonitor == nil)
        #expect(controller.navigationDeactivationObserver == nil)
        #expect(controller.navigationPinned)
    }

    @Test
    func searchInspectorKeepsFindAndReplaceInOneSurface() {
        let inspector = SearchInspectorView()
        #expect(!inspector.showsReplace)
        inspector.showsReplace = true
        #expect(inspector.findBar.showsReplace)
    }

    @Test
    func localFindUsesCompactDocumentBar() {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.showFindBar(replace: false)

        #expect(controller.findBar?.superview === controller.barStack)
        #expect(controller.inspectorItem.isCollapsed)

        controller.dismissFindBar()
        #expect(controller.findBar == nil)
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
}
