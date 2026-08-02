import AppKit

/// One timing authority for document and chrome motion.
public enum Motion {
    public static let quick: TimeInterval = 0.12
    public static let standard: TimeInterval = 0.20
    public static let deliberate: TimeInterval = 0.32

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
