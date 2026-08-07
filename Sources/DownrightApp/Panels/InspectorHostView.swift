import AppKit
import MarkdownRender

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

    /// The header is chrome like any other panel's, so it follows the theme
    /// rather than the system label colours (§11.3).  A host may assign this;
    /// left alone it tracks the current theme and appearance on its own.
    var styleSheet: StyleSheet = .current {
        didSet {
            sectionControl.styleSheet = styleSheet
            applyStyle()
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton: NSButton
    private let sectionControl: PanelSegmentedControl
    private let content = NSView()
    /// One rule between the host's chrome and whatever panel is inside it, so
    /// every panel reads as a card under a switcher rather than as a list that
    /// starts wherever its own header happens to end.
    private let rule = NSView()
    /// Collapses when the panel's name is already the name of its section —
    /// which is every section except one a command renamed.  A header that
    /// says "Tasks" directly above a switcher whose selected segment says
    /// "Tasks" is 26pt spent on saying it twice (§11.4).
    private var titleHeight: NSLayoutConstraint!
    private var closeAction: ButtonAction?
    private var views: [InspectorSection: NSView] = [:]
    /// Overrides for the header text, so the surface a command opened is named
    /// after that command rather than after its slot.
    private var sectionTitles: [InspectorSection: String] = [:]

    private(set) var selectedSection: InspectorSection?

    override init(frame frameRect: NSRect) {
        closeButton = PanelButton.symbol("xmark", label: "Close inspector", action: ButtonAction({}))
        sectionControl = PanelSegmentedControl(
            items: InspectorSection.allCases.map(\.title),
            styleSheet: .current
        )
        super.init(frame: frameRect)

        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let action = ButtonAction { [weak self] in self?.onClose?() }
        closeAction = action
        closeButton.target = action
        closeButton.action = #selector(ButtonAction.fire(_:))
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        rule.wantsLayer = true
        rule.translatesAutoresizingMaskIntoConstraints = false

        sectionControl.onChange = { [weak self] index in
            guard let section = InspectorSection(rawValue: index) else { return }
            self?.select(section)
        }
        sectionControl.setAccessibilityLabel("Inspector sections")
        sectionControl.setAccessibilityHelp("Choose which inspector panel is shown")
        for section in InspectorSection.allCases {
            sectionControl.setEnabled(false, forSegment: section.rawValue)
        }
        sectionControl.translatesAutoresizingMaskIntoConstraints = false

        // Content first, chrome after: sibling views paint in subview order, so
        // the header has to be *above* the panel it labels.  With the header
        // added first, the content view's opaque backdrop painted straight over
        // it and the inspector opened with 80pt of dead space where its title,
        // its close button, and its section switcher should have been.
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(titleLabel)
        addSubview(sectionControl)
        addSubview(closeButton)
        addSubview(rule)

        // The switcher and the close button share one row.  Close has to be on
        // the row that never collapses, or hiding a redundant title would take
        // the only way out of the inspector with it.
        titleHeight = titleLabel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -PanelMetrics.inset
            ),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.topPadding),
            titleHeight,

            sectionControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            sectionControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            sectionControl.heightAnchor.constraint(equalToConstant: PanelSegmentedControl.controlHeight),

            closeButton.leadingAnchor.constraint(equalTo: sectionControl.trailingAnchor, constant: 6),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.centerYAnchor.constraint(equalTo: sectionControl.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
            rule.topAnchor.constraint(equalTo: sectionControl.bottomAnchor, constant: Metrics.topPadding),
            rule.heightAnchor.constraint(equalToConstant: PanelMetrics.hairline),

            content.topAnchor.constraint(equalTo: rule.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Inspector")
        applyStyle()
    }

    required init?(coder: NSCoder) { nil }

    private enum Metrics {
        /// Air above the switcher and between it and the rule.  The header is
        /// 26 + 20 tall with the title collapsed, against the 80 it took when
        /// it carried a title row of its own.
        static let topPadding: CGFloat = 10
        /// Title row: one line of `PanelFont.header` plus the gap under it.
        static let titleRowHeight: CGFloat = 24
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        closeButton.contentTintColor = styleSheet.textSecondary
        rule.layer?.backgroundColor = styleSheet.rule
            .panelAlpha(styleSheet.increaseContrast ? 0.9 : 0.55, increaseContrast: false).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styleSheet = .current
    }

    /// Esc closes the inspector, whatever is inside it.  Doing it here rather
    /// than in each panel is what makes the key work for all of them — a panel
    /// that forgot to implement it used to swallow the key silently (§11.4).
    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// The same close a panel's own Done button should perform.
    func requestClose() { onClose?() }

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
        showTitle(sectionTitles[section] ?? section.title, for: section)
        sectionControl.setSelectedIndex(section.rawValue)
        for (candidate, view) in views { view.isHidden = candidate != section }
        setAccessibilityValue("\(section.title) section")
    }

    /// A panel may name itself — the header should say "Review", not the
    /// generic "Inspector", when the Review command opened it (§7.2).
    func setTitle(_ title: String, for section: InspectorSection) {
        sectionTitles[section] = title
        guard selectedSection == section else { return }
        showTitle(title, for: section)
    }

    /// The title row exists to say something the switcher cannot, so it appears
    /// only when it *is* saying something else.
    private func showTitle(_ title: String, for section: InspectorSection) {
        titleLabel.stringValue = title
        titleLabel.setAccessibilityLabel("\(title) inspector")
        let redundant = title == section.title
        titleLabel.isHidden = redundant
        titleHeight.constant = redundant ? 0 : Metrics.titleRowHeight
    }

    func removeContent(section: InspectorSection) {
        views.removeValue(forKey: section)?.removeFromSuperview()
        sectionTitles.removeValue(forKey: section)
        sectionControl.setEnabled(false, forSegment: section.rawValue)
        guard selectedSection == section else { return }
        selectedSection = views.keys.sorted { $0.rawValue < $1.rawValue }.first
        if let selectedSection { select(selectedSection) }
        else {
            titleLabel.stringValue = ""
            titleLabel.isHidden = true
            titleHeight.constant = 0
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
}
