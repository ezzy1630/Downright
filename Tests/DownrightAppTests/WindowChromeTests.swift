import AppKit
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct WindowChromeTests {
    @Test
    func toolbarUsesNativeThreeZoneLayoutAndCentredModeControl() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }
        let toolbar = try #require(controller.window?.toolbar)

        #expect(controller.window?.isRestorable == false)
        #expect(controller.window?.delegate === controller)
        #expect(toolbar.displayMode == .iconOnly)
        #expect(toolbar.identifier == "DownrightToolbar.v4")
        #expect(toolbar.centeredItemIdentifier?.rawValue == "presentation-mode")
        #expect(controller.toolbarDefaultItemIdentifiers(toolbar).map(\.rawValue) == [
            "contents",
            "presentation-mode",
            "find", "inspector", "overflow",
        ])

        let mode = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "presentation-mode" }?.view as? NSSegmentedControl
        )
        #expect(mode.segmentCount == 2)
        #expect(mode.label(forSegment: 0) == "Document")
        #expect(mode.label(forSegment: 1) == "Source")
        #expect(mode.selectedSegment == 0)
        #expect(mode.constraints.contains {
            $0.firstAttribute == .width && $0.relation == .equal && $0.constant == mode.fittingSize.width
        })

        controller.primaryContainer.textView.focusEntireSource()
        controller.refreshSourceFocusToolbar()
        #expect(mode.selectedSegment == 1)
        controller.primaryContainer.textView.clearSourceFocus()
        #expect(mode.selectedSegment == 0)

        #expect(toolbar.items.contains { $0.itemIdentifier.rawValue == "find" })
        let inspector = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "inspector" } as? NSMenuToolbarItem
        )
        #expect(inspector.menu.items.map(\.title) == ["Tasks", "History", "", "Close Inspector"])
        let overflow = try #require(
            toolbar.items.first { $0.itemIdentifier.rawValue == "overflow" } as? NSMenuToolbarItem
        )
        #expect(overflow.menu.items.contains { $0.title == "Structural Zoom" })
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
        let inspector = try #require(toolbar.items.first { $0.itemIdentifier.rawValue == "inspector" })

        controller.showInInspector(NSView(), section: .tasks)
        #expect(inspector.isBordered)
        #expect(!controller.inspectorItem.isCollapsed)

        controller.closeInspector()
        #expect(!inspector.isBordered)
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
}
