import AppKit

/// One timing authority for document and chrome motion.
public enum Motion {
    public static let quick: TimeInterval = 0.12
    public static let standard: TimeInterval = 0.20
    public static let deliberate: TimeInterval = 0.32
    /// Density rail: proximity grow is snappy; shrink eases out longer.
    public static let hoverGrow: TimeInterval = 0.08
    public static let hoverShrink: TimeInterval = 0.18
    /// Active-mark settle after scroll / section change.
    public static let settle: TimeInterval = 0.20
    /// Optical punch when jumping to a mark.
    public static let jumpPunch: TimeInterval = 0.14
    /// Whole-rail breathe on pointer enter / leave.
    public static let breathe: TimeInterval = 0.12
    /// Preview title lands first; snippet follows.
    public static let previewStagger: TimeInterval = 0.04

    public enum Curve { case easeOut, spring }

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
            switch curve {
            case .easeOut:
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            case .spring:
                context.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.82, 0.28, 1)
            }
            changes(context)
        }, completionHandler: completion)
    }
}
