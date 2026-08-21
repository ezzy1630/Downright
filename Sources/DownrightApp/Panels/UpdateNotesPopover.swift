import AppKit
import MarkdownCore
import MarkdownRender

/// The glass panel that unfurls under "Update Now" while the pointer rests on
/// it, showing what the waiting build actually changes.
///
/// It exists because the press installs.  A button that restarts the app the
/// moment it is clicked has to answer "into what?" before it is clicked, and a
/// tooltip cannot carry release notes.  Hovering is the one gesture that can
/// ask the question without committing to the answer.
///
/// Three constraints shape everything here:
///
/// * **The pill must never move.**  The panel is a separate child window
///   hanging below the pill; the button keeps the exact frame the pointer is
///   already aiming at.
/// * **The travel must be bridged.**  The window's top edge is flush with the
///   pill's bottom edge and the visible glass is inset below it, so a pointer
///   moving from button to panel never crosses dead space.
/// * **It must not eat the click.**  The window never becomes key, never
///   activates the app, and hit-tests to nothing outside its own body.
@MainActor
final class UpdateNotesPopover {
    /// Dwell before the panel appears.  Without it, the panel flashes every
    /// time the pointer sweeps across the titlebar on its way somewhere else,
    /// and no entrance survives being triggered by accident all day.
    static let hoverInDelay: TimeInterval = 0.25
    /// Grace after the pointer leaves both bodies.  Long enough to cross the
    /// bridge on a diagonal, short enough that leaving feels like leaving.
    static let dismissGrace: TimeInterval = 0.14
    /// How often the pointer is tested against the live region.  Cheaper and
    /// far more predictable than tracking areas spanning two windows.
    private static let pointerPollInterval: TimeInterval = 0.1

    fileprivate enum Layout {
        static let width = PanelMetrics.detailWidth
        /// The transparent strip joining the pill to the glass.  Part of the
        /// window, so the pointer is still "inside" while crossing it.
        static let bridgeHeight: CGFloat = 6
        static let inset: CGFloat = 14
        static let notesMinimumHeight: CGFloat = 54
        /// Notes render at the app's own document type scale — this is
        /// Downright reading its own release notes — so the cap is set in
        /// lines rather than pixels: about ten of them, which is an opening
        /// worth reading and still a panel rather than a window.
        static let notesMaximumHeight: CGFloat = 244
        /// Room inside the window for the body's shadow to fall.
        static let shadowMargin = PanelMetrics.floatingShadowMargin
    }

    /// One pointer, one panel.  A second presentation replaces the first
    /// rather than leaving two glass bodies on screen.
    ///
    /// Strong on purpose, and cleared in `dismiss()`.  The panel has to outlive
    /// the call that built it — its own pointer tracking is what takes it down
    /// — so a weak owner here means a body on screen with nothing left alive
    /// to dismiss it.
    private static var current: UpdateNotesPopover?

    private let panel: NSPanel
    private let surface: UpdateNotesSurface
    private weak var anchor: NSView?
    private var pointerTimer: Timer?
    /// Body plus bridge in window coordinates — what the pointer has to stay
    /// inside, as distinct from the window, which is larger by the room the
    /// shadow needs to fall into.
    private let bodyWindowRect: NSRect
    private var outsideSince: Date?
    private var isDismissing = false
    /// The panel dismisses itself on pointer-exit, so the pill it came from
    /// has to be told rather than asked.
    var onDismiss: (() -> Void)?

    // MARK: - Presentation

    /// Builds and shows the panel under `anchor`.  Returns nil when there is
    /// nothing worth showing (no window, no screen, or no update to describe).
    @discardableResult
    static func present(
        from anchor: NSView,
        metadata: UpdateMetadata?,
        isReady: Bool,
        sheet: StyleSheet
    ) -> UpdateNotesPopover? {
        current?.dismiss(animated: false)
        guard let window = anchor.window, window.isVisible, window.screen != nil,
              let metadata
        else {
            return nil
        }
        let popover = UpdateNotesPopover(
            anchor: anchor, window: window, metadata: metadata, isReady: isReady, sheet: sheet
        )
        current = popover
        popover.show()
        return popover
    }

    static func dismissCurrent(animated: Bool = true) {
        current?.dismiss(animated: animated)
    }

    private init(
        anchor: NSView,
        window: NSWindow,
        metadata: UpdateMetadata,
        isReady: Bool,
        sheet: StyleSheet
    ) {
        self.anchor = anchor

        let content = UpdateNotesContentView(metadata: metadata, isReady: isReady, sheet: sheet)
        let bodyHeight = content.preferredHeight(width: Layout.width)
        surface = UpdateNotesSurface(content: content, sheet: sheet)

        // The window carries the bridge strip above the body and shadow room
        // around it; the body itself is the only part that paints.
        let windowSize = NSSize(
            width: Layout.width + Layout.shadowMargin * 2,
            height: bodyHeight + Layout.bridgeHeight + Layout.shadowMargin
        )
        let anchorFrame = anchor.convert(anchor.bounds, to: nil)
        let anchorOnScreen = window.convertToScreen(anchorFrame)
        // Trailing edges align; the window's top edge meets the pill's bottom.
        var origin = NSPoint(
            x: anchorOnScreen.maxX - Layout.width - Layout.shadowMargin,
            y: anchorOnScreen.minY - windowSize.height
        )
        if let screen = window.screen {
            let visible = screen.visibleFrame
            origin.x = min(max(origin.x, visible.minX - Layout.shadowMargin), visible.maxX - windowSize.width + Layout.shadowMargin)
            origin.y = max(origin.y, visible.minY)
        }

        panel = NSPanel(
            contentRect: NSRect(origin: origin, size: windowSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false  // the body draws its own; a window shadow would
                                 // need re-invalidating on every frame of the pour
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = false
        panel.level = .normal
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .transient]
        panel.animationBehavior = .none
        panel.setAccessibilityRole(.popover)
        panel.setAccessibilityLabel("Release notes for \(metadata.displayVersionString)")

        let root = UpdateNotesRootView(liveInset: Layout.shadowMargin)
        root.frame = NSRect(origin: .zero, size: windowSize)
        surface.frame = NSRect(
            x: Layout.shadowMargin,
            y: Layout.shadowMargin,
            width: Layout.width,
            height: bodyHeight
        )
        bodyWindowRect = surface.frame.union(
            NSRect(
                x: surface.frame.minX,
                y: surface.frame.maxY,
                width: surface.frame.width,
                height: Layout.bridgeHeight
            )
        )
        root.liveRegion = bodyWindowRect
        root.addSubview(surface)
        panel.contentView = root
    }

    deinit {
        // Every release path goes through `dismiss()`, which invalidates this.
        // Belt and braces: a repeating timer the run loop still owns would
        // otherwise outlive the object it was polling on behalf of.
        pointerTimer?.invalidate()
    }

    private func show() {
        guard let host = anchor?.window else { return }
        host.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        surface.refreshGlassAfterWindowAttach()
        surface.present()
        startPointerTracking()
    }

    // MARK: - Dismissal

    func dismiss(animated: Bool = true) {
        guard !isDismissing else { return }
        isDismissing = true
        if UpdateNotesPopover.current === self { UpdateNotesPopover.current = nil }
        onDismiss?()
        onDismiss = nil
        pointerTimer?.invalidate()
        pointerTimer = nil
        guard animated, !surface.reducesMotion else {
            close()
            return
        }
        // Nobody watches an exit: a plain fade, faster than the arrival.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.quick
            context.timingFunction = Motion.timing(.easeOut)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.close() }
        }
    }

    private func close() {
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        panel.contentView = nil
    }

    /// The union the pointer must stay inside: the pill, the bridge, the body.
    private var liveScreenRegion: NSRect? {
        guard let anchor, let host = anchor.window else { return nil }
        let anchorOnScreen = host.convertToScreen(anchor.convert(anchor.bounds, to: nil))
        return anchorOnScreen.union(panel.convertToScreen(bodyWindowRect))
    }

    private func startPointerTracking() {
        pointerTimer?.invalidate()
        let timer = Timer.scheduledTimer(
            withTimeInterval: Self.pointerPollInterval, repeats: true
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPointer() }
        }
        // The pour and any document scrolling both run in tracking modes; a
        // default-mode-only timer would stop testing the pointer mid-gesture.
        RunLoop.main.add(timer, forMode: .common)
        pointerTimer = timer
    }

    private func checkPointer() {
        guard let host = anchor?.window, host.isVisible, NSApp.isActive else {
            dismiss()
            return
        }
        guard let region = liveScreenRegion else {
            dismiss()
            return
        }
        if region.contains(NSEvent.mouseLocation) {
            outsideSince = nil
            return
        }
        let since = outsideSince ?? Date()
        outsideSince = since
        if Date().timeIntervalSince(since) >= Self.dismissGrace { dismiss() }
    }
}

// MARK: - Root view

/// Passes every click outside the body straight through to the document.  The
/// window is much larger than what it paints — it carries a bridge strip and
/// shadow room — and none of that margin may swallow a click.
private final class UpdateNotesRootView: NSView {
    var liveRegion: NSRect = .zero
    private let liveInset: CGFloat

    init(liveInset: CGFloat) {
        self.liveInset = liveInset
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard liveRegion.contains(point) else { return nil }
        return super.hitTest(point)
    }
}

// MARK: - Surface (the pour)

/// The glass body, and the one piece of motion in this file.
///
/// It arrives as a *pour*, not a fade: the first visible sliver is already
/// real material at `Motion.floatingSurfaceSliverOpacity`, full presence
/// lands inside the first quarter of the travel, and the rest of the arrival
/// is the body unfurling downward under a reveal mask.  Glass faded up from
/// zero has nothing to refract and reads as a grey rectangle resolving, which
/// is the whole reason those two constants exist.
@MainActor
private final class UpdateNotesSurface: Motion.SpringSurfaceView {
    /// The height that is visible the instant the panel appears.
    private static let sliverHeight: CGFloat = 20

    let reducesMotion: Bool

    private let glass: ChromeGlass
    private let revealMask = CAShapeLayer()
    private var reveal: Motion.SpringScalar
    private var revealTarget: CGFloat = 0

    init(content: NSView, sheet: StyleSheet) {
        reducesMotion = sheet.reduceMotion
        glass = ChromeGlass(
            styleSheet: sheet,
            cornerRadius: PanelMetrics.surfaceRadius,
            tint: .panel
        )
        // A hover surface is quicker than a summoned one: the reader is
        // holding still and waiting for it, so `deliberate` reads as lag.
        reveal = Motion.SpringScalar(
            value: 0, perceptualDuration: Motion.springStandard, bounce: 0.06
        )
        super.init(frame: .zero)

        wantsLayer = true
        revealMask.fillColor = NSColor.black.cgColor
        revealMask.actions = ["path": NSNull(), "frame": NSNull()]
        layer?.mask = revealMask

        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor),
            content.topAnchor.constraint(equalTo: glass.contentView.topAnchor),
            content.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor),
        ])

        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    func refreshGlassAfterWindowAttach() {
        glass.frame = bounds
        glass.layoutSubtreeIfNeeded()
        applyReveal()
    }

    func present() {
        revealTarget = 1
        guard !reducesMotion else {
            reveal.snap(to: 1)
            applyReveal()
            return
        }
        reveal.snap(to: 0)
        applyReveal()
        // `snap` sets the target as well as the value, so the pour has to be
        // retargeted after it or the spring is born already settled.
        reveal.target(1)
        armSprings()
    }

    override func layout() {
        super.layout()
        glass.frame = bounds
        applyReveal()
    }

    override func springTick(dt: CGFloat) -> Bool {
        reveal.advance(dt: dt)
    }

    override func springApply() { applyReveal() }

    override func springsSettleImmediately() {
        reveal.snap(to: revealTarget)
        applyReveal()
    }

    private func applyReveal() {
        let full = bounds.height
        guard full > 1, bounds.width > 1 else { return }
        let sliver = min(Self.sliverHeight, full)
        let fraction = min(max(reveal.value, 0), 1)
        let height = sliver + (full - sliver) * fraction
        // The body unfurls downward, so the revealed rect hangs from the top.
        let rect = CGRect(x: 0, y: full - height, width: bounds.width, height: height)
        let radius = min(PanelMetrics.surfaceRadius, height / 2)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.path = CGPath(
            roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil
        )
        CATransaction.commit()

        let presence = min(1, fraction / max(Motion.floatingSurfacePresenceFraction, 0.001))
        alphaValue = Motion.floatingSurfaceSliverOpacity
            + (1 - Motion.floatingSurfaceSliverOpacity) * presence
    }
}

// MARK: - Content

/// Version, what it changes, and a way out to the full notes.
///
/// The notes are already in hand: the release pipeline runs `generate_appcast`
/// with `--embed-release-notes`, so the appcast `<description>` carries the
/// Markdown and `UpdateMetadata.itemDescription` has it the moment the update
/// is found.  This panel costs no network request of its own.
@MainActor
private final class UpdateNotesContentView: NSView {
    private let stack = NSStackView()
    private let notesScroll = NSScrollView()
    private let metadata: UpdateMetadata
    private let sheet: StyleSheet
    private var notesHeight: NSLayoutConstraint!

    init(metadata: UpdateMetadata, isReady: Bool, sheet: StyleSheet) {
        self.metadata = metadata
        self.sheet = sheet
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12),
        ])

        // Header: the version this installs into, and how far away it is.
        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = 8
        let title = NSTextField(labelWithString: "Downright \(metadata.displayVersionString)")
        title.font = PanelFont.title
        title.textColor = sheet.text
        let status = NSTextField(labelWithString: Self.statusText(metadata, isReady: isReady))
        status.font = PanelFont.secondary
        status.textColor = sheet.textFaint
        status.setContentHuggingPriority(.required, for: .horizontal)
        header.distribution = .fill
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        title.lineBreakMode = .byTruncatingTail
        header.addArrangedSubview(title)
        header.addArrangedSubview(status)
        stack.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let rule = NSBox()
        rule.boxType = .separator
        stack.addArrangedSubview(rule)
        rule.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        notesScroll.hasVerticalScroller = true
        notesScroll.drawsBackground = false
        notesScroll.borderType = .noBorder
        notesScroll.autohidesScrollers = true
        notesScroll.scrollerStyle = .overlay
        stack.addArrangedSubview(notesScroll)
        notesScroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        notesHeight = notesScroll.heightAnchor.constraint(
            equalToConstant: UpdateNotesPopover.Layout.notesMinimumHeight
        )
        notesHeight.isActive = true

        // The footer is the honest half of "capped": the panel shows an
        // opening, and says plainly where the rest of it lives.
        if let infoURL = metadata.infoURL, infoURL.scheme == "https" {
            let link = UpdateNotesLinkButton(title: "Full notes", url: infoURL, sheet: sheet)
            stack.addArrangedSubview(link)
        }
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    /// Lays the notes out at the real width, then reports the height the panel
    /// should take: as tall as the notes need, inside the cap.
    func preferredHeight(width: CGFloat) -> CGFloat {
        let notesWidth = width - 28
        let summary = UpdateNotesSummary.summary(from: metadata.itemDescription)
        if summary.isEmpty {
            let empty = NSTextField(wrappingLabelWithString: "No release notes for this build.")
            empty.font = PanelFont.row
            empty.textColor = sheet.textFaint
            empty.preferredMaxLayoutWidth = notesWidth
            notesScroll.documentView = empty
            empty.frame = NSRect(
                x: 0, y: 0, width: notesWidth, height: empty.fittingSize.height
            )
            notesHeight.constant = UpdateNotesPopover.Layout.notesMinimumHeight
        } else {
            let cap = UpdateNotesPopover.Layout.notesMaximumHeight
            // The factory lays out at a zero width; it is re-run below at the
            // real one so every measurement reflects the shown width.
            // Drop whole lines until the notes fit, rather than letting the
            // scroll view clip the last one. A hover panel that has to be
            // scrolled to finish a sentence is worse than one that stops
            // cleanly and says where the rest is — which the footer does.
            var text = summary
            var measured = Self.measure(text, width: notesWidth, sheet: sheet)
            var guardCount = 0
            while measured > cap, guardCount < 12,
                  let shorter = UpdateNotesSummary.droppingLastLine(text) {
                text = shorter
                measured = Self.measure(text, width: notesWidth, sheet: sheet)
                guardCount += 1
            }
            // A fresh view for the one that is shown: the measuring views were
            // re-laid out repeatedly, and reusing one leaves the discarded
            // candidates' fragments drawn beneath the final text.
            let textView = UpdateNotesView.markdownTextView(for: text, sheet: sheet)
            textView.frame = NSRect(x: 0, y: 0, width: notesWidth, height: max(measured, 1))
            textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
            notesScroll.documentView = textView
            notesHeight.constant = min(
                max(measured, UpdateNotesPopover.Layout.notesMinimumHeight), cap
            )
        }
        widthAnchor.constraint(equalToConstant: width).isActive = true
        layoutSubtreeIfNeeded()
        return ceil(fittingSize.height)
    }

    /// Lays `text` out at `width` and reports the height it needs.
    private static func measure(_ text: String, width: CGFloat, sheet: StyleSheet) -> CGFloat {
        let textView = UpdateNotesView.markdownTextView(for: text, sheet: sheet)
        textView.frame = NSRect(x: 0, y: 0, width: width, height: 1)
        textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        guard let layoutManager = textView.textLayoutManager else {
            return UpdateNotesPopover.Layout.notesMaximumHeight
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)
        return ceil(layoutManager.usageBoundsForTextContainer.height) + 12
    }

    private static func statusText(_ metadata: UpdateMetadata, isReady: Bool) -> String {
        if isReady { return "Ready to install" }
        guard metadata.contentLength > 0 else { return "" }
        return ByteCountFormatter.string(
            fromByteCount: Int64(metadata.contentLength), countStyle: .file
        )
    }

}

/// Trims the embedded release notes to what a hover can honestly show.
///
/// The panel disappears when the pointer leaves it, so it is the wrong
/// surface for a wall of text: it stops early and lets the "Full notes" link
/// carry the rest.  The leading `#` title is dropped because the panel header
/// above it already names the version it would repeat.
enum UpdateNotesSummary {
    static func summary(from markdown: String?) -> String {
        guard let markdown else { return "" }
        let maximumLines = 10
        let maximumCharacters = 700
        var kept: [String] = []
        var characters = 0
        var truncated = false
        var seenContent = false
        for line in markdown.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !seenContent {
                if trimmed.isEmpty { continue }
                if trimmed.hasPrefix("# ") { seenContent = true; continue }
                seenContent = true
            }
            if kept.count >= maximumLines || characters + trimmed.count > maximumCharacters {
                truncated = !trimmed.isEmpty
                break
            }
            kept.append(line)
            characters += trimmed.count
        }
        while let last = kept.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            kept.removeLast()
        }
        guard !kept.isEmpty else { return "" }
        if truncated { kept.append("") ; kept.append("…") }
        return kept.joined(separator: "\n")
    }

    /// Drops one content line, keeping (or adding) the trailing marker that
    /// says the notes were cut.  `nil` once there is nothing left to drop.
    static func droppingLastLine(_ text: String) -> String? {
        var lines = text.components(separatedBy: "\n")
        func dropTrailingNoise() {
            while let last = lines.last {
                let trimmed = last.trimmingCharacters(in: .whitespaces)
                guard trimmed.isEmpty || trimmed == "…" else { return }
                lines.removeLast()
            }
        }
        dropTrailingNoise()
        guard lines.count > 1 else { return nil }
        lines.removeLast()
        dropTrailingNoise()
        guard !lines.isEmpty else { return nil }
        return lines.joined(separator: "\n") + "\n\n…"
    }
}

// MARK: - Footer link

/// A plain text link.  Uses `acceptsFirstMouse` because the panel never
/// becomes key: the first click on it must be the click that works.
@MainActor
private final class UpdateNotesLinkButton: NSButton {
    private let url: URL

    init(title: String, url: URL, sheet: StyleSheet) {
        self.url = url
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        attributedTitle = NSAttributedString(
            string: "\(title) ↗",
            attributes: [
                .font: PanelFont.secondary,
                .foregroundColor: sheet.link,
            ]
        )
        target = self
        action = #selector(open)
        setAccessibilityRole(.link)
        toolTip = url.absoluteString
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    @objc private func open() {
        NSWorkspace.shared.open(url)
        UpdateNotesPopover.dismissCurrent(animated: false)
    }
}
