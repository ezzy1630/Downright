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
            sectionControl.styleSheet = styleSheet
            applyStyle()
        }
    }

    private let titleLabel = NSTextField(labelWithString: "")
    private let closeButton: NSButton
    private let sectionControl: PanelSegmentedControl
    private let content = NSView()
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
    var closeButtonForTesting: NSButton { closeButton }

    override init(frame frameRect: NSRect) {
        closeButton = PanelButton.symbol(
            "xmark",
            label: "Close inspector",
            action: ButtonAction({}),
            firesOnMouseDown: true
        )
        sectionControl = PanelSegmentedControl(
            items: Self.switcherSections.map(\.title),
            styleSheet: .current
        )
        super.init(frame: frameRect)

        // The slim title row is the surface's name, not a caption — it takes
        // the panel-title font and full text colour so it can carry the pane
        // on its own (the switcher carries it for multi-surface panes).
        titleLabel.font = PanelFont.floatingTitle
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let action = ButtonAction { [weak self] in self?.onClose?() }
        closeAction = action
        closeButton.target = action
        closeButton.action = #selector(ButtonAction.fire(_:))
        PanelButton.setImmediatePressHandler(on: closeButton) { [weak self] in
            self?.onClose?()
        }
        closeButton.translatesAutoresizingMaskIntoConstraints = false
        // Closing is a primary panel action, not hover-only decoration. Keep
        // the full 28pt target visible and live from the first frame.
        closeButton.alphaValue = 1

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

        // The floating surface owns the material. A second visual-effect view
        // here becomes a detached compositor sibling on macOS 26 and can
        // erase the document beneath the panel.
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        addSubview(titleLabel)
        addSubview(sectionControl)
        addSubview(closeButton)
        addSubview(rule)
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
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: closeButton.leadingAnchor, constant: -6
            ),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Metrics.titleTopPadding),
            titleHeight,

            sectionControl.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.horizontalInset),
            sectionControl.topAnchor.constraint(equalTo: titleLabel.bottomAnchor),
            switcherHeight,

            closeButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Metrics.closeTrailingInset
            ),
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

    func syncCloseVisibilityWithPointer() {
        closeButton.alphaValue = 1
    }

    private enum Metrics {
        static let horizontalInset: CGFloat = 18
        static let closeTrailingInset: CGFloat = 14
        /// Air above the switcher and between it and the rule.
        static let topPadding: CGFloat = 10
        /// Air above the slim title row — two points more than the switcher's,
        /// so the header's first line never feels nailed to the toolbar rule.
        static let titleTopPadding: CGFloat = 14
        /// Air between the slim title row and the rule under it.
        static let titleBottomGap: CGFloat = 10
        /// Title row: one line of `PanelFont.header` plus the gap under it.
        static let titleRowHeight: CGFloat = 22
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        closeButton.contentTintColor = styleSheet.textSecondary
        rule.layer?.backgroundColor = styleSheet.rule
            .panelAlpha(styleSheet.increaseContrast ? 0.9 : 0.30, increaseContrast: false).cgColor
    }

    /// Esc closes the inspector, whatever is inside it.  Doing it here rather
    /// than in each panel is what makes the key work for all of them — a panel
    /// that forgot to implement it used to swallow the key silently (§11.4).
    override func cancelOperation(_ sender: Any?) { onClose?() }

    /// The same close a panel's own Done button should perform.
    func requestClose() { onClose?() }

    override var acceptsFirstResponder: Bool { true }
    override var canBecomeKeyView: Bool { true }

    /// The selected panel is the first key-loop stop when the shared floating
    /// body opens. Tasks forwards this to its table; other panels land on the
    /// host so Esc and the section switcher remain reachable.
    func focusForPresentation() {
        if let task = views[.tasks] as? TaskPanelView {
            task.focusForPresentation()
        } else {
            window?.makeFirstResponder(self)
        }
    }

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
        view.layoutSubtreeIfNeeded()
        guard let layer = view.layer else {
            completion?()
            return
        }
        for candidate in [content, view] {
            candidate.layer?.removeAnimation(forKey: "inspector-unfurl")
            candidate.layer?.removeAnimation(forKey: "inspector-fade")
        }

        let settled = CATransform3DIdentity
        let lifted = CATransform3DMakeTranslation(0, arriving ? -14 : -8, 0)

        // Reveal the surface from its top edge. Scaling the panel distorted its
        // text and grew from the centre, which read as a card popping sideways.
        // A rounded mask keeps every glyph at final size while the glass pours
        // downward into the pane.
        let mask = CAShapeLayer()
        mask.frame = layer.bounds
        mask.isGeometryFlipped = layer.isGeometryFlipped
        let fullPath = CGPath(
            roundedRect: layer.bounds,
            cornerWidth: 12,
            cornerHeight: 12,
            transform: nil
        )
        let foldedHeight = min(max(3, layer.bounds.height * 0.035), 18)
        let foldedY = layer.isGeometryFlipped
            ? layer.bounds.minY
            : layer.bounds.maxY - foldedHeight
        let foldedPath = CGPath(
            roundedRect: CGRect(
                x: layer.bounds.minX,
                y: foldedY,
                width: layer.bounds.width,
                height: foldedHeight
            ),
            cornerWidth: min(9, foldedHeight / 2),
            cornerHeight: min(9, foldedHeight / 2),
            transform: nil
        )
        mask.path = arriving ? fullPath : foldedPath
        layer.mask = mask

        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak layer, weak mask] in
            guard let self, self.animationGeneration == generation else { return }
            layer?.removeAnimation(forKey: "inspector-unfurl")
            layer?.removeAnimation(forKey: "inspector-fade")
            mask?.removeAllAnimations()
            layer?.mask = nil
            completion?()
        }

        let reveal = CABasicAnimation(keyPath: "path")
        reveal.fromValue = arriving ? foldedPath : fullPath
        reveal.toValue = arriving ? fullPath : foldedPath
        reveal.duration = Motion.deliberate
        reveal.timingFunction = Motion.timing(.structural)
        mask.add(reveal, forKey: "inspector-liquid-reveal")

        let unfurl = CAKeyframeAnimation(keyPath: "transform")
        unfurl.values = arriving
            ? [lifted, CATransform3DMakeTranslation(0, 2, 0), settled]
            : [settled, CATransform3DMakeTranslation(0, -2, 0), lifted]
        unfurl.keyTimes = [0, 0.76, 1]
        unfurl.duration = Motion.deliberate
        unfurl.timingFunctions = [
            Motion.timing(.structural),
            Motion.timing(.decelerate),
        ]
        layer.add(unfurl, forKey: "inspector-unfurl")

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = arriving ? 0.12 : 1
        fade.toValue = arriving ? 1 : 0.12
        // Leaving is shorter than arriving: a panel should get out of the way
        // as fast as it can while still being seen to go.
        fade.duration = arriving ? Motion.standard : Motion.quick
        fade.timingFunction = Motion.timing(.structural)
        // Arriving, the fade rides one beat behind the unfurl so the surface
        // reads as unrolling out of the control rather than popping in beside
        // it; leaving, the panel is already gone before it refolds.
        // `beginTime` uses the layer's media-time coordinate space. A bare
        // 0.12 is long in the past and produces no delay.
        fade.beginTime = arriving
            ? CACurrentMediaTime() + Motion.floatingContentRevealLead
            : 0
        layer.add(fade, forKey: "inspector-fade")

        CATransaction.commit()
    }

    /// How many surfaces the host is holding — a caller closing one needs to
    /// know whether the pane goes with it or another panel takes over.
    var contentCount: Int { views.count }

    /// One measurement contract for every floating inspector. The header is
    /// part of the host, not the selected panel, so measuring the child alone
    /// clips the last task row and the add affordance as soon as Tasks is
    /// routed through this shared host.
    var floatingFittingHeight: CGFloat {
        layoutSubtreeIfNeeded()
        content.layoutSubtreeIfNeeded()
        let contentHeight: CGFloat
        if let task = views[.tasks] as? TaskPanelView, selectedSection == .tasks {
            contentHeight = task.fittedContentHeight
        } else if let section = selectedSection, let view = views[section] {
            let fitted = view.fittingSize.height
            contentHeight = fitted.isFinite && fitted > 0 ? fitted : view.frame.height
        } else {
            contentHeight = 0
        }
        return max(0, headerFittingHeight + contentHeight)
    }

    private var headerFittingHeight: CGFloat {
        guard let section = selectedSection else { return 0 }
        let switcherVisible = Self.switcherSections.filter { views[$0] != nil }.count > 1
        let title = sectionTitles[section] ?? section.title
        let titleVisible = !switcherVisible
            || title != section.title
            || !Self.switcherSections.contains(section)
        let titleHeight = titleVisible ? Metrics.titleRowHeight : 0
        let rowHeight = switcherVisible
            ? PanelSegmentedControl.controlHeight + Metrics.topPadding
            : Metrics.titleBottomGap
        return Metrics.titleTopPadding + titleHeight + rowHeight + PanelMetrics.hairline
    }

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
