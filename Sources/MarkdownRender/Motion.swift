import AppKit
import QuartzCore

/// One timing authority for document and chrome motion (§11.4).
///
/// The system is three durations.  A control that wants a fourth is almost
/// always asking for one of these three and guessing; anything genuinely
/// outside the system is declared below, named, and justified, so the count of
/// distinct timings in the app stays countable.
///
/// Two vocabularies sit on top of the three durations.
///
/// * **Beziers** (`timing(_:)`) for NSAnimationContext's curve-only transport —
///   `NSAnimationContext.timingFunction` accepts a `CAMediaTimingFunction`
///   and nothing else, so every `Motion.run` carriage is a bezier.
/// * **Springs** for everything the pointer drives directly.  A spring is
///   state-first — position *and* velocity — so an interrupted trip resumes
///   at its own speed instead of restarting from zero, and the trip takes
///   however long physics says.  A single scalar integrator (`SpringScalar`,
///   the closed-form damped harmonic solution) carries them per frame under
///   the surfaces' display-link drivers.  `perceptualDuration` speaks the
///   same numbers as the three durations so "countable timings" survives;
///   `bounce` is the same parameterisation SwiftUI's `Spring` uses.
public enum Motion {
    /// Feedback that must not be noticed: hover, press, a colour warming.
    public static let quick: TimeInterval = 0.12
    /// A state change the reader is watching: a check drawing, a thumb sliding.
    public static let standard: TimeInterval = 0.20
    /// A structural change: a panel's contents arriving, an arc travelling.
    public static let deliberate: TimeInterval = 0.32

    /// Perceptual settle for native glass changing topology. Glass needs one
    /// extra breath for refraction, geometry, and content to land as one body;
    /// ordinary structural UI continues to use `deliberate`.
    public static let liquidSettle: TimeInterval = 0.38

    /// Pointer feedback, the tier below `quick`.
    ///
    /// These live here rather than beside the controls that use them because
    /// "one timing authority" has to mean *all* of them.  The toolbar, the task
    /// ring, the panel buttons, and the breadcrumb each grew a private set of
    /// numbers, and once four vocabularies exist nobody can answer what a hover
    /// costs in this app — the surfaces drift apart by a frame or two, which is
    /// exactly the difference between a UI that feels made and one that feels
    /// assembled.
    ///
    /// The press pair is deliberately asymmetric, for the same reason the
    /// density rail's is: pressing should feel instant and releasing should
    /// feel like settling, so `pressOut` is slower than `pressIn`.  The rail
    /// no longer hand-tunes a grow/shrink pair — continuous pointer proximity
    /// springs out of the pointer's own speed, not out of two durations.
    public static let hover: TimeInterval = 0.10
    public static let pressIn: TimeInterval = 0.07
    public static let pressOut: TimeInterval = 0.11
    /// A selection indicator travelling between segments.
    public static let selection: TimeInterval = 0.15
    /// A control briefly asserting itself — a value flashing as it commits.
    public static let emphasis: TimeInterval = 0.11

    /// Whole-rail breathe on pointer enter / leave.
    public static let breathe: TimeInterval = quick
    /// Preview title lands first; snippet follows.
    public static let previewStagger: TimeInterval = quick / 3

    /// Crossfade when the rail's preview swaps to a different section while the
    /// pointer is already inside it.
    ///
    /// Shorter than anything else in the system, on purpose: the preview is
    /// tracking the pointer, so this is not a transition the reader is meant to
    /// perceive — it exists only to keep the swap from tearing. Long enough to
    /// hide the seam, short enough that the panel still feels welded to the
    /// cursor.
    public static let previewCrossfade: TimeInterval = 0.06

    /// The empty-glass handoff has a deliberately short lead before incoming
    /// panel content appears. It is not another animation duration: it is the
    /// staging window inside `MorphCut`, long enough for the material to read
    /// as continuous and short enough that the destination never feels late.
    public static let floatingContentRevealLead: TimeInterval = 0.08

    /// The visible sliver is already a real material edge, so it starts close
    /// to full presence. The surface reaches 1.0 during the first quarter of
    /// its height travel; the rest of the arrival is a pour, not a fade.
    public static let floatingSurfaceSliverOpacity: CGFloat = 0.82
    /// Presence is settled by the first quarter of the structural spring. This
    /// is the smallest useful staging window: below it the material still
    /// looks absent, above it the arrival reads as a fade-plus-grow.
    public static let floatingSurfacePresenceFraction: CGFloat = 0.25

    /// The density rail's impulse, and the only declared exception.
    ///
    /// Everything the rail does is now spring-governed, so its grow, shrink and
    /// settle were all absorbed into `SpringScalar` (asymmetries emerge from
    /// pointer speed, not from a hand-tuned pair of durations).  What remains
    /// is the one non-spring moment: the velocity kick when a jump lands
    /// (points per second, applied to the mark's width spring so the punch
    /// swells and settles through the same physics as everything else).
    public static let jumpPunchKick: CGFloat = 480

    // MARK: - Springs

    /// The three springs, mirroring the three durations.  `perceptualDuration`
    /// is the time the motion takes to stop registering, so a rail that used to
    /// cost `Motion.standard` still costs `Motion.standard`.
    ///
    /// The mode springs are carried by `SpringScalar`; there is no
    /// `CASpringAnimation` in the vocabulary because CA's initial-velocity
    /// parameter is normalised by the from→to distance and cannot take a raw
    /// sampled velocity — the state a handoff actually has.
    public static let springQuick: TimeInterval = quick
    public static let springStandard: TimeInterval = standard
    public static let springDeliberate: TimeInterval = deliberate

    /// A scalar spring for per-frame integration.
    ///
    /// This is the form springs take under a `CADisplayLink` driver: the
    /// surface holds `(value, velocity)`, retargets on every input event, and
    /// `advance(dt:)` each frame.  Velocity is state, never a reset — an
    /// interrupted trip keeps the speed it had, which is the difference a
    /// fixed-duration bezier visually cannot express.
    ///
    /// The integrator is the damped-harmonic closed form evaluated exactly at
    /// the requested `dt` — not a step-wise Euler — so it is unconditionally
    /// stable at any frame rate (a dropped 33 ms frame lands in exactly the
    /// same place the 120 Hz stream would have) and `perceptualDuration`
    /// delivers the duration it claims.  `bounce` runs 0…1 (0 = critically
    /// damped, 1 = bouncy), the same parameterisation SwiftUI's `Spring` uses.
    public struct SpringScalar {
        public private(set) var value: CGFloat
        public private(set) var velocity: CGFloat
        public let angularFrequency: CGFloat
        public let dampingRatio: CGFloat
        private var targetValue: CGFloat
        /// Travel-scaled settle band: ~0.8% of the retargeted distance, so a
        /// sub-unit spring (glow, breathe, colour) never teleports across its
        /// final fraction.  Recomputed when the target moves.
        ///
        /// Capped absolutely by `maximumSettleBand`, because a purely relative
        /// band scales the *snap* with the trip.  A rail mark travelling 12 pt
        /// stops 0.1 pt short at 1.4 pt/s — nobody can see that.  A morph
        /// vessel travelling 800 pt stopped 7 pt short while still carrying
        /// 90 pt/s, which is a visible clunk on the one frame the reader is
        /// watching most closely: the landing.  The cap costs a short tail of
        /// sub-pixel ticking and buys a landing that arrives instead of
        /// stopping.
        private var settleBand: CGFloat

        /// Half a point — one device pixel at 2x, and about 0.06 pt of travel
        /// per frame at the velocity this band implies. Below perception in
        /// both position and speed.
        static let maximumSettleBand: CGFloat = 0.5
        /// The floor, for springs whose whole range is a fraction of a unit.
        static let minimumSettleBand: CGFloat = 0.0006

        /// The ~95% settle constant for a critically damped spring:
        /// (1 + ωt) e^(−ωt) = 0.05 ⇒ ωt ≈ 4.74.
        static let windup: CGFloat = 4.744

        public init(
            value: CGFloat = 0,
            velocity: CGFloat = 0,
            perceptualDuration: TimeInterval = Motion.springStandard,
            bounce: CGFloat = 0
        ) {
            self.value = value
            self.velocity = velocity
            let tau = CGFloat(max(0.02, perceptualDuration))
            self.angularFrequency = Self.windup / tau
            self.dampingRatio = max(0, 1 - bounce * 0.7)
            self.targetValue = value
            self.settleBand = Self.minimumSettleBand
        }

        /// Re-launch the same state at a new perceptual duration — used when a
        /// mark upgrades from pointer tracking to a structural settle.  A
        /// non-nil `bounce` re-tunes the character of the spring with it (the
        /// morph vessel rises to a soft underdamped landing); nil keeps the
        /// current character.
        public mutating func retune(perceptualDuration: TimeInterval, bounce: CGFloat? = nil) {
            guard perceptualDuration > 0.02 else { return }
            let heldTarget = targetValue
            let heldBounce = bounce ?? (dampingRatio < 1 ? (1 - dampingRatio) / 0.7 : 0)
            let newSpring = Self(
                value: value,
                velocity: velocity,
                perceptualDuration: perceptualDuration,
                bounce: heldBounce
            )
            self = newSpring
            targetValue = heldTarget
        }

        /// Teleport to a value — Reduce Motion, layout passes, brand-new marks.
        public mutating func snap(to target: CGFloat) {
            value = target
            velocity = 0
            targetValue = target
            settleBand = Self.minimumSettleBand
        }

        public mutating func target(_ target: CGFloat) {
            guard target != targetValue else { return }
            settleBand = min(
                max(abs(target - value) * 0.008, Self.minimumSettleBand),
                Self.maximumSettleBand
            )
            targetValue = target
        }

        /// A velocity kick; the spring turns it into a swell-and-settle on its
        /// own. Points-per-second.
        public mutating func kick(_ impulse: CGFloat) {
            velocity += impulse
        }

        /// Integrate exactly through `dt` and settle once inside the
        /// travel-scaled band (with near-zero velocity). Returns `false` once
        /// settled, so a driver can park.
        @discardableResult
        public mutating func advance(dt: CGFloat) -> Bool {
            let dt = max(0, dt)
            let omega = angularFrequency
            let zeta = dampingRatio
            let x0 = value - targetValue
            let v0 = velocity
            let damped = zeta * omega
            let exponent = exp(-damped * dt)

            let x: CGFloat
            let v: CGFloat
            if zeta >= 1 - 0.000_001 {
                // Critically damped:  x(t) = e^(−ωt) (A + Bt).
                let s = sqrt(max(0, zeta * zeta - 1)) * omega
                if s > 0.000_001 {
                    // Overdamped (unreachable: dampingRatio ≥ 0.3): the two
                    // real roots, kept exact for completeness.
                    let lambdaPlus = -damped + s
                    let lambdaMinus = -damped - s
                    let c1 = (v0 + (damped + s) * x0) / (2 * s)
                    let c2 = x0 - c1
                    x = c1 * exp(lambdaPlus * dt) + c2 * exp(lambdaMinus * dt)
                    v = c1 * lambdaPlus * exp(lambdaPlus * dt) + c2 * lambdaMinus * exp(lambdaMinus * dt)
                } else {
                    let a = x0
                    let b = v0 + omega * x0
                    x = exponent * (a + b * dt)
                    v = exponent * (b - omega * (a + b * dt))
                }
            } else {
                // Underdamped:  e^(−ζωt) (A cos ωd t + B sin ωd t).
                let omegaD = omega * sqrt(max(0, 1 - zeta * zeta))
                let a = x0
                let b = omegaD > 0.000_001 ? (v0 + damped * x0) / omegaD : 0
                let ct = cos(omegaD * dt)
                let st = sin(omegaD * dt)
                x = exponent * (a * ct + b * st)
                v = exponent * ((b * omegaD - a * damped) * ct - (a * omegaD + b * damped) * st)
            }

            if abs(x) < settleBand && abs(v) < settleBand * omega {
                value = targetValue
                velocity = 0
                return false
            }
            value = targetValue + x
            velocity = v
            return true
        }

        public var target: CGFloat { targetValue }
    }

    // MARK: - Composed springs

    /// Two scalar springs as one point.
    public struct SpringPoint {
        public var x: SpringScalar
        public var y: SpringScalar

        public init(value: CGPoint = .zero, perceptualDuration: TimeInterval = Motion.springStandard, bounce: CGFloat = 0) {
            x = SpringScalar(value: value.x, perceptualDuration: perceptualDuration, bounce: bounce)
            y = SpringScalar(value: value.y, perceptualDuration: perceptualDuration, bounce: bounce)
        }

        public var value: CGPoint { CGPoint(x: x.value, y: y.value) }
        public var target: CGPoint { CGPoint(x: x.target, y: y.target) }

        public mutating func snap(to value: CGPoint) {
            x.snap(to: value.x)
            y.snap(to: value.y)
        }

        public mutating func target(_ value: CGPoint) {
            x.target(value.x)
            y.target(value.y)
        }

        public mutating func retune(perceptualDuration: TimeInterval) {
            x.retune(perceptualDuration: perceptualDuration)
            y.retune(perceptualDuration: perceptualDuration)
        }

        public mutating func retune(perceptualDuration: TimeInterval, bounce: CGFloat?) {
            x.retune(perceptualDuration: perceptualDuration, bounce: bounce)
            y.retune(perceptualDuration: perceptualDuration, bounce: bounce)
        }

        @discardableResult
        public mutating func advance(dt: CGFloat) -> Bool {
            var moving = false
            moving = x.advance(dt: dt) || moving
            moving = y.advance(dt: dt) || moving
            return moving
        }
    }

    /// Two scalars as one size.
    public struct SpringSize {
        public var width: SpringScalar
        public var height: SpringScalar

        public init(value: CGSize = .zero, perceptualDuration: TimeInterval = Motion.springStandard, bounce: CGFloat = 0) {
            width = SpringScalar(value: value.width, perceptualDuration: perceptualDuration, bounce: bounce)
            height = SpringScalar(value: value.height, perceptualDuration: perceptualDuration, bounce: bounce)
        }

        public var value: CGSize { CGSize(width: width.value, height: height.value) }
        public var target: CGSize { CGSize(width: width.target, height: height.target) }

        public mutating func snap(to value: CGSize) {
            width.snap(to: value.width)
            height.snap(to: value.height)
        }

        public mutating func target(_ value: CGSize) {
            width.target(value.width)
            height.target(value.height)
        }

        public mutating func retune(perceptualDuration: TimeInterval) {
            width.retune(perceptualDuration: perceptualDuration)
            height.retune(perceptualDuration: perceptualDuration)
        }

        public mutating func retune(perceptualDuration: TimeInterval, bounce: CGFloat?) {
            width.retune(perceptualDuration: perceptualDuration, bounce: bounce)
            height.retune(perceptualDuration: perceptualDuration, bounce: bounce)
        }

        @discardableResult
        public mutating func advance(dt: CGFloat) -> Bool {
            var moving = false
            moving = width.advance(dt: dt) || moving
            moving = height.advance(dt: dt) || moving
            return moving
        }
    }

    /// A rect springed as **centre + size**, never as four edges.
    ///
    /// Edges springed independently allow the four sides to disagree mid-flight
    /// and the rect visibly shears; a centre and a size always form a rect on
    /// every frame.
    public struct SpringRect {
        public var centre: SpringPoint
        public var size: SpringSize

        public init(rect: CGRect = .zero, perceptualDuration: TimeInterval = Motion.springStandard, bounce: CGFloat = 0) {
            centre = SpringPoint(
                value: CGPoint(x: rect.midX, y: rect.midY),
                perceptualDuration: perceptualDuration, bounce: bounce
            )
            size = SpringSize(
                value: rect.size,
                perceptualDuration: perceptualDuration, bounce: bounce
            )
        }

        public var rect: CGRect {
            let size = size.value
            return CGRect(
                x: centre.value.x - size.width / 2,
                y: centre.value.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        /// Where this rect is headed — for a surface that has to abandon the
        /// journey and land (live resize).
        public var target: CGRect {
            let size = size.target
            let centre = centre.target
            return CGRect(
                x: centre.x - size.width / 2,
                y: centre.y - size.height / 2,
                width: size.width,
                height: size.height
            )
        }

        public mutating func snap(to rect: CGRect) {
            centre.snap(to: CGPoint(x: rect.midX, y: rect.midY))
            size.snap(to: rect.size)
        }

        public mutating func target(_ rect: CGRect) {
            centre.target(CGPoint(x: rect.midX, y: rect.midY))
            size.target(rect.size)
        }

        public mutating func retune(perceptualDuration: TimeInterval) {
            centre.retune(perceptualDuration: perceptualDuration)
            size.retune(perceptualDuration: perceptualDuration)
        }

        public mutating func retune(perceptualDuration: TimeInterval, bounce: CGFloat?) {
            centre.retune(perceptualDuration: perceptualDuration, bounce: bounce)
            size.retune(perceptualDuration: perceptualDuration, bounce: bounce)
        }

        @discardableResult
        public mutating func advance(dt: CGFloat) -> Bool {
            var moving = false
            moving = centre.advance(dt: dt) || moving
            moving = size.advance(dt: dt) || moving
            return moving
        }
    }

    /// OK Lab — the colour space colours move in.
    ///
    /// Four springs: `L`/`a`/`b` (the perception-aligned axes) plus alpha,
    /// the same per-channel velocity semantics a raw sRGB spring had — but the
    /// linear distance between two colours in OKLab is approximately the
    /// perceptual distance.  Two failures of sRGB-space springing disappear:
    /// midpoints no longer darken (gamma-encoded sRGB midpoints do), and a
    /// transition between two equally-light hues no longer passes through a
    /// desaturated dead zone where the channel means collide.
    struct SpringLab {
        var L: SpringScalar
        var a: SpringScalar
        var b: SpringScalar

        init(perceptualDuration: TimeInterval, bounce: CGFloat = 0) {
            L = SpringScalar(value: 0.5, perceptualDuration: perceptualDuration, bounce: bounce)
            a = SpringScalar(value: 0, perceptualDuration: perceptualDuration, bounce: bounce)
            b = SpringScalar(value: 0, perceptualDuration: perceptualDuration, bounce: bounce)
        }
    }

    /// A colour springed in OKLab with a linear alpha channel.
    public struct SpringColor {
        private var lab: SpringLab
        private var alpha: SpringScalar
        public let perceptualDuration: TimeInterval
        public let bounce: CGFloat

        public init(value: NSColor = .clear, perceptualDuration: TimeInterval = Motion.springQuick, bounce: CGFloat = 0) {
            self.perceptualDuration = perceptualDuration
            self.bounce = bounce
            lab = SpringLab(perceptualDuration: perceptualDuration, bounce: bounce)
            alpha = SpringScalar(value: 1, perceptualDuration: perceptualDuration, bounce: bounce)
            snap(to: value)
        }

        public mutating func snap(to color: NSColor) {
            let (l, a, b) = OKLab.oklab(of: color)
            lab.L.snap(to: l)
            lab.a.snap(to: a)
            lab.b.snap(to: b)
            alpha.snap(to: color.alphaComponent)
        }

        public mutating func target(_ color: NSColor) {
            let (l, a, b) = OKLab.oklab(of: color)
            lab.L.target(l)
            lab.a.target(a)
            lab.b.target(b)
            alpha.target(color.alphaComponent)
        }

        public mutating func retune(perceptualDuration: TimeInterval) {
            lab.L.retune(perceptualDuration: perceptualDuration)
            lab.a.retune(perceptualDuration: perceptualDuration)
            lab.b.retune(perceptualDuration: perceptualDuration)
            alpha.retune(perceptualDuration: perceptualDuration)
        }

        /// A velocity kick on the alpha channel alone — a cascade pip arriving,
        /// a badge popping in: the hue glides, the appearance swells.
        public mutating func kickAlpha(_ impulse: CGFloat) {
            alpha.kick(impulse)
        }

        @discardableResult
        public mutating func advance(dt: CGFloat) -> Bool {
            var moving = false
            moving = lab.L.advance(dt: dt) || moving
            moving = lab.a.advance(dt: dt) || moving
            moving = lab.b.advance(dt: dt) || moving
            moving = alpha.advance(dt: dt) || moving
            return moving
        }

        public var value: NSColor {
            OKLab.sRGB(L: lab.L.value, a: lab.a.value, b: lab.b.value, alpha: alpha.value)
        }

        /// The colour this spring is heading for — for a surface that has to
        /// abandon the journey and land (live resize, a trip with no display
        /// to fly on).
        public var target: NSColor {
            OKLab.sRGB(L: lab.L.target, a: lab.a.target, b: lab.b.target, alpha: alpha.target)
        }
    }

    // MARK: OKLab

    /// The sRGB ↔ OKLab conversions that give `SpringColor` its per-channel
    /// linearity in the space the eye actually measures.
    enum OKLab {
        @inline(__always) private static func linear(_ c: CGFloat) -> CGFloat {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }

        @inline(__always) private static func gamma(_ c: CGFloat) -> CGFloat {
            c <= 0.0031308 ? 12.92 * c : 1.055 * pow(c, 1 / 2.4) - 0.055
        }

        @inline(__always) private static func cbrt(_ x: CGFloat) -> CGFloat {
            x < 0 ? -pow(-x, 1 / 3) : pow(x, 1 / 3)
        }

        /// sRGB (gamma-encoded, in the space `NSColor.sRGB` speaks) to OKLab.
        static func oklab(of color: NSColor) -> (L: CGFloat, a: CGFloat, b: CGFloat) {
            guard let srgb = color.usingColorSpace(.sRGB) else { return (0.5, 0, 0) }
            let r = linear(srgb.redComponent)
            let g = linear(srgb.greenComponent)
            let b = linear(srgb.blueComponent)
            // The OKLab 3x3, applied to linear sRGB.
            let l = 0.412_221_470_8 * r + 0.536_332_536_3 * g + 0.051_445_992_9 * b
            let m = 0.211_903_498_2 * r + 0.680_699_545_1 * g + 0.107_396_956_6 * b
            let s = 0.088_302_461_9 * r + 0.281_718_837_6 * g + 0.629_978_700_5 * b
            let l_ = cbrt(l), m_ = cbrt(m), s_ = cbrt(s)
            return (
                0.210_454_255_3 * l_ + 0.793_617_785_0 * m_ - 0.004_072_046_8 * s_,
                1.977_998_495_1 * l_ - 2.428_592_205_0 * m_ + 0.450_593_709_9 * s_,
                0.025_904_037_1 * l_ + 0.782_771_766_2 * m_ - 0.808_675_766_0 * s_
            )
        }

        /// OKLab back to sRGB, gamma-encoded, clamped into the displayable cube.
        static func sRGB(L: CGFloat, a: CGFloat, b: CGFloat, alpha: CGFloat) -> NSColor {
            let l_ = L + 0.396_337_777_4 * a + 0.215_803_757_3 * b
            let m_ = L - 0.105_561_345_8 * a - 0.063_854_172_8 * b
            let s_ = L - 0.089_484_177_5 * a - 1.291_485_548_0 * b
            let l = l_ * l_ * l_, m = m_ * m_ * m_, s = s_ * s_ * s_
            let r = 4.076_741_662_1 * l - 3.307_711_591_3 * m + 0.230_969_929_2 * s
            let g = -1.268_438_004_6 * l + 2.609_757_401_1 * m - 0.341_319_396_5 * s
            let b = -0.004_196_086_3 * l - 0.703_418_614_7 * m + 1.707_614_701_0 * s
            return NSColor(
                srgbRed: min(1, max(0, gamma(r))),
                green: min(1, max(0, gamma(g))),
                blue: min(1, max(0, gamma(b))),
                alpha: min(1, max(0, alpha))
            )
        }
    }

    // MARK: - Driver

    /// The driver's elapsed-time accounting, split out from `SpringDriver`.
    ///
    /// Separate because the rule it holds is a *policy* with a bug history, not
    /// an implementation detail, and because a display link cannot be driven
    /// from a test: arming a clock that is already running must leave it
    /// strictly alone.  `start` says whether it did anything; `tick` is the only
    /// thing that ever moves the mark.
    struct FrameClock {
        private var lastTick: CFTimeInterval = 0
        private(set) var isRunning = false

        /// Begins timing from `now`.  Returns whether this call started it —
        /// `false` means it was already running and the clock was untouched.
        @discardableResult
        mutating func start(now: CFTimeInterval) -> Bool {
            guard !isRunning else { return false }
            lastTick = now
            isRunning = true
            return true
        }

        mutating func stop() {
            isRunning = false
            lastTick = 0
        }

        /// Seconds since the previous tick, advancing the mark to `now`.
        mutating func tick(now: CFTimeInterval) -> CGFloat {
            let dt = max(0, now - lastTick)
            lastTick = now
            return CGFloat(dt)
        }
    }

    /// One display-link driver per view (§11.4).
    ///
    /// The link is created through `NSView.displayLink(target:selector:)`, not
    /// `CADisplayLink.displayLink`, because that call binds to the display the
    /// view is actually on — a ProMotion internal panel beside a 60 Hz
    /// external monitor each get the refresh rate they can show.  A driver is
    /// owned by its view, never by the app: this is a per-view clock, and
    /// surfaces that handed one link an extra frame of ticks on the wrong
    /// display never got the coast bug out until the lifecycle was examined.
    ///
    /// The contract is two closures. `advance(dt:)` integrates the springs and
    /// returns `false` when every spring has settled; `apply()` draws the
    /// frame's state and is also called on the settle tick, so the parked
    /// state can never hold a stale frame.  The driver parks itself when
    /// `advance` asks it to, when the view leaves its window, and when the
    /// owning view deinits.
    public final class SpringDriver {
        private weak var view: NSView?
        private var link: CADisplayLink?
        private var clock = FrameClock()

        public var advance: (CGFloat) -> Bool
        public var apply: () -> Void

        public init(view: NSView, advance: @escaping (CGFloat) -> Bool, apply: @escaping () -> Void) {
            self.view = view
            self.advance = advance
            self.apply = apply
        }

        public var isRunning: Bool { clock.isRunning }

        /// Arm the link. A parked driver that is armed again gets a fresh link;
        /// an already-running driver is left strictly alone.
        ///
        /// Arming must **never** re-base the clock of a running driver.  It used
        /// to, and that is a time leak with the pointer at one end of it: mouse
        /// events and the display link share the main run loop, so a `mouseMoved`
        /// arriving a millisecond before the next frame reset `lastTick` to a
        /// millisecond ago, and the springs integrated 1 ms of a 8.3 ms frame.
        /// Move the pointer continuously — a hover, a scrub, the exact moment the
        /// rail has to feel welded to the cursor — and the retargeting rate *is*
        /// the event rate, so nearly every frame's elapsed time was thrown away
        /// and the marks crawled toward targets they should have reached in a
        /// tenth of a second.  Stop moving and the resets stop with it, so the
        /// motion completed at full speed the instant you held still: the exact
        /// signature of "it does it, but in glue".
        @discardableResult
        public func arm() -> Bool {
            if clock.isRunning { return true }
            guard let view, view.window != nil else { return false }
            clock.start(now: CACurrentMediaTime())
            let link = view.displayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            return true
        }

        /// Tear the link down immediately — window teardown, explicit stop,
        /// lifecycle end. The display link retains its target, so a parked
        /// driver is also the only way a driver stops being retained.
        public func park() {
            link?.invalidate()
            link = nil
            clock.stop()
        }

        /// The single lifecycle hook surfaces call from `viewDidMoveToWindow`:
        /// leaving the window means no display exists to tick.
        public func viewDidMoveToWindow(window: NSWindow?) {
            if window == nil { park() }
        }

        @objc private func step(_ link: CADisplayLink) {
            let dt = clock.tick(now: CACurrentMediaTime())
            let moving = advance(dt)
            apply()
            if !moving { park() }
        }
    }

    /// A view whose springs step on one per-view driver.
    ///
    /// The base class that owns the driver lifecycle, so "park on window
    /// teardown, park in `deinit`" is written once instead of in every surface
    /// that springs.  Subclasses drive the two hooks: `springTick(dt:)`
    /// integrates and says whether to keep ticking, and `springApply()` draws
    /// the frame — it runs on the settle frame too, so the parked state is
    /// always drawn.
    open class SpringSurfaceView: NSView {
        private var springDriver: Motion.SpringDriver?

        public var springsAreRunning: Bool { springDriver?.isRunning ?? false }

        /// The per-frame integration hook. Return `true` to keep ticking,
        /// `false` to park at the end of this frame.
        open func springTick(dt: CGFloat) -> Bool { false }

        /// The per-frame draw of that integration.
        open func springApply() {}

        /// Put every spring on its target *now* and draw that, abandoning the
        /// journey.  Overridden by surfaces that own springs; the base does
        /// nothing because a surface with no springs has nothing to settle.
        ///
        /// This is the live-resize contract.  A resize loop retargets geometry
        /// on every one of AppKit's frames, so a spring chasing it is always
        /// behind and the surface wobbles like jelly hanging off the window
        /// edge — the one place in the app where lag reads as broken rather
        /// than alive, because the reader is dragging the thing themselves and
        /// expects it welded to the cursor.
        open func springsSettleImmediately() {}

        /// Start (or keep) the driver. Cheap; the link parks itself.
        ///
        /// Refused during a live resize: the surface is being dragged, so
        /// there is nothing to animate toward — it settles instead.
        @discardableResult
        public func armSprings() -> Bool {
            guard !inLiveResize else {
                springsSettleImmediately()
                return false
            }
            let driver = springDriver ?? makeSpringDriver()
            return driver.arm()
        }

        /// Stop the driver immediately.
        public func parkSprings() { springDriver?.park() }

        open override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            springDriver?.viewDidMoveToWindow(window: window)
        }

        open override func viewWillStartLiveResize() {
            super.viewWillStartLiveResize()
            parkSprings()
            springsSettleImmediately()
        }

        open override func viewDidEndLiveResize() {
            super.viewDidEndLiveResize()
            // The drag is over and the geometry is final: land on it rather
            // than spring toward a target the reader has already chosen.
            springsSettleImmediately()
        }

        deinit {
            springDriver?.park()
        }

        private func makeSpringDriver() -> Motion.SpringDriver {
            let driver = Motion.SpringDriver(
                view: self,
                advance: { [weak self] dt in self?.springTick(dt: dt) ?? false },
                apply: { [weak self] in self?.springApply() }
            )
            springDriver = driver
            return driver
        }
    }

    // MARK: - Curves

    /// Three curves, because there are three lengths of movement here.
    ///
    /// `decelerate` is the pointer-answer curve: it leaves fast and lands
    /// soft, which is what makes a short duration read as responsive rather
    /// than abrupt, and it is reserved for movement a pointer produced in the
    /// last quarter second.  `structural` is its deliberate-length sibling: a
    /// gentler entry so a 0.32 s move reads as a controlled launch and glide
    /// rather than a snap followed by drift.
    ///
    /// The beziers are all contained inside [0, 1], so none of them can
    /// overshoot; motion that should overshoot has to say so with values,
    /// which is what `pop(_:)` is for.
    public enum Curve {
        case easeOut
        case decelerate
        case snap
        /// The structural move's curve: entry under power but no whip — the
        /// first control point sits at a third of the height, not at the top —
        /// and a soft flat landing. For `deliberate`-length movement; the
        /// rail's settles spring instead of beziers, so this is the bezier
        /// side of "settling".
        case structural
    }

    private static func controlPoints(_ curve: Curve) -> (x1: CGFloat, y1: CGFloat, x2: CGFloat, y2: CGFloat) {
        switch curve {
        case .easeOut:
            (0.0, 0.0, 0.58, 1.0)
        case .decelerate:
            (0.22, 0.82, 0.28, 1.0)
        case .snap:
            (0.16, 1.0, 0.3, 1.0)
        case .structural:
            (0.30, 0.30, 0.20, 1.0)
        }
    }

    public static func timing(_ curve: Curve = .decelerate) -> CAMediaTimingFunction {
        switch curve {
        case .easeOut:
            return CAMediaTimingFunction(name: .easeOut)
        case .decelerate, .snap, .structural:
            let p = controlPoints(curve)
            return CAMediaTimingFunction(
                controlPoints: Float(p.x1), Float(p.y1), Float(p.x2), Float(p.y2)
            )
        }
    }

    // Curve *evaluation* — a Newton solve for the bezier's parameter and its
    // slope — used to exist here for exactly one caller: recovering the
    // velocity an interrupted scroll animation had, by differentiating the
    // curve it was riding. The scroll is a spring now and carries its velocity
    // as state, so there is nothing left to reconstruct and the solver went
    // with the thing that needed it.

    // MARK: - Scroll

    /// A programmatic scroll's trip, scaled by distance.
    ///
    /// A fixed duration turned a three-line jump into a crawl and a cross-
    /// chapter jump into a teleport; √distance gives short hops a short time
    /// and long descents room to carry, then clamps so neither extreme leaves
    /// the system's vocabulary.
    public static func scrollDuration(for distance: CGFloat) -> TimeInterval {
        var duration = 0.0115 * sqrt(max(0, distance))
        duration = min(0.55, max(0.18, duration))
        return duration
    }

    /// A scale that overshoots and settles along its axis of travel — the one
    /// shape a bezier cannot express, written once so every "this landed"
    /// moment in the app bounces the same way.
    ///
    /// Liquid objects squash and stretch: when `travelAxis` is given, the
    /// driven axis overshoots to `overshoot` while the cross axis dips toward
    /// volume-conserving squeeze, so the object stretches the way it is
    /// moving. With a nil axis (a press, a flash) the scale stays uniform.
    ///
    /// `cornerRadius`, when given, rides the same envelope — the radius
    /// swells with the overshoot, which reads as the whole body softening
    /// while it is in flight.
    public static func pop(
        from start: CGFloat,
        overshoot: CGFloat = 1.06,
        duration: TimeInterval = standard,
        travelAxis: CGVector? = nil,
        cornerRadius: CGFloat? = nil
    ) -> CAAnimation {
        // The shape of the travel axis governs the scale; a nil axis is a
        // uniform press/flash.
        let peakAlong = overshoot
        let peakCross = travelAxis == nil ? overshoot : 1 - (overshoot - 1) * 0.45
        let timingFunctions = [Motion.timing(.decelerate), Motion.timing(.easeOut)]

        let scale: CAKeyframeAnimation
        if let travelAxis {
            let length = hypot(travelAxis.dx, travelAxis.dy)
            guard length > 0.000_1 else {
                return pop(from: start, overshoot: overshoot, duration: duration, cornerRadius: cornerRadius)
            }
            let ux = travelAxis.dx / length
            let uy = travelAxis.dy / length
            func transform(along: CGFloat, cross: CGFloat) -> CATransform3D {
                let sx = 1 + (along - 1) * ux * ux + (cross - 1) * uy * uy
                let sy = 1 + (along - 1) * uy * uy + (cross - 1) * ux * ux
                return CATransform3DMakeScale(sx, sy, 1)
            }
            scale = CAKeyframeAnimation(keyPath: "transform")
            scale.values = [
                NSValue(caTransform3D: transform(along: start, cross: start)),
                NSValue(caTransform3D: transform(along: peakAlong, cross: peakCross)),
                NSValue(caTransform3D: CATransform3DIdentity),
            ]
        } else {
            scale = CAKeyframeAnimation(keyPath: "transform.scale")
            scale.values = [start, peakAlong, 1]
        }
        scale.keyTimes = [0, 0.55, 1] as [NSNumber]
        scale.duration = duration
        scale.timingFunctions = timingFunctions

        guard let cornerRadius, cornerRadius > 0 else { return scale }
        return popGroup(scale: scale, cornerRadius: cornerRadius, duration: duration)
    }

    private static func popGroup(
        scale: CAKeyframeAnimation,
        cornerRadius: CGFloat,
        duration: TimeInterval
    ) -> CAAnimation {
        // The radius rides the scale's envelope as a keyframe so it swells
        // with the overshoot and settles back with it — a plain from/to
        // animation would ramp up and then hard-cut on removal, which is the
        // "snap back" a liquid body must never do.
        let radius = CAKeyframeAnimation(keyPath: "cornerRadius")
        radius.values = [cornerRadius, cornerRadius * 1.15, cornerRadius]
        radius.keyTimes = scale.keyTimes
        radius.duration = duration
        radius.timingFunctions = scale.timingFunctions
        let group = CAAnimationGroup()
        group.animations = [scale, radius]
        group.duration = duration
        group.beginTime = scale.beginTime
        group.fillMode = scale.fillMode
        return group
    }

    // MARK: - Driver

    /// Run an `NSAnimationContext` group — the bezier carriage. Springs cannot
    /// travel on this (see the file header): spring surfaces go through their
    /// own display-link drivers.
    public static func run(
        reduceMotion: Bool,
        duration: TimeInterval = standard,
        curve: Curve = .decelerate,
        changes: (NSAnimationContext) -> Void,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduceMotion ? 0 : duration
            context.allowsImplicitAnimation = !reduceMotion
            context.timingFunction = timing(curve)
            changes(context)
        }, completionHandler: completion)
    }

    // MARK: - Morph

    /// Everything a morphing surface anchors to: where is it, how are its
    /// corners, what does it hold.  Anchors live in *window* space — the one
    /// coordinate system a source control and a destination panel both
    /// inhabit without conversion.  `MorphPresenter` turns a pair of anchors
    /// into one travelled body.
    public struct MorphAnchor: Equatable {
        public var frame: CGRect
        /// The surface's corner curvature.  A pill-shaped source (the ring)
        /// starts fully round and flattens as the body spreads into the panel.
        public var cornerRadius: CGFloat
        /// The tint the glass wears while this anchor is in effect. `nil`
        /// means the panel tone (transparent) — the natural resting state of
        /// a docked surface.
        public var tint: NSColor?

        public init(frame: CGRect = .zero, cornerRadius: CGFloat = 0, tint: NSColor? = nil) {
            self.frame = frame
            self.cornerRadius = cornerRadius
            self.tint = tint
        }
    }

    /// Content-cut windows for a morph. The travelling glass is continuous;
    /// the *contents* rasterise across a narrow progress band so the eye never
    /// has to watch two full-resolution surfaces crosscut:
    ///
    /// * outgoing p ∈ [0.00, 0.30] — the source's content hands it off.
    /// * gap      p ∈ [0.30, 0.35] — empty glass in flight.
    /// * incoming p ∈ [0.35, 0.75] — the destination's content fills it in.
    ///
    /// The gap is the whole trick: one clear window beats any crossfade.
    public enum MorphCut {
        /// The progress at which the outgoing content has fully handed off and
        /// the vessel is empty glass.  Anything the *container* around a morph
        /// has to do — a pane giving its width back, a divider moving — belongs
        /// here rather than at the landing: by this point nothing the reader is
        /// reading is still on screen, so the layout may change without the
        /// text appearing to jump underneath it.
        public static let handoff: CGFloat = 0.30

        /// p ∈ [0, 0.30], 1 → 0.
        public static func outgoing(_ p: CGFloat) -> CGFloat {
            clamp01(1 - p / handoff)
        }

        /// p ∈ [0.35, 0.75], 0 → 1.
        public static func incoming(_ p: CGFloat) -> CGFloat {
            guard p > 0.35 else { return 0 }
            guard p < 0.75 else { return 1 }
            return (p - 0.35) / 0.40
        }

        /// The glass is alone and resting: p ∈ (0.30, 0.35).
        public static func inFlight(_ p: CGFloat) -> Bool {
            p > 0.30 && p < 0.35
        }

        private static func clamp01(_ v: CGFloat) -> CGFloat {
            min(1, max(0, v))
        }
    }
}
