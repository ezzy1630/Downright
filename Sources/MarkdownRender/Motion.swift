import AppKit

/// One timing authority for document and chrome motion (§11.4).
///
/// The system is three durations.  A control that wants a fourth is almost
/// always asking for one of these three and guessing; anything genuinely
/// outside the system is declared below, named, and justified, so the count of
/// distinct timings in the app stays countable.
public enum Motion {
    /// Feedback that must not be noticed: hover, press, a colour warming.
    public static let quick: TimeInterval = 0.12
    /// A state change the reader is watching: a check drawing, a thumb sliding.
    public static let standard: TimeInterval = 0.20
    /// A structural change: a panel's contents arriving, an arc travelling.
    public static let deliberate: TimeInterval = 0.32

    /// Active-mark settle after scroll / section change.
    public static let settle: TimeInterval = standard
    /// Whole-rail breathe on pointer enter / leave.
    public static let breathe: TimeInterval = quick
    /// Preview title lands first; snippet follows.
    public static let previewStagger: TimeInterval = quick / 3

    /// The density rail's own timings, and the only declared exceptions.
    ///
    /// The rail tracks the pointer continuously rather than answering a
    /// discrete action, so its grow/shrink pair is deliberately asymmetric —
    /// snappy toward the pointer, longer away from it — and its jump punch is
    /// tuned against the scroll animation it interrupts.  Nothing else may
    /// reach for these.
    public static let hoverGrow: TimeInterval = 0.08
    public static let hoverShrink: TimeInterval = 0.18
    public static let jumpPunch: TimeInterval = 0.14

    /// Two curves, because there are two kinds of movement here.
    ///
    /// `decelerate` is the house curve: it leaves fast and lands soft, which is
    /// what makes a short duration read as responsive rather than abrupt.  It
    /// is *not* a spring — all four control points sit inside [0, 1], so it
    /// cannot overshoot.  Motion that should overshoot has to say so with
    /// values, which is what `pop(_:)` is for.
    public enum Curve {
        case easeOut
        case decelerate

        /// Kept so existing call sites keep compiling; `decelerate` is the
        /// honest name for what this curve does.
        public static let spring: Curve = .decelerate
    }

    public static func timing(_ curve: Curve = .decelerate) -> CAMediaTimingFunction {
        switch curve {
        case .easeOut:
            CAMediaTimingFunction(name: .easeOut)
        case .decelerate:
            CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1)
        }
    }

    /// A scale that overshoots and settles — the one shape a bezier cannot
    /// express, written once so every "this landed" moment in the app bounces
    /// by the same amount over the same time.
    public static func pop(
        from start: CGFloat,
        overshoot: CGFloat = 1.06,
        duration: TimeInterval = standard
    ) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [start, overshoot, 1]
        animation.keyTimes = [0, 0.55, 1]
        animation.duration = duration
        animation.timingFunctions = [timing(.decelerate), timing(.easeOut)]
        return animation
    }

    public static func run(
        reduceMotion: Bool,
        duration: TimeInterval = standard,
        curve: Curve = .easeOut,
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
}
