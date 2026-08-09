import AppKit

/// Document windows route the one event that a floating surface cannot receive
/// itself: a left click on the document behind it. This is cheaper than an
/// `NSEvent` local monitor per controller and preserves the original event so
/// the click that dismisses the panel can still place the caret.
final class DocumentWindow: NSWindow {
    var onFloatingOutsideMouseDown: (() -> Void)?
    weak var floatingSurface: NSView?

    static func shouldDismissFloatingClick(
        at locationInWindow: NSPoint,
        content: NSView,
        surface: NSView
    ) -> Bool {
        let contentPoint = content.convert(locationInWindow, from: nil)
        let surfacePoint: NSPoint
        if surface.window === content.window {
            surfacePoint = surface.convert(locationInWindow, from: nil)
        } else if let sourceWindow = content.window, let surfaceWindow = surface.window {
            let screenPoint = sourceWindow.convertToScreen(
                NSRect(origin: locationInWindow, size: .zero)
            ).origin
            let childPoint = surfaceWindow.convertFromScreen(
                NSRect(origin: screenPoint, size: .zero)
            ).origin
            surfacePoint = surface.convert(childPoint, from: nil)
        } else {
            return false
        }
        return content.bounds.contains(contentPoint) && !surface.bounds.contains(surfacePoint)
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown,
           let surface = floatingSurface,
           let surfaceWindow = surface.window,
           surfaceWindow === self || (childWindows ?? []).contains(where: { $0 === surfaceWindow }),
           let content = contentView {
            if Self.shouldDismissFloatingClick(
                at: event.locationInWindow,
                content: content,
                surface: surface
            ) {
                // AppKit's menu tracking and context menus do not enter this
                // left-button path. The event remains untouched so the
                // document receives the same click after dismissal.
                onFloatingOutsideMouseDown?()
            }
        }
        super.sendEvent(event)
    }
}
