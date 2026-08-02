import AppKit
import MarkdownRender

@MainActor
protocol HistoryInspectorViewDelegate: AnyObject {
    func historyInspectorDidRequestFullHistory(_ inspector: HistoryInspectorView)
    func historyInspector(_ inspector: HistoryInspectorView, didRequestRestore record: SnapshotStore.VersionRecord)
}

/// Compact history controls for the shared inspector. Full rendered comparison
/// remains a separate window because it needs document-scale room.
@MainActor
final class HistoryInspectorView: NSView {
    weak var delegate: HistoryInspectorViewDelegate?

    var styleSheet: StyleSheet {
        didSet {
            timeline.styleSheet = styleSheet
            applyStyle()
        }
    }

    var versions: [SnapshotStore.VersionRecord] = [] {
        didSet {
            timeline.versions = versions
            timeline.selectedIndex = max(0, versions.count - 1)
            updateCaption()
        }
    }

    private let backdrop: PanelBackdrop
    private let timeline: VersionTimelineView
    private let caption = NSTextField(wrappingLabelWithString: "")
    private let openButton: NSButton
    private var openAction: ButtonAction?

    init(styleSheet: StyleSheet = .current) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        timeline = VersionTimelineView(styleSheet: styleSheet)
        openButton = PanelButton.text("Open comparison…", action: ButtonAction({}))
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        timeline.delegate = self
        timeline.translatesAutoresizingMaskIntoConstraints = false
        addSubview(timeline)

        caption.font = PanelFont.row
        caption.maximumNumberOfLines = 0
        caption.translatesAutoresizingMaskIntoConstraints = false
        addSubview(caption)

        let action = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.historyInspectorDidRequestFullHistory(self)
        }
        openAction = action
        openButton.target = action
        openButton.action = #selector(ButtonAction.fire(_:))
        openButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(openButton)

        NSLayoutConstraint.activate([
            timeline.leadingAnchor.constraint(equalTo: leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: trailingAnchor),
            timeline.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            caption.topAnchor.constraint(equalTo: timeline.bottomAnchor, constant: 8),
            openButton.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            openButton.topAnchor.constraint(equalTo: caption.bottomAnchor, constant: 12),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Version history")
        applyStyle()
        updateCaption()
    }

    required init?(coder: NSCoder) { nil }

    private func updateCaption() {
        guard let selected = timeline.selectedRecord else {
            caption.stringValue = "No saved versions yet. Downright records local snapshots when this file changes."
            openButton.isEnabled = false
            return
        }
        caption.stringValue = "Selected \(RelativeTime.long(selected.date)). Open comparison to review it beside the current document."
        openButton.isEnabled = true
    }

    private func applyStyle() {
        caption.textColor = styleSheet.textSecondary
    }
}

extension HistoryInspectorView: VersionTimelineDelegate {
    func versionTimeline(_ view: VersionTimelineView, didScrubTo record: SnapshotStore.VersionRecord) {
        updateCaption()
    }

    func versionTimeline(_ view: VersionTimelineView, didRequestRestore record: SnapshotStore.VersionRecord) {
        delegate?.historyInspector(self, didRequestRestore: record)
    }
}
