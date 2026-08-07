import AppKit
import MarkdownRender

@MainActor
protocol LocalAIPanelViewDelegate: AnyObject {
    func localAIPanel(_ panel: LocalAIPanelView, didRequest task: LocalAITask)
    func localAIPanel(_ panel: LocalAIPanelView, didApply preview: LocalAIPreview)
    func localAIPanelDidCancel(_ panel: LocalAIPanelView)
}

@MainActor
final class LocalAIPanelView: NSView, PanelSurface {
    weak var delegate: LocalAIPanelViewDelegate?

    var styleSheet: StyleSheet { didSet { backdrop.styleSheet = styleSheet; applyStyle() } }
    var availability: LocalAIAvailability = .systemUnavailable { didSet { updateStatus() } }
    var result: LocalAIResult? { didSet { updateResult() } }
    var isRunning = false { didSet { updateStatus() } }
    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: Command.localAI.panelTitle)
    private let taskPopup = NSPopUpButton()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let previewLabel = NSTextField(wrappingLabelWithString: "")
    private var actions: [ButtonAction] = []

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)
        buildInterface()
        applyStyle()
        updateStatus()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildInterface() {
        titleLabel.font = PanelFont.header
        taskPopup.addItems(withTitles: LocalAITask.allCases.map(\.title))
        taskPopup.target = self
        taskPopup.action = #selector(runRequested(_:))
        taskPopup.setAccessibilityLabel("Local AI task")

        statusLabel.font = PanelFont.secondary
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        previewLabel.font = PanelFont.row
        previewLabel.lineBreakMode = .byWordWrapping
        previewLabel.maximumNumberOfLines = 12
        previewLabel.setAccessibilityLabel("Local AI preview")

        let applyAction = ButtonAction { [weak self] in self?.applyRequested() }
        let cancelAction = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.localAIPanelDidCancel(self)
        }
        actions = [applyAction, cancelAction]
        let apply = PanelButton.text("Apply Preview", action: applyAction)
        let cancel = PanelButton.text("Close", action: cancelAction)

        for view in [titleLabel, taskPopup, statusLabel, previewLabel, apply, cancel] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            taskPopup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            taskPopup.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            taskPopup.widthAnchor.constraint(equalToConstant: 150),
            statusLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            statusLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            previewLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            previewLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            previewLabel.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 10),
            apply.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            apply.topAnchor.constraint(equalTo: previewLabel.bottomAnchor, constant: 12),
            cancel.leadingAnchor.constraint(equalTo: apply.trailingAnchor, constant: 6),
            cancel.centerYAnchor.constraint(equalTo: apply.centerYAnchor),
        ])
        setAccessibilityRole(.group)
        setAccessibilityLabel("Local on-device AI")
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        statusLabel.textColor = styleSheet.textFaint
        previewLabel.textColor = styleSheet.text
    }

    private func updateStatus() {
        if isRunning {
            statusLabel.stringValue = "Working on this Mac…"
        } else {
            switch availability {
            case .available: statusLabel.stringValue = "On-device only. Nothing is sent to a server."
            case .frameworkUnavailable: statusLabel.stringValue = "Apple on-device AI is not installed."
            case .systemUnavailable: statusLabel.stringValue = "This Mac does not provide Apple on-device AI."
            }
        }
        statusLabel.setAccessibilityLabel(statusLabel.stringValue)
    }

    private func updateResult() {
        guard let result else { previewLabel.stringValue = "Select a task to preview a result."; return }
        if let preview = result.preview {
            previewLabel.stringValue = "Original:\n\(preview.originalSource)\n\nProposed:\n\(preview.proposedSource)"
        } else {
            previewLabel.stringValue = result.text
        }
        previewLabel.setAccessibilityValue(previewLabel.stringValue)
    }

    @objc private func runRequested(_ sender: NSPopUpButton) {
        guard let task = LocalAITask.allCases[safe: sender.indexOfSelectedItem] else { return }
        delegate?.localAIPanel(self, didRequest: task)
    }

    private func applyRequested() {
        guard let preview = result?.preview else { return }
        delegate?.localAIPanel(self, didApply: preview)
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? { indices.contains(index) ? self[index] : nil }
}
