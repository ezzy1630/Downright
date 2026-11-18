import AppKit
import Carbon.HIToolbox
import NativeUITestBridge

/// Native input for an invisible window in the test process.
/// NSWindow dispatches events and tracks gestures in its own responder chain.
@MainActor
public final class WindowInput {
    public enum Key {
        case character(Character)
        case `return`, escape, delete, left, right, up, down

        var eventFields: (String, UInt16) {
            switch self {
            case .character(let character):
                let keyCodes: [Character: Int] = [
                    "a": kVK_ANSI_A, "e": kVK_ANSI_E, "\\": kVK_ANSI_Backslash,
                    " ": kVK_Space, "[": kVK_ANSI_LeftBracket, "]": kVK_ANSI_RightBracket,
                ]
                return (String(character), UInt16(keyCodes[Character(String(character).lowercased())] ?? 0))
            case .return: return ("\r", UInt16(kVK_Return))
            case .escape: return ("\u{1b}", UInt16(kVK_Escape))
            case .delete: return ("\u{7f}", UInt16(kVK_Delete))
            case .left: return (String(UnicodeScalar(NSLeftArrowFunctionKey)!), UInt16(kVK_LeftArrow))
            case .right: return (String(UnicodeScalar(NSRightArrowFunctionKey)!), UInt16(kVK_RightArrow))
            case .up: return (String(UnicodeScalar(NSUpArrowFunctionKey)!), UInt16(kVK_UpArrow))
            case .down: return (String(UnicodeScalar(NSDownArrowFunctionKey)!), UInt16(kVK_DownArrow))
            }
        }
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        public init(_ description: String) { self.description = description }
    }

    public let window: NSWindow
    private var eventNumber = 0

    public init(_ window: NSWindow) {
        self.window = window
        // AppKit routes mouse-down and wheel only to ordered windows. Alpha
        // and ignoresMouseEvents keep it invisible and out of desktop input.
        // Ordering it back does not make it key or activate NSApplication.
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.acceptsMouseMovedEvents = true
        window.orderBack(nil)
        // AppKit's inactive first-click gate otherwise swallows NSTextView
        // input. This calls the local responder callback, skipping the
        // WindowServer focus request made by makeKey / makeKeyAndOrderFront.
        window.becomeKey()
        window.layoutIfNeeded()
    }

    public func press(_ key: Key, modifiers: NSEvent.ModifierFlags = []) throws {
        let (characters, code) = key.eventFields
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters,
                charactersIgnoringModifiers: characters.lowercased(), isARepeat: false, keyCode: code
            ) else { throw Failure("Could not construct \(type) for \(key)") }
            window.sendEvent(event)
        }
    }

    public func type(_ text: String) throws {
        for character in text {
            try press(character == "\n" ? .return : .character(character))
        }
    }

    public func click(at point: NSPoint, count: Int = 1, modifiers: NSEvent.ModifierFlags = []) throws {
        guard count > 0 else { throw Failure("A click count must be positive") }
        for clickCount in 1...count {
            try gesture(from: point, to: point, clickCount: clickCount, modifiers: modifiers)
        }
    }

    public func drag(from start: NSPoint, to end: NSPoint, modifiers: NSEvent.ModifierFlags = []) throws {
        try gesture(from: start, to: end, clickCount: 1, modifiers: modifiers)
    }

    public func doubleClickAndDrag(from start: NSPoint, to end: NSPoint) throws {
        try gesture(from: start, to: start, clickCount: 1, modifiers: [])
        try gesture(from: start, to: end, clickCount: 2, modifiers: [])
    }

    private func gesture(
        from start: NSPoint, to end: NSPoint, clickCount: Int, modifiers: NSEvent.ModifierFlags
    ) throws {
        eventNumber += 1
        let down = try mouse(.leftMouseDown, at: start, count: clickCount, modifiers: modifiers)
        let up = try mouse(.leftMouseUp, at: end, count: clickCount, modifiers: modifiers)
        let drag = start == end ? nil : try mouse(.leftMouseDragged, at: end, count: clickCount, modifiers: modifiers)
        // The real NSTextView tracking loop consumes drag/up while
        // processing the initial down. Give those events to this window only.
        DRSendWindowMouseGesture(window, down, [drag, up].compactMap { $0 })
    }

    /// Built-in menu commands normally resolve against the key window.
    /// Supply the fixture's target explicitly to AppKit's action dispatcher.
    public func sendAction(_ action: Selector, to target: AnyObject?, from sender: Any? = nil) throws {
        guard let target, NSApp.sendAction(action, to: target, from: sender) else {
            throw Failure("Could not dispatch \(NSStringFromSelector(action)) in \(window.title)")
        }
    }

    /// Scope the real copy/cut/paste actions to a named pasteboard.
    public func withPrivatePasteboard(_ run: (NSPasteboard) throws -> Void) throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        var outcome: Result<Void, Error>?
        DRWithPrivatePasteboard(pasteboard) {
            outcome = Result { try run(pasteboard) }
        }
        guard let outcome else { throw Failure("The private pasteboard scope did not run") }
        try outcome.get()
    }

    public func move(to point: NSPoint) throws {
        eventNumber += 1
        let event = try mouse(.mouseMoved, at: point, count: 0, modifiers: [])
        let content = window.contentView
        let hit = content?.hitTest(content?.superview?.convert(point, from: nil) ?? point)
        var view = hit
        while let candidate = view {
            let local = candidate.convert(point, from: nil)
            if candidate.trackingAreas.isEmpty { candidate.updateTrackingAreas() }
            let area = candidate.trackingAreas.first { area in
                let region = area.options.contains(.inVisibleRect) ? candidate.visibleRect : area.rect
                return area.options.contains(.mouseMoved) && region.contains(local) && area.owner is NSResponder
            }
            if let owner = area?.owner as? NSResponder {
                DRSendWindowTrackedMove(window, event, owner)
                return
            }
            view = candidate.superview
        }
        window.sendEvent(event)
    }

    private func mouse(
        _ type: NSEvent.EventType, at point: NSPoint, count: Int, modifiers: NSEvent.ModifierFlags
    ) throws -> NSEvent {
        guard let event = NSEvent.mouseEvent(
            with: type, location: point, modifierFlags: modifiers,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, eventNumber: eventNumber, clickCount: count,
            pressure: type == .leftMouseDown || type == .leftMouseDragged ? 1 : 0
        ) else { throw Failure("Could not construct \(type) at \(point)") }
        return event
    }

    public func scroll(deltaY: Int32, at point: NSPoint) throws {
        guard let event = CGEvent(
            scrollWheelEvent2Source: CGEventSource(stateID: .privateState), units: .pixel, wheelCount: 1,
            wheel1: deltaY, wheel2: 0, wheel3: 0
        ) else { throw Failure("Could not construct a scroll event") }
        // An unposted CGEvent has no window. NSEvent keeps its location in
        // AppKit's flipped coordinate system; encode the receiver's local
        // point there because NSWindow consumes it as locationInWindow.
        event.location = CGPoint(x: point.x, y: CGDisplayBounds(CGMainDisplayID()).height - point.y)
        event.flags = []
        guard let wheel = NSEvent(cgEvent: event) else { throw Failure("Could not bridge the scroll event") }
        window.sendEvent(wheel)
    }

    public func wait(
        until condition: @escaping () -> Bool, _ description: String,
        notification: Notification.Name? = nil, object: AnyObject? = nil
    ) async throws {
        if condition() { return }
        let timeout: TimeInterval = 1
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var observer: NSObjectProtocol?
            var timer: Timer?

            @MainActor func check() {
                let ready = condition()
                guard ready || ProcessInfo.processInfo.systemUptime >= deadline else { return }
                timer?.invalidate()
                if let observer { NotificationCenter.default.removeObserver(observer) }
                if ready { continuation.resume() }
                else { continuation.resume(throwing: Failure("Timed out after \(timeout)s waiting for \(description)")) }
            }

            if let notification {
                observer = NotificationCenter.default.addObserver(
                    forName: notification, object: object, queue: .main
                ) { _ in MainActor.assumeIsolated { check() } }
            }
            timer = Timer.scheduledTimer(
                withTimeInterval: notification == nil ? 0.01 : timeout, repeats: notification == nil
            ) { _ in MainActor.assumeIsolated { check() } }
        }
    }

    public func snapshot() throws -> Data {
        window.layoutIfNeeded()
        guard let content = window.contentView,
              let bitmap = content.bitmapImageRepForCachingDisplay(in: content.bounds) else {
            throw Failure("Could not allocate a window bitmap for \(window.title)")
        }
        content.cacheDisplay(in: content.bounds, to: bitmap)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw Failure("Could not encode a window bitmap for \(window.title)")
        }
        return data
    }
}
