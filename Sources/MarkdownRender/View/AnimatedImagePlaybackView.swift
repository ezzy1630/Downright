import AppKit
import ImageIO

/// A still until the reader explicitly presses Play. Only the next frame is
/// decoded, and no timer remains scheduled while the view cannot be seen.
final class AnimatedImagePlaybackView: NSView {
    let animation: AnimatedImageSource
    let playButton = NSButton()
    private let decoder: AnimatedFrameDecoder
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    private(set) var frameIndex = 0
    private(set) var wantsPlayback = false
    private var decoding = false
    private var cycle = AnimatedImagePlaybackCycle()
    private var generation = 0
    override var isFlipped: Bool { true }

    init(image: NSImage, animation: AnimatedImageSource, background: NSColor) {
        self.animation = animation
        self.decoder = AnimatedFrameDecoder(animation)
        super.init(frame: .zero)
        setAccessibilityElement(false)
        wantsLayer = true
        layer?.contents = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        layer?.contentsGravity = .resize
        layer?.backgroundColor = background.cgColor
        playButton.bezelStyle = .regularSquare
        playButton.imagePosition = .imageOnly
        playButton.target = self
        playButton.action = #selector(togglePlayback)
        addSubview(playButton)
        updateButton()
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didChangeOcclusionStateNotification, NSView.boundsDidChangeNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateRunning() }
            })
        }
    }
    required init?(coder: NSCoder) { nil }
    deinit {
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
    }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); updateRunning() }
    override func layout() {
        super.layout()
        let side = min(28, bounds.height, bounds.width)
        playButton.frame = NSRect(x: max(0, bounds.width - side), y: 0, width: side, height: side)
        updateRunning()
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHiddenOrHasHiddenAncestor else { return nil }
        let local = convert(point, from: superview)
        return playButton.frame.contains(local) ? playButton : nil
    }
    @objc func togglePlayback() {
        wantsPlayback.toggle()
        generation &+= 1
        updateButton()
        updateRunning()
    }
    private func updateButton() {
        let title = wantsPlayback ? "Pause image" : "Play image"
        playButton.image = NSImage(systemSymbolName: wantsPlayback ? "pause.fill" : "play.fill", accessibilityDescription: title)
        playButton.toolTip = title
        playButton.setAccessibilityLabel(title)
    }
    private var canRun: Bool {
        wantsPlayback && NSApp.isActive && window?.isVisible == true
            && window?.occlusionState.contains(.visible) == true
            && !isHiddenOrHasHiddenAncestor && !visibleRect.isEmpty
    }
    func updateRunning() {
        guard canRun else {
            timer?.invalidate()
            timer = nil
            return
        }
        guard !decoding, timer?.isValid != true else { return }
        timer = Timer.scheduledTimer(withTimeInterval: animation.delays[frameIndex], repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advanceFrame() }
        }
        if let timer { RunLoop.main.add(timer, forMode: .common) }
    }
    private func advanceFrame() {
        guard canRun, !decoding else { return }
        guard let next = cycle.nextFrame(after: frameIndex, frameCount: animation.frameCount, loopCount: animation.loopCount) else {
            wantsPlayback = false
            updateButton()
            return
        }
        decoding = true
        let token = generation
        let pixels = min(2048, max(1, Int(ceil(max(bounds.width, bounds.height) * (window?.backingScaleFactor ?? 2)))))
        decoder.decode(next, maxPixelDimension: pixels) { [weak self] frame in
            guard let self else { return }
            self.decoding = false
            if self.generation == token, self.canRun, let frame {
                self.layer?.contents = frame
                self.frameIndex = next
            }
            if frame == nil { self.wantsPlayback = false; self.updateButton() }
            self.updateRunning()
        }
    }
}

/// A completed finite animation starts at frame zero when Play is pressed
/// again; pausing partway through keeps its current loop and frame.
struct AnimatedImagePlaybackCycle {
    private var completedLoops = 0
    private var finished = false

    mutating func nextFrame(after frame: Int, frameCount: Int, loopCount: Int) -> Int? {
        if finished {
            finished = false
            completedLoops = 0
            return 0
        }
        let next = frame + 1
        guard next == frameCount else { return next }
        completedLoops += 1
        if loopCount > 0, completedLoops >= loopCount {
            finished = true
            return nil
        }
        return 0
    }
}

/// Each ImageIO source is confined to one serial queue and reused across frames.
/// The view owns only a displayed frame and at most one pending decode.
private final class AnimatedFrameDecoder: @unchecked Sendable {
    private let animation: AnimatedImageSource
    private let queue = DispatchQueue(label: "downright.image-playback", qos: .userInitiated)
    private var source: CGImageSource?
    init(_ animation: AnimatedImageSource) { self.animation = animation }
    func decode(_ index: Int, maxPixelDimension: Int, completion: @escaping @MainActor (CGImage?) -> Void) {
        queue.async { [self] in
            if source == nil { source = animation.makeImageSource() }
            let image = source.flatMap { AnimatedImageSource.frame(index, of: $0, maxPixelDimension: maxPixelDimension) }
            DispatchQueue.main.async { completion(image) }
        }
    }
}
