import AppKit
import MarkdownRender

/// A child window leaves TextKit geometry, reading anchors, and first responder
/// alone. It uses an opaque themed surface, with no continuous animation.
@MainActor
final class StarPromptNotice: NSObject {
    let panel: NSPanel
    private weak var parent: NSWindow?
    private var observers: [NSObjectProtocol] = []
    private var dismissalMonitor: Any?
    private var themeObservation: ThemeObservation?
    private var appearanceObservation: NSKeyValueObservation?
    private let body = NSView()
    private let title = NSTextField(labelWithString: "Enjoying Downright?")
    private let detail = NSTextField(labelWithString: "A GitHub star helps others discover it.")
    private let close = NSButton(title: "", target: nil, action: nil)
    private let openRepository: () -> Void

    init(parent: NSWindow, openRepository: @escaping () -> Void) {
        self.parent = parent
        self.openRepository = openRepository
        panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 326, height: 112),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isFloatingPanel = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.transient, .fullScreenAuxiliary]
        panel.setAccessibilityRole(.popover)
        panel.setAccessibilityLabel("Support Downright")

        body.frame = NSRect(origin: .zero, size: panel.frame.size)
        body.wantsLayer = true
        body.layer?.cornerRadius = 10
        body.layer?.borderWidth = 1
        panel.contentView = body

        title.font = PanelFont.system(12, weight: .semibold)
        detail.font = PanelFont.system(11.5)
        let star = NSButton(title: "Star on GitHub", target: self, action: #selector(starClicked))
        star.bezelStyle = .rounded
        star.controlSize = .small
        star.image = NSImage(systemSymbolName: "star", accessibilityDescription: nil)
        star.imagePosition = .imageLeading
        star.setAccessibilityLabel("Star Downright on GitHub")
        close.target = self
        close.action = #selector(closeClicked)
        close.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "Dismiss")
        close.isBordered = false
        close.toolTip = "Dismiss — won’t be shown again"
        close.setAccessibilityLabel("Dismiss GitHub star suggestion")

        for view in [title, detail, star, close] {
            view.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(view)
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 16),
            title.topAnchor.constraint(equalTo: body.topAnchor, constant: 14),
            title.trailingAnchor.constraint(lessThanOrEqualTo: close.leadingAnchor, constant: -8),
            close.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
            close.topAnchor.constraint(equalTo: body.topAnchor, constant: 8),
            close.widthAnchor.constraint(equalToConstant: 26),
            close.heightAnchor.constraint(equalToConstant: 26),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 5),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: body.trailingAnchor, constant: -16),
            star.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            star.topAnchor.constraint(equalTo: detail.bottomAnchor, constant: 10),
            star.bottomAnchor.constraint(lessThanOrEqualTo: body.bottomAnchor, constant: -12),
        ])
        applyStyle()
    }

    func show() {
        guard let parent else { return }
        reposition()
        parent.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        themeObservation = ThemeStore.shared.observe { [weak self] _ in self?.applyStyle() }
        appearanceObservation = parent.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyStyle() }
        }
        for name in [NSWindow.didResizeNotification, NSWindow.didMoveNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: parent, queue: .main
            ) { [weak self] _ in MainActor.assumeIsolated { self?.reposition() } })
        }
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: parent, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.dismiss() } })
        observers.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: parent, queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.panel.isKeyWindow else { return }
                self.dismiss()
            }
        })
        dismissalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            let consume = MainActor.assumeIsolated {
                guard let self else { return false }
                if event.type == .keyDown {
                    guard event.keyCode == 53,
                          event.window === self.parent || event.window === self.panel else { return false }
                    self.dismiss()
                    return true
                }
                guard event.window !== self.panel else { return false }
                self.dismiss()
                return false // Keep the outside click's original action live.
            }
            return consume ? nil : event
        }
        NSAccessibility.post(element: panel, notification: .created)
    }

    func dismiss() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
        if let dismissalMonitor { NSEvent.removeMonitor(dismissalMonitor) }
        dismissalMonitor = nil
        themeObservation?.cancel()
        themeObservation = nil
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        parent?.removeChildWindow(panel)
        panel.orderOut(nil)
    }

    private func applyStyle() {
        guard let parent else { return }
        // Native button chrome must use the same appearance as the themed body.
        panel.appearance = parent.effectiveAppearance
        let sheet = StyleSheet(theme: ThemeStore.shared.current, appearance: parent.effectiveAppearance)
        body.layer?.backgroundColor = sheet.background.cgColor
        body.layer?.borderColor = sheet.textFaint.withAlphaComponent(0.35).cgColor
        title.textColor = sheet.text
        detail.textColor = sheet.text
        close.contentTintColor = sheet.text
    }

    private func reposition() {
        guard let parent, let content = parent.contentView else { return }
        let contentOnScreen = parent.convertToScreen(content.convert(content.bounds, to: nil))
        let top = contentOnScreen.maxY - content.safeAreaInsets.top - 8
        panel.setFrameOrigin(NSPoint(
            x: contentOnScreen.maxX - panel.frame.width - 12,
            y: top - panel.frame.height
        ))
    }

    @objc private func starClicked() { dismiss(); openRepository() }
    @objc private func closeClicked() { dismiss() }
}
