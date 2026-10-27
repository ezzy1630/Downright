#if DEBUG
import AppKit
import MarkdownRender

/// Temporary CI controls; remove with the rendering diagnosis before release.
@MainActor
enum NativeRenderingDiagnostic {
    private static var controlWindow: NSWindow?

    static func makeTextView(content: NSAttributedString, textKit2: Bool,
                             decorated: Bool, styleSheet: StyleSheet) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: textKit2)
        view.frame = NSRect(x: 0, y: 0, width: 700, height: 500)
        view.minSize = NSSize(width: 0, height: 500)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,
                              height: CGFloat.greatestFiniteMagnitude)
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.autoresizingMask = [.width]
        view.textContainer?.size = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = true
        view.textContainerInset = NSSize(width: 10, height: 10)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = true
        if decorated {
            view.textStorage?.setAttributedString(content)
            view.backgroundColor = styleSheet.background
        } else {
            view.string = content.string
            view.font = .systemFont(ofSize: 16)
            view.textColor = .black
            view.backgroundColor = .white
        }
        view.setAccessibilityLabel("Native rendering control")
        return view
    }

    static func showIfRequested(content: NSAttributedString?) {
        guard let mode = ProcessInfo.processInfo.environment["DOWNRIGHT_DEBUG_NATIVE_WINDOW"],
              ["textkit1-system", "textkit2-system", "textkit2-decorated"].contains(mode),
              let content else { return }
        let view = makeTextView(content: content, textKit2: mode != "textkit1-system",
                                decorated: mode == "textkit2-decorated", styleSheet: .current)
        let scroll = NSScrollView(frame: view.frame)
        scroll.hasVerticalScroller = true
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Native rendering control: " + mode
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        controlWindow = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
    }
}
#endif
