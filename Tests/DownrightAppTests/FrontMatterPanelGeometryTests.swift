import AppKit
import MarkdownRender
import Testing

@testable import DownrightApp

/// Reddit report: with Tasks already in the floating inspector, opening Front
/// Matter drew the add form's type popup and Add Field button on top of each
/// other. Two causes: the surface was measured before the "Front Matter"
/// title row existed, and the window's height cap left less room than the
/// editor's fixed 176pt list plus its pinned form (hosted baseline: 164pt of
/// a 352pt column at 760×520, 256pt at 1020×728). The list may now scroll
/// down to a declared minimum; the form below it keeps its own rows.
@Suite(.serialized)
@MainActor
struct FrontMatterPanelGeometryTests {
    /// Compact is the panel proportion in the report's crop (its window size
    /// is not visible); 1020×728 is the stock window.
    @Test(arguments: [(760.0, 520.0), (1020.0, 728.0)])
    func frontMatterOverTasksKeepsItsFormUsable(width: Double, height: Double) throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        let window = try #require(controller.window)
        window.appearance = NSAppearance(named: .aqua)
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

        // The fraction cap alone, as at the baseline.
        let target = try #require(window.contentView)
        let available = max(0, target.bounds.height - target.safeAreaInsets.top)
        let fractionCap = max(40, min(FloatingPanelSurface.Top.windowHeightFraction * available, available)
            - 2 * PanelMetrics.floatingMargin)
        let minimum = editor.minimumFloatingContentHeight
        let facts = "content \(Int(target.bounds.width))×\(Int(target.bounds.height)), fraction cap \(fractionCap), "
            + "host needs \(host.floatingFittingHeight) (minimum \(host.floatingMinimumHeight)), "
            + "surface \(surface.bounds.height), editor \(editor.frame.height) with minimum \(minimum)"

        #expect(minimum > 0 && editor.frame.height >= minimum - 0.5,
                "The surface leaves the editor less than its shortest usable column; \(facts)")

        let controls = descendants(of: editor)
        let list = try #require(controls.compactMap { $0 as? NSScrollView }.first { !$0.isHidden },
                                "No visible field list")
        let type = try #require(controls.first { $0.accessibilityLabel() == "New field type" })
        let add = try #require(controls.first { $0.accessibilityLabel() == "Add front matter field" })
        let listRect = list.convert(list.bounds, to: surface)
        let typeRect = type.convert(type.bounds, to: surface)
        let addRect = add.convert(add.bounds, to: surface)
        let geometry = "list \(listRect), type \(typeRect), add \(addRect); \(facts)"

        // Each required control keeps its own size: the list scrolls, it
        // does not vanish, and neither form control is squeezed.
        #expect(list.frame.height >= 47.5, "The field list collapsed; \(geometry)")
        for control in [type, add] {
            let natural = control.intrinsicContentSize.height
            #expect(control.frame.width > 0 && control.frame.height > 0
                        && (natural <= 0 || control.frame.height >= natural - 0.5),
                    "\(control.accessibilityLabel() ?? "control") is compressed; \(geometry)")
        }
        // Separate places: list above the form, and the form's two rows apart.
        let inset = { (rect: NSRect) in rect.insetBy(dx: 0.5, dy: 0.5) }
        #expect(!inset(listRect).intersects(inset(typeRect)) && !inset(listRect).intersects(inset(addRect)),
                "The field list overlaps the add form; \(geometry)")
        #expect(typeRect.minY >= addRect.maxY - 0.5 || addRect.minY >= typeRect.maxY - 0.5,
                "Type popup and Add Field share a row band; \(geometry)")
        let visible = surface.bounds.insetBy(dx: -0.5, dy: -0.5)
        #expect(visible.contains(listRect) && visible.contains(typeRect) && visible.contains(addRect),
                "Part of the editor is outside the visible surface \(surface.bounds); \(geometry)")
        saveEvidence(of: surface, named: "front-matter-over-tasks-\(Int(width))x\(Int(height))-light")
    }

    /// The title row has to be counted when the surface is measured. Content
    /// short enough to clear any cap makes a stale measurement visible on a
    /// runner whose screen clamps tall windows.
    @Test func commandTitledPanelOverTasksIsMeasuredWithItsTitleRow() throws {
        let (directory, file) = try fixture()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = DocumentWindowController()
        defer { controller.close() }
        try controller.open(file, mode: .live)
        let window = try #require(controller.window)
        window.setContentSize(NSSize(width: 1020, height: 728))
        window.layoutIfNeeded()

        controller.toggleTaskPanel()
        controller.floatingSurface?.settleForTesting()
        let probe = NSView()
        probe.translatesAutoresizingMaskIntoConstraints = false
        probe.heightAnchor.constraint(equalToConstant: 120).isActive = true
        controller.installTrailing(probe, title: "Probe Title")
        let surface = try #require(controller.floatingSurface)
        surface.settleForTesting()
        window.layoutIfNeeded()

        let host = try #require(controller.inspectorHost)
        let fitting = host.floatingFittingHeight
        try #require(fitting > 120 && fitting < 236, "Probe expects a short panel under any cap, got \(fitting)")
        #expect(abs(surface.bounds.height - fitting) <= 0.5,
                "Surface \(surface.bounds.height) was measured without the title row its \(fitting)pt content needs")
    }

    private func fixture() throws -> (URL, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-front-matter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("notes.md")
        let source = "---\nkind: notes\nupdated: 2026-01-01\n---\n\n# Notes\n\n- [ ] First task\n- [ ] Second task\n"
        try Data(source.utf8).write(to: file)
        return (directory, file)
    }

    /// Hosted runs upload the check evidence directory whether or not a test
    /// fails; this writes beside its `ui-failures` folder. Native glass is not
    /// captured by `cacheDisplay`; the controls and their placement are.
    private func saveEvidence(of view: NSView, named name: String) {
        guard let failures = ProcessInfo.processInfo.environment["DOWNRIGHT_UI_TEST_ARTIFACTS"],
              let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
        else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let folder = URL(fileURLWithPath: failures, isDirectory: true)
            .deletingLastPathComponent().appendingPathComponent("ui-evidence", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try bitmap.representation(using: .png, properties: [:])?
                .write(to: folder.appendingPathComponent("\(name).png"))
        } catch {
            print("Could not save front matter evidence: \(error)")
        }
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
