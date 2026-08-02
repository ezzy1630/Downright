import AppKit
import MarkdownCore
import MarkdownRender

/// One window over one document.
///
/// The window owns the document, the text surface, and every transient panel.
/// §11.4 is the layout rule: nothing is resident.  The outline, tasks, siblings,
/// find, and the conflict bar are all summoned and dismissed; what stays on
/// screen is the document, the density gutter, and a breadcrumbView.
@MainActor
final class DocumentWindowController: NSWindowController {
    let markdownDocument = MarkdownDocument()
    private(set) var mode: RenderMode = .live

    var onClose: (() -> Void)?

    // Text surface.  Internal rather than private because the command and
    // support extensions live in sibling files, and `private` is file-scoped.
    var primaryContainer: MarkdownContainerView!
    var splitContainer: MarkdownContainerView?
    var splitViewContainer: NSSplitView?

    // Persistent chrome
    let breadcrumbView = BreadcrumbView()
    let densityGutterView = DensityGutterView()

    // Transient panels (§11.4)
    var outlinePanel: OutlinePanelView?
    var taskPanel: TaskPanelView?
    var siblingSidebar: SiblingSidebarView?
    var navigationPanel: NavigationPanelView?
    var navigationWindow: NavigationPanelWindow?
    var navigationClickMonitor: Any?
    var navigationDeactivationObserver: NSObjectProtocol?
    var navigationSidebar: NSStackView?
    var findBar: FindBarView?
    var conflictBar: ConflictBarView?
    var changeSummaryBar: ChangeSummaryBarView?
    var searchResults: SearchResultsPanelView?
    var searchInspector: SearchInspectorView?
    var historyInspector: HistoryInspectorView?
    var inspectorHost: InspectorHostView?
    var frontMatterEditor: FrontMatterEditorView?
    var assetDoctorPanel: AssetDoctorView?
    var tidySheetWindow: NSWindow?
    var tableEditorWindow: NSWindow?
    private var auxiliaryWindows: [NSWindowController] = []

    // Layout containers
    private var rootView: NSView!
    private var leadingPane: NSView!
    private var trailingPane: NSView!
    var barStack: NSStackView!
    private var windowSplitController: NSSplitViewController!
    var sidebarItem: NSSplitViewItem!
    var inspectorItem: NSSplitViewItem!

    // State
    var scanner: SiblingScanner?
    var pathResolver: PathResolver?
    let findSession = FindSession()
    let jumpHistory = JumpHistory()
    var activeStyleSheet = StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)
    private var themeObservation: ThemeObservation?
    let progressRing = TaskProgressRing()
    private var isPinned = false
    var navigationPinned = false
    private var isFocusMode = false
    var isFocusModeEnabled: Bool { isFocusMode }
    var pendingConflict: MarkdownDocument.Conflict?
    var breadcrumbHideWorkItem: DispatchWorkItem?

    // MARK: - Construction

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.tabbingMode = .preferred
        // Session restoration is owned by DocumentStateStore. AppKit window
        // archives can resurrect obsolete toolbar item views across releases.
        window.isRestorable = false
        window.setFrameAutosaveName("DownrightDocumentWindow")
        window.minSize = NSSize(width: 520, height: 400)
        self.init(window: window)
        window.delegate = self
        buildInterface()
        window.setContentSize(NSSize(width: 1020, height: 728))
        wireDocument()
        observeTheme()
    }

    // MARK: - Opening

    func open(_ url: URL, mode: RenderMode) throws {
        try markdownDocument.open(url)
        // Source Focus is a transient editing state.  Old Read/Source state
        // always migrates into the single editable Document surface.
        self.mode = .live

        scanner = SiblingScanner(
            documentURL: url,
            extraDirectories: Preferences.shared.values.siblingScanDirectories
        )
        scanner?.onChange = { [weak self] in self?.refreshSiblings() }
        pathResolver = PathResolver(documentURL: url)

        window?.title = url.lastPathComponent
        window?.subtitle = url.deletingLastPathComponent().lastPathComponent
        window?.representedURL = url
        applyMode(.live)
        primaryContainer.textView.zoomLevel = markdownDocument.state.zoomLevel
        primaryContainer.textView.foldedHeadingSlugs = markdownDocument.state.foldedHeadings
        primaryContainer.textView.update(document: markdownDocument.parsed, dirty: .wholesale)

        primaryContainer.wantsLayer = true
        primaryContainer.alphaValue = activeStyleSheet.reduceMotion ? 1 : 0
        primaryContainer.layer?.setAffineTransform(CGAffineTransform(translationX: 0, y: -6))
        Motion.run(
            reduceMotion: activeStyleSheet.reduceMotion,
            duration: Motion.quick,
            changes: { _ in
                self.primaryContainer.animator().alphaValue = 1
                self.primaryContainer.layer?.setAffineTransform(.identity)
            }
        )

        refreshDerivedUI()
        if markdownDocument.state.sidebarVisible {
            openNavigationOverlay(focusSearch: false)
            pinNavigationPanel()
        }
        if markdownDocument.state.splitViewEnabled { toggleSplitView() }

        // Restore reading position, then offer to jump to the first thing that
        // changed while the app was closed (§8.2).
        let restored = markdownDocument.restoredOffset()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.primaryContainer.textView.scroll(toOffset: restored, position: .top, animated: false)
            let selection = NSRange(
                location: min(self.markdownDocument.state.selectionLocation, self.markdownDocument.storage.length),
                length: 0
            )
            let available = self.markdownDocument.storage.length - selection.location
            self.primaryContainer.textView.setSourceSelectedRanges([
                NSRange(location: selection.location, length: min(self.markdownDocument.state.selectionLength, available))
            ])
            if !self.markdownDocument.changes.isEmpty { self.presentUnreadChanges() }
            self.dumpLayoutIfRequested()
        }
    }

    /// `DOWNRIGHT_DEBUG_LAYOUT=1` dumps the view geometry once the window has
    /// laid out.  A blank document area has exactly one cause — some view in
    /// this chain has no height — and guessing which is slower than printing.
    func dumpLayoutIfRequested() {
        guard ProcessInfo.processInfo.environment["DOWNRIGHT_DEBUG_LAYOUT"] != nil else { return }
        if ProcessInfo.processInfo.environment["DOWNRIGHT_DEBUG_PANELS"] != nil {
            if siblingSidebar == nil { toggleSiblingSidebar() }
            if taskPanel == nil { toggleTaskPanel() }
        }
        window?.layoutIfNeeded()
        rootView.layoutSubtreeIfNeeded()
        let lines = [
            "window       \(window?.frame ?? .zero)",
            "contentView  \(window?.contentView?.frame ?? .zero)",
            "rootView     \(rootView.frame)",
            "leadingPane  \(leadingPane.frame)",
            "trailingPane \(trailingPane.frame)",
            "barStack     \(barStack.frame)  arranged=\(barStack.arrangedSubviews.count)",
            "container    \(primaryContainer.frame)",
            "  scrollView \(primaryContainer.scrollView.frame)",
            "  clipView   \(primaryContainer.scrollView.contentView.frame)",
            "  docView    \(primaryContainer.scrollView.documentView?.frame ?? .zero)",
            "  textView   \(primaryContainer.textView.frame)",
            "  container  \(primaryContainer.textView.textContainer?.size ?? .zero)",
            "  insets     \(primaryContainer.scrollView.contentInsets)",
            "breadcrumb   \(breadcrumbView.frame)  fitting=\(breadcrumbView.fittingSize)",
            "gutter       \(densityGutterView.frame)  fitting=\(densityGutterView.fittingSize)",
            "storage      \(markdownDocument.storage.length) chars",
            "clipBounds   \(primaryContainer.scrollView.contentView.bounds)",
            "tvInContainer \(primaryContainer.textView.convert(primaryContainer.textView.bounds, to: primaryContainer))",
            "scrollBG     \(primaryContainer.scrollView.backgroundColor) drawsBG=\(primaryContainer.scrollView.drawsBackground)",
            "tvBG         \(primaryContainer.textView.styleSheet.background) / \(primaryContainer.textView.backgroundColor)",
            "tvDrawsBG    \(primaryContainer.textView.drawsBackground)",
            "measureWidth \(primaryContainer.textView.styleSheet.measureWidth)",
        ]
        FileHandle.standardError.write(Data(("\n--- Downright layout ---\n" + lines.joined(separator: "\n") + "\n").utf8))

        guard let directory = ProcessInfo.processInfo.environment["DOWNRIGHT_DEBUG_CAPTURE"] else { return }

        // The titlebar, traffic lights and toolbar are drawn by the window's
        // frame view, not by our content view, so a capture of the content
        // alone shows the document without any of the chrome around it.
        if let frameView = window?.contentView?.superview,
           frameView.bounds.width > 0, frameView.bounds.height > 0,
           let rep = frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds) {
            frameView.cacheDisplay(in: frameView.bounds, to: rep)
            if let png = rep.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("window.png"))
            }
        }

        for (name, view) in [("root", rootView!), ("container", primaryContainer as NSView),
                             ("scroll", primaryContainer.scrollView as NSView),
                             ("clip", primaryContainer.scrollView.contentView as NSView),
                             ("textview", primaryContainer.textView as NSView)] {
            guard view.bounds.width > 0, view.bounds.height > 0,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            guard let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        FileHandle.standardError.write(Data("captured to \(directory)\n".utf8))
    }

    func adopt(text: String, title: String) {
        markdownDocument.adopt(text: text, displayURL: nil)
        window?.title = title
        applyMode(.live)
        primaryContainer.textView.update(document: markdownDocument.parsed, dirty: .wholesale)
        refreshDerivedUI()
    }

    // MARK: - Interface

    private func buildInterface() {
        primaryContainer = MarkdownContainerView(storage: markdownDocument.storage)
        primaryContainer.textView.markdownDelegate = self
        primaryContainer.textView.styleSheet = activeStyleSheet
        primaryContainer.topAccessory = breadcrumbView
        // The density rail is available on demand, not a permanent right rail.

        breadcrumbView.delegate = self
        breadcrumbView.styleSheet = activeStyleSheet
        densityGutterView.delegate = self
        densityGutterView.styleSheet = activeStyleSheet
        progressRing.styleSheet = activeStyleSheet
        breadcrumbView.alphaValue = 0

        rootView = NSView()
        leadingPane = NSView()
        trailingPane = NSView()
        barStack = NSStackView()
        barStack.orientation = .vertical
        barStack.spacing = 0
        barStack.distribution = .fill
        barStack.alignment = .leading

        for view in [primaryContainer, barStack] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }

        let sidebarController = NSViewController()
        sidebarController.view = leadingPane
        let documentController = NSViewController()
        documentController.view = rootView
        let inspectorController = NSViewController()
        inspectorController.view = trailingPane

        let split = NSSplitViewController()
        let sidebar = NSSplitViewItem(sidebarWithViewController: sidebarController)
        sidebar.minimumThickness = 200
        sidebar.maximumThickness = 380
        sidebar.canCollapse = true
        sidebar.isCollapsed = true
        let document = NSSplitViewItem(viewController: documentController)
        let inspector = NSSplitViewItem(inspectorWithViewController: inspectorController)
        inspector.minimumThickness = 260
        inspector.maximumThickness = 420
        inspector.canCollapse = true
        inspector.isCollapsed = true
        split.addSplitViewItem(sidebar)
        split.addSplitViewItem(document)
        split.addSplitViewItem(inspector)
        windowSplitController = split
        sidebarItem = sidebar
        inspectorItem = inspector
        window?.contentViewController = split

        NSLayoutConstraint.activate([
            primaryContainer!.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            primaryContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            primaryContainer.topAnchor.constraint(equalTo: rootView.topAnchor),
            primaryContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            barStack.leadingAnchor.constraint(equalTo: primaryContainer!.leadingAnchor),
            barStack.trailingAnchor.constraint(equalTo: primaryContainer.trailingAnchor),
            barStack.topAnchor.constraint(equalTo: primaryContainer.topAnchor),
        ])

        buildToolbar()
    }

    private func buildToolbar() {
        // v4 installs the centred Document/Source presentation control and
        // replaces the previous multi-button inspector cluster.
        let toolbar = NSToolbar(identifier: "DownrightToolbar.v4")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.isVisible = true
        toolbar.centeredItemIdentifier = NSToolbarItem.Identifier("presentation-mode")
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func wireDocument() {
        markdownDocument.onReparse = { [weak self] parsed, dirty in
            guard let self else { return }
            self.primaryContainer.textView.update(document: parsed, dirty: dirty)
            self.splitContainer?.textView.update(document: parsed, dirty: dirty)
            self.refreshDerivedUI()
        }
        markdownDocument.onExternalEvent = { [weak self] event in self?.handleExternalEvent(event) }
        markdownDocument.onDirtyChanged = { [weak self] dirty in
            self?.window?.isDocumentEdited = dirty
        }
        markdownDocument.currentTopOffsetProvider = { [weak self] in
            self?.primaryContainer.textView.topVisibleOffset ?? 0
        }
        markdownDocument.restoreOffsetHandler = { [weak self] offset in
            self?.primaryContainer.textView.scroll(toOffset: offset, position: .top, animated: false)
        }
        markdownDocument.changes.onChange = { [weak self] in self?.refreshChangeDecorations() }
    }

    private func observeTheme() {
        themeObservation = ThemeStore.shared.observe { [weak self] theme in
            guard let self, let window = self.window else { return }
            self.activeStyleSheet = StyleSheet(theme: theme, appearance: window.effectiveAppearance)
            self.applyStyleSheet()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: Preferences.didChange, object: nil
        )
    }

    @objc private func preferencesDidChange() {
        activeStyleSheet = StyleSheet(theme: ThemeStore.shared.current, appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance)
        applyStyleSheet()
    }

    func applyStyleSheet() {
        primaryContainer.textView.styleSheet = activeStyleSheet
        splitContainer?.textView.styleSheet = activeStyleSheet
        breadcrumbView.styleSheet = activeStyleSheet
        densityGutterView.styleSheet = activeStyleSheet
        progressRing.styleSheet = activeStyleSheet
        outlinePanel?.styleSheet = activeStyleSheet
        navigationPanel?.styleSheet = activeStyleSheet
        taskPanel?.styleSheet = activeStyleSheet
        siblingSidebar?.styleSheet = activeStyleSheet
        findBar?.styleSheet = activeStyleSheet
        searchInspector?.styleSheet = activeStyleSheet
        historyInspector?.styleSheet = activeStyleSheet
        conflictBar?.styleSheet = activeStyleSheet
        changeSummaryBar?.styleSheet = activeStyleSheet
        searchResults?.styleSheet = activeStyleSheet
        frontMatterEditor?.styleSheet = activeStyleSheet
        assetDoctorPanel?.styleSheet = activeStyleSheet
    }

    // MARK: - Modes (§3.2)

    func applyMode(_ newMode: RenderMode) {
        let newMode = newMode.normalizedForEditing
        mode = newMode
        primaryContainer.textView.mode = newMode
        // Never persist a transient raw-source presentation.
        markdownDocument.state.mode = .live
        refreshSourceFocusToolbar()
        window?.toolbar?.validateVisibleItems()
    }

    // MARK: - Derived UI

    func refreshDerivedUI() {
        let parsed = markdownDocument.parsed
        outlinePanel?.headings = parsed.headings
        outlinePanel?.sectionMetrics = Metrics.sectionMetrics(parsed)
        outlinePanel?.foldedIndices = Set(parsed.headings.indices.filter {
            primaryContainer.textView.foldedHeadingSlugs.contains(parsed.headings[$0].slug)
        })
        outlinePanel?.reload()
        navigationPanel?.headings = parsed.headings
        navigationPanel?.sectionMetrics = Metrics.sectionMetrics(parsed)
        navigationPanel?.foldedIndices = Set(parsed.headings.indices.filter {
            primaryContainer.textView.foldedHeadingSlugs.contains(parsed.headings[$0].slug)
        })
        navigationPanel?.reload()

        taskPanel?.tasks = parsed.tasks
        taskPanel?.headings = parsed.headings
        taskPanel?.reload()
        frontMatterEditor?.document = parsed
        if let assetDoctorPanel { configureAssetDoctor(assetDoctorPanel) }
        refreshDocumentLensIfVisible()
        refreshDiagnosticsPanels()
        refreshVisualDebuggerIfVisible()
        refreshReviewPanelIfVisible()
        progressRing.progress = (
            done: parsed.tasks.filter(\.isChecked).count,
            total: parsed.tasks.count
        )
        refreshToolbarSelectionState()

        pathResolver?.invalidate()
        refreshDensityBands()
        refreshBreadcrumb()
        markdownDocument.state.zoomLevel = primaryContainer.textView.zoomLevel
        markdownDocument.state.foldedHeadings = primaryContainer.textView.foldedHeadingSlugs
    }

    func refreshDensityBands() {
        let parsed = markdownDocument.parsed
        let changes = markdownDocument.changes.visibleMarks.map { ($0.kind, $0.range) }
        densityGutterView.bands = DensityGutterView.bands(
            for: parsed, changes: changes, searchHits: findSession.matches
        )
        let length = CGFloat(max(1, parsed.length))
        let current = parsed.headings.lastIndex { $0.range.location <= primaryContainer.textView.topVisibleOffset }
        densityGutterView.outlineEntries = parsed.headings.enumerated().map { index, heading in
            DensityOutlineEntry(
                title: heading.title,
                level: heading.level,
                fraction: CGFloat(heading.range.location) / length,
                isCurrent: index == current
            )
        }
        densityGutterView.needsDisplay = true
    }

    func refreshBreadcrumb() {
        let offset = primaryContainer.textView.topVisibleOffset
        let headings = markdownDocument.parsed.headings
        guard var index = headings.lastIndex(where: { $0.range.location <= offset }) else {
            breadcrumbView.trail = []
            return
        }
        var trail: [(index: Int, title: String, level: Int)] = []
        while true {
            let heading = headings[index]
            trail.insert((index, heading.title, heading.level), at: 0)
            guard let parent = heading.parentIndex else { break }
            index = parent
        }
        breadcrumbView.trail = trail
    }

    func refreshChangeDecorations() {
        primaryContainer.textView.changeMarks = markdownDocument.changes.visibleMarks.map {
            (kind: $0.kind, range: $0.range, words: $0.wordRanges)
        }
        splitContainer?.textView.changeMarks = primaryContainer.textView.changeMarks
        refreshDensityBands()
    }

    func refreshSiblings() {
        guard let scanner else { return }
        siblingSidebar?.siblings = scanner.siblings
        siblingSidebar?.reload()
        navigationPanel?.siblings = scanner.siblings
        navigationPanel?.reload()
    }

    // MARK: - External changes (§8.1)

    private func handleExternalEvent(_ event: MarkdownDocument.ExternalEvent) {
        switch event {
        case .applied(let hunks):
            refreshChangeDecorations()
            pathResolver?.invalidate()
            guard !hunks.isEmpty else { return }
            showChangeSummary("Updated on disk — \(hunks.count) block\(hunks.count == 1 ? "" : "s") changed")

        case .conflict(let conflict):
            pendingConflict = conflict
            showConflictBar("Changed on disk — \(conflict.changedBlockCount) block\(conflict.changedBlockCount == 1 ? "" : "s")")

        case .fileRemoved:
            showConflictBar("File was moved or deleted")

        case .fileRestored:
            dismissConflictBar()
        }
    }

    private func presentUnreadChanges() {
        let count = markdownDocument.changes.count
        guard count > 0 else { return }
        showChangeSummary("\(count) change\(count == 1 ? "" : "s") since you last read this")
        refreshChangeDecorations()
    }

    private func showChangeSummary(_ message: String) {
        if changeSummaryBar == nil {
            let bar = ChangeSummaryBarView()
            bar.delegate = self
            bar.styleSheet = activeStyleSheet
            changeSummaryBar = bar
            barStack.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: barStack.widthAnchor).isActive = true
        }
        changeSummaryBar?.message = message
    }

    private func showConflictBar(_ message: String) {
        if conflictBar == nil {
            let bar = ConflictBarView()
            bar.delegate = self
            bar.styleSheet = activeStyleSheet
            conflictBar = bar
            barStack.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: barStack.widthAnchor).isActive = true
        }
        conflictBar?.message = message
    }

    func dismissConflictBar() {
        conflictBar?.removeFromSuperview()
        conflictBar = nil
        pendingConflict = nil
    }

    func dismissChangeSummary() {
        changeSummaryBar?.removeFromSuperview()
        changeSummaryBar = nil
    }

    // MARK: - Panels

    func toggleOutlinePanel() {
        if navigationPinned {
            closePinnedNavigation()
        } else if navigationPanel != nil || navigationWindow != nil {
            closeNavigationOverlay()
        } else {
            openNavigationOverlay(focusSearch: false)
        }
    }

    func toggleTaskPanel() {
        if inspectorHost?.selectedSection == .tasks, !inspectorItem.isCollapsed {
            closeInspector()
            return
        }
        let panel = taskPanel ?? TaskPanelView()
        if taskPanel == nil {
            panel.delegate = self
            panel.styleSheet = activeStyleSheet
            taskPanel = panel
        }
        panel.tasks = markdownDocument.parsed.tasks
        panel.headings = markdownDocument.parsed.headings
        showInInspector(panel, section: .tasks)
        panel.reload()
    }

    func toggleSiblingSidebar() {
        if navigationPinned {
            closePinnedNavigation()
        } else if navigationPanel != nil || navigationWindow != nil {
            closeNavigationOverlay()
        } else {
            openNavigationOverlay(focusSearch: false)
        }
    }

    private func dismissSiblingSidebar() {
        navigationSidebar?.removeFromSuperview()
        navigationSidebar = nil
        siblingSidebar?.removeFromSuperview()
        siblingSidebar = nil
        outlinePanel = nil
        sidebarItem.isCollapsed = true
    }

    func openNavigationOverlay(focusSearch: Bool) {
        guard let window else { return }
        if navigationPinned {
            if focusSearch { navigationPanel?.focusSearch() }
            return
        }
        if navigationWindow != nil {
            if focusSearch {
                navigationWindow?.makeKey()
                navigationPanel?.focusSearch()
            }
            return
        }
        let panel = NavigationPanelView(styleSheet: activeStyleSheet)
        panel.delegate = self
        panel.onLayoutNeedsUpdate = { [weak self] in
            self?.repositionNavigationOverlay(animated: true)
        }
        panel.headings = markdownDocument.parsed.headings
        panel.sectionMetrics = Metrics.sectionMetrics(markdownDocument.parsed)
        panel.siblings = scanner?.siblings ?? []
        panel.foldedIndices = Set(markdownDocument.parsed.headings.indices.filter {
            primaryContainer.textView.foldedHeadingSlugs.contains(markdownDocument.parsed.headings[$0].slug)
        })
        panel.currentHeadingIndex = markdownDocument.parsed.headings.lastIndex {
            $0.range.location <= containerTextView.topVisibleOffset
        }
        panel.reload()
        navigationPanel = panel
        let child = NavigationPanelWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        child.contentView = panel
        child.isOpaque = false
        child.backgroundColor = .clear
        child.hasShadow = true
        child.hidesOnDeactivate = false
        child.onEscape = { [weak self] in self?.closeNavigationOverlay() }
        navigationWindow = child
        let targetFrame = navigationOverlayFrame(in: window)
        let startFrame = activeStyleSheet.reduceMotion ? targetFrame : targetFrame.offsetBy(dx: -6, dy: 0)
        child.setFrame(startFrame, display: false)
        child.alphaValue = activeStyleSheet.reduceMotion ? 1 : 0
        window.addChildWindow(child, ordered: .above)
        child.orderFront(nil)
        DispatchQueue.main.async { [weak panel] in
            panel?.reload()
        }
        startNavigationDismissalObservers(parent: window, panel: child)
        PanelAnimation.run(reduceMotion: activeStyleSheet.reduceMotion, duration: 0.16) { _ in
            child.alphaValue = 1
            child.setFrame(targetFrame, display: true)
        }
        markdownDocument.state.sidebarVisible = false
        if focusSearch {
            child.makeKey()
            panel.focusSearch()
        }
        refreshToolbarSelectionState()
    }

    func closeNavigationOverlay() {
        guard let child = navigationWindow else { return }
        stopNavigationDismissalObservers()
        let finish = { [weak self, weak child] in
            guard let self, let child else { return }
            child.parent?.removeChildWindow(child)
            child.orderOut(nil)
            if self.navigationWindow === child { self.navigationWindow = nil; self.navigationPanel = nil }
            self.refreshToolbarSelectionState()
        }
        guard !activeStyleSheet.reduceMotion else { finish(); return }
        let endFrame = child.frame.offsetBy(dx: -6, dy: 0)
        PanelAnimation.run(
            reduceMotion: false,
            duration: 0.16,
            { _ in
                child.alphaValue = 0
                child.setFrame(endFrame, display: true)
            },
            completion: finish
        )
    }

    func pinNavigationPanel() {
        guard let panel = navigationPanel else { return }
        stopNavigationDismissalObservers()
        if let child = navigationWindow {
            child.parent?.removeChildWindow(child)
            child.orderOut(nil)
            child.contentView = nil
            navigationWindow = nil
        }
        dismissSiblingSidebar()
        panel.setPinned(true)
        install(panel, in: leadingPane)
        navigationPanel = panel
        sidebarItem.isCollapsed = false
        navigationPinned = true
        markdownDocument.state.sidebarVisible = true
        refreshToolbarSelectionState()
    }

    func closePinnedNavigation() {
        guard navigationPinned else { return }
        navigationPanel?.removeFromSuperview()
        navigationPanel = nil
        navigationPinned = false
        sidebarItem.isCollapsed = true
        markdownDocument.state.sidebarVisible = false
        refreshToolbarSelectionState()
    }

    private func navigationOverlayFrame(in window: NSWindow) -> NSRect {
        let local = window.contentView?.convert(window.contentView?.bounds ?? .zero, to: nil) ?? .zero
        let screenFrame = window.convertToScreen(local)
        let visible = (window.screen ?? NSScreen.main)?.visibleFrame ?? screenFrame
        return NavigationPanelGeometry.frame(
            contentScreenFrame: screenFrame,
            visibleScreenFrame: visible,
            preferredHeight: navigationPanel?.preferredHeight
        )
    }

    private func repositionNavigationOverlay(animated: Bool = false) {
        guard let window, let child = navigationWindow, navigationPanel != nil else { return }
        let frame = navigationOverlayFrame(in: window)
        guard frame != child.frame else { return }
        if animated && !activeStyleSheet.reduceMotion {
            PanelAnimation.run(reduceMotion: false, duration: Motion.quick) { _ in
                child.animator().setFrame(frame, display: true)
            }
        } else {
            child.setFrame(frame, display: true)
        }
    }

    private func startNavigationDismissalObservers(parent: NSWindow, panel: NSPanel) {
        stopNavigationDismissalObservers()
        navigationClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) {
            [weak self, weak parent, weak panel] event in
            guard let self, let parent, let panel else { return event }
            guard event.window === parent, let contentView = parent.contentView else { return event }
            let point = contentView.convert(event.locationInWindow, from: nil)
            if contentView.bounds.contains(point), event.window !== panel { self.closeNavigationOverlay() }
            return event
        }
        navigationDeactivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.closeNavigationOverlay() }
        }
    }

    private func stopNavigationDismissalObservers() {
        if let monitor = navigationClickMonitor {
            NSEvent.removeMonitor(monitor)
            navigationClickMonitor = nil
        }
        if let observer = navigationDeactivationObserver {
            NotificationCenter.default.removeObserver(observer)
            navigationDeactivationObserver = nil
        }
    }

    func installTrailing(_ view: NSView) {
        showInInspector(view, section: .context)
    }

    func dismissTrailing(_ view: NSView) {
        inspectorHost?.removeContent(view, section: .context)
        if inspectorHost?.hasContent != true { closeInspector() }
        else { refreshToolbarSelectionState() }
    }

    func showInInspector(_ view: NSView, section: InspectorSection) {
        let host: InspectorHostView
        if let inspectorHost { host = inspectorHost }
        else {
            let created = InspectorHostView()
            created.onClose = { [weak self] in self?.closeInspector() }
            install(created, in: trailingPane)
            inspectorHost = created
            host = created
        }
        host.setContent(view, section: section)
        inspectorItem.isCollapsed = false
        refreshToolbarSelectionState()
    }

    func closeInspector() {
        inspectorItem.isCollapsed = true
        refreshToolbarSelectionState()
    }

    /// Keeps auxiliary windows (timeline, compare, lightbox) alive for as long
    /// as this document window is.
    func retainTimeline(_ controller: NSWindowController) {
        auxiliaryWindows.append(controller)
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: controller.window, queue: .main
        ) { [weak self, weak controller] _ in
            MainActor.assumeIsolated {
                self?.auxiliaryWindows.removeAll { $0 === controller }
            }
        }
    }

    private func install(_ view: NSView, in pane: NSView) {
        for existing in pane.subviews { existing.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            view.topAnchor.constraint(equalTo: pane.topAnchor),
            view.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
    }

    // MARK: - Find (§9.4)

    func showFindBar(replace: Bool) {
        let inspector: SearchInspectorView
        if let searchInspector { inspector = searchInspector }
        else {
            let created = SearchInspectorView(styleSheet: activeStyleSheet)
            created.findBar.delegate = self
            searchInspector = created
            findBar = created.findBar
            inspector = created
        }
        inspector.showsReplace = replace
        showInInspector(inspector, section: .search)
        inspector.findBar.focusSearchField()
    }

    func dismissFindBar() {
        searchInspector?.removeFromSuperview()
        inspectorHost?.removeContent(section: .search)
        searchInspector = nil
        findBar = nil
        searchResults = nil
        findSession.clear()
        primaryContainer.textView.searchHits = []
        primaryContainer.textView.currentSearchHit = nil
        refreshDensityBands()
        if inspectorHost?.hasContent != true { closeInspector() }
        else { refreshToolbarSelectionState() }
    }

    var currentFindQuery: FindQuery { findSession.query }

    func applyFindQuery(_ query: FindQuery) { runFind(query) }

    func runFind(_ query: FindQuery) {
        findSession.update(query: query, in: markdownDocument.text, caret: primaryContainer.textView.topVisibleOffset)
        // A hit inside a folded or elided range forces that range visible; the
        // text view owns that rule (§14's four-way interaction).
        primaryContainer.textView.searchHits = findSession.matches
        primaryContainer.textView.currentSearchHit = findSession.currentMatch
        findBar?.statusText = findSession.statusText
        findBar?.isQueryValid = FindEngine.isValid(query)
        refreshDensityBands()
        if let match = findSession.currentMatch {
            primaryContainer.textView.scroll(toOffset: match.location, position: .center, animated: false)
        }
    }

    func advanceFind(forward: Bool) {
        guard let match = findSession.advance(forward: forward) else { return }
        primaryContainer.textView.currentSearchHit = match
        findBar?.statusText = findSession.statusText
        recordJump(to: match.location, label: "Search hit")
        primaryContainer.textView.scroll(toOffset: match.location, position: .center, animated: true)
    }

    // MARK: - Navigation

    func recordJump(to offset: Int, label: String) {
        jumpHistory.record(
            from: JumpHistory.Entry(url: markdownDocument.url, offset: primaryContainer.textView.topVisibleOffset, label: "Reading position"),
            to: JumpHistory.Entry(url: markdownDocument.url, offset: offset, label: label)
        )
    }

    func jump(to offset: Int, label: String, animated: Bool = true) {
        recordJump(to: offset, label: label)
        primaryContainer.textView.scroll(toOffset: offset, position: .center, animated: animated)
        refreshBreadcrumb()
    }

    func goBack() {
        guard let entry = jumpHistory.goBack() else { return }
        primaryContainer.textView.scroll(toOffset: entry.offset, position: .center, animated: true)
    }

    func goForward() {
        guard let entry = jumpHistory.goForward() else { return }
        primaryContainer.textView.scroll(toOffset: entry.offset, position: .center, animated: true)
    }

    // MARK: - Split view (§9.3)

    func toggleSplitView() {
        if let split = splitViewContainer {
            primaryContainer.removeFromSuperview()
            split.removeFromSuperview()
            splitViewContainer = nil
            splitContainer = nil
            primaryContainer.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(primaryContainer)
            NSLayoutConstraint.activate([
                primaryContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                primaryContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                primaryContainer.topAnchor.constraint(equalTo: rootView.topAnchor),
                primaryContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            ])
            markdownDocument.state.splitViewEnabled = false
            return
        }

        // Two panes over the same buffer — the second primaryContainer shares the
        // document's storage, so an edit in one appears in the other with no
        // synchronisation code at all (§3.1 paying off).
        let second = MarkdownContainerView(storage: markdownDocument.storage)
        second.textView.markdownDelegate = self
        second.textView.styleSheet = activeStyleSheet
        second.textView.mode = .live
        second.textView.update(document: markdownDocument.parsed, dirty: .wholesale)
        splitContainer = second

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false

        primaryContainer.removeFromSuperview()
        primaryContainer.translatesAutoresizingMaskIntoConstraints = true
        second.translatesAutoresizingMaskIntoConstraints = true
        split.addArrangedSubview(primaryContainer)
        split.addArrangedSubview(second)
        rootView.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            split.topAnchor.constraint(equalTo: rootView.topAnchor),
            split.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        rootView.layoutSubtreeIfNeeded()
        split.setPosition(max(1, split.bounds.width / 2), ofDividerAt: 0)
        splitViewContainer = split
        markdownDocument.state.splitViewEnabled = true
    }

    // MARK: - Window lifecycle

    func documentWillClose() {
        stopNavigationDismissalObservers()
        closeNavigationOverlay()
        navigationPanel?.removeFromSuperview()
        navigationPanel = nil
        let selection = primaryContainer.textView.sourceSelectedRange
        markdownDocument.state.selectionLocation = selection.location
        markdownDocument.state.selectionLength = selection.length
        markdownDocument.state.splitViewEnabled = splitViewContainer != nil
        markdownDocument.saveIfNeeded()
        markdownDocument.close()
        themeObservation?.cancel()
        NotificationCenter.default.removeObserver(self)
    }

    var isWindowPinned: Bool { isPinned }

    func togglePin() {
        isPinned.toggle()
        window?.level = isPinned ? .floating : .normal
    }

    func toggleFocusMode() {
        isFocusMode.toggle()
        window?.toolbar?.isVisible = !isFocusMode
        densityGutterView.isHidden = isFocusMode
        breadcrumbView.isHidden = isFocusMode
        if isFocusMode {
            closeNavigationOverlay()
            sidebarItem.isCollapsed = true
            inspectorItem.isCollapsed = true
        } else if markdownDocument.state.sidebarVisible {
            sidebarItem.isCollapsed = false
        }
        refreshToolbarSelectionState()
    }
}

// MARK: - Window delegate

extension DocumentWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        refreshToolbarSelectionState()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        markdownDocument.undoManager
    }

    func windowDidResize(_ notification: Notification) {
        repositionNavigationOverlay()
    }

    func windowDidMove(_ notification: Notification) {
        repositionNavigationOverlay()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        repositionNavigationOverlay()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard !isFocusMode else { return }
        window?.toolbar?.isVisible = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard markdownDocument.isDirty, markdownDocument.url != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(markdownDocument.displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: try? markdownDocument.save(); return true
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        documentWillClose()
        onClose?()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard window?.occlusionState.contains(.visible) == false else { return }
        markdownDocument.saveIfNeeded()
    }
}
