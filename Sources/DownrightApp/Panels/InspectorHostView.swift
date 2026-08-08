import AppKit
import MarkdownRender

enum InspectorSection: Int, CaseIterable, Equatable {
    case tasks = 0
    case history = 1
    case context = 2
    case search = 3

    var title: String {
        switch self {
        case .search: "Search"
        case .tasks: "Tasks"
        case .history: "History"
        case .context: "Document"
        }
    }
}

/// Owns the one trailing inspector surface. The toolbar chooses the section;
/// this view owns only its header, close affordance, and content lifecycle.
@MainActor
final class InspectorHostView: NSView {
    private static let switcherSections: [InspectorSection] = [.tasks, .history, .context]
    private var animationGeneration = 0
    var onClose: (() -> Void)?
    /// When a morph vessel owns the arrival/departure, the unfurl must stand
    /// down so the two never animate the same view (§ Ring of glass).
    var morphOwnsTransitions = false

    /// The header is chrome like any other panel's, so it follows the theme
    /// rather than the system label colours (§11.3).  A host may assign this;
    /// left alone it tracks the current theme and appearance on its own.
    var styleSheet: StyleSheet = .current {
        didSet {
            backdrop.styleSheet = styleSheet
            sectionControl.styleSheet = styleSheet
            applyStyle()
        }
    }

    /// One glass column runs under the switcher and the panel alike, so the
    /// header never reads as a matte lid on a vibrant surface (§11.4).
    private let backdrop = PanelBackdrop(styleSheet: .current)
    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton: NSButton
    private let sectionControl: PanelSegmentedControl
    private let content = NSView()
    /// A persistent boundary between document and inspector. Glass alone is
    /// too dependent on the wallpaper and theme to define the two surfaces.
    private let leadingRule = NSView()
    /// One rule between the host's chrome and whatever panel is inside it, so
    /// the header reads as the panel's own cap rather than as part of the list
    /// that happens to start below it.
    private let rule = NSView()
    /// The header is one row whose contents follow how much the host holds.
    /// A single surface gets a slim title-plus-close row — a one-item tab
    /// strip would be chrome saying nothing.  Two or more surfaces trade the
    /// title for the switcher, which then *is* the title (and carries the
    /// close button), unless a command renamed the surface and the name row
    /// still earns its line.
    private var titleHeight: NSLayoutConstraint!
    private var switcherHeight: NSLayoutConstraint!
    /// The close button rides whichever row is on screen.
    private var closeOnTitleRow: NSLayoutConstraint!
    private var closeOnSwitcherRow: NSLayoutConstraint!
    private var ruleBelowTitle: NSLayoutConstraint!
    private var ruleBelowSwitcher: NSLayoutConstraint!
    private var closeAction: ButtonAction?
    private var views: [InspectorSection: NSView] = [:]
    /// Overrides for the header text, so the surface a command opened is named
    /// after that command rather than after its slot.
    private var sectionTitles: [InspectorSection: String] = [:]

    private(set) var selectedSection: InspectorSection?

    override init(frame frameRect: NSRect) {
        closeButton = PanelButton.symbol("xmark", label: "Close inspector", action: ButtonAction({}))
        sectionControl = PanelSegmentedControl(
            items: Self.switcherSections.map(\.title),
            styleSheet: .current
        )
        super.init(frame: frameRect)

        // The slim title row is the surface's name, not a caption — it takes
        // the panel-title font and full text colour so it can carry the pane
        // on its own (the switcher carries it for multi-surface panes).
        titleLabel.font = PanelFont.title
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
            guard let section = Self.switcherSections.element(at: index) else { return }
            self?.select(section)
        }
        sectionControl.setAccessibilityLabel("Inspector sections")
        sectionControl.setAccessibilityHelp("Choose which inspector panel is shown")
        for index in Self.switcherSections.indices {
            sectionControl.setEnabled(false, forSegment: index)
        }
        sectionControl.translatesAutoresizingMaskIntoConstraints = false

        // Backdrop first, then content, then chrome: sibling views paint in
        // subview order, so the header has to be *above* the panel it labels.
        // With the header added first, the content view's backdrop painted
        // straight over it and the inspector opened with 80pt of dead space
        // where its title, its close button, and its section switcher should
        // have been.  The shared backdrop underneath both is what lets the
        // header and the panel read as one continuous glass column.  It blends
        // with the window so the page ghosts through the whole column, and a
        // themed veil keeps the chrome legible over a busy document (§11.4).
        backdrop.blendsWithinWindow = true
        // A whisper of veil: the column should read as the window's own glass,
        // not as a slab laid over it.
        backdrop.veilAlpha = 0.12
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        addSubview(backdrop)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(titleLabel)
        addSubview(sectionControl)
        addSubview(closeButton)
        addSubview(rule)
        leadingRule.wantsLayer = true
        leadingRule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(leadingRule)

        // The close button rides whichever header row is on screen, and the
        // rule sits under whichever is lower — both pairs swap in
        // `updateHeaderChrome()` as sections come and go.
        titleHeight = titleLabel.heightAnchor.constraint(equalToConstant: 0)
        switcherHeight = sectionControl.heightAnchor.constraint(
            equalToConstant: PanelSegmentedControl.controlHeight
        )
        closeOnTitleRow = closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor)
        closeOnSwitcherRow = closeButton.centerYAnchor.constraint(equalTo: sectionControl.centerYAnchor)
        ruleBelowTitle = rule.topAnchor.constraint(
            equalTo: titleLabel.bottomAnchor, constant: Metrics.titleBottomGap
        )
        ruleBelowSwitcher = rule.topAnchor.constraint(
            equalTo: sectionControl.bottomAnchor, constant: Metrics.topPadding
        )
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            leadingRule.leadingAnchor.constraint(equalTo: leadingAnchor),
            leadingRule.topAnchor.constraint(equalTo: topAnchor),
            leadingRule.bottomAnchor.constraint(equalTo: bottomAnchor),
            leadingRule.widthAnchor.constraint(equalToConstant: PanelMetrics.hairline),

            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6
            ),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.titleTopPadding),
            titleHeight,

            sectionControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            sectionControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            switcherHeight,

            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),

            rule.leadingAnchor.constraint(equalTo: leadingAnchor),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor),
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
        /// Air above the switcher and between it and the rule.
        static let topPadding: CGFloat = 10
        /// Air above the slim title row — two points more than the switcher's,
        /// so the header's first line never feels nailed to the toolbar rule.
        static let titleTopPadding: CGFloat = 12
        /// Air between the slim title row and the rule under it.
        static let titleBottomGap: CGFloat = 8
        /// Title row: one line of `PanelFont.header` plus the gap under it.
        static let titleRowHeight: CGFloat = 24
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.text
        closeButton.contentTintColor = styleSheet.textSecondary
        rule.layer?.backgroundColor = styleSheet.rule
            .panelAlpha(styleSheet.increaseContrast ? 0.9 : 0.55, increaseContrast: false).cgColor
        leadingRule.layer?.backgroundColor = styleSheet.rule
            .panelAlpha(styleSheet.increaseContrast ? 1 : 0.82, increaseContrast: false).cgColor
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
        if let index = Self.switcherSections.firstIndex(of: section) {
            sectionControl.setEnabled(true, forSegment: index)
        }
        installIfNeeded(view)
        select(section, announceArrival: true)
    }

    func select(_ section: InspectorSection) {
        select(section, announceArrival: false)
    }

    private func select(_ section: InspectorSection, announceArrival: Bool) {
        guard views[section] != nil else { return }
        let previous = selectedSection
        selectedSection = section
        updateHeaderChrome()
        if let index = Self.switcherSections.firstIndex(of: section) {
            sectionControl.setSelectedIndex(index)
        }
        for (candidate, view) in views { view.isHidden = candidate != section }
        if announceArrival, previous != section, let view = views[section] {
            guard !morphOwnsTransitions else {
                // The travelling glass is the arrival now; the unfurl would
                // only double it.
                view.alphaValue = 1
                return
            }
            playArrival(on: view)
        }
        setAccessibilityValue("\(section.title) section")
    }

    /// The panel unfurls downward out of the control that summoned it.
    ///
    /// The toolbar button sits directly above this pane's top edge, so the
    /// honest reading of "open Tasks" is that the list comes *down* from the
    /// ring — not that a rectangle fades in somewhere to the right.  Three
    /// things say that in one gesture: the surface starts a little above its
    /// resting place and descends, it starts slightly compressed toward its
    /// top edge and settles to full height, and it fades up.  Anchoring the
    /// scale at the top means the panel grows away from the ring rather than
    /// out of its own middle.
    ///
    /// The duration is `deliberate`, the same clock the ring's release wave
    /// runs on, because the two are halves of one movement (§11.4).
    private func playArrival(on view: NSView) {
        animateUnfurl(on: view, arriving: true, completion: nil)
    }

    /// The reverse: the panel folds back up toward the ring before the pane
    /// itself collapses, so closing is a retreat rather than a disappearance.
    ///
    /// This one runs on the content container rather than on a single panel,
    /// because a close can arrive with the surfaces already torn down — the
    /// container is the one thing that is always there to fold.  The
    /// completion runs even when Reduce Motion skips the animation, so callers
    /// can always sequence the collapse behind it.
    func playDeparture(completion: @escaping () -> Void) {
        guard !morphOwnsTransitions else {
            // The vessel is the departure; the unfurl would only double it.
            completion()
            return
        }
        animateUnfurl(on: content, arriving: false, completion: completion)
    }

    private func animateUnfurl(on view: NSView, arriving: Bool, completion: (() -> Void)?) {
        animationGeneration &+= 1
        let generation = animationGeneration
        guard !styleSheet.reduceMotion, window != nil else {
            completion?()
            return
        }
        view.wantsLayer = true
        guard let layer = view.layer else {
            completion?()
            return
        }
        for candidate in [content, view] {
            candidate.layer?.removeAnimation(forKey: "inspector-unfurl")
            candidate.layer?.removeAnimation(forKey: "inspector-fade")
        }

        let settled = CATransform3DIdentity
        var folded = CATransform3DMakeScale(1, 0.94, 1)
        folded = CATransform3DTranslate(folded, 0, 10, 0)

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak layer] in
            guard let self, self.animationGeneration == generation else { return }
            layer?.removeAnimation(forKey: "inspector-unfurl")
            layer?.removeAnimation(forKey: "inspector-fade")
            completion?()
        }

        let unfurl = CABasicAnimation(keyPath: "transform")
        unfurl.fromValue = arriving ? folded : settled
        unfurl.toValue = arriving ? settled : folded
        unfurl.duration = Motion.deliberate
        unfurl.timingFunction = Motion.timing(.structural)
        layer.add(unfurl, forKey: "inspector-unfurl")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = arriving ? 0 : 1
        fade.toValue = arriving ? 1 : 0
        // Leaving is shorter than arriving: a panel should get out of the way
        // as fast as it can while still being seen to go.
        fade.duration = arriving ? Motion.standard : Motion.quick
        fade.timingFunction = Motion.timing(.structural)
        // Arriving, the fade rides one beat behind the unfurl so the surface
        // reads as unrolling out of the control rather than popping in beside
        // it; leaving, the panel is already gone before it refolds.
        // `beginTime` uses the layer's media-time coordinate space. A bare
        // 0.12 is long in the past and produces no delay.
        fade.beginTime = arriving ? CACurrentMediaTime() + Motion.quick : 0
        layer.add(fade, forKey: "inspector-fade")

        CATransaction.commit()
    }

    /// How many surfaces the host is holding — a caller closing one needs to
    /// know whether the pane goes with it or another panel takes over.
    var contentCount: Int { views.count }

    /// The surface installed for a section, if any — so a caller that has to
    /// animate a panel out can name the view it is carrying.
    func content(for section: InspectorSection) -> NSView? { views[section] }

    /// A panel may name itself — the header should say "Review", not the
    /// generic "Inspector", when the Review command opened it (§7.2).
    func setTitle(_ title: String, for section: InspectorSection) {
        sectionTitles[section] = title
        guard selectedSection == section else { return }
        updateHeaderChrome()
    }

    /// One header, three shapes:
    ///
    /// * one surface — a slim title-plus-close row.  A one-segment switcher
    ///   would be a tab strip with nothing to switch to.
    /// * several surfaces — the switcher carries the close button, and the
    ///   title row collapses, because a header saying "Tasks" above a segment
    ///   saying "Tasks" is the same line twice.
    /// * several surfaces and a command-named one ("Review") — the title row
    ///   stays, because it says something the switcher cannot.
    private func updateHeaderChrome() {
        guard let section = selectedSection else {
            titleLabel.stringValue = ""
            titleLabel.isHidden = true
            titleHeight.constant = 0
            sectionControl.isHidden = true
            switcherHeight.constant = 0
            closeButton.isHidden = true
            closeOnTitleRow.isActive = false
            closeOnSwitcherRow.isActive = false
            ruleBelowTitle.isActive = false
            ruleBelowSwitcher.isActive = false
            return
        }
        let switcherVisible = Self.switcherSections.filter { views[$0] != nil }.count > 1
        let title = sectionTitles[section] ?? section.title
        let titleVisible = !switcherVisible
            || title != section.title
            || !Self.switcherSections.contains(section)

        titleLabel.stringValue = title
        titleLabel.setAccessibilityLabel("\(title) inspector")
        titleLabel.isHidden = !titleVisible
        titleHeight.constant = titleVisible ? Metrics.titleRowHeight : 0
        sectionControl.isHidden = !switcherVisible
        switcherHeight.constant = switcherVisible ? PanelSegmentedControl.controlHeight : 0
        closeButton.isHidden = false

        // Close rides the switcher row when it is on screen, the title row
        // otherwise; the rule sits under whichever row is lower.  A dead
        // anchor would centre the button on a collapsed row.
        closeOnSwitcherRow.isActive = switcherVisible
        closeOnTitleRow.isActive = titleVisible && !switcherVisible
        ruleBelowSwitcher.isActive = switcherVisible
        ruleBelowTitle.isActive = titleVisible && !switcherVisible
    }

    func removeContent(section: InspectorSection) {
        views.removeValue(forKey: section)?.removeFromSuperview()
        sectionTitles.removeValue(forKey: section)
        if let index = Self.switcherSections.firstIndex(of: section) {
            sectionControl.setEnabled(false, forSegment: index)
        }
        guard selectedSection == section else { updateHeaderChrome(); return }
        selectedSection = views.keys.sorted { $0.rawValue < $1.rawValue }.first
        if let selectedSection { select(selectedSection) }
        else {
            updateHeaderChrome()
            setAccessibilityValue("No inspector section")
        }
    }

    func removeContent(_ view: NSView, section: InspectorSection) {
        guard views[section] === view else { return }
        removeContent(section: section)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        styleSheet = .current
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
