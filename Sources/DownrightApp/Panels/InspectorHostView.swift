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
    private let sectionControl: NSSegmentedControl
    private let content = NSView()
    private var closeAction: ButtonAction?
    private var views: [InspectorSection: NSView] = [:]

    private(set) var selectedSection: InspectorSection?

    override init(frame frameRect: NSRect) {
        closeButton = PanelButton.symbol("xmark", label: "Close inspector", action: ButtonAction({}))
        sectionControl = NSSegmentedControl(
            labels: InspectorSection.allCases.map(\.title),
            trackingMode: .selectOne,
            target: nil,
            action: nil
        )
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

        sectionControl.target = self
        sectionControl.action = #selector(sectionChanged(_:))
        sectionControl.controlSize = .small
        sectionControl.focusRingType = .default
        sectionControl.setAccessibilityLabel("Inspector sections")
        sectionControl.setAccessibilityHelp("Choose which inspector panel is shown")
        for section in InspectorSection.allCases {
            sectionControl.setEnabled(false, forSegment: section.rawValue)
        }
        sectionControl.selectedSegment = -1
        sectionControl.translatesAutoresizingMaskIntoConstraints = false

        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        addSubview(closeButton)
        addSubview(sectionControl)
        addSubview(content)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.centerYAnchor.constraint(equalTo: closeButton.centerYAnchor),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: closeButton.leadingAnchor, constant: -8),
            closeButton.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            sectionControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            sectionControl.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            sectionControl.topAnchor.constraint(equalTo: closeButton.bottomAnchor, constant: 8),
            sectionControl.heightAnchor.constraint(equalToConstant: 24),
            content.topAnchor.constraint(equalTo: sectionControl.bottomAnchor, constant: 8),
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
        sectionControl.setEnabled(true, forSegment: section.rawValue)
        installIfNeeded(view)
        select(section)
    }

    func select(_ section: InspectorSection) {
        guard views[section] != nil else { return }
        selectedSection = section
        titleLabel.stringValue = section.title
        titleLabel.setAccessibilityLabel("\(section.title) inspector")
        sectionControl.selectedSegment = section.rawValue
        for (candidate, view) in views { view.isHidden = candidate != section }
        setAccessibilityValue("\(section.title) section")
    }

    func removeContent(section: InspectorSection) {
        views.removeValue(forKey: section)?.removeFromSuperview()
        sectionControl.setEnabled(false, forSegment: section.rawValue)
        guard selectedSection == section else { return }
        selectedSection = views.keys.sorted { $0.rawValue < $1.rawValue }.first
        if let selectedSection { select(selectedSection) }
        else {
            titleLabel.stringValue = ""
            sectionControl.selectedSegment = -1
            setAccessibilityValue("No inspector section")
        }
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

    @objc private func sectionChanged(_ sender: NSSegmentedControl) {
        guard sender.selectedSegment >= 0,
              let section = InspectorSection(rawValue: sender.selectedSegment) else { return }
        select(section)
    }
}
