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
    // Sibling extensions implement delegate callbacks, so the presentation
    // mode is intentionally internal rather than file-private.
    var mode: RenderMode = .live

    var onClose: (() -> Void)?

    // Text surface.  Internal rather than private because the command and
    // support extensions live in sibling files, and `private` is file-scoped.
    var primaryContainer: MarkdownContainerView!
    var splitContainer: MarkdownContainerView?
    var splitViewContainer: NSSplitView?

    // Persistent chrome
    let breadcrumbView = BreadcrumbView()
    let densityGutterView = DensityGutterView()
    /// Activity cue for sustained work (parses and exports past a second).
    let activityIndicator = ActivityIndicatorView()

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
    var activeStyleSheet = DocumentWindowController.makeStyleSheet(
        theme: ThemeStore.shared.current,
        appearance: NSApp.effectiveAppearance
    )
    private var themeObservation: ThemeObservation?
    let progressRing = TaskProgressRing()
    private var isPinned = false
    var navigationPinned = false
    private var focusRestoreSidebar = false
    private var focusRestoreInspector = false
    private var focusModeApplied = false
    private var discardChangesOnClose = false
    private var focusDimmingViews: [FocusDimmingView] = []
    private var isSynchronizingPanes = false
    private var pendingInitialRestoreOffset: Int?
    private var deferredInitialRestoreOffset: Int?
    var isFocusModeEnabled: Bool { Preferences.shared.values.focusMode }
    var pendingConflict: MarkdownDocument.Conflict?
    weak var toolbarPresentationControl: ToolbarPresentationControl?

    /// Coalesces panel/metrics refresh so typing does not rebuild outline,
    /// density bands, and diagnostics on every parse commit.
    private var derivedUIRefreshWorkItem: DispatchWorkItem?
    private var findRefreshWorkItem: DispatchWorkItem?
    private var cachedMetricsDocumentID: ObjectIdentifier?
    private var cachedSectionMetrics: [ReadingMetrics] = []
    private var cachedWordCount = 0

    // MARK: - Construction

    private static func makeStyleSheet(theme: Theme, appearance: NSAppearance) -> StyleSheet {
        var configuredTheme = theme
        configuredTheme.typography = Preferences.shared.effectiveTypography
        return StyleSheet(theme: configuredTheme, appearance: appearance)
    }

    private var renderConfiguration: MarkdownRenderConfiguration {
        MarkdownRenderConfiguration(
            showInvisibles: Preferences.shared.values.showInvisibles,
            revealPolicy: Preferences.shared.values.revealMarkersAtAllCursors ? .allCursors : .primaryCaret,
            typographicSubstitution: Preferences.shared.values.typographicSubstitution,
            typewriterScrolling: Preferences.shared.values.typewriterScrolling,
            reflowHardWrappedParagraphs: Preferences.shared.values.reflowHardWrappedParagraphs,
            codeCollapseThreshold: Preferences.shared.values.codeBlockCollapseThreshold,
            largeFileThresholdMegabytes: Preferences.shared.values.largeFileThresholdMegabytes
        )
    }

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = false
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
        resetTransientChrome()
        try markdownDocument.open(url)
        let requestedMode = mode.normalizedForEditing
        self.mode = requestedMode

        scanner = SiblingScanner(
            documentURL: url,
            extraDirectories: Preferences.shared.values.siblingScanDirectories
        )
        scanner?.onChange = { [weak self] in self?.refreshSiblings() }
        pathResolver = PathResolver(documentURL: url)

        window?.title = url.lastPathComponent
        window?.subtitle = url.deletingLastPathComponent().lastPathComponent
        window?.representedURL = url
        applyMode(requestedMode)
        applyRenderConfiguration()
        primaryContainer.textView.zoomLevel = markdownDocument.state.zoomLevel
        primaryContainer.textView.foldedHeadingSlugs = markdownDocument.state.foldedHeadings
        // Structure-only tree is ready; full decoration follows via onReparse.
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

        scheduleDerivedUIRefresh(immediate: true)
        if markdownDocument.state.sidebarVisible || Preferences.shared.values.siblingSidebarVisible {
            openNavigationOverlay(focusSearch: false)
            pinNavigationPanel()
        }
        if markdownDocument.state.splitViewEnabled { toggleSplitView() }
        applyFocusMode(Preferences.shared.values.focusMode, animated: false)

        // Paint a deterministic first frame. Apply a saved deep offset only
        // after the document surface has had a chance to establish its TextKit
        // viewport; restoring it during the first layout pass can otherwise
        // produce a blank surface until the first user scroll.
        pendingInitialRestoreOffset = 0
        deferredInitialRestoreOffset = markdownDocument.restoredOffset()
        DispatchQueue.main.async { [weak self] in
            self?.restoreInitialReadingPositionIfReady()
        }
    }

    /// Clears find / conflict / change chrome that must not survive a document hop.
    func resetTransientChrome() {
        derivedUIRefreshWorkItem?.cancel()
        findRefreshWorkItem?.cancel()
        cachedMetricsDocumentID = nil
        cachedSectionMetrics = []
        cachedWordCount = 0

        findSession.clear()
        for pane in documentPanes {
            pane.textView.searchHits = []
            pane.textView.currentSearchHit = nil
        }
        findBar?.statusText = ""
        dismissConflictBar()
        dismissChangeSummary()
    }

    private func restoreInitialReadingPositionIfReady() {
        guard let restored = pendingInitialRestoreOffset, window?.isVisible == true else { return }
        pendingInitialRestoreOffset = nil

        window?.layoutIfNeeded()
        rootView.layoutSubtreeIfNeeded()
        primaryContainer.layoutSubtreeIfNeeded()
        primaryContainer.textView.resizeToFitContent()

        // TextKit 2 can defer the first rendering surface when the initial
        // bounds jump straight into a deep, restored section. Prime the
        // document once at the top before applying the saved position. This
        // stays off-screen, but makes the first visible frame deterministic.
        primaryContainer.textView.scroll(toOffset: 0, position: .top, animated: false)
        primaryContainer.textView.prepareForDisplay()
        primaryContainer.textView.displayIfNeeded()
        primaryContainer.textView.scroll(toOffset: restored, position: .top, animated: false)
        primaryContainer.textView.prepareForDisplay()
        primaryContainer.textView.needsDisplay = true
        primaryContainer.scrollView.contentView.needsDisplay = true
        updateBreadcrumbAndGutter()

        let selection = NSRange(
            location: min(markdownDocument.state.selectionLocation, markdownDocument.storage.length),
            length: 0
        )
        let available = markdownDocument.storage.length - selection.location
        primaryContainer.textView.setSourceSelectedRanges([
            NSRange(location: selection.location, length: min(markdownDocument.state.selectionLength, available))
        ])
        window?.makeFirstResponder(primaryContainer.textView)
        if !markdownDocument.changes.isEmpty { presentUnreadChanges() }
        dumpLayoutIfRequested()

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.primaryContainer.textView.scroll(toOffset: restored, position: .top, animated: false)
            self.primaryContainer.textView.prepareForDisplay()
            self.primaryContainer.textView.displayIfNeeded()
            self.primaryContainer.scrollView.contentView.displayIfNeeded()
        }

        guard let deferred = deferredInitialRestoreOffset, deferred > 0 else { return }
        deferredInitialRestoreOffset = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            guard let self, self.window?.isVisible == true else { return }
            self.window?.layoutIfNeeded()
            self.primaryContainer.layoutSubtreeIfNeeded()
            self.primaryContainer.textView.scroll(toOffset: deferred, position: .top, animated: false)
            self.primaryContainer.textView.prepareForDisplay()
            self.primaryContainer.textView.displayIfNeeded()
            self.primaryContainer.scrollView.contentView.displayIfNeeded()
            self.updateBreadcrumbAndGutter()
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
        primaryContainer.topAccessoryOverlaysContent = true
        // Keep the document map on the leading edge of the document surface.
        // It reads as contents there; on the trailing edge it looks like an
        // unexplained second scrollbar.
        primaryContainer.leadingAccessory = densityGutterView
        breadcrumbView.delegate = self
        breadcrumbView.styleSheet = activeStyleSheet
        densityGutterView.delegate = self
        densityGutterView.styleSheet = activeStyleSheet
        progressRing.styleSheet = activeStyleSheet

        rootView = DocumentRootView(backgroundColor: activeStyleSheet.background)
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
            primaryContainer.topAnchor.constraint(equalTo: barStack.bottomAnchor),
            primaryContainer.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            barStack.leadingAnchor.constraint(equalTo: primaryContainer!.leadingAnchor),
            barStack.trailingAnchor.constraint(equalTo: primaryContainer.trailingAnchor),
            barStack.topAnchor.constraint(equalTo: rootView.topAnchor),
        ])

        buildToolbar()
    }

    private func buildToolbar() {
        // Keep the document switch in the optical centre with explicit flexible
        // spaces. AppKit then owns hit testing and the layout stays stable when
        // a toolbar item is hidden or the window gets narrower.
        let toolbar = NSToolbar(identifier: "DownrightToolbar.v10")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.centeredItemIdentifier = Self.modeItem
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.isVisible = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    private func wireDocument() {
        markdownDocument.onReparse = { [weak self] parsed, dirty in
            guard let self else { return }
            self.primaryContainer.textView.update(document: parsed, dirty: dirty)
            self.splitContainer?.textView.update(document: parsed, dirty: dirty)
            self.synchronizePanes(from: self.primaryContainer.textView)
            self.scheduleDerivedUIRefresh()
            self.scheduleFindRefresh()
        }
        markdownDocument.onParseActivity = { [weak self] busy in
            busy ? self?.activityIndicator.begin() : self?.activityIndicator.end()
        }
        markdownDocument.onExternalEvent = { [weak self] event in self?.handleExternalEvent(event) }
        markdownDocument.onDirtyChanged = { [weak self] dirty in
            self?.window?.isDocumentEdited = dirty
        }
        markdownDocument.onSaveFailure = { [weak self] error in
            self?.presentSaveError(error)
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
            self.activeStyleSheet = Self.makeStyleSheet(theme: theme, appearance: window.effectiveAppearance)
            self.applyStyleSheet()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: Preferences.didChange, object: nil
        )
    }

    @objc private func preferencesDidChange() {
        activeStyleSheet = Self.makeStyleSheet(
            theme: ThemeStore.shared.current,
            appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance
        )
        applyStyleSheet()
        applyFocusMode(Preferences.shared.values.focusMode, animated: true)
        applySiblingVisibilityPreference()
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
        (rootView as? DocumentRootView)?.backgroundColor = activeStyleSheet.background
        applyRenderConfiguration()
    }

    private func applyRenderConfiguration() {
        let configuration = renderConfiguration
        for pane in documentPanes where pane.textView.configuration != configuration {
            pane.textView.configuration = configuration
        }
    }

    // MARK: - Modes (§3.2)

    func applyMode(_ newMode: RenderMode) {
        let newMode = newMode.normalizedForEditing
        mode = newMode
        for pane in documentPanes where pane.textView.mode != newMode {
            pane.textView.mode = newMode
        }
        // Never persist a transient raw-source presentation.
        markdownDocument.state.mode = .live
        refreshSourceFocusToolbar()
        window?.toolbar?.validateVisibleItems()
    }

    var documentPanes: [MarkdownContainerView] {
        [primaryContainer, splitContainer].compactMap { $0 }
    }

    func synchronizePanes(from source: MarkdownTextView) {
        guard splitContainer != nil, !isSynchronizingPanes else { return }
        isSynchronizingPanes = true
        defer { isSynchronizingPanes = false }

        let selection = source.sourceSelectedRanges
        let scrollOffset = source.topVisibleOffset
        for pane in documentPanes where pane.textView !== source {
            let textView = pane.textView
            if textView.configuration != source.configuration { textView.configuration = source.configuration }
            if textView.mode != source.mode { textView.mode = source.mode }
            if textView.zoomLevel != source.zoomLevel { textView.zoomLevel = source.zoomLevel }
            if textView.foldedHeadingSlugs != source.foldedHeadingSlugs {
                textView.foldedHeadingSlugs = source.foldedHeadingSlugs
            }
            if textView.sourceFocus != source.sourceFocus {
                switch source.sourceFocus {
                case .none:
                    textView.clearSourceFocus()
                case .document:
                    textView.focusEntireSource()
                case .scoped(let range):
                    textView.focusSource(in: range)
                }
            }
            textView.setSourceSelectedRanges(selection)
            textView.scroll(toOffset: scrollOffset, position: .top, animated: false)
        }
        markdownDocument.state.zoomLevel = source.zoomLevel
        markdownDocument.state.foldedHeadings = source.foldedHeadingSlugs
    }

    func setSharedZoom(_ level: ZoomLevel) {
        let source = containerTextView
        source.zoomLevel = level
        synchronizePanes(from: source)
        markdownDocument.state.zoomLevel = level
        outlinePanel?.zoomLevel = level
    }

    func setSharedFolds(_ folded: Set<String>, from source: MarkdownTextView? = nil) {
        let source = source ?? containerTextView
        source.foldedHeadingSlugs = folded
        synchronizePanes(from: source)
        markdownDocument.state.foldedHeadings = folded
    }

    // MARK: - Derived UI

    func scheduleDerivedUIRefresh(immediate: Bool = false) {
        derivedUIRefreshWorkItem?.cancel()
        if immediate {
            refreshDerivedUI()
            return
        }
        let work = DispatchWorkItem { [weak self] in self?.refreshDerivedUI() }
        derivedUIRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
    }

    func scheduleFindRefresh() {
        guard !currentFindQuery.isEmpty else { return }
        findRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.currentFindQuery.isEmpty else { return }
            self.runFind(self.currentFindQuery)
        }
        findRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04, execute: work)
    }

    func refreshDerivedUI() {
        let parsed = markdownDocument.parsed
        let source = containerTextView
        let metrics = sectionMetrics(for: parsed)
        let foldedIndices = Set(parsed.headings.indices.filter {
            source.foldedHeadingSlugs.contains(parsed.headings[$0].slug)
        })
        if let outlinePanel {
            outlinePanel.headings = parsed.headings
            outlinePanel.sectionMetrics = metrics
            outlinePanel.foldedIndices = foldedIndices
            outlinePanel.reload()
        }
        if let navigationPanel {
            navigationPanel.headings = parsed.headings
            navigationPanel.sectionMetrics = metrics
            navigationPanel.foldedIndices = foldedIndices
            navigationPanel.reload()
        }

        if let taskPanel {
            taskPanel.tasks = parsed.tasks
            taskPanel.headings = parsed.headings
            taskPanel.reload()
        }
        frontMatterEditor?.document = parsed
        if let assetDoctorPanel { configureAssetDoctor(assetDoctorPanel) }
        refreshDocumentLensIfVisible()
        refreshDiagnosticsPanels()
        refreshVisualDebuggerIfVisible()
        refreshReviewPanelIfVisible()
        let completedTasks = parsed.tasks.reduce(into: 0) { count, task in
            if task.isChecked { count += 1 }
        }
        progressRing.progress = (done: completedTasks, total: parsed.tasks.count)
        refreshToolbarSelectionState()

        // Path existence is stable across local edits; wipe only on external
        // writes and document hops (see handleExternalEvent / open).
        refreshDensityBands(metrics: metrics)
        refreshBreadcrumb()
        markdownDocument.state.zoomLevel = source.zoomLevel
        markdownDocument.state.foldedHeadings = source.foldedHeadingSlugs
        updateFocusDimmingViews()
    }

    private func sectionMetrics(for parsed: ParsedDocument) -> [ReadingMetrics] {
        let id = ObjectIdentifier(parsed.root)
        if cachedMetricsDocumentID == id { return cachedSectionMetrics }
        let metrics = Metrics.sectionMetrics(parsed)
        cachedMetricsDocumentID = id
        cachedSectionMetrics = metrics
        cachedWordCount = metrics.reduce(0) { $0 + $1.words }
        if cachedWordCount == 0, parsed.length > 0 {
            cachedWordCount = markdownDocument.text.split(whereSeparator: { $0.isWhitespace }).count
        }
        return metrics
    }

    func refreshDensityBands(metrics: [ReadingMetrics]? = nil) {
        let parsed = markdownDocument.parsed
        _ = metrics ?? sectionMetrics(for: parsed)
        let wordCount = cachedWordCount
        let readMinutes = max(1, (wordCount + 199) / 200)
        densityGutterView.metricsSummary = "\(wordCount) words · \(readMinutes) min read"
        let changes = markdownDocument.changes.visibleMarks.map { ($0.kind, $0.range) }
        densityGutterView.bands = DensityGutterView.bands(
            for: parsed, changes: changes, searchHits: findSession.matches
        )
        let length = CGFloat(max(1, parsed.length))
        let source = containerTextView
        let current = parsed.headings.lastIndex { $0.range.location <= source.topVisibleOffset }
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
        let offset = containerTextView.topVisibleOffset
        let headings = markdownDocument.parsed.headings
        guard var index = headings.lastIndex(where: { $0.range.location <= offset })
            ?? headings.indices.first
        else {
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
            scheduleFindRefresh()
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

    func showChangeSummary(_ message: String) {
        if changeSummaryBar == nil {
            let bar = ChangeSummaryBarView()
            bar.delegate = self
            bar.styleSheet = activeStyleSheet
            changeSummaryBar = bar
            barStack.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: barStack.widthAnchor).isActive = true
        }
        changeSummaryBar?.configure(message: message, changeCount: markdownDocument.changes.count)
        rootView.needsLayout = true
    }

    func showConflictBar(_ message: String) {
        if conflictBar == nil {
            let bar = ConflictBarView()
            bar.delegate = self
            bar.styleSheet = activeStyleSheet
            conflictBar = bar
            barStack.addArrangedSubview(bar)
            bar.widthAnchor.constraint(equalTo: barStack.widthAnchor).isActive = true
        }
        conflictBar?.message = message
        rootView.needsLayout = true
    }

    func dismissConflictBar() {
        if let conflictBar {
            barStack.removeArrangedSubview(conflictBar)
            conflictBar.removeFromSuperview()
        }
        conflictBar = nil
        pendingConflict = nil
        rootView.needsLayout = true
    }

    func dismissChangeSummary() {
        if let changeSummaryBar {
            barStack.removeArrangedSubview(changeSummaryBar)
            changeSummaryBar.removeFromSuperview()
        }
        changeSummaryBar = nil
        rootView.needsLayout = true
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
        if searchInspector != nil {
            dismissFindBar()
        }

        let bar: FindBarView
        if let findBar {
            bar = findBar
        } else {
            let created = FindBarView(styleSheet: activeStyleSheet, presentation: .bar)
            created.delegate = self
            findBar = created
            barStack.addArrangedSubview(created)
            created.widthAnchor.constraint(equalTo: barStack.widthAnchor).isActive = true
            bar = created
        }
        bar.showsReplace = replace
        bar.focusSearchField()
        refreshToolbarSelectionState()
    }

    func showFindInspector(replace: Bool) {
        if searchInspector == nil, findBar != nil {
            dismissFindBar()
        }

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
        if let findBar, barStack.arrangedSubviews.contains(findBar) {
            barStack.removeArrangedSubview(findBar)
        }
        findBar?.removeFromSuperview()
        searchInspector?.removeFromSuperview()
        inspectorHost?.removeContent(section: .search)
        searchInspector = nil
        findBar = nil
        searchResults = nil
        findSession.clear()
        for pane in documentPanes {
            pane.textView.searchHits = []
            pane.textView.currentSearchHit = nil
        }
        refreshDensityBands()
        if inspectorHost?.hasContent != true { closeInspector() }
        else { refreshToolbarSelectionState() }
    }

    var currentFindQuery: FindQuery { findSession.query }

    func applyFindQuery(_ query: FindQuery) { runFind(query) }

    func runFind(_ query: FindQuery, scrollToMatch: Bool = true) {
        findRefreshWorkItem?.cancel()
        let source = containerTextView
        findSession.update(query: query, in: markdownDocument.text, caret: source.topVisibleOffset)
        // A hit inside a folded or elided range forces that range visible; the
        // text view owns that rule (§14's four-way interaction).
        for pane in documentPanes {
            pane.textView.searchHits = findSession.matches
            pane.textView.currentSearchHit = findSession.currentMatch
        }
        findBar?.statusText = findSession.statusText
        findBar?.isQueryValid = FindEngine.isValid(query)
        refreshDensityBands()
        if scrollToMatch, let match = findSession.currentMatch {
            source.scroll(toOffset: match.location, position: .center, animated: false)
            synchronizePanes(from: source)
        }
    }

    func advanceFind(forward: Bool) {
        guard let match = findSession.advance(forward: forward) else { return }
        let source = containerTextView
        for pane in documentPanes { pane.textView.currentSearchHit = match }
        findBar?.statusText = findSession.statusText
        recordJump(to: match.location, label: "Search hit")
        source.scroll(toOffset: match.location, position: .center, animated: true)
        synchronizePanes(from: source)
    }

    // MARK: - Navigation

    func recordJump(to offset: Int, label: String) {
        jumpHistory.record(
            from: JumpHistory.Entry(url: markdownDocument.url, offset: containerTextView.topVisibleOffset, label: "Reading position"),
            to: JumpHistory.Entry(url: markdownDocument.url, offset: offset, label: label)
        )
    }

    func jump(to offset: Int, label: String, animated: Bool = true) {
        recordJump(to: offset, label: label)
        let source = containerTextView
        source.scroll(toOffset: offset, position: .center, animated: animated)
        synchronizePanes(from: source)
        refreshBreadcrumb()
    }

    func goBack() {
        guard let entry = jumpHistory.goBack() else { return }
        let source = containerTextView
        source.scroll(toOffset: entry.offset, position: .center, animated: true)
        synchronizePanes(from: source)
    }

    func goForward() {
        guard let entry = jumpHistory.goForward() else { return }
        let source = containerTextView
        source.scroll(toOffset: entry.offset, position: .center, animated: true)
        synchronizePanes(from: source)
    }

    // MARK: - Split view (§9.3)

    func toggleSplitView() {
        if let split = splitViewContainer {
            synchronizePanes(from: containerTextView)
            focusDimmingViews.removeAll { view in
                if view.superview === splitContainer {
                    view.removeFromSuperview()
                    return true
                }
                return false
            }
            primaryContainer.removeFromSuperview()
            split.removeFromSuperview()
            splitViewContainer = nil
            splitContainer = nil
            primaryContainer.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(primaryContainer)
            NSLayoutConstraint.activate([
                primaryContainer.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
                primaryContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
                primaryContainer.topAnchor.constraint(equalTo: barStack.bottomAnchor),
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
        second.textView.configuration = renderConfiguration
        let source = containerTextView
        second.textView.mode = source.mode
        second.textView.zoomLevel = source.zoomLevel
        second.textView.foldedHeadingSlugs = source.foldedHeadingSlugs
        second.textView.update(document: markdownDocument.parsed, dirty: .wholesale)
        second.textView.setSourceSelectedRanges(source.sourceSelectedRanges)
        second.textView.scroll(toOffset: source.topVisibleOffset, position: .top, animated: false)
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
            split.topAnchor.constraint(equalTo: barStack.bottomAnchor),
            split.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
        ])
        rootView.layoutSubtreeIfNeeded()
        split.setPosition(max(1, split.bounds.width / 2), ofDividerAt: 0)
        splitViewContainer = split
        markdownDocument.state.splitViewEnabled = true
        if isFocusModeEnabled { installFocusDimmingView(in: second) }
        synchronizePanes(from: source)
    }

    // MARK: - Preference-driven presentation

    func applySiblingVisibilityPreference() {
        guard markdownDocument.url != nil else { return }
        // Focus mode owns the chrome while active. Apply this preference after
        // focus mode exits so it cannot reopen a hidden sidebar mid-session.
        guard !isFocusModeEnabled else { return }
        let shouldShow = Preferences.shared.values.siblingSidebarVisible
        if shouldShow, !navigationPinned {
            if navigationWindow == nil { openNavigationOverlay(focusSearch: false) }
            pinNavigationPanel()
        } else if !shouldShow, navigationPinned {
            closePinnedNavigation()
        }
    }

    private func installFocusDimmingView(in container: MarkdownContainerView) {
        guard !focusDimmingViews.contains(where: { $0.superview === container }) else { return }
        let overlay = FocusDimmingView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        overlay.alphaValue = activeStyleSheet.reduceMotion ? 1 : 0
        focusDimmingViews.append(overlay)
        Motion.run(reduceMotion: activeStyleSheet.reduceMotion, duration: Motion.quick) { _ in
            overlay.alphaValue = 1
        }
    }

    private func removeFocusDimmingViews(animated: Bool) {
        let views = focusDimmingViews
        focusDimmingViews.removeAll()
        let finish = {
            views.forEach { $0.removeFromSuperview() }
        }
        guard animated, !activeStyleSheet.reduceMotion else {
            finish()
            return
        }
        Motion.run(reduceMotion: false, duration: Motion.quick) { _ in
            views.forEach { $0.alphaValue = 0 }
        } completion: {
            finish()
        }
    }

    func updateFocusDimmingViews() {
        guard isFocusModeEnabled else { return }
        for overlay in focusDimmingViews {
            guard let container = overlay.superview else { continue }
            let textView = container.subviews.compactMap { $0 as? NSScrollView }
                .first?.documentView as? MarkdownTextView
            guard let textView else { continue }
            overlay.highlightRect = focusRect(for: textView, in: container)
        }
        focusDimmingViews.forEach { $0.needsDisplay = true }
    }

    private func focusRect(for textView: MarkdownTextView, in container: NSView) -> NSRect? {
        let storage = markdownDocument.text as NSString
        guard storage.length > 0 else { return nil }
        let offset = min(max(0, textView.sourceSelectedRange.location), storage.length - 1)
        let paragraph = storage.paragraphRange(for: NSRange(location: offset, length: 0))
        guard let start = textView.rect(forOffset: paragraph.location) else { return nil }
        let end = textView.rect(forOffset: max(paragraph.location, paragraph.upperBound - 1)) ?? start
        return textView.convert(start.union(end).insetBy(dx: -8, dy: -4), to: container)
    }

    // MARK: - Window lifecycle

    @discardableResult
    func confirmPendingChangesBeforeClose(markDiscardForWindowClose: Bool) -> Bool {
        discardChangesOnClose = false
        guard markdownDocument.isDirty, markdownDocument.url != nil else { return true }

        let alert = NSAlert()
        alert.messageText = "Save changes to \(markdownDocument.displayName)?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveDocument()
        case .alertSecondButtonReturn:
            discardChangesOnClose = markDiscardForWindowClose
            return true
        default:
            return false
        }
    }

    @discardableResult
    func documentWillClose() -> Bool {
        guard discardChangesOnClose || !markdownDocument.isDirty || saveDocument() else { return false }
        discardChangesOnClose = false
        derivedUIRefreshWorkItem?.cancel()
        findRefreshWorkItem?.cancel()
        stopNavigationDismissalObservers()
        closeNavigationOverlay()
        removeFocusDimmingViews(animated: false)
        navigationPanel?.removeFromSuperview()
        navigationPanel = nil
        let selection = primaryContainer.textView.sourceSelectedRange
        markdownDocument.state.selectionLocation = selection.location
        markdownDocument.state.selectionLength = selection.length
        markdownDocument.state.splitViewEnabled = splitViewContainer != nil
        markdownDocument.close()
        themeObservation?.cancel()
        NotificationCenter.default.removeObserver(self)
        return true
    }

    var isWindowPinned: Bool { isPinned }

    func togglePin() {
        isPinned.toggle()
        window?.level = isPinned ? .floating : .normal
    }

    func toggleFocusMode() {
        Preferences.shared.update { $0.focusMode.toggle() }
    }

    func applyFocusMode(_ enabled: Bool, animated: Bool) {
        if enabled {
            if !focusModeApplied {
                focusRestoreSidebar = !sidebarItem.isCollapsed
                focusRestoreInspector = !inspectorItem.isCollapsed
                focusModeApplied = true
            }
            closeNavigationOverlay()
            sidebarItem.isCollapsed = true
            inspectorItem.isCollapsed = true
            window?.toolbar?.isVisible = false
            densityGutterView.isHidden = true
            breadcrumbView.isHidden = true
            documentPanes.forEach { installFocusDimmingView(in: $0) }
            updateFocusDimmingViews()
        } else {
            guard focusModeApplied else {
                window?.toolbar?.isVisible = true
                densityGutterView.isHidden = false
                breadcrumbView.isHidden = false
                return
            }
            removeFocusDimmingViews(animated: animated)
            window?.toolbar?.isVisible = true
            densityGutterView.isHidden = false
            breadcrumbView.isHidden = false
            sidebarItem.isCollapsed = !focusRestoreSidebar
            inspectorItem.isCollapsed = !focusRestoreInspector
            focusModeApplied = false
        }
        refreshToolbarSelectionState()
    }
}

// MARK: - Window delegate

extension DocumentWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        restoreInitialReadingPositionIfReady()
        refreshToolbarSelectionState()
    }

    func windowDidBecomeVisible(_ notification: Notification) {
        restoreInitialReadingPositionIfReady()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        markdownDocument.undoManager
    }

    func windowDidResize(_ notification: Notification) {
        repositionNavigationOverlay()
        updateFocusDimmingViews()
    }

    func windowDidMove(_ notification: Notification) {
        repositionNavigationOverlay()
    }

    func windowDidChangeScreen(_ notification: Notification) {
        repositionNavigationOverlay()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        guard !isFocusModeEnabled else { return }
        window?.toolbar?.isVisible = true
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmPendingChangesBeforeClose(markDiscardForWindowClose: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard documentWillClose() else { return }
        onClose?()
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard window?.occlusionState.contains(.visible) == false else { return }
        markdownDocument.saveIfNeeded()
    }
}

@MainActor
private final class FocusDimmingView: NSView {
    var highlightRect: NSRect?

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(rect: bounds)
        if let highlightRect {
            let cutout = NSBezierPath(roundedRect: highlightRect, xRadius: 6, yRadius: 6)
            path.append(cutout)
            path.windingRule = .evenOdd
        }
        NSColor.black.withAlphaComponent(0.18).setFill()
        path.fill()
    }
}

/// Document chrome is laid out top-to-bottom.  Keeping the root flipped makes
/// its frame coordinates agree with the flipped Markdown container and avoids
/// inverted bar/document constraints.
private final class DocumentRootView: NSView {
    var backgroundColor: NSColor {
        didSet { needsDisplay = true }
    }

    init(backgroundColor: NSColor) {
        self.backgroundColor = backgroundColor
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        backgroundColor = .windowBackgroundColor
        super.init(coder: coder)
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        backgroundColor.setFill()
        dirtyRect.fill()
    }
}
