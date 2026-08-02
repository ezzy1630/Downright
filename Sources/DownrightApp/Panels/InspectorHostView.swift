import AppKit

enum InspectorSection: Int, CaseIterable, Equatable {
    case search
    case tasks
    case history
    case context

    var title: String {
        switch self {
        case .search: "Search"
        case .tasks: "Tasks"
        case .history: "History"
        case .context: "Inspector"
        }
    }

    var symbolName: String {
        switch self {
        case .search: "magnifyingglass"
        case .tasks: "checkmark.circle"
        case .history: "clock.arrow.circlepath"
        case .context: "sidebar.right"
        }
    }
}

/// Owns the one trailing inspector surface. The toolbar chooses the section;
/// this view owns only its header, close affordance, and content lifecycle.
@MainActor
final class InspectorHostView: NSView {
    var onClose: (() -> Void)?

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton: NSButton
    private let content = NSView()
    private var closeAction: ButtonAction?
    private var views: [InspectorSection: NSView] = [:]

    private(set) var selectedSection: InspectorSection?

    override init(frame frameRect: NSRect) {
        closeButton = PanelButton.symbol("xmark", label: "Close inspector", action: ButtonAction({}))
        super.init(frame: frameRect)

        titleLabel.font = PanelFont.header
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let action = ButtonAction { [weak self] in self?.onClose?() }
        closeAction = action
        closeButton.target = action
        closeButton.action = #selector(ButtonAction.fire(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(closeButton)
        addSubview(content)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            content.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Inspector")
    }

    required init?(coder: NSCoder) { nil }

    var hasContent: Bool { !views.isEmpty }

    func setContent(_ view: NSView, section: InspectorSection) {
        if let old = views[section], old !== view { old.removeFromSuperview() }
        views[section] = view
        installIfNeeded(view)
        select(section)
    }

    func select(_ section: InspectorSection) {
        guard views[section] != nil else { return }
        selectedSection = section
        titleLabel.stringValue = section.title
        titleLabel.setAccessibilityLabel("\(section.title) inspector")
        for (candidate, view) in views { view.isHidden = candidate != section }
    }

    func removeContent(section: InspectorSection) {
        views.removeValue(forKey: section)?.removeFromSuperview()
        guard selectedSection == section else { return }
        selectedSection = views.keys.sorted { $0.rawValue < $1.rawValue }.first
        if let selectedSection { select(selectedSection) }
        else { titleLabel.stringValue = "" }
    }

    func removeContent(_ view: NSView, section: InspectorSection) {
        guard views[section] === view else { return }
        removeContent(section: section)
    }

    private func installIfNeeded(_ view: NSView) {
        guard view.superview == nil else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            view.topAnchor.constraint(equalTo: content.topAnchor),
            view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }
}
