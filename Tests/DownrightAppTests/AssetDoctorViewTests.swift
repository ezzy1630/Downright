import AppKit
import Foundation
import MarkdownCore
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct AssetDoctorViewTests {
    @Test
    func groupsDiagnosticsAndReportsEmptyState() {
        let view = AssetDoctorView()
        #expect(view.accessibilityLabel() == "Asset Doctor")
        #expect(view.numberOfRows(in: NSTableView()) == 0)

        view.diagnostics = [
            diagnostic(code: .missing, severity: .warning, line: 2),
            diagnostic(code: .missing, severity: .warning, line: 3),
            diagnostic(code: .unsafe, severity: .error, line: 8),
        ]
        // One group and one row per diagnostic.  Group order is stable by code.
        #expect(view.numberOfRows(in: NSTableView()) == 5)
        #expect(view.tableView(NSTableView(), isGroupRow: 0))
        #expect(!view.tableView(NSTableView(), isGroupRow: 1))
        #expect(view.tableView(NSTableView(), isGroupRow: 3))
    }

    @Test
    func diagnosticRowExposesSeverityAndSourceToAccessibility() {
        let view = AssetDoctorView()
        view.diagnostics = [diagnostic(code: .missingAlt, severity: .warning, line: 14)]
        let table = NSTableView()
        let row = view.tableView(table, viewFor: nil, row: 1)
        let label = row?.accessibilityLabel() ?? ""
        #expect(label.contains("Warning"))
        #expect(label.contains("line 14"))
        #expect(label.contains("assets/image.png"))
    }

    @Test
    func proposalPassesThroughDelegateWithoutMutatingSource() throws {
        let view = AssetDoctorView()
        let reference = diagnostic(code: .missing, severity: .warning, line: 1).reference
        let diagnostic = AssetDiagnostic(
            code: .missing,
            message: "Image asset was not found.",
            range: reference.destinationRange,
            reference: reference
        )
        let delegate = RecordingAssetDoctorDelegate()
        view.delegate = delegate
        let proposal = AssetDoctor.relinkProposal(for: diagnostic.reference, to: "assets/new image.png")

        view.apply(proposal)

        #expect(delegate.applied?.replacement == "assets/new%20image.png")
        #expect(delegate.selected == nil)
    }

    private func diagnostic(
        code: AssetDiagnosticCode,
        severity: AssetDiagnosticSeverity,
        line: Int
    ) -> AssetDiagnostic {
        let source = "assets/image.png"
        let reference = AssetReference(
            source: source,
            sourceText: source,
            destinationRange: NSRange(location: 7, length: source.utf16.count),
            imageRange: NSRange(location: 0, length: 24),
            altText: code == .missingAlt ? "" : "Image",
            title: nil,
            kind: .relativeLocal,
            url: URL(fileURLWithPath: "/tmp/assets/image.png"),
            line: line
        )
        return AssetDiagnostic(
            code: code,
            message: "Asset diagnostic for \(code.rawValue).",
            range: reference.destinationRange,
            reference: reference
        )
    }
}

@MainActor
private final class RecordingAssetDoctorDelegate: AssetDoctorViewDelegate {
    var selected: AssetDiagnostic?
    var applied: AssetSourceProposal?

    func assetDoctorView(_ view: AssetDoctorView, didSelect diagnostic: AssetDiagnostic) {
        selected = diagnostic
    }

    func assetDoctorView(_ view: AssetDoctorView, didReveal diagnostic: AssetDiagnostic) {}

    func assetDoctorView(
        _ view: AssetDoctorView,
        didRequestProposal kind: AssetProposalKind,
        for diagnostic: AssetDiagnostic
    ) {}

    func assetDoctorView(_ view: AssetDoctorView, didApply proposal: AssetSourceProposal) {
        applied = proposal
    }
}
