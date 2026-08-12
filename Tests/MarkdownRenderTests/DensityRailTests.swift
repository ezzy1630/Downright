import AppKit
import Foundation
import MarkdownCore
import Testing

@testable import MarkdownRender

@Suite("Density rail")
struct DensityRailTests {
    @Test("Detached preview inherits the sheet appearance")
    @MainActor
    func previewUsesResolvedAppearance() {
        let light = NSAppearance(named: .aqua) ?? NSApp.effectiveAppearance
        let dark = NSAppearance(named: .darkAqua) ?? NSApp.effectiveAppearance
        let window = DensityGutterPreviewWindow(
            styleSheet: StyleSheet(theme: ThemeStore.shared.current, appearance: light)
        )
        #expect(window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua)

        window.styleSheet = StyleSheet(theme: ThemeStore.shared.current, appearance: dark)
        #expect(window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        #expect(window.contentView?.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

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
        #expect(DensityGutterView.jumpPunchBoost == 4)
        #expect(Motion.springQuick == 0.12)
        #expect(Motion.springStandard == 0.20)
        #expect(Motion.springDeliberate == 0.32)
        #expect(Motion.jumpPunchKick == 480)
        #expect(Motion.breathe == Motion.quick)
        #expect(Motion.previewStagger == Motion.quick / 3)
        #expect(DensityOutlineWindow.rowHeight == 44)
        #expect(DensityOutlineWindow.cornerRadius == 14)
        #expect(DensityOutlineWindow.showDwell == 0.25)
        #expect(DensityOutlineWindow.showDuration == 0.12)
        #expect(DensityOutlineWindow.hideDuration == 0.09)
    }

    @Test("Leading preview stays inside the page margin")
    func previewWidthRespectsTextBoundary() {
        #expect(DensityGutterPreviewWindow.resolvedMaximumWidth(
            anchorX: 72,
            maximumTrailingX: 412,
            opensInward: false
        ) == 320)
        #expect(DensityGutterPreviewWindow.resolvedMaximumWidth(
            anchorX: 72,
            maximumTrailingX: 360,
            opensInward: false
        ) == 280)
        // A ~1020pt window leaves ~166pt of margin beside the wall-pinned
        // rail: the card shrinks into it rather than vanishing.
        #expect(DensityGutterPreviewWindow.resolvedMaximumWidth(
            anchorX: 72,
            maximumTrailingX: 246,
            opensInward: false
        ) == 166)
        #expect(DensityGutterPreviewWindow.resolvedMaximumWidth(
            anchorX: 72,
            maximumTrailingX: 220,
            opensInward: false
        ) == 140)
        #expect(DensityGutterPreviewWindow.resolvedMaximumWidth(
            anchorX: 72,
            maximumTrailingX: 200,
            opensInward: false
        ) == nil)
        #expect(DensityGutterPreviewWindow.resolvedMaximumWidth(
            anchorX: 800,
            maximumTrailingX: nil,
            opensInward: true
        ) == 320)
        #expect(DensityGutterPreviewWindow.resolvedMaximumWidth(
            anchorX: -40,
            maximumTrailingX: 300,
            minimumOriginX: 4,
            opensInward: false
        ) == 296)
    }

    /// The integrator is the closed-form damped-harmonic solution, so where
    /// the state lands after any elapsed time is a pure function of that time
    /// — a dropped 33 ms frame lands exactly where the 120 Hz stream would
    /// have, instead of Euler's error accumulating.  Advancing half twice
    /// must land exactly where advancing once lands, mid-flight.
    @Test("Spring integration is frame-rate independent")
    func springIsFrameRateIndependent() {
        for dt: CGFloat in [1.0 / 120.0, 1.0 / 60.0, 1.0 / 30.0] {
            var whole = Motion.SpringScalar(value: 0, perceptualDuration: Motion.springQuick)
            whole.target(100)
            var split = Motion.SpringScalar(value: 0, perceptualDuration: Motion.springQuick)
            split.target(100)
            _ = whole.advance(dt: dt)
            _ = split.advance(dt: dt / 2)
            _ = split.advance(dt: dt / 2)
            #expect(abs(whole.value - split.value) < 1e-9)
            #expect(abs(whole.velocity - split.velocity) < 1e-9)
        }
    }

    /// A sub-unit trip (glow 0 → 0.12, breathe 1 → 1.08) used to settle on an
    /// absolute tolerance and teleport across its last fraction.  The band is
    /// travel-scaled now, but the rule under test is the same: a finite step
    /// count must never jump the full travel.
    @Test("Sub-unit springs traverse the travel instead of teleporting")
    func subUnitSpringsTraverse() {
        var glow = Motion.SpringScalar(value: 0, perceptualDuration: Motion.springQuick)
        glow.target(0.12)
        _ = glow.advance(dt: 1.0 / 120.0)
        #expect(glow.value > 0)
        #expect(glow.value < 0.12)
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

    /// With an adaptive pitch a fixed 4pt hover row leaves a gap between marks
    /// that resolves to no mark at all, so the preview blinks out on every
    /// crossing.  The row has to scale with the spacing.
    @Test("Hover hands over between marks with no dead band")
    func hoverHandover() {
        let tight: [CGFloat] = [100, 109, 118]
        let wide: [CGFloat] = [100, 120, 140]
        #expect(DensityGutterView.dismissalSlop(for: tight) == 4.5)
        #expect(DensityGutterView.dismissalSlop(for: wide) == 10)
        // Never below the floor, and defined for a lone mark.
        #expect(DensityGutterView.dismissalSlop(for: [100, 104]) == 4)
        #expect(DensityGutterView.dismissalSlop(for: [100]) == 4)

        // Every point between two marks resolves to one of them.
        let slop = DensityGutterView.dismissalSlop(for: wide)
        for step in 0...40 {
            let y = 100 + CGFloat(step) / 2
            let index = DensityGutterView.nextHoveredBandIndex(
                at: y,
                positions: wide,
                currentIndex: 0,
                activationSlop: DensityGutterView.hoverActivationSlop,
                dismissalSlop: slop
            )
            #expect(index != nil)
        }
    }

    @Test("Proximity falloff is smooth and heading marks share one rhythm")
    func proximityAndHeadingWidths() {
        #expect(DensityGutterView.proximityInfluence(distance: 0) == 1)
        #expect(DensityGutterView.proximityInfluence(distance: 36) == 0)
        let mid = DensityGutterView.proximityInfluence(distance: 18)
        #expect(mid > 0.4 && mid < 0.6)

        #expect(DensityGutterView.headingMarkWidth(level: 1) == 26)
        #expect(DensityGutterView.headingMarkWidth(level: 2) == 26)
        #expect(DensityGutterView.headingMarkWidth(level: 3) == 26)
        #expect(DensityGutterView.headingMarkWidth(level: 4) == 26)
        #expect(DensityGutterView.headingMarkWidth(level: 1, emphasized: true) == 32)
        #expect(DensityGutterView.headingMarkWidth(level: 2, emphasized: true) == 32)
        #expect(DensityGutterView.headingMarkWidth(level: 3, emphasized: true) == 32)
        #expect(DensityGutterView.headingMarkWidth(level: 4, emphasized: true) == 32)
    }

    /// The rail's hover regression, as a clock rule.
    ///
    /// Every pointer event arms the driver, and arming used to re-base the
    /// clock.  Mouse events and the display link share the main run loop, so an
    /// event landing shortly before a frame left that frame only the sliver of
    /// time since the event to integrate — and a continuous hover retargets at
    /// the event rate, so nearly every frame's elapsed time was thrown away.
    /// The springs crawled while the pointer moved and completed the instant it
    /// stopped: motion in glue.  Arming a running clock must be inert.
    @Test("Arming a running driver never swallows elapsed time")
    func armingDoesNotRebaseTheClock() {
        var clock = Motion.FrameClock()
        #expect(clock.start(now: 0) == true)
        #expect(clock.isRunning)

        let frame: CFTimeInterval = 1.0 / 120.0
        #expect(abs(clock.tick(now: frame) - CGFloat(frame)) < 1e-9)

        // A pointer event arrives mid-frame and arms the already-running
        // driver.  It must report "already running" and touch nothing.
        #expect(clock.start(now: frame * 1.9) == false)

        // The next frame therefore still integrates a whole frame, not the
        // sliver between the event and the tick.
        #expect(abs(clock.tick(now: frame * 2) - CGFloat(frame)) < 1e-9)

        clock.stop()
        #expect(!clock.isRunning)
        #expect(clock.start(now: 99) == true)
    }

    /// A parked driver re-armed after an idle spell starts from *now*, so the
    /// first frame back is one frame long — never the whole idle gap replayed
    /// into the springs as a teleport.
    @Test("Re-arming after a park starts the clock fresh")
    func reArmingStartsFresh() {
        var clock = Motion.FrameClock()
        clock.start(now: 100)
        _ = clock.tick(now: 100.5)
        clock.stop()
        clock.start(now: 900)
        #expect(abs(clock.tick(now: 900.01) - 0.01) < 1e-9)
    }

    @Test("Neighbourhood dim softens distant marks under hover")
    func neighborhoodDimPolicy() {
        #expect(DensityGutterView.neighborhoodFactor(index: 2, hoveredIndex: nil) == 1)
        #expect(DensityGutterView.neighborhoodFactor(index: 2, hoveredIndex: 2) == 1)
        #expect(DensityGutterView.neighborhoodFactor(index: 3, hoveredIndex: 2) == 0.92)
        #expect(DensityGutterView.neighborhoodFactor(index: 5, hoveredIndex: 2) == 0.82)
    }

    /// The whole point of the sizing rules: the cluster is a share of the rail,
    /// not a fixed cluster that is a huddle in a tall window and a solid bar in
    /// a short one.
    @Test("Stack span scales with the rail and never fills or collapses it")
    func stackSpanEnvelope() {
        for height in stride(from: 120.0, through: 1600.0, by: 20.0) {
            let track = DensityGutterView.trackRange(height: CGFloat(height))
            let trackHeight = track.bottom - track.top
            let capacity = DensityGutterView.stackCapacity(track: trackHeight)
            guard capacity >= DensityGutterView.minimumStackMarks else { continue }

            let pitch = DensityGutterView.markPitch(track: trackHeight, count: capacity)
            #expect(pitch >= DensityGutterView.minPitch)
            #expect(pitch <= DensityGutterView.maxPitch)

            let positions = DensityGutterView.centeredBandYPositions(
                height: CGFloat(height), count: capacity, markGap: pitch
            )
            let span = positions.last! - positions.first!
            // Never a second scrollbar…
            #expect(span <= trackHeight * DensityGutterView.maxSpanFraction + 0.001)
            // …and never a lonely dash in an empty column.  The stack is
            // deliberately condensed, so the floor is the tightest a full
            // stack gets in a tall window: (ceiling − 1) × maxPitch.
            #expect(span >= trackHeight * 0.12)
            // Stays inside the track it was measured against.
            #expect(positions.first! >= track.top - 0.001)
            #expect(positions.last! <= track.bottom + 0.001)
        }
    }

    @Test("Capacity follows the track instead of a fixed mark budget")
    func capacityFollowsTrack() {
        let tall = DensityGutterView.stackCapacity(track: 1344)
        let medium = DensityGutterView.stackCapacity(track: 244)
        let short = DensityGutterView.stackCapacity(track: 44)
        let tiny = DensityGutterView.stackCapacity(track: 20)

        #expect(tall == DensityGutterView.stackCapacityCeiling)
        #expect(medium > short)
        #expect(short > tiny)
        #expect(tiny < DensityGutterView.minimumStackMarks)

        // A short rail thins rather than squeezing marks under the legible pitch.
        for track in stride(from: 40.0, through: 1600.0, by: 4.0) {
            let capacity = DensityGutterView.stackCapacity(track: CGFloat(track))
            guard capacity > 1 else { continue }
            let pitch = DensityGutterView.markPitch(track: CGFloat(track), count: capacity)
            #expect(CGFloat(capacity - 1) * pitch <= CGFloat(track) + 0.001)
        }
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
        #expect(DensityGutterView.isOverlay(.change(.modified)))
        #expect(DensityGutterView.isOverlay(.searchHit))
        #expect(!DensityGutterView.isOverlay(.codeBlock))
        #expect(!DensityGutterView.isOverlay(.table))
        #expect(!DensityGutterView.isOverlay(.math))
        #expect(!DensityGutterView.isOverlay(.taskList))
        #expect(!DensityGutterView.isOverlay(.image))
        #expect(!DensityGutterView.isOverlay(.callout))
    }

    /// Body-shape bands are kept for the hover preview, so the rail has to
    /// exclude them itself rather than relying on the band builder.
    @Test("Body-shape bands become neither marks nor pips")
    func bodyBandsAreNotIndexed() {
        let bands = [
            heading(1, 0.0),
            DensityBand(kind: .codeBlock, startFraction: 0.1, endFraction: 0.2),
            heading(1, 0.3),
            DensityBand(kind: .table, startFraction: 0.4, endFraction: 0.5),
            DensityBand(kind: .callout, startFraction: 0.55, endFraction: 0.6),
            heading(1, 0.7),
            DensityBand(kind: .image, startFraction: 0.8, endFraction: 0.85),
        ]

        let selection = DensityGutterView.selection(for: bands, capacity: 20)
        #expect(selection.marks.count == 3)
        #expect(levels(selection.marks) == [1, 1, 1])
        #expect(selection.pips.allSatisfy { $0.isEmpty })
    }

    @Test("Outline state keeps heading position and current marker")
    func outlineEntryState() {
        let entry = DensityOutlineEntry(title: "Section", level: 2, fraction: 0.4, isCurrent: true)
        #expect(entry == DensityOutlineEntry(title: "Section", level: 2, fraction: 0.4, isCurrent: true))
        #expect(entry != DensityOutlineEntry(title: "Section", level: 2, fraction: 0.4, isCurrent: false))
    }

    @Test("Document-map marks stay centered in the viewport")
    func centeredBandPositions() {
        let positions = DensityGutterView.centeredBandYPositions(
            height: 800, count: 4, markGap: 20
        )

        #expect(positions.count == 4)
        #expect(positions == [370, 390, 410, 430])
        #expect((positions.first! + positions.last!) / 2 == 400)
    }

    // MARK: - Selection

    private func heading(_ level: Int, _ fraction: CGFloat) -> DensityBand {
        DensityBand(kind: .heading(level: level), startFraction: fraction, endFraction: fraction)
    }

    private func levels(_ bands: [DensityBand]) -> [Int] {
        bands.map { band in
            if case .heading(let level) = band.kind { return level }
            return -1
        }
    }

    /// Index-stride thinning could keep an H3 while dropping the H1 that
    /// contains it, so the rail described a shape the document has not got.
    @Test("Thinning drops depth before it drops position")
    func depthBudgetKeepsStructure() {
        var bands: [DensityBand] = []
        for index in 0..<4 {
            bands.append(heading(1, CGFloat(index) * 0.25))
            for child in 1...4 {
                bands.append(heading(3, CGFloat(index) * 0.25 + CGFloat(child) * 0.04))
            }
        }

        let selected = DensityGutterView.selectHeadings(bands, capacity: 6)
        #expect(selected.count <= 6)
        // Every H1 survives; the H3s are what gets thinned.
        #expect(levels(selected).filter { $0 == 1 }.count == 4)
        #expect(selected.map(\.startFraction).sorted() == selected.map(\.startFraction))
    }

    /// One H1 and forty H2s used to draw a single tick: the deepest depth that
    /// fits whole is the H1 on its own.
    @Test("Spare capacity is filled from the next depth down")
    func depthBudgetFillsSpareSlots() {
        var bands = [heading(1, 0)]
        for index in 0..<40 {
            bands.append(heading(2, CGFloat(index + 1) / 41))
        }

        let selected = DensityGutterView.selectHeadings(bands, capacity: 12)
        #expect(selected.count == 12)
        #expect(levels(selected).contains(1))
        #expect(levels(selected).filter { $0 == 2 }.count == 11)
    }

    @Test("A document shallower than capacity keeps every heading")
    func depthBudgetKeepsShallowDocuments() {
        let bands = (0..<5).map { heading($0 % 3 + 1, CGFloat($0) / 5) }
        #expect(DensityGutterView.selectHeadings(bands, capacity: 20).count == 5)
    }

    /// Thinning used to run over the merged band list, so a Find with many
    /// matches could evict the outline it was meant to annotate.
    @Test("Overlay volume never reduces the heading stack")
    func overlaysDoNotEvictHeadings() {
        let headings = (0..<8).map { heading(1, CGFloat($0) / 8) }
        let hits = (0..<400).map {
            DensityBand(
                kind: .searchHit,
                startFraction: CGFloat($0) / 400,
                endFraction: CGFloat($0) / 400
            )
        }

        let clean = DensityGutterView.selection(for: headings, capacity: 20)
        let noisy = DensityGutterView.selection(for: headings + hits, capacity: 20)

        #expect(clean.marks.count == 8)
        #expect(noisy.marks.count == 8)
        #expect(noisy.pips.allSatisfy { $0.searchHit })
    }

    @Test("Overlay pips are opt-in on the reading rail")
    @MainActor
    func overlayPipsAreOptIn() {
        let view = DensityGutterView()
        #expect(!view.showsOverlayPips)

        let bands = [
            heading(1, 0.1),
            DensityBand(kind: .change(.modified), startFraction: 0.15, endFraction: 0.16),
            DensityBand(kind: .searchHit, startFraction: 0.17, endFraction: 0.18),
        ]
        let selection = DensityGutterView.selection(
            for: bands,
            capacity: 8,
            includeOverlays: false
        )
        #expect(selection.marks.count == 1)
        #expect(selection.pips.allSatisfy { $0.isEmpty })
    }

    /// An overlay belongs to the section it falls in, not to whichever mark is
    /// physically closest — a change at the top of a section is not the
    /// previous section's change.
    @Test("Pips attach to the enclosing section")
    func pipsAttachToEnclosingSection() {
        let marks = [heading(1, 0.0), heading(1, 0.5), heading(1, 0.9)]
        let overlays = [
            DensityBand(kind: .change(.inserted), startFraction: 0.52, endFraction: 0.55),
            DensityBand(kind: .searchHit, startFraction: 0.95, endFraction: 0.96),
            // Before every heading — front matter belongs to the first section.
            DensityBand(kind: .change(.deleted), startFraction: 0.0, endFraction: 0.0),
        ]

        let pips = DensityGutterView.pips(for: overlays, on: marks)
        #expect(pips[0].change == .deleted)
        #expect(pips[1].change == .inserted)
        #expect(pips[1].searchHit == false)
        #expect(pips[2].searchHit)
        #expect(pips[2].change == nil)
    }

    @Test("Mixed change kinds in one section report as modified")
    func mixedChangesCollapseToModified() {
        let marks = [heading(1, 0.0), heading(1, 0.5)]
        let overlays = [
            DensityBand(kind: .change(.inserted), startFraction: 0.1, endFraction: 0.1),
            DensityBand(kind: .change(.deleted), startFraction: 0.2, endFraction: 0.2),
        ]
        #expect(DensityGutterView.pips(for: overlays, on: marks)[0].change == .modified)
    }

    /// Sparse documents still need a hover target for their available
    /// headings. Only a rail that is physically too short suppresses its
    /// stack.
    @Test("Sparse documents keep their available heading anchors")
    func sparseDocumentsKeepHeadingAnchors() {
        let two = (0..<2).map { heading(1, CGFloat($0) / 2) }
        #expect(DensityGutterView.selection(for: two, capacity: 20).marks.count == 2)

        let three = (0..<3).map { heading(1, CGFloat($0) / 3) }
        #expect(DensityGutterView.selection(for: three, capacity: 20).marks.count == 3)

        // A tiny rail suppresses the stack rather than packing marks into an
        // unreadable bar.
        let many = (0..<40).map { heading(1, CGFloat($0) / 40) }
        let tinyCapacity = DensityGutterView.stackCapacity(track: 20)
        #expect(DensityGutterView.selection(for: many, capacity: tinyCapacity).marks.isEmpty)
    }

    /// A document with no headings still has to show its review state.
    @Test("Heading-less documents index their overlays instead")
    func headinglessDocumentsIndexOverlays() {
        let changes = (0..<6).map {
            DensityBand(
                kind: .change(.modified),
                startFraction: CGFloat($0) / 6,
                endFraction: CGFloat($0) / 6
            )
        }
        let selection = DensityGutterView.selection(for: changes, capacity: 20)
        #expect(selection.marks.count == 6)
        #expect(selection.pips.allSatisfy { $0.isEmpty })
    }

    @Test("Stride sampling keeps the ends so the cluster still spans the whole")
    func strideSamplingKeepsEnds() {
        let bands = (0..<40).map { heading(1, CGFloat($0) / 40) }
        let sampled = DensityGutterView.strideSampled(bands, limit: 9)
        #expect(sampled.count == 9)
        #expect(sampled.first!.startFraction == bands.first!.startFraction)
        #expect(sampled.last!.startFraction == bands.last!.startFraction)
        #expect(DensityGutterView.strideSampled(bands, limit: 1).count == 1)
        #expect(DensityGutterView.strideSampled(bands, limit: 0).isEmpty)
        #expect(DensityGutterView.strideSampled(bands, limit: 100).count == 40)
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

    @Test("Pointer wobble remains a smooth click; deliberate travel becomes scrubbing")
    func scrubActivationHasARealThreshold() {
        let origin = NSPoint(x: 20, y: 100)
        #expect(!DensityGutterView.shouldBeginScrub(
            from: origin, to: NSPoint(x: 21, y: 102)
        ))
        #expect(DensityGutterView.shouldBeginScrub(
            from: origin, to: NSPoint(x: 20, y: 104)
        ))
    }
}
