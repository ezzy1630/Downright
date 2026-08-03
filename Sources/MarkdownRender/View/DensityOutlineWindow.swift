import AppKit

public struct DensityOutlineEntry: Equatable, Sendable {
    public var title: String
    public var level: Int
    public var fraction: CGFloat
    public var isCurrent: Bool

    public init(title: String, level: Int, fraction: CGFloat, isCurrent: Bool = false) {
        self.title = title
        self.level = level
        self.fraction = fraction
        self.isCurrent = isCurrent
    }
}

/// Expanded navigation rail. It is a child window so it can grow over the
/// document without changing the document measure or split-view geometry.
final class DensityOutlineWindow: NSPanel, NSTableViewDataSource, NSTableViewDelegate {
    static let rowHeight: CGFloat = 44
    static let cornerRadius: CGFloat = 14
    static let showDwell: TimeInterval = 0.25
    static let hideDelay: TimeInterval = 0.09
    static let showDuration: TimeInterval = 0.12
    static let hideDuration: TimeInterval = 0.09

    var styleSheet: StyleSheet { didSet { backdrop.styleSheet = styleSheet; table.reloadData() } }
    var entries: [DensityOutlineEntry] = [] { didSet { table.reloadData() } }
    var onSelect: ((CGFloat) -> Void)?
    var onPointerPresence: ((Bool) -> Void)?

    private let table = OutlineTableView()
    private let scroll = NSScrollView()
    private let backdrop: OutlineBackdrop
    private var presentedFrame = NSRect.zero
    private var dismissGeneration = 0

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = OutlineBackdrop(styleSheet: styleSheet)
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        animationBehavior = .none

        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = Self.rowHeight
        table.intercellSpacing = .zero
        table.selectionHighlightStyle = .none
        table.dataSource = self
        table.delegate = self
        table.onSingleClick = { [weak self] in self?.activateSelection(nil) }
        table.onActivate = { [weak self] in self?.activateSelection(nil) }
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("outline"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)

        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: backdrop.topAnchor, constant: 6),
            scroll.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor, constant: -6),
        ])
        contentView = backdrop
        backdrop.onPointerPresence = { [weak self] in self?.onPointerPresence?($0) }
    }

    override var canBecomeKey: Bool { true }

    func show(rightOf rail: NSView, over parent: NSWindow, keyboard: Bool) {
        guard !entries.isEmpty else { return }
        let railFrame = rail.convert(rail.bounds, to: nil)
        let railScreen = parent.convertToScreen(railFrame)
        let maximumHeight = max(160, floor(parent.frame.height * 0.70))
        let desiredHeight = min(maximumHeight, CGFloat(entries.count) * table.rowHeight + 12)
        let size = NSSize(width: 360, height: desiredHeight)
        var origin = NSPoint(x: railScreen.maxX + 8, y: railScreen.midY - size.height / 2)
        if let visible = (parent.screen ?? NSScreen.main)?.visibleFrame {
            origin.x = max(visible.minX + 4, origin.x)
            origin.y = min(max(visible.minY + 4, origin.y), visible.maxY - size.height - 4)
        }
        let finalFrame = NSRect(origin: origin, size: size)
        dismissGeneration += 1
        presentedFrame = finalFrame
        setFrame(finalFrame.offsetBy(dx: styleSheet.reduceMotion ? 0 : 4, dy: 0), display: true)
        if self.parent !== parent { parent.addChildWindow(self, ordered: .above) }
        alphaValue = styleSheet.reduceMotion ? 1 : 0
        orderFront(nil)

        let current = entries.firstIndex(where: \.isCurrent) ?? 0
        table.selectRowIndexes(IndexSet(integer: current), byExtendingSelection: false)
        table.scrollRowToVisible(current)
        if keyboard {
            makeKey()
            makeFirstResponder(table)
        }
        GutterChrome.animate(reduceMotion: styleSheet.reduceMotion, duration: Self.showDuration) { _ in
            self.animator().alphaValue = 1
            self.animator().setFrame(finalFrame, display: true)
        }
    }

    func dismiss() {
        guard isVisible else { return }
        dismissGeneration += 1
        let generation = dismissGeneration
        let parentWindow = parent
        let remove = { [weak self] in
            guard let self, self.dismissGeneration == generation else { return }
            parentWindow?.removeChildWindow(self)
            self.orderOut(nil)
            self.alphaValue = 1
        }
        guard !styleSheet.reduceMotion else { remove(); return }
        let frame = frame
        GutterChrome.animate(reduceMotion: false, duration: Self.hideDuration) { _ in
            self.animator().alphaValue = 0
            self.animator().setFrame(frame.offsetBy(dx: 4, dy: 0), display: true)
        } completion: {
            remove()
        }
    }

    func cancelDismissAnimation() {
        guard isVisible else { return }
        dismissGeneration += 1
        alphaValue = 1
        setFrame(presentedFrame, display: true)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let identifier = NSUserInterfaceItemIdentifier("densityOutlineRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? DensityOutlineRow
            ?? DensityOutlineRow(identifier: identifier)
        cell.configure(entry: entries[row], styleSheet: styleSheet)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        table.needsDisplay = true
    }

    @objc private func activateSelection(_ sender: Any?) {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard entries.indices.contains(row) else { return }
        let fraction = entries[row].fraction
        dismiss()
        onSelect?(fraction)
    }
}

private final class OutlineTableView: NSTableView {
    var onSingleClick: (() -> Void)?
    var onActivate: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        let row = row(at: convert(event.locationInWindow, from: nil))
        super.mouseDown(with: event)
        guard row >= 0 else { return }
        onSingleClick?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.keyCode == 76 { onActivate?(); return }
        super.keyDown(with: event)
    }
}

private final class DensityOutlineRow: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var leading: NSLayoutConstraint!
    private var trackingArea: NSTrackingArea?
    private var isHovered = false
    private var styleSheet = StyleSheet.current
    private var isCurrent = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.lineBreakMode = .byTruncatingTail
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        leading = label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12)
        NSLayoutConstraint.activate([
            leading,
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isCurrent || isHovered else { return }
        let alpha: CGFloat = isCurrent ? 0.08 : 0.05
        styleSheet.text.withAlphaComponent(alpha).setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6).fill()
    }

    func configure(entry: DensityOutlineEntry, styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        isCurrent = entry.isCurrent
        leading.constant = 12 + CGFloat(max(0, min(5, entry.level - 1))) * 14
        label.stringValue = entry.title
        label.font = NSFont.systemFont(ofSize: 12, weight: entry.isCurrent ? .semibold : .regular)
        label.textColor = entry.isCurrent ? styleSheet.accent : styleSheet.text
    }
}

private final class OutlineBackdrop: NSVisualEffectView {
    var styleSheet: StyleSheet { didSet { needsDisplay = true } }
    var onPointerPresence: ((Bool) -> Void)?
    private var trackingArea: NSTrackingArea?

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = DensityOutlineWindow.cornerRadius
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onPointerPresence?(true) }
    override func mouseExited(with event: NSEvent) { onPointerPresence?(false) }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        styleSheet.rule.setStroke()
        let path = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            xRadius: DensityOutlineWindow.cornerRadius,
            yRadius: DensityOutlineWindow.cornerRadius
        )
        path.lineWidth = 1
        path.stroke()
    }
}
