import AppKit

/// Synthetic trackpad and wheel scroll events.
///
/// Every scroll gesture over the document surface is decided by reading an
/// `NSEvent` — its phase, its momentum phase, whether its deltas are precise,
/// which modifiers are held, and how far it travelled.  That decoding is part
/// of what the tests are testing, so they drive real `NSEvent`s built from
/// `CGEvent`s rather than a stand-in that would only ever agree with whatever
/// the coordinator already believed.
enum SyntheticScroll {
    struct Unavailable: Error {}

    /// - Parameters:
    ///   - precise: `true` for a trackpad, whose deltas are points and whose
    ///     gestures have phases; `false` for a wheel, whose deltas are lines
    ///     and which has neither phases nor a momentum tail.
    static func event(
        deltaX: CGFloat = 0,
        deltaY: CGFloat = 0,
        phase: CGScrollPhase? = .changed,
        momentum: CGMomentumScrollPhase = CGMomentumScrollPhase.none,
        precise: Bool = true,
        modifiers: NSEvent.ModifierFlags = [],
        at seconds: TimeInterval = 0
    ) throws -> NSEvent {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ) else { throw Unavailable() }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: precise ? 1 : 0)
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: Double(deltaY))
        event.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: Double(deltaX))
        if !precise {
            // A wheel's `scrollingDelta` is read out of the line fields, not
            // the point ones — the difference the whole coarse-device path
            // turns on, so it has to be real here too.
            event.setIntegerValueField(
                .scrollWheelEventDeltaAxis1, value: Int64(deltaY.rounded())
            )
            event.setIntegerValueField(
                .scrollWheelEventDeltaAxis2, value: Int64(deltaX.rounded())
            )
        }
        if let phase {
            event.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(phase.rawValue))
        }
        event.setIntegerValueField(
            .scrollWheelEventMomentumPhase, value: Int64(momentum.rawValue)
        )
        // Always set, including to nothing: a `CGEvent` built with no source
        // is entitled to pick up whatever the keyboard happens to be doing,
        // and a stray ⌘ on the developer's hand must not decide a test.
        event.flags = flags(for: modifiers)
        event.timestamp = UInt64(max(0, seconds) * 1_000_000_000)
        guard let decoded = NSEvent(cgEvent: event) else { throw Unavailable() }
        return decoded
    }

    private static func flags(for modifiers: NSEvent.ModifierFlags) -> CGEventFlags {
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.capsLock) { flags.insert(.maskAlphaShift) }
        if modifiers.contains(.function) { flags.insert(.maskSecondaryFn) }
        return flags
    }
}
