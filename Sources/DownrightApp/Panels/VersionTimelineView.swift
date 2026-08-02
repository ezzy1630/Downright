import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol VersionTimelineDelegate: AnyObject {
    func versionTimeline(_ view: VersionTimelineView, didScrubTo record: SnapshotStore.VersionRecord)
    func versionTimeline(_ view: VersionTimelineView, didRequestRestore record: SnapshotStore.VersionRecord)
}

/// Version timeline scrubber (§8.3, `⌘⇧V`).
///
/// Ticks are positioned **by time, not by index**.  That is the whole design:
/// an agent that rewrote the file five times in one minute should look like a
/// burst, and the afternoon you spent editing it yourself should look like a
/// gap.  Evenly spaced ticks would erase exactly the information you opened the
/// timeline to find.
final class VersionTimelineView: NSView {
    weak var delegate: VersionTimelineDelegate?

    var styleSheet: StyleSheet {
        didSet {
            applyStyle()
        }
    }

    var versions: [SnapshotStore.VersionRecord] = [] {
        didSet {
            selectedIndex = min(max(0, selectedIndex), max(0, versions.count - 1))
            restoreButton.isEnabled = !versions.isEmpty
            needsDisplay = true
        }
    }

    var selectedIndex: Int = 0 {
        didSet {
            guard selectedIndex != oldValue else { return }
            updateAccessibility()
            needsDisplay = true
        }
    }

    private let restoreButton: NSButton
    private var restoreAction: ButtonAction?

    private let trackHeight: CGFloat = 3
    private let tickHeight: CGFloat = 16
    private let horizontalInset: CGFloat = 16
    private let restoreWidth: CGFloat = 84

    // MARK: - Init

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        let action = ButtonAction {}
        self.restoreButton = PanelButton.text("Restore", action: action)
        super.init(frame: NSRect(x: 0, y: 0, width: 520, height: 84))

        let restore = ButtonAction { [weak self] in
            guard let self, let record = self.selectedRecord else { return }
            self.delegate?.versionTimeline(self, didRequestRestore: record)
        }
        restoreAction = restore
        restoreButton.target = restore
        restoreButton.action = #selector(ButtonAction.fire(_:))
        restoreButton.isEnabled = false
        addSubview(restoreButton)

        NSLayoutConstraint.activate([
            restoreButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -horizontalInset),
            restoreButton.centerYAnchor.constraint(equalTo: centerYAnchor),
            restoreButton.widthAnchor.constraint(equalToConstant: restoreWidth),
        ])

        setAccessibilityElement(true)
        setAccessibilityRole(.slider)
        setAccessibilityLabel("Version timeline")
        updateAccessibility()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 84)
    }

    override var isFlipped: Bool { true }

    var selectedRecord: SnapshotStore.VersionRecord? {
        guard selectedIndex >= 0, selectedIndex < versions.count else { return nil }
        return versions[selectedIndex]
    }

    private func applyStyle() {
        updateAccessibility()
        needsDisplay = true
    }

    private func updateAccessibility() {
        guard let record = selectedRecord else {
            setAccessibilityValueDescription("No versions")
            return
        }
        setAccessibilityValueDescription("\(RelativeTime.stamp(record.date)), \(RelativeTime.long(record.date))")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    // MARK: - Geometry

    private var trackRect: NSRect {
        NSRect(
            x: horizontalInset,
            y: 26,
            width: max(40, bounds.width - horizontalInset * 2 - restoreWidth - 12),
            height: trackHeight
        )
    }

    private func x(for date: Date) -> CGFloat {
        let track = trackRect
        guard let first = versions.first?.date, let last = versions.last?.date else { return track.minX }
        let span = last.timeIntervalSince(first)
        // A history that is one burst has no meaningful time axis; centre it
        // rather than pile every tick on the left edge.
        guard span > 1 else { return track.midX }
        let fraction = CGFloat(date.timeIntervalSince(first) / span)
        return track.minX + min(1, max(0, fraction)) * track.width
    }

    private func nearestIndex(toX position: CGFloat) -> Int? {
        guard !versions.isEmpty else { return nil }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, record) in versions.enumerated() {
            let distance = abs(x(for: record.date) - position)
            if distance < bestDistance {
                bestDistance = distance
                best = index
            }
        }
        return best
    }

    private func color(for kind: SnapshotStore.SnapshotKind) -> NSColor {
        switch kind {
        case .external:
            // The writes you did not make are the ones you came here for.
            return styleSheet.changeColor(.modified)
        case .local:
            return styleSheet.textSecondary
        case .baseline:
            return styleSheet.textFaint
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        let contrast = styleSheet.increaseContrast

        styleSheet.rule.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()

        guard !versions.isEmpty else {
            drawCaption("No saved versions yet", at: track.midX, color: styleSheet.textFaint)
            return
        }

        for (index, record) in versions.enumerated() where index != selectedIndex {
            // Semi-transparent so a cluster of writes reads darker than a lone
            // one — the density *is* the signal.
            color(for: record.kind).panelAlpha(0.55, increaseContrast: contrast).setFill()
            let position = x(for: record.date)
            NSRect(x: position - 1, y: track.midY - tickHeight / 2, width: 2, height: tickHeight).fill()
        }

        guard let record = selectedRecord else { return }
        let position = x(for: record.date)

        styleSheet.accent.setFill()
        NSRect(x: position - 1.5, y: track.midY - tickHeight / 2 - 3, width: 3, height: tickHeight + 6).fill()
        let knob = NSRect(x: position - 5, y: track.midY - 5, width: 10, height: 10)
        NSBezierPath(ovalIn: knob).fill()

        drawCaption(
            "\(RelativeTime.stamp(record.date))  ·  \(RelativeTime.long(record.date))",
            at: position, color: styleSheet.text
        )
    }

    private func drawCaption(_ text: String, at centerX: CGFloat, color: NSColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: PanelFont.secondary,
            .foregroundColor: color,
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let track = trackRect
        let x = min(max(track.minX, centerX - size.width / 2), track.maxX - size.width)
        (text as NSString).draw(at: NSPoint(x: x, y: track.maxY + 12), withAttributes: attributes)
    }

    // MARK: - Scrubbing

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) { scrub(event) }
    override func mouseDragged(with event: NSEvent) { scrub(event) }

    private func scrub(_ event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let index = nearestIndex(toX: point.x), index != selectedIndex else { return }
        selectedIndex = index
        if let record = selectedRecord { delegate?.versionTimeline(self, didScrubTo: record) }
    }

    override func keyDown(with event: NSEvent) {
        switch KeyBinding.key(for: event) {
        case "left": step(-1)
        case "right": step(1)
        default: super.keyDown(with: event)
        }
    }

    private func step(_ delta: Int) {
        guard !versions.isEmpty else { return }
        let next = min(max(0, selectedIndex + delta), versions.count - 1)
        guard next != selectedIndex else { return }
        selectedIndex = next
        if let record = selectedRecord { delegate?.versionTimeline(self, didScrubTo: record) }
    }

    override func accessibilityPerformIncrement() -> Bool {
        step(1)
        return true
    }

    override func accessibilityPerformDecrement() -> Bool {
        step(-1)
        return true
    }
}
