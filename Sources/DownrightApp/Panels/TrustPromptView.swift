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
final class TrustPromptView: NSView, PanelSurface, FloatingContentMeasuring {
    weak var delegate: TrustPromptViewDelegate?

    var request: TrustRequest? {
        didSet { reload() }
    }

    var styleSheet: StyleSheet {
        didSet { backdrop.styleSheet = styleSheet; applyStyle() }
    }

    var preferredWidth: CGFloat { PanelMetrics.detailWidth }

    private let backdrop: PanelBackdrop
    /// The explanation scrolls; the decisions never do. A height-capped
    /// prompt used to compress its buttons into one unclickable strip
    /// (issue #56), so they live in a footer at their natural height and only
    /// the text above them gives way.
    private let body = TrustPromptBody()
    private let scrollView: NSScrollView
    private let buttons = NSStackView()
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
        self.scrollView = PanelList.makeScrollView(documentView: body)
        super.init(frame: .zero)
        installBackdrop(backdrop)
        body.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        titleLabel.font = PanelFont.system(13, weight: .semibold)
        titleLabel.maximumNumberOfLines = 3
        targetLabel.font = PanelFont.monospaced(11)
        targetLabel.maximumNumberOfLines = 4
        consequenceLabel.font = PanelFont.secondary
        consequenceLabel.maximumNumberOfLines = 4
        askedByLabel.font = PanelFont.secondary
        askedByLabel.maximumNumberOfLines = 2
        for label in labels {
            label.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(label)
        }

        // Deny is the default and also the Esc key.  Both keys agree, and both
        // agree with the safe answer.
        configure(denyButton, action: #selector(deny(_:)), label: "Do not allow this action")
        denyButton.keyEquivalent = "\r"
        configure(allowOnceButton, action: #selector(allowOnce(_:)), label: "Allow this action once")
        configure(allowFileButton, action: #selector(allowFile(_:)), label: "Always allow this action for this file")
        configure(allowFolderButton, action: #selector(allowFolder(_:)), label: "Always allow this action for this folder")
        configure(revokeButton, action: #selector(revoke(_:)), label: "Revoke matching trust")
        revokeButton.hasDestructiveAction = true

        for button in allButtons { buttons.addArrangedSubview(button) }
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 5
        buttons.setClippingResistancePriority(.required, for: .vertical)
        buttons.setHuggingPriority(.required, for: .vertical)
        buttons.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttons)

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -Self.footerGap),
            body.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            body.topAnchor.constraint(equalTo: clip.topAnchor),
            body.widthAnchor.constraint(equalTo: clip.widthAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: body.topAnchor, constant: PanelMetrics.headerTopPadding),
            targetLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            targetLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            targetLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            consequenceLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            consequenceLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            consequenceLabel.topAnchor.constraint(equalTo: targetLabel.bottomAnchor, constant: 8),
            askedByLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            askedByLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            askedByLabel.topAnchor.constraint(equalTo: consequenceLabel.bottomAnchor, constant: 4),
            askedByLabel.bottomAnchor.constraint(equalTo: body.bottomAnchor),
            buttons.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            buttons.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -PanelMetrics.inset),
            buttons.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -PanelMetrics.inset),
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
        // A long file or folder name truncates in the middle, keeping its
        // extension, instead of widening the panel; height never gives way.
        button.lineBreakMode = .byTruncatingMiddle
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .vertical)
        button.setAccessibilityLabel(label)
    }

    private var labels: [NSTextField] { [titleLabel, targetLabel, consequenceLabel, askedByLabel] }

    /// Wrapping labels measure against an explicit width; without one,
    /// `fittingSize` reports a single long line and the panel is sized too
    /// short for the wrapped text.
    private func updateWrapWidth(_ width: CGFloat) {
        let wrap = max(0, width - 2 * PanelMetrics.inset)
        for label in labels where label.preferredMaxLayoutWidth != wrap {
            label.preferredMaxLayoutWidth = wrap
        }
    }

    override func layout() {
        updateWrapWidth(bounds.width)
        super.layout()
    }

    private static let footerGap: CGFloat = 14

    var prefersFullFloatingHeight: Bool { true }

    /// The whole prompt at the current width. The floating inspector fits to
    /// this; when its cap is lower, only the explanation scrolls.
    var fittedContentHeight: CGFloat {
        updateWrapWidth(bounds.width > 0 ? bounds.width : preferredWidth)
        body.layoutSubtreeIfNeeded()
        return body.fittingSize.height + Self.footerGap
            + buttons.fittingSize.height + PanelMetrics.inset
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

        let fileName = Self.fileGrantName(for: request)
        allowFileButton.isHidden = fileName == nil
        allowFileButton.title = fileName.map { "Always Allow for \($0)" } ?? "Always Allow for This File"
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

    /// The file the policy will actually persist. Local effects are scoped to
    /// their target; URL effects without a local target are scoped to the
    /// requesting document. The button must name that same file.
    static func fileGrantName(for request: TrustRequest) -> String? {
        let path = request.target.canonicalPath ?? request.documentPath
        return path.map { URL(fileURLWithPath: $0).lastPathComponent }
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
        case .loadRemoteAsset:
            return "Load an image from \(host(of: request.target.externalURL) ?? "an external site")?"
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
        case .loadRemoteAsset:
            return "Allowing contacts the server below and displays its image. The server can observe your IP address."
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

    var decisionButtonsForTesting: [NSButton] { allButtons }

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

/// Flipped so the prompt reads from the top when it scrolls.
private final class TrustPromptBody: NSView {
    override var isFlipped: Bool { true }
}
