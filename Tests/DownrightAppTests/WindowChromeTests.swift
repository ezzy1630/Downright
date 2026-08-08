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
            "activity", "find", "tasks-progress", "update-pill", "overflow",
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

        // Find is a toolbar item, not an overflow entry.  The overflow used
        // to be the only interactive control on the trailing edge, which put
        // every panel in the app behind one unlabelled glyph and a menu — in a
        // window with room for more buttons.  It shares `ToolbarActionButton`'s
        // 30pt geometry with the overflow so the cluster reads as one row.
        for identifier in ["find"] {
            let button = try #require(
                toolbar.items.first { $0.itemIdentifier.rawValue == identifier }?.view
                    as? ToolbarActionButton,
                "\(identifier) is not a toolbar button"
            )
            #expect(button.intrinsicContentSize.width == 30)
            #expect(button.intrinsicContentSize.height == 30)
            #expect(!button.isOn, "\(identifier) should rest unlit with its panel closed")
        }
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

        #expect(controller.barStack.arrangedSubviews.count == 1)
        #expect(controller.changeSummaryBar?.superview !== controller.barStack)
        #expect(controller.barStack.frame.height > 0)
        #expect(controller.primaryContainer.frame.minY >= controller.barStack.frame.maxY - 0.5)
    }

    @Test
    func changeSummaryUsesCompactCountedNavigation() {
        let bar = ChangeSummaryBarView()
        bar.configure(message: "Updated on disk", changeCount: 4)
        #expect(bar.intrinsicContentSize.height == PanelMetrics.reviewBarHeight)
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

    /// The find bar's exit used to call `removeFromSuperview()` and *then*
    /// `removeArrangedSubview(_:)`.  The first call already un-arranges the
    /// view, so the second raised out of `-[NSStackView _removeView:…]` and
    /// aborted the process — closing the find bar crashed the app every time
    /// the fade completed.  Closing repeatedly has to be harmless too, because
    /// Escape repeats faster than the 0.16 s exit.
    @Test
    func closingTheFindBarRetiresItFromTheStackWithoutRaising() {
        let controller = DocumentWindowController()
        defer { controller.close() }

        controller.showFindBar(replace: false)
        let bar = controller.findBar
        #expect(bar != nil)
        #expect(controller.barStack.arrangedSubviews.contains { $0 === bar })

        controller.dismissFindBar()
        controller.dismissFindBar()
        #expect(controller.findBar == nil)

        // Reduce Motion retires the pill synchronously; with motion on, the
        // fade owns the removal and only the state has to have settled.
        if controller.activeStyleSheet.reduceMotion {
            #expect(!controller.barStack.arrangedSubviews.contains { $0 === bar })
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

    /// DESIGN.md's "Avoid" list names a permanent status bar outright, so the
    /// bar ships hidden and costs no height until View ▸ Status Bar asks for
    /// it.  It shipped visible and unconditional, with no toggle anywhere.
    @Test
    func statusBarIsOffByDefaultAndCostsNoHeightWhenHidden() {
        #expect(Preferences.Values().showStatusBar == false)

        let controller = DocumentWindowController()
        defer { controller.close() }
        _ = controller.window

        #expect(controller.statusBarView.isVisible == Preferences.shared.values.showStatusBar)

        controller.statusBarView.isVisible = false
        #expect(controller.statusBarView.isHidden)
        #expect(controller.statusBarView.intrinsicContentSize.height == 0)

        controller.statusBarView.isVisible = true
        #expect(!controller.statusBarView.isHidden)
        #expect(controller.statusBarView.intrinsicContentSize.height > 0)
    }

    /// A trailing panel is an accessory to the document.  At its 300pt minimum
    /// in a 620pt window it was half the app, so the opening width is capped
    /// against the window as well as clamped to the panel's own range.  The
    /// divider stays draggable past it either way.
    @Test
    func inspectorNeverOpensWiderThanItsShareOfTheWindow() {
        typealias Width = DocumentWindowController.InspectorWidth

        // Roomy window: the panel gets exactly what it asked for.
        #expect(Width.opening(300, availableWidth: 1400) == 300)
        #expect(Width.opening(300, availableWidth: 800) == 300)
        // Tight window: capped at its share rather than taking half the app.
        #expect(Width.opening(520, availableWidth: 800) == 320)
        #expect(Width.opening(520, availableWidth: 1000) == 400)
        // No room to give: leave the divider alone entirely.
        #expect(Width.opening(300, availableWidth: 620) == nil)
        #expect(Width.opening(300, availableWidth: 0) == nil)
        // Still clamped to the panel's own range in a very wide window.
        #expect(Width.opening(900, availableWidth: 4000) == Width.maximum)
    }
}
