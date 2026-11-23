import AppKit
import MarkdownRender
import Testing

@testable import DownrightApp

/// Reddit report: with Tasks already in the floating inspector, opening Front
/// Matter drew the add form's type popup and Add Field button on top of each
/// other. The editor's column is all required constraints (a 176pt field
/// viewport plus a pinned footer), so a surface shorter than that column has
/// no valid layout. Two ways to get there are told apart here: the surface
/// measured before the "Front Matter" title row existed, or the window's
/// height cap left less room than the column needs.
@Suite(.serialized)
@MainActor
struct FrontMatterPanelGeometryTests {
    /// Compact is the panel proportion in the report's crop (its window size
    /// is not visible); 1020×728 is the stock window; the tall window's cap
    /// clears the column, so only a stale measurement can squeeze it.
    @Test(arguments: [(760.0, 520.0), (1020.0, 728.0), (1100.0, 1000.0)])
    func frontMatterOverTasksKeepsItsFormUsable(width: Double, height: Double) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-front-matter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.md")
        let source = "---\nkind: notes\nupdated: 2026-01-01\n---\n\n# Notes\n\n- [ ] First task\n- [ ] Second task\n"
        try Data(source.utf8).write(to: file)

        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: width, height: height))
        window.layoutIfNeeded()

        // The report's switcher shows Tasks mounted beside Document.
        controller.toggleTaskPanel()
        controller.floatingSurface?.settleForTesting()
        controller.showFrontMatterEditor()
        let surface = try #require(controller.floatingSurface)
        surface.settleForTesting()
        window.layoutIfNeeded()
        surface.layoutSubtreeIfNeeded()

        let host = try #require(controller.inspectorHost)
        let editor = try #require(controller.frontMatterEditor)
        try #require(host.selectedSection == .context && host.contentCount == 2,
                     "Fixture expects Front Matter selected with Tasks mounted")

        // Same ceiling as the controller: 60% of the area under the toolbar.
        let target = try #require(window.contentView)
        let available = max(0, target.bounds.height - target.safeAreaInsets.top)
        let cap = max(40, min(FloatingPanelSurface.Top.windowHeightFraction * available, available)
            - 2 * PanelMetrics.floatingMargin)
        let fitting = host.floatingFittingHeight
        let shown = surface.bounds.height
        let column = editor.fittingSize.height
        let facts = "window \(Int(width))×\(Int(height)), cap \(cap), host needs \(fitting), "
            + "surface \(shown), editor \(editor.frame.height) of \(column) required"

        #expect(shown >= min(cap, fitting) - 0.5,
                "Stale measurement: the surface is shorter than its own content and cap allow; \(facts)")
        #expect(editor.frame.height >= column - 0.5,
                "The surface leaves the editor less than its required column; \(facts)")

        let controls = descendants(of: editor)
        let type = try #require(controls.first { $0.accessibilityLabel() == "New field type" })
        let add = try #require(controls.first { $0.accessibilityLabel() == "Add front matter field" })
        let typeRect = type.convert(type.bounds, to: surface)
        let addRect = add.convert(add.bounds, to: surface)
        let visible = surface.bounds.insetBy(dx: -0.5, dy: -0.5)
        #expect(!typeRect.insetBy(dx: 0.5, dy: 0.5).intersects(addRect.insetBy(dx: 0.5, dy: 0.5)),
                "Type popup \(typeRect) overlaps Add Field \(addRect); \(facts)")
        #expect(visible.contains(typeRect) && visible.contains(addRect),
                "Add form outside the visible surface \(surface.bounds): type \(typeRect), add \(addRect); \(facts)")
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
