import AppKit
import Foundation
import MarkdownCore
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct DiagnosticsViewTests {
    @Test
    func healthGroupsFindingsAndKeepsExactRanges() throws {
        let source = "# Title\n\n#### Café\n"
        let finding = try #require(DocumentHealth.analyze(source).first { $0.id == "heading.skipped-level" })
        let view = DocumentHealthView()
        view.sourceText = source
        view.diagnostics = [finding]

        #expect(view.accessibilityLabel() == "Document health")
        #expect(view.numberOfRows(in: NSTableView()) == 2)
        #expect(view.tableView(NSTableView(), isGroupRow: 0))
        let row = view.tableView(NSTableView(), viewFor: nil, row: 1)
        #expect(row?.accessibilityLabel()?.contains("Source range 9–18") == true)
    }

    @Test
    func healthSendsOnlySafeFixesAsOneBatch() throws {
        let source = "# Title\n\n#### Café\n"
        let findings = DocumentHealth.analyze(source)
        let view = DocumentHealthView()
        let delegate = RecordingDiagnosticsDelegate()
        view.delegate = delegate
        view.sourceText = source
        view.diagnostics = findings

        view.applySafeFixesForTesting()

        #expect(delegate.healthFixes.count == 1)
        #expect(delegate.healthFixes.first?.replacement == "## ")
    }

    @Test
    func healthLocalIgnoreCanBeReset() throws {
        let source = "# Title\n\n#### Café\n"
        let finding = try #require(DocumentHealth.analyze(source).first { $0.id == "heading.skipped-level" })
        let view = DocumentHealthView()
        view.sourceText = source
        view.diagnostics = [finding]
        view.selectFindingForTesting(at: 1)
        view.ignoreSelectionForTesting()
        #expect(view.numberOfRows(in: NSTableView()) == 0)
        // Reset is intentionally local.  It does not change the source or the report.
        view.resetIgnoredFindings()
        #expect(view.numberOfRows(in: NSTableView()) == 2)
    }

    @Test
    func renderTargetsAcceptInjectedCustomProfileAndExposeProposal() throws {
        let source = "See [[Design Notes|the notes]].\n"
        let document = MarkdownParser.parse(source)
        let custom = RenderTargetProfile.custom(name: "Strict docs", capabilities: [.rawHTML])
        let view = RenderTargetsView()
        let delegate = RecordingDiagnosticsDelegate()
        view.delegate = delegate
        view.profiles = [custom, .gitHub]
        view.selectedProfile = custom
        view.sourceText = source
        view.document = document

        #expect(view.selectedProfile == custom)
        #expect(view.numberOfRows(in: NSTableView()) == 2)
        view.applySafeFixesForTesting()
        #expect(delegate.targetFixes.count == 1)
        #expect(delegate.targetFixes.first?.replacement == "[the notes](<Design Notes>)")
    }

    @Test
    func renderTargetRowsExposeSourceRangeToVoiceOver() throws {
        let source = "See [[Design Notes]].\n"
        let view = RenderTargetsView()
        view.sourceText = source
        view.document = MarkdownParser.parse(source)
        let row = view.tableView(NSTableView(), viewFor: nil, row: 1)
        let label = try #require(row?.accessibilityLabel())
        #expect(label.contains("Source range"))
        #expect(label.contains("Wikilinks"))
    }
}

@MainActor
private final class RecordingDiagnosticsDelegate: DocumentHealthViewDelegate, RenderTargetsViewDelegate {
    var healthFixes: [TextEdit] = []
    var targetFixes: [TextEdit] = []

    func documentHealthView(_ view: DocumentHealthView, didSelect diagnostic: DocumentHealthDiagnostic) {}
    func documentHealthView(_ view: DocumentHealthView, didApply fixes: [TextEdit]) { healthFixes = fixes }
    func documentHealthViewWantsSourceMode(_ view: DocumentHealthView) {}

    func renderTargetsView(_ view: RenderTargetsView, didSelect profile: RenderTargetProfile) {}
    func renderTargetsView(_ view: RenderTargetsView, didSelect diagnostic: CompatibilityDiagnostic) {}
    func renderTargetsView(_ view: RenderTargetsView, didApply fixes: [TextEdit]) { targetFixes = fixes }
    func renderTargetsViewWantsSourceMode(_ view: RenderTargetsView) {}
}
