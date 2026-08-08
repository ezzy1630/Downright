import AppKit
import Foundation
import Testing

@testable import MarkdownRender

/// The motion system's own arithmetic, separate from any surface that uses it.
/// Everything here is a value type, so none of it needs a window — which is the
/// point: the parts of the animation system that can be wrong in a way a reader
/// would notice are all pure functions of state.
@Suite("Motion system")
struct MotionSystemTests {
    // MARK: - Settle

    /// The settle band is travel-scaled so a sub-unit spring never teleports
    /// across its last fraction — but scaling it *only* by travel scales the
    /// snap with the trip too.  A morph vessel crossing the window used to stop
    /// seven points short while still carrying ninety points per second, which
    /// is a visible clunk on the one frame a reader is watching most closely.
    @Test("A long trip lands, rather than stopping short of its target")
    func longTripsDoNotSnapVisibly() {
        var spring = Motion.SpringScalar(value: 0, perceptualDuration: Motion.springDeliberate)
        spring.target(800)

        var lastValue = spring.value
        var lastVelocity = spring.velocity
        var frames = 0
        while spring.advance(dt: 1.0 / 120.0), frames < 1000 {
            lastValue = spring.value
            lastVelocity = spring.velocity
            frames += 1
        }

        // `lastValue` is the final *drawn* frame: the settle happens inside the
        // call that returns false, so the gap a reader could see is the band
        // plus the one frame of travel still to come at that speed.
        let visibleGap = abs(800 - lastValue)
        let frameTravel = abs(lastVelocity) / 120
        #expect(visibleGap <= Motion.SpringScalar.maximumSettleBand + frameTravel)
        // Uncapped, this trip stopped seven points out. Guard the regression
        // in the units that matter rather than only against the constant.
        #expect(visibleGap < 1)
        // And it was barely moving when it stopped — an invisible landing needs
        // both: near the target *and* slow.
        #expect(abs(lastVelocity) < 25)
        #expect(spring.value == 800)
    }

    /// The cap must not swallow the travel-scaled floor: a spring whose entire
    /// range is a fraction of a unit still has to traverse it.
    @Test("The absolute cap never coarsens a sub-unit spring")
    func capDoesNotCoarsenSmallTravel() {
        var glow = Motion.SpringScalar(value: 0, perceptualDuration: Motion.springQuick)
        glow.target(0.12)
        var steps = 0
        while glow.advance(dt: 1.0 / 60.0), steps < 1000 { steps += 1 }
        // A 0.12 travel under a 0.5 cap would settle on frame one if the cap
        // applied blindly.
        #expect(steps > 4)
    }

    // MARK: - Interruption

    /// The whole reason the system is spring-based: a change of destination
    /// mid-flight is a change of *target*, not a new journey from a standstill.
    @Test("Retargeting mid-flight preserves velocity")
    func retargetingKeepsSpeed() {
        var spring = Motion.SpringScalar(value: 0, perceptualDuration: Motion.springStandard)
        spring.target(500)
        for _ in 0..<6 { _ = spring.advance(dt: 1.0 / 120.0) }

        let speedBefore = spring.velocity
        let positionBefore = spring.value
        #expect(speedBefore > 0)

        spring.target(900)
        // Neither the position nor the speed may jump on a retarget.
        #expect(spring.value == positionBefore)
        #expect(spring.velocity == speedBefore)
    }

    /// A snap is the opposite: an explicit teleport that grounds the motion.
    @Test("Snapping grounds both position and velocity")
    func snappingGrounds() {
        var spring = Motion.SpringScalar(value: 0, perceptualDuration: Motion.springStandard)
        spring.target(500)
        for _ in 0..<6 { _ = spring.advance(dt: 1.0 / 120.0) }
        spring.snap(to: 42)
        #expect(spring.value == 42)
        #expect(spring.velocity == 0)
    }

    // MARK: - Morph cut

    /// The content windows are offset with a deliberate hole between them.
    /// Overlapping crossfades read as a double image; the empty-glass gap is
    /// what makes a morph read as one thing *becoming* another.
    @Test("The morph cut leaves a gap where neither content is drawn")
    func morphCutHasAnEmptyGap() {
        // Departure: the source is whole at the start, gone by the handoff.
        #expect(Motion.MorphCut.outgoing(0) == 1)
        #expect(Motion.MorphCut.outgoing(Motion.MorphCut.handoff) == 0)
        #expect(Motion.MorphCut.outgoing(1) == 0)

        // Arrival: nothing before the gap closes, whole by the end.
        #expect(Motion.MorphCut.incoming(0) == 0)
        #expect(Motion.MorphCut.incoming(Motion.MorphCut.handoff) == 0)
        #expect(Motion.MorphCut.incoming(1) == 1)

        // The gap itself: a progress where *both* are invisible.
        let inGap: CGFloat = 0.32
        #expect(Motion.MorphCut.inFlight(inGap))
        #expect(Motion.MorphCut.outgoing(inGap) == 0)
        #expect(Motion.MorphCut.incoming(inGap) == 0)

        // And it is genuinely a hole, not a seam: the windows never overlap.
        for step in 0...100 {
            let p = CGFloat(step) / 100
            let both = Motion.MorphCut.outgoing(p) > 0 && Motion.MorphCut.incoming(p) > 0
            #expect(!both, "contents overlap at progress \(p)")
        }
    }

    /// Anything the container has to do belongs at the handoff rather than at
    /// the landing — by then no read text is on screen, so layout may change
    /// without appearing to move under the eye.
    @Test("The handoff sits inside the flight, not at either end")
    func handoffIsMidFlight() {
        #expect(Motion.MorphCut.handoff > 0)
        #expect(Motion.MorphCut.handoff < 1)
        #expect(!Motion.MorphCut.inFlight(0))
        #expect(!Motion.MorphCut.inFlight(1))
    }

    // MARK: - Staggered release

    /// A cascade schedules each step behind the last, and the *driver* is the
    /// only thing that knows time is passing.  A step that waits on a wall
    /// clock instead of on elapsed frames can only be released by an event —
    /// and a cascade is exactly the case where no further event is coming, so
    /// the later steps never appear while the display link spins at full
    /// refresh reporting them as still to do.
    @Test("A delayed spring releases from elapsed frames, not from an event")
    func delayedSpringsReleaseOnTheirOwn() {
        var pip = DensityGutterView.PipSimulation(
            centre: CGPoint.zero,
            diameter: 4,
            color: NSColor.systemRed.cgColor
        )
        pip.retarget(
            centre: CGPoint.zero,
            diameter: 4,
            color: NSColor.systemRed.cgColor,
            delay: Motion.previewStagger * 3,
            releaseNow: false
        )
        #expect(!pip.engaged)

        // Nothing but frames — no retarget, no event, no clock.
        var frames = 0
        while !pip.engaged, frames < 600 {
            _ = pip.advance(dt: 1.0 / 120.0)
            frames += 1
        }
        #expect(pip.engaged, "a scheduled step never joined the cascade")

        // And having joined, it must eventually settle so the driver can park.
        var settling = 0
        while pip.advance(dt: 1.0 / 120.0), settling < 2000 { settling += 1 }
        #expect(settling < 2000, "the driver would spin for ever on this pip")
    }

    // MARK: - Colour

    /// Colours spring in OKLab and are read back as sRGB, so the conversion
    /// has to be lossless enough that a spring sitting still on a colour does
    /// not drift off the one the theme asked for.
    @Test("A colour survives the round trip through OKLab")
    func colourRoundTrips() {
        let probes: [NSColor] = [
            .init(srgbRed: 0, green: 0, blue: 0, alpha: 1),
            .init(srgbRed: 1, green: 1, blue: 1, alpha: 1),
            .init(srgbRed: 0.20, green: 0.45, blue: 0.78, alpha: 1),
            .init(srgbRed: 0.93, green: 0.71, blue: 0.13, alpha: 0.6),
            .init(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1),
        ]
        for probe in probes {
            let settled = Motion.SpringColor(value: probe).value
            guard let a = probe.usingColorSpace(.sRGB),
                  let b = settled.usingColorSpace(.sRGB) else {
                Issue.record("probe did not convert to sRGB")
                continue
            }
            #expect(abs(a.redComponent - b.redComponent) < 0.001)
            #expect(abs(a.greenComponent - b.greenComponent) < 0.001)
            #expect(abs(a.blueComponent - b.blueComponent) < 0.001)
            #expect(abs(a.alphaComponent - b.alphaComponent) < 0.001)
        }
    }

    /// A grey arrives from the theme as a two-channel `GenericGray` colour.
    /// Read as raw components that is `(0, 0)` — which, taken as RGB, is opaque
    /// black.  Normalising through sRGB first is what keeps a grey grey.
    @Test("A greyscale colour does not spring through black")
    func greyscaleColoursSurvive() {
        var spring = Motion.SpringColor(value: .white)
        let white = spring.value.usingColorSpace(.sRGB)
        #expect((white?.redComponent ?? 0) > 0.95)
        #expect((white?.alphaComponent ?? 0) > 0.95)

        spring.target(.black)
        _ = spring.advance(dt: 1.0 / 120.0)
        // One frame in it is still nearly white, not already black.
        let stepped = spring.value.usingColorSpace(.sRGB)
        #expect((stepped?.redComponent ?? 0) > 0.5)
    }

    /// The reason for OKLab rather than raw sRGB channels: a transition
    /// between two equally-light hues must not dip through a dark, desaturated
    /// midpoint.  Gamma-encoded channel means do exactly that.
    @Test("A hue transition does not darken through its middle")
    func hueTransitionKeepsItsLightness() {
        let from = NSColor(srgbRed: 0.10, green: 0.45, blue: 0.85, alpha: 1)
        let to = NSColor(srgbRed: 0.95, green: 0.72, blue: 0.15, alpha: 1)
        let floor = min(
            Motion.OKLab.oklab(of: from).L,
            Motion.OKLab.oklab(of: to).L
        )

        var spring = Motion.SpringColor(value: from, perceptualDuration: Motion.springStandard)
        spring.target(to)
        var sampled = 0
        while spring.advance(dt: 1.0 / 120.0), sampled < 1000 {
            sampled += 1
            let lightness = Motion.OKLab.oklab(of: spring.value).L
            // Never darker than the darker end — a monotone climb, no dip.
            #expect(lightness >= floor - 0.01, "darkened to \(lightness) below \(floor)")
        }
        #expect(sampled > 4)
    }

    // MARK: - Scroll

    /// A three-line hop and a cross-chapter descent must not cost the same.
    /// Spring settle time is otherwise a constant, so the distance scaling is
    /// carried by retuning rather than emerging on its own.
    @Test("Scroll duration scales with distance, within the system's bounds")
    func scrollDurationScales() {
        let hop = Motion.scrollDuration(for: 40)
        let page = Motion.scrollDuration(for: 900)
        let chapter = Motion.scrollDuration(for: 6000)
        #expect(hop < page)
        #expect(page < chapter)
        // Neither extreme leaves the vocabulary.
        #expect(hop >= 0.18)
        #expect(chapter <= 0.55)
        #expect(Motion.scrollDuration(for: 0) == 0.18)
        // Negative distance is nonsense, not a crash.
        #expect(Motion.scrollDuration(for: -100) == 0.18)
    }
}
