import AppKit

/// One owner across every document window. Usage stays in memory while reading;
/// document opens, deactivation, termination, and retirement persist it locally.
@MainActor
final class StarPromptCoordinator {
    private var usage: StarPromptUsage
    private let save: (StarPromptUsage) -> Void
    private let document: () -> DocumentWindowController?
    private let openRepository: () -> Void
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var readingClock = StarPromptReadingClock()
    private var notice: StarPromptNotice?

    init(
        usage: StarPromptUsage,
        save: @escaping (StarPromptUsage) -> Void,
        document: @escaping () -> DocumentWindowController?,
        openRepository: @escaping () -> Void
    ) {
        self.usage = usage
        self.save = save
        self.document = document
        self.openRepository = openRepository
    }

    func start() {
        guard timer == nil, !usage.hasBeenOffered else { return }
        readingClock = StarPromptReadingClock()
        // Default run-loop mode deliberately defers the offer during menus,
        // mouse tracking, live resize, and modal interactions.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
        timer?.tolerance = 1
        for name in [NSApplication.didBecomeActiveNotification,
                     NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification,
                     NSWindow.didChangeOcclusionStateNotification] {
            observers.append(NotificationCenter.default.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.sample(allowPresentation: false)
                    if !NSApp.isActive { self?.persist() }
                }
            })
        }
    }

    func recordOpen(origin: StarPromptUsage.OpenOrigin) {
        usage.recordOpen(origin: origin)
        persist()
    }

    /// The Help-menu action is already an answer; it must suppress a future ask.
    func retire() {
        usage.retire()
        persist()
        stopObserving()
        notice?.dismiss()
        notice = nil
    }

    func stop() {
        sample(allowPresentation: false)
        persist()
        stopObserving()
        notice?.dismiss()
        notice = nil
    }

    private func persist() { save(usage) }

    private func stopObserving() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }

    private func sample(allowPresentation: Bool = true) {
        let now = ProcessInfo.processInfo.systemUptime
        let controller = document()
        let window = controller?.window
        let isReading = NSApp.isActive && window?.isKeyWindow == true
            && window?.occlusionState.contains(.visible) == true
            && window?.isMiniaturized == false && window?.attachedSheet == nil
            && NSApp.modalWindow == nil
        usage.recordForegroundTime(readingClock.sample(at: now, isReading: isReading))

        guard allowPresentation, usage.isEligible, isReading,
              let controller, let window,
              !controller.isFocusModeEnabled, controller.findBar == nil,
              controller.conflictBar == nil, controller.inspectorHost?.selectedSection == nil,
              !window.inLiveResize,
              controller.documentPanes.allSatisfy({ !$0.textView.hasMarkedText() }),
              NSEvent.pressedMouseButtons == 0,
              Self.isInputIdle
        else { return }

        let notice = StarPromptNotice(parent: window, openRepository: { [weak self] in
            self?.openRepository()
        })
        self.notice = notice
        notice.show()
        // Retire at presentation, including quitting or closing this window
        // without pressing a button. A new version is never a new invitation.
        usage.retire()
        persist()
        stopObserving()
    }

    private static var isInputIdle: Bool {
        [CGEventType.keyDown, .leftMouseDown, .rightMouseDown, .scrollWheel].allSatisfy {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) >= 5
        }
    }
}
