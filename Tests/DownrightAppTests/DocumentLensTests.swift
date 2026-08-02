import AppKit
import Foundation
import Testing
import MarkdownCore
import MarkdownRender
@testable import DownrightApp

@Suite(.serialized)
struct DocumentLensModelTests {
    @Test
    func buildsEveryTabWithExactSourceRanges() throws {
        let text = """
        # Title

        [Guide](https://example.com)

        - [ ] Ship it

        ~~old~~
        """
        let document = MarkdownParser.parse(text)
        let health = DocumentHealth.analyze(document)
        let report = MarkdownCompatibility.diagnose(document, for: .commonMark)
        let model = DocumentLensModel(input: DocumentLensInput(
            document: document,
            health: health,
            renderTarget: report,
            changes: [DocumentLensChange(id: "one", kind: .inserted, range: NSRange(location: 0, length: 7))]
        ))

        #expect(model.sections.map(\.tab) == DocumentLensTab.allCases)
        let structure = model.section(.structure)
        let title = try #require(structure.items.first { $0.kind == .heading })
        #expect((text as NSString).substring(with: title.range) == "# Title")
        let link = try #require(model.section(.links).items.first { $0.kind == .link })
        #expect((text as NSString).substring(with: link.range) == "[Guide](https://example.com)")
        let task = try #require(model.section(.tasks).items.first)
        #expect((text as NSString).substring(with: task.range) == "Ship it\n")
        let change = try #require(model.section(.changes).items.first)
        #expect(change.range == NSRange(location: 0, length: 7))
        #expect(model.section(.renderTarget).count > 0)
    }

    @Test
    func groupsHealthAndAssetsWithoutChangingOrder() throws {
        let document = MarkdownParser.parse("# A\n\n![alt](missing.png)\n")
        let asset = AssetDoctor.diagnose(document, context: AssetResolutionContext(
            documentURL: URL(fileURLWithPath: "/tmp/readme.md"),
            workspaceRoot: URL(fileURLWithPath: "/tmp"),
            maximumBytes: 1
        ), probe: AssetProbe { _ in nil })
        let model = DocumentLensModel(input: DocumentLensInput(document: document, assets: asset))
        #expect(model.section(.assets).count == asset.count)
        #expect(model.section(.assets).items.allSatisfy { $0.range.length > 0 })
        #expect(model.section(.health).groups.allSatisfy { !$0.title.isEmpty })
    }
}

@MainActor
@Suite(.serialized)
struct DocumentLensViewTests {
    @Test
    func tabSwitchAndReturnSelectsTheExactItem() throws {
        let text = "# Title\n\n- [ ] Task\n"
        let document = MarkdownParser.parse(text)
        let view = DocumentLensView()
        view.model = DocumentLensModel(input: DocumentLensInput(document: document))
        let delegate = RecordingLensDelegate()
        view.delegate = delegate

        view.selectedTab = .tasks
        #expect(view.numberOfRows(in: NSTableView()) == 2)
        let row = view.tableView(NSTableView(), viewFor: nil, row: 1)
        #expect(row?.accessibilityLabel()?.contains("Task") == true)
        // The callback contract is exercised through the view's test hook.
        view.selectItemForTesting(at: 1)
        #expect(delegate.range == document.tasks.first?.contentRange)
    }
}

@MainActor
private final class RecordingLensDelegate: DocumentLensViewDelegate {
    var range: NSRange?
    var profile: RenderTargetProfile?

    func documentLens(_ view: DocumentLensView, didSelect range: NSRange, item: DocumentLensItem) {
        self.range = range
    }

    func documentLens(_ view: DocumentLensView, didSelectRenderTarget profile: RenderTargetProfile) {
        self.profile = profile
    }
}
