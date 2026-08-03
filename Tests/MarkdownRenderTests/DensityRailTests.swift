import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

@Suite("Density rail")
struct DensityRailTests {
    @Test("Outline geometry and dwell policy stay on spec")
    func outlineGeometryAndTiming() {
        #expect(DensityGutterView.width == 72)
        #expect(DensityGutterView.hoverDwell == 0.08)
        #expect(DensityOutlineWindow.rowHeight == 44)
        #expect(DensityOutlineWindow.cornerRadius == 14)
        #expect(DensityOutlineWindow.showDwell == 0.25)
        #expect(DensityOutlineWindow.showDuration == 0.12)
        #expect(DensityOutlineWindow.hideDuration == 0.09)
    }

    @Test("At-rest bands carry navigation signals, not body minimap stripes")
    func atRestBands() {
        let source = """
        # First

        - [ ] Ship rail

        ```swift
        let body = true
        ```

        | Name |
        | --- |
        | body |

        ## Second
        """
        let document = MarkdownParser.parse(source)
        let bands = DensityGutterView.bands(
            for: document,
            changes: [(.modified, NSRange(location: 0, length: 5))],
            searchHits: [NSRange(location: 10, length: 4)]
        )

        #expect(bands.contains { if case .heading = $0.kind { true } else { false } })
        #expect(bands.contains { if case .taskList = $0.kind { true } else { false } })
        #expect(bands.contains { if case .searchHit = $0.kind { true } else { false } })
        #expect(bands.contains { if case .change = $0.kind { true } else { false } })
        #expect(bands.contains { if case .codeBlock = $0.kind { true } else { false } })
        #expect(bands.contains { if case .table = $0.kind { true } else { false } })
        #expect(bands.filter { DensityGutterView.isVisibleAtRest($0.kind) }.count == 4)
        #expect(!DensityGutterView.isVisibleAtRest(.codeBlock))
        #expect(!DensityGutterView.isVisibleAtRest(.table))
        #expect(!DensityGutterView.isVisibleAtRest(.math))
        #expect(!DensityGutterView.isVisibleAtRest(.taskList))
        #expect(!DensityGutterView.isVisibleAtRest(.image))
        #expect(!DensityGutterView.isVisibleAtRest(.callout))
    }

    @Test("Outline state keeps heading position and current marker")
    func outlineEntryState() {
        let entry = DensityOutlineEntry(title: "Section", level: 2, fraction: 0.4, isCurrent: true)
        #expect(entry == DensityOutlineEntry(title: "Section", level: 2, fraction: 0.4, isCurrent: true))
        #expect(entry != DensityOutlineEntry(title: "Section", level: 2, fraction: 0.4, isCurrent: false))
    }

    @Test("Document-map marks stay centered in the viewport")
    func centeredBandPositions() {
        let positions = DensityGutterView.centeredBandYPositions(height: 800, count: 4)

        #expect(positions.count == 4)
        #expect(positions == [386.5, 395.5, 404.5, 413.5])
        #expect((positions.first! + positions.last!) / 2 == 400)
    }

    @Test("Current heading is the nearest heading at the viewport top")
    func currentHeadingPolicy() {
        let bands = [
            DensityBand(kind: .heading(level: 1), startFraction: 0.1, endFraction: 0.1),
            DensityBand(kind: .heading(level: 2), startFraction: 0.3, endFraction: 0.3),
            DensityBand(kind: .heading(level: 2), startFraction: 0.8, endFraction: 0.8),
        ]
        #expect(DensityGutterView.currentHeadingFraction(in: bands, at: 0.35...0.6) == 0.3)
        #expect(DensityGutterView.currentHeadingFraction(in: bands, at: 0...0.05) == 0.1)
    }
}
