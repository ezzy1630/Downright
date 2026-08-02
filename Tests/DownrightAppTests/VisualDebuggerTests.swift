import AppKit
import Foundation
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightApp

@Suite(.serialized)
struct VisualDebuggerModelTests {
    @Test
    func reportsCaretBlockInlineModeAndMapping() throws {
        let text = "# Title\n\nA **bold** word.\n"
        let document = MarkdownParser.parse(text)
        let offset = (text as NSString).range(of: "bold").location
        let sourceRange = NSRange(location: offset, length: 0)
        let model = VisualDebuggerModel(input: VisualDebuggerInput(
            document: document,
            selection: sourceRange,
            mode: .live,
            style: VisualDebuggerStyleFacts(fontFamily: "Test Font", pointSize: 13, paragraphAlignment: "left"),
            mapping: VisualDebuggerMapping(
                sourceRange: sourceRange,
                textKitRange: NSRange(location: 9, length: 0),
                sourceOffset: offset,
                textKitOffset: 9,
                isCanonical: true
            )
        ))

        #expect(model.mode == .live)
        #expect(model.line == 3)
        #expect(model.column == 5)
        #expect(model.block?.kind == "paragraph")
        #expect(model.inline?.kind == "strong")
        #expect(model.mapping.textKitOffset == 9)
        #expect(model.summary.contains("Inline: strong"))
        #expect(model.summary.contains("Font: Test Font"))
    }

    @Test
    func filtersTargetAndAssetDiagnosticsAtSelection() {
        let text = "![image](missing.png)\n\n~~old~~\n"
        let document = MarkdownParser.parse(text)
        let sourceRange = NSRange(location: 0, length: document.length)
        let report = MarkdownCompatibility.diagnose(document, for: .commonMark)
        let references = AssetDoctor.references(in: document, context: AssetResolutionContext(documentURL: nil, workspaceRoot: nil))
        let diagnostics = references.map { reference in
            AssetDiagnostic(code: .missing, message: "Asset is missing.", range: reference.destinationRange, reference: reference)
        }
        let model = VisualDebuggerModel(input: VisualDebuggerInput(
            document: document,
            selection: sourceRange,
            mode: .read,
            renderTargetReport: report,
            assets: diagnostics
        ))

        #expect(model.renderTarget?.name == "CommonMark")
        #expect(model.renderDiagnostics.contains { $0.capability == .strikethrough })
        #expect(model.assetDiagnostics.count == 1)
    }

    @Test
    func summaryIsStableAndIncludesHiddenCoordinates() {
        let document = MarkdownParser.parse("# Heading\n")
        let model = VisualDebuggerModel(input: VisualDebuggerInput(
            document: document,
            selection: NSRange(location: 0, length: 0),
            mode: .read,
            mapping: VisualDebuggerMapping(
                sourceRange: NSRange(location: 0, length: 0),
                textKitRange: NSRange(location: 0, length: 0),
                sourceOffset: 0,
                textKitOffset: 0,
                isCanonical: false,
                hiddenSourceRanges: [NSRange(location: 0, length: 2)]
            )
        ))
        #expect(model.summary.contains("Canonical source offset: no"))
        #expect(model.summary.contains("Hidden source ranges: 0..<2 (length 2)"))
        #expect(model.summary.contains("Block content range:"))
    }
}

@MainActor
@Suite(.serialized)
struct VisualDebuggerViewTests {
    @Test
    func exposesReadOnlySummaryAndCopiesIt() {
        let view = VisualDebuggerView()
        view.model = VisualDebuggerModel(input: VisualDebuggerInput(
            document: MarkdownParser.parse("# Title\n"),
            selection: NSRange(location: 0, length: 0),
            mode: .read
        ))
        #expect(view.accessibilityLabel() == "Visual Debugger")
        #expect(view.summaryTextForTesting().contains("Visual Debugger"))
        view.copySummaryForTesting()
        #expect(NSPasteboard.general.string(forType: .string)?.contains("Visual Debugger") == true)
    }
}
