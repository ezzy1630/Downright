import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

@Suite("Density rail")
struct DensityRailTests {
    @Test("Outline geometry and dwell policy stay on spec")
    func outlineGeometryAndTiming() {
        #expect(DensityGutterView.width == 72)
        #expect(DensityGutterView.hoverDwell == 0.02)
        #expect(DensityGutterView.hoverActivationSlop == 22)
        #expect(DensityGutterView.hoverDismissalSlop == 4)
        #expect(DensityGutterView.previewExitDelay == 0.06)
        #expect(DensityGutterView.proximityRadius == 36)
        #expect(DensityGutterView.magneticPull == 1.5)
        #expect(DensityGutterView.scrubVelocityPull == 2.0)
        #expect(DensityGutterView.stackCompression == 0.08)
        #expect(DensityGutterView.breatheScale == 1.08)
        #expect(DensityGutterView.neighborhoodDim == 0.82)
        #expect(DensityGutterView.shortDocMarkGap == 18)
        #expect(DensityGutterView.shortDocThreshold == 3)
        #expect(DensityGutterView.jumpPunchBoost == 4)
        #expect(Motion.hoverGrow == 0.08)
        #expect(Motion.hoverShrink == 0.18)
        #expect(Motion.settle == 0.20)
        #expect(Motion.jumpPunch == 0.14)
        #expect(Motion.breathe == 0.12)
        #expect(Motion.previewStagger == 0.04)
        #expect(DensityOutlineWindow.rowHeight == 44)
        #expect(DensityOutlineWindow.cornerRadius == 14)
        #expect(DensityOutlineWindow.showDwell == 0.25)
        #expect(DensityOutlineWindow.showDuration == 0.12)
        #expect(DensityOutlineWindow.hideDuration == 0.09)
    }

    @Test("Hover opens near a mark but dismisses outside its row")
    func hoverHysteresis() {
        let positions: [CGFloat] = [100, 200]
        let activation = DensityGutterView.hoverActivationSlop
        let dismissal = DensityGutterView.hoverDismissalSlop

        #expect(DensityGutterView.nextHoveredBandIndex(
            at: 100 + activation - 1,
            positions: positions,
            currentIndex: nil,
            activationSlop: activation,
            dismissalSlop: dismissal
        ) == 0)
        #expect(DensityGutterView.nextHoveredBandIndex(
            at: 100 + activation + 1,
            positions: positions,
            currentIndex: nil,
            activationSlop: activation,
            dismissalSlop: dismissal
        ) == nil)
        #expect(DensityGutterView.nextHoveredBandIndex(
            at: 100 + dismissal,
            positions: positions,
            currentIndex: 0,
            activationSlop: activation,
            dismissalSlop: dismissal
        ) == 0)
        #expect(DensityGutterView.nextHoveredBandIndex(
            at: 100 + dismissal + 1,
            positions: positions,
            currentIndex: 0,
            activationSlop: activation,
            dismissalSlop: dismissal
        ) == nil)
        #expect(DensityGutterView.nextHoveredBandIndex(
            at: 200 - activation + 1,
            positions: positions,
            currentIndex: 0,
            activationSlop: activation,
            dismissalSlop: dismissal
        ) == 1)
    }

    @Test("Proximity falloff is smooth and level widths encode depth")
    func proximityAndHeadingWidths() {
        #expect(DensityGutterView.proximityInfluence(distance: 0) == 1)
        #expect(DensityGutterView.proximityInfluence(distance: 36) == 0)
        let mid = DensityGutterView.proximityInfluence(distance: 18)
        #expect(mid > 0.4 && mid < 0.6)

        #expect(DensityGutterView.headingMarkWidth(level: 1) == 26)
        #expect(DensityGutterView.headingMarkWidth(level: 2) == 20)
        #expect(DensityGutterView.headingMarkWidth(level: 3) == 14)
        #expect(DensityGutterView.headingMarkWidth(level: 4) == 10)
        #expect(DensityGutterView.headingMarkWidth(level: 1, emphasized: true) == 30)
        #expect(DensityGutterView.headingMarkWidth(level: 2, emphasized: true) == 26)
        #expect(DensityGutterView.headingMarkWidth(level: 3, emphasized: true) == 20)
        #expect(DensityGutterView.headingMarkWidth(level: 4, emphasized: true) == 14)
    }

    @Test("Neighbourhood dim softens distant marks under hover")
    func neighborhoodDimPolicy() {
        #expect(DensityGutterView.neighborhoodFactor(index: 2, hoveredIndex: nil) == 1)
        #expect(DensityGutterView.neighborhoodFactor(index: 2, hoveredIndex: 2) == 1)
        #expect(DensityGutterView.neighborhoodFactor(index: 3, hoveredIndex: 2) == 0.92)
        #expect(DensityGutterView.neighborhoodFactor(index: 5, hoveredIndex: 2) == 0.82)
    }

    @Test("Short documents use a wider resting gap")
    func shortDocumentSpacing() {
        #expect(DensityGutterView.restingMarkGap(count: 1) == 18)
        #expect(DensityGutterView.restingMarkGap(count: 2) == 18)
        #expect(DensityGutterView.restingMarkGap(count: 3) == 10)
        #expect(DensityGutterView.restingMarkGap(count: 8) == 10)

        let short = DensityGutterView.centeredBandYPositions(
            height: 800, count: 2, markGap: DensityGutterView.restingMarkGap(count: 2)
        )
        let dense = DensityGutterView.centeredBandYPositions(height: 800, count: 2, markGap: 10)
        #expect(short[1] - short[0] > dense[1] - dense[0])
    }

    @Test("Stack compression tightens gaps near the pointer")
    func stackCompressionNearPointer() {
        let resting = DensityGutterView.centeredBandYPositions(height: 800, count: 4)
        let compressed = DensityGutterView.centeredBandYPositions(
            height: 800,
            count: 4,
            pointerY: resting[1]
        )
        #expect(resting.count == 4)
        #expect(compressed.count == 4)
        let restGap = resting[2] - resting[1]
        let nearGap = compressed[2] - compressed[1]
        #expect(nearGap < restGap)
        #expect((compressed.first! + compressed.last!) / 2 == 400)
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
        #expect(positions == [385, 395, 405, 415])
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
