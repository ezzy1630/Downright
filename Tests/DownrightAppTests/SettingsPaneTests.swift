import AppKit
import Testing
@testable import DownrightApp

// The Settings window, which is mostly constructed rather than laid out by
// hand: both bugs these tests pin down were timing accidents of construction —
// a tab that read a title before the pane had one, and a form that hung off the
// bottom of an unflipped clip view.

@Suite(.serialized)
@MainActor
struct SettingsPaneTests {
    @Test
    func everyPaneNamesItselfBeforeItsViewLoads() {
        for pane in SettingsPane.allCases {
            let controller = PreferencesWindowController.controller(for: pane)
            // The tab item is built from a controller whose view has not loaded,
            // and it copies the title once.  A pane that names itself in
            // `loadView()` is therefore unnamed at exactly the moment that
            // matters, and the label falls back to the class description.
            #expect(!controller.isViewLoaded, "\(pane) loaded its view during construction")
            #expect(controller.title == pane.title)
            #expect(NSTabViewItem(viewController: controller).label == pane.title)
        }
    }

    @Test
    func settingsTabsAreLabelledWithPaneNames() {
        let controller = PreferencesWindowController()
        defer { controller.close() }

        #expect(controller.tabLabelsForTesting == SettingsPane.allCases.map(\.title))
        // The failure mode was a raw class description in the toolbar.
        #expect(!controller.tabLabelsForTesting.contains { $0.contains("DownrightApp.") })
    }

    /// A short pane — the General pane is six controls — must start under the
    /// title bar, not at the foot of a 620pt window.
    @Test
    func aShortPaneSitsAtTheTopOfItsScrollView() throws {
        let pane = PreferencesPane(pane: .general, rows: {
            [.section("On open"), .toggle("Restore windows", help: nil, get: { false }, set: { _ in })]
        })
        let scroll = try #require(pane.view as? NSScrollView)
        scroll.frame = NSRect(x: 0, y: 0, width: 760, height: 620)
        scroll.layoutSubtreeIfNeeded()

        let form = try #require(scroll.documentView as? NSStackView)
        let firstRow = try #require(form.arrangedSubviews.first)
        #expect(form.isFlipped, "the document stack must use top-left coordinates")
        #expect(form.frame.height >= scroll.contentView.bounds.height)
        #expect(form.frame.minY == 0)
        #expect(scroll.contentView.bounds.origin.y == 0)
        #expect(firstRow.frame.minY <= 24, "the first row must stay at the top of a short pane")
    }

    /// Filtering rebuilds the stack under a live clip view, so the pane has to
    /// come back to the top of the *new* list rather than keep the offset of
    /// the one the user was reading.
    @Test
    func filteringReturnsThePaneToItsFirstRow() throws {
        let rows: [PreferenceRow] = (0..<40).map { index in
            .toggle("Setting \(index)", help: nil, get: { false }, set: { _ in })
        }
        let pane = PreferencesPane(pane: .editor, rows: { rows })
        let scroll = try #require(pane.view as? NSScrollView)
        scroll.frame = NSRect(x: 0, y: 0, width: 760, height: 200)
        scroll.layoutSubtreeIfNeeded()

        let form = try #require(scroll.documentView)
        #expect(form.frame.height > scroll.contentView.bounds.height, "the list must overflow")
        scroll.contentView.scroll(to: NSPoint(x: 0, y: 120))
        scroll.reflectScrolledClipView(scroll.contentView)
        #expect(scroll.contentView.bounds.origin.y > 0)

        pane.searchQuery = "Setting 3"
        scroll.layoutSubtreeIfNeeded()
        #expect(scroll.contentView.bounds.origin.y == 0)
        #expect(form.frame.minY == 0)
    }
}
