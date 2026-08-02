import AppKit
import MarkdownRender

enum TrustPromptDecision: Sendable, Equatable {
    case allowOnce
    case allowForFile
    case allowForFolder
    case deny
    case revoke
}

@MainActor
protocol TrustPromptViewDelegate: AnyObject {
    func trustPrompt(_ view: TrustPromptView, didChoose decision: TrustPromptDecision, request: TrustRequest)
}

/// Non-modal, read-only prompt for an external effect.  It reports a typed
/// decision; it never opens a URL, reads a file, or launches an application.
@MainActor
final class TrustPromptView: NSView, PanelSurface {
    weak var delegate: TrustPromptViewDelegate?

    var request: TrustRequest? {
        didSet { reload() }
    }

    var styleSheet: StyleSheet {
        didSet { backdrop.styleSheet = styleSheet; applyStyle() }
    }

    var preferredWidth: CGFloat { 360 }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Permission Needed")
    private let effectLabel = NSTextField(labelWithString: "")
    private let targetLabel = NSTextField(wrappingLabelWithString: "")
    private let allowOnceButton = NSButton(title: "Allow Once", target: nil, action: nil)
    private let allowFileButton = NSButton(title: "Allow for File", target: nil, action: nil)
    private let allowFolderButton = NSButton(title: "Allow for Folder", target: nil, action: nil)
    private let denyButton = NSButton(title: "Deny", target: nil, action: nil)
    private let revokeButton = NSButton(title: "Revoke", target: nil, action: nil)

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        effectLabel.font = PanelFont.rowEmphasised
        effectLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(effectLabel)

        targetLabel.font = PanelFont.secondary
        targetLabel.maximumNumberOfLines = 4
        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(targetLabel)

        configure(allowOnceButton, action: #selector(allowOnce(_:)), label: "Allow this action once")
        configure(allowFileButton, action: #selector(allowFile(_:)), label: "Allow this action for this file")
        configure(allowFolderButton, action: #selector(allowFolder(_:)), label: "Allow this action for this folder")
        configure(denyButton, action: #selector(deny(_:)), label: "Deny this action")
        configure(revokeButton, action: #selector(revoke(_:)), label: "Revoke matching trust")

        let buttons = NSStackView(views: [allowOnceButton, allowFileButton, allowFolderButton, denyButton, revokeButton])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 5
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            effectLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            effectLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            effectLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 12),
            targetLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            targetLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            targetLabel.topAnchor.constraint(equalTo: effectLabel.bottomAnchor, constant: 4),
            buttons.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 14),
            buttons.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -PanelMetrics.inset),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Permission Needed")
        applyStyle()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func configure(_ button: NSButton, action: Selector, label: String) {
        button.target = self
        button.action = action
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.setAccessibilityLabel(label)
    }

    func reload() {
        guard let request else {
            effectLabel.stringValue = "No pending action"
            targetLabel.stringValue = ""
            return
        }
        effectLabel.stringValue = request.effect.title
        targetLabel.stringValue = "Target: \(request.target.displayName)"
        effectLabel.setAccessibilityLabel(request.effect.title)
        targetLabel.setAccessibilityLabel(targetLabel.stringValue)
    }

    func chooseForTesting(_ decision: TrustPromptDecision) {
        choose(decision)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard request != nil else { super.keyDown(with: event); return }
        if event.keyCode == 36 || event.keyCode == 76 {
            choose(.allowOnce)
        } else if event.keyCode == 53 {
            choose(.deny)
        } else {
            super.keyDown(with: event)
        }
    }

    @objc private func allowOnce(_ sender: Any?) { choose(.allowOnce) }
    @objc private func allowFile(_ sender: Any?) { choose(.allowForFile) }
    @objc private func allowFolder(_ sender: Any?) { choose(.allowForFolder) }
    @objc private func deny(_ sender: Any?) { choose(.deny) }
    @objc private func revoke(_ sender: Any?) { choose(.revoke) }

    private func choose(_ decision: TrustPromptDecision) {
        guard let request else { return }
        delegate?.trustPrompt(self, didChoose: decision, request: request)
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        effectLabel.textColor = styleSheet.text
        targetLabel.textColor = styleSheet.textSecondary
        for button in [allowOnceButton, allowFileButton, allowFolderButton, denyButton, revokeButton] {
            button.contentTintColor = styleSheet.textSecondary
        }
    }
}
