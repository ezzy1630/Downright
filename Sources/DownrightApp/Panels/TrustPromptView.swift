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
///
/// The safe answer is the default one.  `⏎` denies and `⎋` denies, so a reader
/// clearing a stack of prompts by holding Return grants nothing — the previous
/// arrangement, where Return meant Allow, made the fastest possible input the
/// most dangerous one (§11.4).  Allow keeps a plain bezel so it never looks
/// like the recommended answer.
@MainActor
final class TrustPromptView: NSView, PanelSurface {
    weak var delegate: TrustPromptViewDelegate?

    var request: TrustRequest? {
        didSet { reload() }
    }

    var styleSheet: StyleSheet {
        didSet { backdrop.styleSheet = styleSheet; applyStyle() }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(wrappingLabelWithString: "Permission Needed")
    private let targetLabel = NSTextField(wrappingLabelWithString: "")
    private let consequenceLabel = NSTextField(wrappingLabelWithString: "")
    private let askedByLabel = NSTextField(wrappingLabelWithString: "")
    private let denyButton = NSButton(title: "Don’t Allow", target: nil, action: nil)
    private let allowOnceButton = NSButton(title: "Allow Once", target: nil, action: nil)
    private let allowFileButton = NSButton(title: "Always Allow for This File", target: nil, action: nil)
    private let allowFolderButton = NSButton(title: "Always Allow for This Folder", target: nil, action: nil)
    private let revokeButton = NSButton(title: "Revoke Existing Permission", target: nil, action: nil)

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)
        installBackdrop(backdrop)

        titleLabel.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 3
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        targetLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        targetLabel.maximumNumberOfLines = 4
        targetLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(targetLabel)

        consequenceLabel.font = PanelFont.secondary
        consequenceLabel.maximumNumberOfLines = 4
        consequenceLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(consequenceLabel)

        askedByLabel.font = PanelFont.secondary
        askedByLabel.maximumNumberOfLines = 2
        askedByLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(askedByLabel)

        // Deny is the default and also the Esc key.  Both keys agree, and both
        // agree with the safe answer.
        configure(denyButton, action: #selector(deny(_:)), label: "Do not allow this action")
        denyButton.keyEquivalent = "\r"
        configure(allowOnceButton, action: #selector(allowOnce(_:)), label: "Allow this action once")
        configure(allowFileButton, action: #selector(allowFile(_:)), label: "Always allow this action for this file")
        configure(allowFolderButton, action: #selector(allowFolder(_:)), label: "Always allow this action for this folder")
        configure(revokeButton, action: #selector(revoke(_:)), label: "Revoke matching trust")
        revokeButton.hasDestructiveAction = true

        let buttons = NSStackView(views: [
            denyButton, allowOnceButton, allowFileButton, allowFolderButton, revokeButton,
        ])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 5
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            targetLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            targetLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            targetLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            consequenceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            consequenceLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            consequenceLabel.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 8),
            askedByLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            askedByLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            askedByLabel.topAnchor.constraint(equalTo: consequenceLabel.bottomAnchor, constant: 4),
            buttons.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            buttons.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            buttons.topAnchor.constraint(equalTo: askedByLabel.bottomAnchor, constant: 14),
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
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityLabel(label)
    }

    // MARK: - Copy

    func reload() {
        guard let request else {
            titleLabel.stringValue = "No pending action"
            targetLabel.stringValue = ""
            consequenceLabel.stringValue = ""
            askedByLabel.stringValue = ""
            for button in allButtons { button.isHidden = true }
            return
        }
        for button in allButtons { button.isHidden = false }

        // Lead with what is about to happen and to what, not with the word
        // "Permission".  A raw URL under a generic heading tells a reader
        // nothing they can decide on.
        titleLabel.stringValue = Self.headline(for: request)
        targetLabel.stringValue = request.target.displayName
        consequenceLabel.stringValue = Self.consequence(for: request.effect)
        askedByLabel.stringValue = request.documentPath.map {
            "Requested by \(URL(fileURLWithPath: $0).lastPathComponent)."
        } ?? "Requested by the current document."

        allowFileButton.isHidden = documentName == nil
        allowFileButton.title = documentName.map { "Always Allow for \($0)" } ?? "Always Allow for This File"
        // Name the folder.  "Allow for Folder" without the folder is a grant
        // whose scope the reader cannot see.
        allowFolderButton.isHidden = folderName == nil
        allowFolderButton.title = folderName.map { "Always Allow for “\($0)”" } ?? "Always Allow for This Folder"

        // The group keeps its name; the specifics are its value, so VoiceOver
        // reads "Permission Needed — Open example.com in your browser?".
        setAccessibilityValue("\(titleLabel.stringValue) \(request.target.displayName)")
        for button in [allowFileButton, allowFolderButton] {
            button.setAccessibilityLabel(button.title)
        }
    }

    private var allButtons: [NSButton] {
        [denyButton, allowOnceButton, allowFileButton, allowFolderButton, revokeButton]
    }

    private var documentName: String? {
        request?.documentPath.map { URL(fileURLWithPath: $0).lastPathComponent }
    }

    /// The folder a "Allow for Folder" grant would actually cover.
    private var folderName: String? {
        guard let request else { return nil }
        let path = request.target.canonicalPath ?? request.documentPath
        guard let path else { return nil }
        let folder = URL(fileURLWithPath: path).deletingLastPathComponent()
        return folder.lastPathComponent.isEmpty ? folder.path : folder.lastPathComponent
    }

    private static func headline(for request: TrustRequest) -> String {
        switch request.effect {
        case .openExternalLink:
            return "Open \(host(of: request.target.externalURL) ?? "an external site") in your browser?"
        case .readLocalAsset:
            return "Read a file from outside this document’s folder?"
        case .launchPathOrEditor:
            return "Open this path in another application?"
        case .automationAppIntent:
            return "Run an app or automation from this document?"
        }
    }

    private static func consequence(for effect: TrustEffect) -> String {
        switch effect {
        case .openExternalLink:
            return "Allowing hands the address below to your default browser. Downright does not load it."
        case .readLocalAsset:
            return "Allowing lets this document display the file below. Downright reads it; it never writes to it."
        case .launchPathOrEditor:
            return "Allowing asks macOS to open the path below in the application registered for it."
        case .automationAppIntent:
            return "Allowing lets this document ask another application to act on your behalf."
        }
    }

    private static func host(of urlString: String?) -> String? {
        guard let urlString, let host = URL(string: urlString)?.host else { return nil }
        return host
    }

    // MARK: - Decisions

    func chooseForTesting(_ decision: TrustPromptDecision) {
        choose(decision)
    }

    override var acceptsFirstResponder: Bool { true }

    /// Esc denies, matching the default button rather than fighting it.
    override func cancelOperation(_ sender: Any?) { choose(.deny) }

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
        // The headline is the most important text on the panel, so it uses the
        // primary colour — it used to use the faintest one on the surface.
        titleLabel.textColor = styleSheet.text
        targetLabel.textColor = styleSheet.textSecondary
        consequenceLabel.textColor = styleSheet.textSecondary
        askedByLabel.textColor = styleSheet.textFaint
        denyButton.contentTintColor = styleSheet.text
        for button in [allowOnceButton, allowFileButton, allowFolderButton, revokeButton] {
            button.contentTintColor = styleSheet.textSecondary
        }
    }
}
