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
    var statusBarView: DocumentStatusBarView!
    /// Activity cue for sustained work (parses and exports past a second).
    let activityIndicator = ActivityIndicatorView()

    // Transient panels (§11.4)
    var taskPanel: TaskPanelView?
    var findBar: FindBarView?
    var conflictBar: ConflictBarView?
    var changeSummaryBar: ChangeSummaryBarView?
    /// Held for layout tests and the transient toast's fixed corner inset.
    var changeSummaryTopConstraint: NSLayoutConstraint?
    private var changeSummaryDismissWorkItem: DispatchWorkItem?
    var searchResults: SearchResultsPanelView?
    var searchInspector: SearchInspectorView?
    var historyInspector: HistoryInspectorView?
    var inspectorHost: InspectorHostView?
    /// The travelling glass body, kept while any trip is in flight and
    /// removed on settle.  One vessel serves every trip in the window.
    private var morphVessel: MorphVessel?
    var hasMorphVesselForTesting: Bool { morphVessel != nil }
    func settleMorphForTesting() { morphVessel?.springsSettleImmediately() }
    /// Where the vessel currently in flight is headed. A window resize can
    /// re-aim the floating body without changing its direction.
    private enum MorphDestination {
        /// Floating arrival: down from the toolbar edge into the panel frame.
        case floating
        /// Floating dismissal: up into the sliver the pour came out of.
        case toolTop
    }
    private var morphDestination: MorphDestination = .floating
    /// The floating Tasks surface (§8.5's floating clause): the one panel
    /// that pours out of the toolbar edge and hangs over the document
    /// instead of docking in the split.  Kept for as long as it is on screen;
    /// torn down on dismissal.
    private(set) var floatingSurface: FloatingPanelSurface?
    /// The transparent compositor boundary for the floating surface. It is a
    /// child of the document window, so it follows the document while keeping
    /// `NSGlassEffectView` outside the document window's own glass stage.
    private var floatingPanelWindow: FloatingPanelWindow?
    var isTaskPanelFloating: Bool {
        floatingSurface != nil && inspectorHost?.selectedSection == .tasks
    }
    /// The surface's resting frame in window space, remembered so a retarget
    /// can still aim after the dismissal hands the glass off early.
    private var floatingSurfaceFrame = NSRect.zero
    /// The responder that was active before a floating surface opened. It is
    /// restored before the original outside click is delivered, so a dismiss
    /// never costs the document caret.
    private weak var floatingFocusRestoreView: NSView?
    /// Notification tokens that keep a flying trip aimed at the live pane.
    private var morphRetargetTokens: [NSObjectProtocol] = []
    /// Re-order the detached panel after app activation without rebuilding its
    /// content or stealing an in-progress quick-add field.
    private var floatingActivationObserver: NSObjectProtocol?
    var frontMatterEditor: FrontMatterEditorView?
    var assetDoctorPanel: AssetDoctorView?
    var tidySheetWindow: NSWindow?
    var tableEditorWindow: NSWindow?
    private var auxiliaryWindows: [NSWindowController] = []

    // Layout containers
    private var rootView: NSView!
    var barStack: NSStackView!
    private var windowSplitController: NSSplitViewController!
    /// A surface must never become an arbitrary child of the split view. On
    /// macOS 26 that makes the glass compositor treat the panes as detached
    /// siblings and the document can disappear behind the material. The
    /// overlay is a separate lane above the split, still inside the window's
    /// glass stage, so the split keeps ownership of its panes.
    private var floatingOverlayHost: NSView!

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
    private var focusModeApplied = false
    private var discardChangesOnClose = false
    private var focusDimmingViews: [FocusDimmingView] = []
    private var isSynchronizingPanes = false
    private var pendingInitialRestoreOffset: Int?
    private var deferredInitialRestoreOffset: Int?
    var isFocusModeEnabled: Bool { Preferences.shared.values.focusMode }
    var pendingConflict: MarkdownDocument.Conflict?
    weak var toolbarPresentationControl: ToolbarPresentationControl?
    weak var toolbarDocumentIdentityView: ToolbarDocumentIdentityView?
    /// The two panel buttons promoted out of the `···` overflow.  Weak, because
    /// the toolbar item owns its view; the controller only needs them to keep
    /// their lit state in step with the panels they open.
    weak var toolbarFindButton: ToolbarActionButton?
    var toolbarGlassBand: ToolbarGlassBand?
    /// The `···` button. Sections that live behind it morph out of it.
    weak var toolbarOverflowButton: ToolbarMenuButton?
    /// One update pill per window; created lazily by the toolbar and owned by
    /// the toolbar item's view.  It observes the coordinator itself, so it
    /// needs no wiring from the controller.  Internal (not private) because
    /// the toolbar delegate lives in a separate file.
    var updateStatusPill: UpdateStatusPill?

    /// Cached offset for the last breadcrumb rebuild, to avoid walking the
    /// heading tree on every scroll frame when the current section hasn't changed.
    private var lastBreadcrumbOffset: Int = -1

    /// Coalesces panel/metrics refresh so typing does not rebuild outline,
    /// density bands, and diagnostics on every parse commit.
    private var derivedUIRefreshWorkItem: DispatchWorkItem?
    private var findRefreshWorkItem: DispatchWorkItem?
    private var cachedMetricsDocumentID: ObjectIdentifier?
    private var cachedSectionMetrics: [ReadingMetrics] = []
    private var cachedWordCount = 0
    private var autosaveWorkItem: DispatchWorkItem?

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
        let window = DocumentWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titlebarSeparatorStyle = .none
        window.tabbingMode = .preferred
        // Session restoration is owned by DocumentStateStore. AppKit window
        // archives can resurrect obsolete toolbar item views across releases.
        window.isRestorable = false
        window.minSize = NSSize(width: 520, height: 400)
        self.init(window: window)
        applyWindowAppearance(for: ThemeStore.shared.current)
        window.backgroundColor = activeStyleSheet.background
        window.delegate = self
        buildInterface()
        window.setContentSize(NSSize(width: 1020, height: 728))
        if let screen = window.screen ?? NSScreen.main {
            _ = window.cascadeTopLeft(from: NSPoint(x: screen.visibleFrame.minX + 80, y: screen.visibleFrame.maxY - 60))
        } else {
            window.center()
        }
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
        pathResolver = PathResolver(documentURL: url)
        configureLocalAssetAccess(for: primaryContainer.textView, documentURL: url)

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
        autosaveWorkItem?.cancel()
        cachedMetricsDocumentID = nil
        cachedSectionMetrics = []
        cachedWordCount = 0

        stopSpeaking()
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
        switch markdownDocument.unreadChanges {
        case .none:
            break
        case .marked:
            presentUnreadChanges()
        case .previousVersionUnavailable(let reason):
            // Still say the file moved on, even when the bytes to diff against
            // are gone — silence would read as "nothing happened".
            showChangeSummary(reason == .corrupt
                ? "Changed since you last read it — the previous version is damaged"
                : "Changed since you last read it — the previous version is no longer available")
        }
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
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        if ProcessInfo.processInfo.environment["DOWNRIGHT_DEBUG_FIND"] != nil,
           findBar == nil
        {
            showFindBar(replace: false)
            findBar?.alphaValue = 1
            findBar?.layer?.setAffineTransform(.identity)
        }
        if ProcessInfo.processInfo.environment["DOWNRIGHT_DEBUG_PANELS"] != nil {
            if taskPanel == nil { toggleTaskPanel() }
        }
        window?.layoutIfNeeded()
        rootView.layoutSubtreeIfNeeded()
        let lines = [
            "window       \(window?.frame ?? .zero)",
            "contentView  \(window?.contentView?.frame ?? .zero)",
            "rootView     \(rootView.frame)",
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

        if let toolbar = window?.toolbar {
            for item in toolbar.items {
                let view = item.view
                FileHandle.standardError.write(Data((
                    "toolbar \(item.itemIdentifier.rawValue) "
                    + "view=\(String(describing: type(of: view))) "
                    + "frame=\(view?.frame ?? .zero) "
                    + "intrinsic=\(view?.intrinsicContentSize ?? .zero) "
                    + "hidden=\(view?.isHidden ?? false)\n"
                ).utf8))
            }
        }

        // The inspector is the other place a "blank rectangle" can come from:
        // its header lives above the panel, so a header laid out behind the
        // toolbar or at zero height reads as dead space rather than as a bug.
        if let host = inspectorHost {
            var lines = [
                "inspector    host=\(host.frame) safeArea=\(host.safeAreaInsets) "
                + "selected=\(String(describing: host.selectedSection))",
            ]
            for sub in host.subviews {
                lines.append(
                    "  \(type(of: sub)) frame=\(sub.frame) "
                    + "hidden=\(sub.isHidden) alpha=\(sub.alphaValue)"
                )
            }
            FileHandle.standardError.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        }

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
        wireKeyEventHandler(primaryContainer.textView)
        // Style through the container so `scrollView.backgroundColor` follows
        // the theme — styling the text view directly left the scroll surface on
        // the fallback colour and showed a seam beside the document map (§8.6).
        primaryContainer.styleSheet = activeStyleSheet
        primaryContainer.topAccessory = breadcrumbView
        // The current-section cue lives in a stable orientation lane. A
        // reader must never trade the first line of prose for navigation.
        primaryContainer.topAccessoryOverlaysContent = false
        // The document map is navigation, not a second scrollbar. Keep it in
        // the leading lane where the outline it expands into belongs.
        primaryContainer.leadingAccessory = densityGutterView
        breadcrumbView.delegate = self
        breadcrumbView.styleSheet = activeStyleSheet
        densityGutterView.delegate = self
        densityGutterView.styleSheet = activeStyleSheet
        progressRing.styleSheet = activeStyleSheet
        toolbarPresentationControl?.styleSheet = activeStyleSheet

        rootView = DocumentRootView(backgroundColor: activeStyleSheet.background)
        let toolbarGlassBand = ToolbarGlassBand(styleSheet: activeStyleSheet)
        self.toolbarGlassBand = toolbarGlassBand
        barStack = NSStackView()
        barStack.orientation = .vertical
        barStack.spacing = 0
        barStack.distribution = .fill
        barStack.alignment = .centerX

        statusBarView = DocumentStatusBarView(styleSheet: activeStyleSheet)
        statusBarView.isVisible = Preferences.shared.values.showStatusBar

        for view in [toolbarGlassBand, primaryContainer, barStack, statusBarView] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(view)
        }
        // Keep transient bars (conflict, find) off the very top edge so a
        // centred find bar does not feel nailed to the toolbar.
        barStack.edgeInsets = NSEdgeInsets(top: 14, left: 0, bottom: 0, right: 0)

        let documentController = NSViewController()
        documentController.view = rootView

        // The document is the only split pane. Inspector sections are floating
        // surfaces now; retaining a collapsed inspector item would leave a
        // second presentation system and keep resize state alive for dead UI.
        let split = NSSplitViewController()
        let document = NSSplitViewItem(viewController: documentController)
        split.addSplitViewItem(document)
        windowSplitController = split
        window?.contentViewController = split
        // Layer 3: the split and the floating lane share one window stage.
        // The surface itself is never mounted on the split view.
        installFloatingOverlayHost()
        installMorphRetargeting()

        NSLayoutConstraint.activate([
            primaryContainer!.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            primaryContainer.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            primaryContainer.topAnchor.constraint(equalTo: barStack.bottomAnchor),
            primaryContainer.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),

            statusBarView.leadingAnchor.constraint(equalTo: primaryContainer!.leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: primaryContainer.trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),

            barStack.leadingAnchor.constraint(equalTo: primaryContainer!.leadingAnchor),
            barStack.trailingAnchor.constraint(equalTo: primaryContainer.trailingAnchor),
            barStack.topAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor),

            toolbarGlassBand.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            toolbarGlassBand.trailingAnchor.constraint(equalTo: rootView.trailingAnchor),
            toolbarGlassBand.topAnchor.constraint(equalTo: rootView.topAnchor),
            toolbarGlassBand.bottomAnchor.constraint(equalTo: rootView.safeAreaLayoutGuide.topAnchor),
        ])

        buildToolbar()
    }

    // MARK: Morph chip: Layer 3 container

    /// Builds the window's two drawing lanes without putting glass on the split
    /// view itself. The split controller remains a real child controller, so
    /// AppKit still owns pane layout; the overlay is its sibling in this root.
    private func installFloatingOverlayHost() {
        guard let hostWindow = window, let split = windowSplitController else { return }

        let stage = NSView()
        stage.wantsLayer = false
        let splitView = split.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        let overlay = NSView()
        overlay.wantsLayer = false

        overlay.translatesAutoresizingMaskIntoConstraints = false

        let holder = NSViewController()
        holder.view = stage
        holder.addChild(split)
        stage.addSubview(splitView)
        stage.addSubview(overlay)
        NSLayoutConstraint.activate([
            splitView.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: stage.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
            overlay.leadingAnchor.constraint(equalTo: stage.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: stage.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: stage.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: stage.bottomAnchor),
        ])
        floatingOverlayHost = overlay

        if #available(macOS 26.0, *) {
            let container = NSGlassEffectContainerView(frame: stage.bounds)
            container.autoresizingMask = [.width, .height]
            container.contentView = stage
            let glassRoot = NSViewController()
            glassRoot.view = container
            glassRoot.addChild(holder)
            hostWindow.contentViewController = glassRoot
        } else {
            hostWindow.contentViewController = holder
        }
    }

    /// Keep a flying trip aimed at the pane's true resting place.  A live
    /// window resize or a divider drag moves the pane half a metre while the
    /// vessel is mid-air; retargeting only refits the destination.
    private func installMorphRetargeting() {
        guard window != nil else { return }
        let center = NotificationCenter.default
        let windowToken = center.addObserver(
            forName: NSWindow.didResizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.retargetMorphDestination()
            }
        }
        morphRetargetTokens = [windowToken]
    }

    private func retargetMorphDestination() {
        guard let vessel = morphVessel, let window else {
            // No flight to aim: the settled surface itself re-clamps to the
            // window it now finds itself in (the cap lives on the window).
            refitFloatingSurface()
            return
        }
        let anchor: Motion.MorphAnchor = switch morphDestination {
        case .floating:
            Motion.MorphAnchor(
                frame: floatingDestinationAnchor(in: window),
                cornerRadius: FloatingPanelSurface.Top.cornerRadius,
                tint: FloatingPanelSurface.glassTint(activeStyleSheet)
            )
        case .toolTop:
            floatingSourceAnchor(in: window)
        }
        vessel.retarget(to: anchor, window: window)
    }

    private func buildToolbar() {
        // Keep the document switch in the optical centre with explicit flexible
        // spaces. AppKit then owns hit testing and the layout stays stable when
        // a toolbar item is hidden or the window gets narrower.
        let toolbar = NSToolbar(identifier: "DownrightToolbar.v11")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.sizeMode = .regular
        toolbar.centeredItemIdentifier = Self.modeItem
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        toolbar.isVisible = true
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
        // The identity item *is* the title, so AppKit must not draw a second
        // one behind it.  This used to be set from inside the item factory,
        // which meant the window's title visibility depended on when the
        // toolbar happened to build its views — and a toolbar rebuild after a
        // full-screen transition could leave the two fighting.
        window?.titleVisibility = .hidden
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
            if dirty { self?.scheduleAutosave() }
        }
        markdownDocument.onWillApplyUndoRedo = { [weak self] in
            guard let self else { return }
            for pane in self.documentPanes {
                pane.textView.preserveViewportAcrossUndoRedo()
            }
            // Undoing a tick or a drag reshapes the list the same way the
            // forward edit did.
            self.refitFloatingSurfaceAfterContentChange()
        }
        markdownDocument.onSaveFailure = { [weak self] error in
            self?.presentSaveError(error)
        }
        // The reading position belongs to whichever pane the reader is in, not
        // always the primary one — in split view the anchor used to be captured
        // from and restored to the other pane.
        markdownDocument.currentTopOffsetProvider = { [weak self] in
            self?.containerTextView.topVisibleOffset ?? 0
        }
        markdownDocument.restoreOffsetHandler = { [weak self] offset in
            guard let self else { return }
            for pane in self.documentPanes {
                pane.textView.scroll(toOffset: offset, position: .top, animated: false)
            }
        }
        // An external write replaces the whole buffer, which drops the
        // selection; put it back on the same text rather than at the same
        // offset, since the offsets have moved.
        markdownDocument.currentSelectionProvider = { [weak self] in
            self?.containerTextView.sourceSelectedRange ?? NSRange(location: 0, length: 0)
        }
        markdownDocument.restoreSelectionHandler = { [weak self] range in
            self?.containerTextView.setSourceSelectedRanges([range])
        }
        markdownDocument.onExternalWriteActivity = { [weak self] busy in
            busy ? self?.activityIndicator.begin() : self?.activityIndicator.end()
        }
        markdownDocument.onFileRenamed = { [weak self] newURL in
            self?.adoptRenamedFile(newURL)
        }
        markdownDocument.changes.onChange = { [weak self] in self?.refreshChangeDecorations() }
    }

    private func observeTheme() {
        themeObservation = ThemeStore.shared.observe { [weak self] theme in
            guard let self, let window = self.window else { return }
            self.applyWindowAppearance(for: theme)
            self.activeStyleSheet = Self.makeStyleSheet(theme: theme, appearance: window.effectiveAppearance)
            self.applyStyleSheet()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: Preferences.didChange, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(accessibilityDisplayOptionsDidChange),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil
        )
    }

    private func applyWindowAppearance(for theme: Theme) {
        // Following macOS means native controls inherit macOS directly. Do not
        // pin each window to the selected theme's appearance: that severs the
        // system appearance chain even when the theme pair changes correctly.
        if Preferences.shared.values.followsSystemAppearance {
            window?.appearance = nil
            return
        }
        switch theme.appearance {
        case .light: window?.appearance = NSAppearance(named: .aqua)
        case .dark: window?.appearance = NSAppearance(named: .darkAqua)
        case .auto: window?.appearance = nil
        }
    }

    @objc private func accessibilityDisplayOptionsDidChange() {
        guard let window else { return }
        activeStyleSheet = Self.makeStyleSheet(
            theme: ThemeStore.shared.current,
            appearance: window.effectiveAppearance
        )
        applyStyleSheet()
    }

    @objc private func preferencesDidChange() {
        applyWindowAppearance(for: ThemeStore.shared.current)
        activeStyleSheet = Self.makeStyleSheet(
            theme: ThemeStore.shared.current,
            appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance
        )
        applyStyleSheet()
        applyFocusMode(Preferences.shared.values.focusMode, animated: true)
        applyStatusBarPreference()
        rebuildSiblingScannerIfFoldersChanged()
    }

    /// The status bar is opt-in (DESIGN.md's "Avoid" list names a permanent
    /// one), so its visibility follows the preference rather than the window's
    /// existence.  Hidden it also gives back its height, because
    /// `intrinsicContentSize` reports zero — the document simply extends to the
    /// window edge instead of leaving a blank strip.
    func applyStatusBarPreference() {
        statusBarView.isVisible = Preferences.shared.values.showStatusBar
    }

    /// A rename is an identity change, not content to reconcile: the bytes are
    /// the same, the path is not.  Following it keeps history, path resolution
    /// and the sibling list pointing at the file the reader is actually in.
    private func adoptRenamedFile(_ newURL: URL) {
        window?.title = newURL.lastPathComponent
        window?.subtitle = newURL.deletingLastPathComponent().lastPathComponent
        window?.representedURL = newURL
        configureLocalAssetAccess(for: primaryContainer.textView, documentURL: newURL)
        if let splitContainer {
            configureLocalAssetAccess(for: splitContainer.textView, documentURL: newURL)
        }
        pathResolver = PathResolver(documentURL: newURL)
        scanner = SiblingScanner(
            documentURL: newURL,
            extraDirectories: Preferences.shared.values.siblingScanDirectories
        )
        dismissConflictBar()
        showChangeSummary("Renamed to \(newURL.lastPathComponent)")
    }

    /// The scanner is otherwise built only in `open(_:mode:)`, so editing the
    /// extra-folder list in Settings appeared to do nothing until the document
    /// was reopened.
    private func rebuildSiblingScannerIfFoldersChanged() {
        let folders = Preferences.shared.values.siblingScanDirectories
        guard let url = markdownDocument.url, scanner?.extraDirectories != folders else { return }
        scanner = SiblingScanner(documentURL: url, extraDirectories: folders)
    }

    func applyStyleSheet() {
        primaryContainer.styleSheet = activeStyleSheet
        splitContainer?.styleSheet = activeStyleSheet
        breadcrumbView.styleSheet = activeStyleSheet
        densityGutterView.styleSheet = activeStyleSheet
        statusBarView.styleSheet = activeStyleSheet
        progressRing.styleSheet = activeStyleSheet
        taskPanel?.styleSheet = activeStyleSheet
        floatingSurface?.styleSheet = activeStyleSheet
        findBar?.styleSheet = activeStyleSheet
        searchInspector?.styleSheet = activeStyleSheet
        historyInspector?.styleSheet = activeStyleSheet
        conflictBar?.styleSheet = activeStyleSheet
        changeSummaryBar?.styleSheet = activeStyleSheet
        searchResults?.styleSheet = activeStyleSheet
        frontMatterEditor?.styleSheet = activeStyleSheet
        assetDoctorPanel?.styleSheet = activeStyleSheet
        // The inspector header is chrome like any other panel's; it never
        // followed the theme before because nothing assigned it one.
        inspectorHost?.styleSheet = activeStyleSheet
        (rootView as? DocumentRootView)?.backgroundColor = activeStyleSheet.background
        toolbarGlassBand?.styleSheet = activeStyleSheet
        window?.backgroundColor = activeStyleSheet.background
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
            if !activeStyleSheet.reduceMotion, pane.textView.window != nil {
                pane.textView.wantsLayer = true
                pane.textView.layer?.removeAnimation(forKey: "mode-crossfade")
                let transition = CATransition()
                transition.type = .fade
                transition.duration = Motion.standard
                transition.timingFunction = Motion.timing(.decelerate)
                pane.textView.layer?.add(transition, forKey: "mode-crossfade")
            }
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
        breadcrumbView.zoomLevel = level
        announceTransientStatus(zoomAnnouncement(level))
    }

    private func zoomAnnouncement(_ level: ZoomLevel) -> String {
        switch level {
        case .h1: return "Top level — top-level headings"
        case .h2: return "Two levels — headings through level two"
        case .headings: return "Headings — all headings"
        case .skeleton: return "Skeleton — headings, first sentences, artifacts"
        case .everything: return "Everything — all content visible"
        }
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

    /// Find-as-you-type path.  Each keystroke currently re-runs a fresh
    /// regular-expression match over the whole document synchronously on the
    /// main thread; coalescing them into one run per idle tick makes typing in
    /// the search field cheap instead of O(document) per character.
    func scheduleFindQuery(_ query: FindQuery) {
        guard !query.isEmpty else {
            runFind(query)  // clearing the field must take effect immediately
            return
        }
        findRefreshWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.runFind(query)
        }
        findRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06, execute: work)
    }

    // MARK: - Autosave

    /// Schedules a save after a brief idle period when the document is dirty
    /// and autosave is enabled.  Repeated edits reset the timer, so a rapid
    /// typing burst produces one save, not one per keystroke.
    private func scheduleAutosave() {
        guard Preferences.shared.values.autosaveEnabled,
              markdownDocument.url != nil else { return }
        autosaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.markdownDocument.isDirty else { return }
            _ = self.saveDocument()
        }
        autosaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    func refreshDerivedUI() {
        let parsed = markdownDocument.parsed
        let source = containerTextView
        let metrics = sectionMetrics(for: parsed)
        if let taskPanel {
            taskPanel.tasks = parsed.tasks
            taskPanel.headings = parsed.headings
            taskPanel.reload()
            refitFloatingSurface()
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

    /// Change marks go visited on departure or after a dwell, never on
    /// arrival — see `jumpChange`.  Driven from the scroll path so "left the
    /// viewport" is something the reader actually did.
    func noteVisibleChangeMarks() {
        let view = containerTextView
        let visible = view.enclosingScrollView?.documentVisibleRect ?? view.visibleRect
        let origin = view.textContainerOrigin
        let top = view.topVisibleOffset
        let bottom = view.sourceOffset(
            at: NSPoint(x: origin.x + 1, y: max(visible.maxY - 1, visible.minY))
        )
        markdownDocument.changes.noteVisibleRange(
            NSRange(location: min(top, bottom), length: abs(bottom - top))
        )
        toolbarDocumentIdentityView?.hasExternalChanges = markdownDocument.changes.unreadCount > 0
    }

    func refreshDensityBands(metrics: [ReadingMetrics]? = nil) {
        primaryContainer.refreshMarginNotes()
        splitContainer?.refreshMarginNotes()
        let parsed = markdownDocument.parsed
        _ = metrics ?? sectionMetrics(for: parsed)
        let wordCount = cachedWordCount
        let readMinutes = max(1, (wordCount + 199) / 200)
        // The gutter's hover summary is the *only* place these two live: the
        // status bar used to repeat them permanently, which is what a calm
        // document surface is meant not to do.
        densityGutterView.metricsSummary = "\(wordCount) words · \(readMinutes) min read"
        statusBarView.hasFileURL = markdownDocument.url != nil
        densityGutterView.bands = DensityGutterView.bands(
            for: parsed, changes: [], searchHits: findSession.matches
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
        breadcrumbView.zoomLevel = containerTextView.zoomLevel
        let offset = containerTextView.topVisibleOffset
        // Skip the heading tree walk if the offset hasn't crossed a heading
        // boundary since the last scroll.  The breadcrumb view's own
        // `sameTrail` guard already prevents UI rebuilds, but the tree walk
        // (`lastIndex(where:)`) is O(headings) and measurable for large docs.
        guard offset != lastBreadcrumbOffset else { return }
        lastBreadcrumbOffset = offset
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
        // Change tracking still powers summaries, navigation, persistence, and
        // accessibility.  The coloured document marks and density-rail dots
        // are intentionally absent from the calm reading surface.
        primaryContainer.textView.changeMarks = []
        splitContainer?.textView.changeMarks = []
        refreshDensityBands()
    }

    /// "I have read all of these" — the review queue's one explicit exit.
    ///
    /// Reachable from the Navigate menu, ⌘⇧R and the palette, not only from the
    /// summary bar.  The bar is raised by a live external write and goes away
    /// with it, so it can only ever answer for changes that arrived while the
    /// window was in front of you; marks outlive the bar by design (they are
    /// persisted across a close/reopen), and until this existed the reader who
    /// came back to a rewritten file simply had no control that turned the
    /// highlighting off.
    func markChangesReviewed() {
        guard !markdownDocument.changes.isEmpty else { return }
        let count = markdownDocument.changes.count
        markdownDocument.changes.clear()
        dismissChangeSummary()
        toolbarDocumentIdentityView?.hasExternalChanges = false
        announceTransientStatus(
            "Marked \(count) change\(count == 1 ? "" : "s") as reviewed"
        )
    }

    // MARK: - External changes (§8.1)

    private func handleExternalEvent(_ event: MarkdownDocument.ExternalEvent) {
        switch event {
        case .applied(let hunks):
            refreshChangeDecorations()
            pathResolver?.invalidate()
            scheduleFindRefresh()
            guard !hunks.isEmpty else { return }
            toolbarDocumentIdentityView?.hasExternalChanges = true
            showChangeSummary()

        case .conflict(let conflict):
            toolbarDocumentIdentityView?.hasExternalChanges = true
            pendingConflict = conflict
            showConflictBar("Changed on disk — \(conflict.changedBlockCount) block\(conflict.changedBlockCount == 1 ? "" : "s")")

        case .fileRemoved:
            toolbarDocumentIdentityView?.hasExternalChanges = true
            showConflictBar("File was moved or deleted")

        case .fileRestored:
            toolbarDocumentIdentityView?.hasExternalChanges = false
            dismissConflictBar()
        }
    }

    private func presentUnreadChanges() {
        guard markdownDocument.changes.unreadCount > 0 else { return }
        showChangeSummary()
        refreshChangeDecorations()
    }

    /// Shows the change summary.  With no message the bar describes the write
    /// Where the floating change bar sits, measured from the top of the
    /// document container.
    ///
    /// The bar is chrome the *window* floats over the document, while the
    /// breadcrumb is chrome the *container* reserves a lane for.  Pinned to the
    /// window's own top the two occupied the same band, and on any window below
    /// roughly 1000pt the bar simply sat on top of the trail — 227pt of overlap
    /// at 640pt wide.  Clearing the container's reserved lane is what keeps them
    /// two pieces of chrome instead of one collision.
    private var changeSummaryTopInset: CGFloat { 14 }

    /// The lane changes height when the breadcrumb is hidden — Focus mode — so
    /// the bar's offset is a constant that gets refreshed, not one set once.
    func refreshChangeSummaryTopInset() {
        changeSummaryTopConstraint?.constant = changeSummaryTopInset
    }

    /// itself from the tracker's marks; a message is for the events the marks
    /// cannot name, such as a rename.
    func showChangeSummary(_ message: String? = nil) {
        changeSummaryDismissWorkItem?.cancel()
        if changeSummaryBar == nil {
            let bar = ChangeSummaryBarView()
            bar.delegate = self
            bar.styleSheet = activeStyleSheet
            changeSummaryBar = bar
            bar.translatesAutoresizingMaskIntoConstraints = false
            rootView.addSubview(bar, positioned: .above, relativeTo: nil)
            let top = bar.topAnchor.constraint(
                equalTo: rootView.topAnchor,
                constant: changeSummaryTopInset
            )
            changeSummaryTopConstraint = top
            NSLayoutConstraint.activate([
                top,
                bar.trailingAnchor.constraint(equalTo: rootView.trailingAnchor, constant: -16),
            ])
        }
        refreshChangeSummaryTopInset()
        changeSummaryBar?.configure(
            message: message,
            summary: ChangeSummaryBarView.Summary(
                marks: markdownDocument.changes.unreadMarks,
                documentLength: markdownDocument.text.utf16.count
            )
        )
        rootView.needsLayout = true
        rootView.layoutSubtreeIfNeeded()
        animateChangeSummaryInIfNeeded()
        scheduleChangeSummaryDismissal()
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
        changeSummaryDismissWorkItem?.cancel()
        changeSummaryDismissWorkItem = nil
        if let changeSummaryBar {
            changeSummaryBar.removeFromSuperview()
        }
        changeSummaryBar = nil
        rootView.needsLayout = true
    }

    private func scheduleChangeSummaryDismissal() {
        let work = DispatchWorkItem { [weak self] in self?.animateChangeSummaryOut() }
        changeSummaryDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.5, execute: work)
    }

    private func animateChangeSummaryInIfNeeded() {
        guard let bar = changeSummaryBar else { return }
        bar.layer?.removeAllAnimations()
        guard !activeStyleSheet.reduceMotion, let layer = bar.layer else {
            bar.alphaValue = 1
            return
        }

        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = [
            CATransform3DMakeScale(0.72, 0.82, 1),
            CATransform3DMakeScale(1.04, 0.96, 1),
            CATransform3DIdentity,
        ]
        transform.keyTimes = [0, 0.64, 1]
        transform.timingFunctions = [
            CAMediaTimingFunction(name: .easeOut),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]
        transform.duration = 0.42

        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 0
        opacity.toValue = 1
        opacity.duration = 0.20
        layer.add(transform, forKey: "change-toast-materialize")
        layer.add(opacity, forKey: "change-toast-fade-in")
        bar.alphaValue = 1
    }

    private func animateChangeSummaryOut() {
        guard let bar = changeSummaryBar else { return }
        changeSummaryDismissWorkItem = nil
        guard !activeStyleSheet.reduceMotion, let layer = bar.layer else {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.16
                bar.animator().alphaValue = 0
            } completionHandler: { [weak self] in
                Task { @MainActor in self?.dismissChangeSummary() }
            }
            return
        }

        let group = CAAnimationGroup()
        let transform = CAKeyframeAnimation(keyPath: "transform")
        transform.values = [
            CATransform3DIdentity,
            CATransform3DMakeScale(1.03, 0.94, 1),
            CATransform3DMakeScale(0.62, 0.74, 1),
        ]
        transform.keyTimes = [0, 0.30, 1]
        let opacity = CABasicAnimation(keyPath: "opacity")
        opacity.fromValue = 1
        opacity.toValue = 0
        group.animations = [transform, opacity]
        group.duration = 0.34
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in self?.dismissChangeSummary() }
        layer.add(group, forKey: "change-toast-dematerialize")
        CATransaction.commit()
    }

    // MARK: - End of life

    deinit {
        for token in morphRetargetTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    // MARK: - Panels

    // MARK: Morphing arrivals

    /// Whether this window can fly a travelling glass vessel. Reduce Motion
    /// takes the instant presentation path: no vessel, unfurl, or scale.
    private var canMorphInspector: Bool {
        guard let window, window.isVisible, window.screen != nil,
              !activeStyleSheet.reduceMotion
        else { return false }
        return true
    }

    /// The surface lane is deliberately not the split view. It sits above the
    /// document in the shared stage, while the stage remains the glass
    /// container's content on macOS 26.
    private func floatingSurfaceHost(in window: NSWindow) -> NSView {
        if let floatingOverlayHost, floatingOverlayHost.window === window {
            return floatingOverlayHost
        }
        return window.contentView ?? NSView()
    }

    /// The Tasks panel morphs from the toolbar ring and hangs over the
    /// document: travelling glass is aimed at a measured frame instead of a
    /// docked pane. The height is content-driven with a ceiling — the
    /// surface is measured once at the cap (60% of the window's content
    /// height) at its full width, then fitted to the list's own document
    /// height. Offscreen and Reduce Motion presentations use the deterministic
    /// sliver path; visible windows use the ring-to-card vessel.
    ///
    /// Dismissal rule for the floating surface — one panel, one way out, all
    /// listed here so the contract lives in one place: Esc, the header close
    /// button, a second press of the ring, or a click on the document outside
    /// the glass. Ordinary app switching is deliberately not a dismissal;
    /// the surface remains available when the window becomes key again.
    private func presentFloatingSurface(_ surface: FloatingPanelSurface) {
        guard let window, let target = window.contentView else { return }
        let morphs = canMorphInspector
        let width = min(
            surface.preferredWidth,
            max(200, target.bounds.width - 2 * PanelMetrics.floatingMargin)
        )
        let cap = floatingHeightCap(in: target)
        let frame = floatingFrame(for: surface, in: target, width: width, cap: cap)
        let resting = screenFrame(frame, in: target, window: window)
        let sliver = NSRect(
            x: resting.minX,
            y: resting.maxY - FloatingPanelSurface.Top.pourSliverHeight,
            width: resting.width,
            height: FloatingPanelSurface.Top.pourSliverHeight
        )

        // The child window is transparent, so it owns the final bounds from
        // the first frame. The surface pours inside those bounds; resizing a
        // real window on every display-link tick makes arrival step.
        let shadowMargin = PanelMetrics.floatingShadowMargin
        let childFrame = resting.insetBy(dx: -shadowMargin, dy: -shadowMargin)
        let child = FloatingPanelWindow(frame: childFrame)
        child.appearance = ChromeGlass.materialAppearance(activeStyleSheet)
        child.floatingSurface = surface
        child.onOutsideMouseDown = { [weak self] in
            self?.restoreFloatingFocusAndClose()
        }
        let childContent = NSView(frame: NSRect(origin: .zero, size: childFrame.size))
        childContent.autoresizingMask = [.width, .height]
        childContent.clipsToBounds = false
        child.contentView = childContent
        surface.frame = NSRect(
            x: shadowMargin,
            y: shadowMargin,
            width: resting.width,
            height: resting.height
        )
        if morphs {
            surface.alphaValue = 0
            surface.prepareForMorphArrival()
        }

        surface.configureWindowFrames(
            resting: resting,
            sliver: sliver,
            contentHeight: frame.height
        )
        surface.onWindowFrameChange = { [weak child, weak surface] frame in
            guard let child, let surface else { return }
            child.setFrame(
                frame.insetBy(dx: -shadowMargin, dy: -shadowMargin),
                display: true
            )
            surface.frame = NSRect(
                x: shadowMargin,
                y: shadowMargin,
                width: frame.width,
                height: frame.height
            )
            surface.needsLayout = true
        }
        surface.onFrameSpringSettled = { [weak self, weak surface] in
            guard let self, let surface, self.floatingSurface === surface else { return }
            if surface.isDismissing {
                self.removeFloatingSurface()
            } else {
                self.focusFloatingSurface(surface)
                self.refreshToolbarSelectionState()
            }
        }
        childContent.addSubview(surface)
        surface.layoutSubtreeIfNeeded()
        window.addChildWindow(child, ordered: .above)
        child.orderFront(nil)
        surface.refreshGlassAfterWindowAttach()

        surface.setRestingFrame(resting)
        surface.layoutSubtreeIfNeeded()
        floatingSurface = surface
        floatingPanelWindow = child
        if let documentWindow = window as? DocumentWindow {
            documentWindow.floatingSurface = surface
            documentWindow.onFloatingOutsideMouseDown = { [weak self] in
                self?.restoreFloatingFocusAndClose()
            }
        }
        floatingActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restoreFloatingPanelWindow()
            }
        }
        floatingSurfaceFrame = resting
        if morphs {
            morphDestination = .floating
            let vessel = makeMorphVessel(in: window)
            let destination = Motion.MorphAnchor(
                frame: floatingDestinationAnchor(in: window),
                cornerRadius: FloatingPanelSurface.Top.cornerRadius,
                tint: FloatingPanelSurface.glassTint(activeStyleSheet)
            )
            vessel.fly(
                MorphVessel.Trip(
                    from: floatingSourceAnchor(in: window),
                    to: destination,
                    incomingContent: surface,
                    outgoingContent: progressRing,
                    onHandoff: { [weak surface] in
                        surface?.playMorphArrivalDetails()
                    },
                    onSettle: { [weak self, weak vessel, weak surface] in
                        surface?.alphaValue = 1
                        vessel?.removeFromSuperview()
                        guard let self else { return }
                        if self.morphVessel === vessel { self.morphVessel = nil }
                        guard let surface, self.floatingSurface === surface else { return }
                        self.refitFloatingSurface()
                        self.focusFloatingSurface(surface)
                        (surface.content as? InspectorHostView)?.syncCloseVisibilityWithPointer()
                        self.refreshToolbarSelectionState()
                    }
                ),
                window: window
            )
        } else {
            surface.presentFromSliver(animated: !activeStyleSheet.reduceMotion)
            focusFloatingSurface(surface)
        }
        refreshToolbarSelectionState()
    }

    /// The same surface retreats into the toolbar ring. Offscreen and Reduce
    /// Motion dismissals use the deterministic sliver path.
    private func dismissFloatingSurface() {
        guard let surface = floatingSurface else {
            removeFloatingSurface()
            return
        }
        if canMorphInspector, let window {
            surface.prepareForMorphDismissal()
            morphDestination = .toolTop
            let vessel = makeMorphVessel(in: window)
            vessel.fly(
                MorphVessel.Trip(
                    from: Motion.MorphAnchor(
                        frame: floatingDestinationAnchor(in: window),
                        cornerRadius: FloatingPanelSurface.Top.cornerRadius,
                        tint: FloatingPanelSurface.glassTint(activeStyleSheet)
                    ),
                    to: floatingSourceAnchor(in: window),
                    incomingContent: nil,
                    outgoingContent: surface,
                    onHandoff: { [weak self, weak surface] in
                        guard let self, self.floatingSurface === surface else { return }
                        self.removeFloatingSurface()
                    },
                    onSettle: { [weak self, weak vessel] in
                        vessel?.removeFromSuperview()
                        guard let self else { return }
                        if self.morphVessel === vessel { self.morphVessel = nil }
                        self.refreshToolbarSelectionState()
                    }
                ),
                window: window
            )
            return
        }
        surface.dismissToSliver(animated: !activeStyleSheet.reduceMotion)
    }

    private func removeFloatingSurface() {
        if let documentWindow = window as? DocumentWindow {
            documentWindow.floatingSurface = nil
            documentWindow.onFloatingOutsideMouseDown = nil
        }
        if let floatingActivationObserver {
            NotificationCenter.default.removeObserver(floatingActivationObserver)
            self.floatingActivationObserver = nil
        }
        floatingPanelWindow?.orderOut(nil)
        if let parent = window, let child = floatingPanelWindow {
            parent.removeChildWindow(child)
        }
        floatingSurface?.onWindowFrameChange = nil
        floatingSurface?.onFrameSpringSettled = nil
        floatingSurface?.removeFromSuperview()
        floatingPanelWindow = nil
        floatingSurface = nil
    }

    /// The morph's resting place in window space — the surface's own frame,
    /// or the frame it last rested at once the dismissal hands it off.
    private func floatingDestinationAnchor(in window: NSWindow) -> NSRect {
        if let surface = floatingSurface, let target = window.contentView {
            let width = min(
                surface.preferredWidth,
                max(200, target.bounds.width - 2 * PanelMetrics.floatingMargin)
            )
            let frame = floatingFrame(
                for: surface,
                in: target,
                width: width,
                cap: floatingHeightCap(in: target)
            )
            floatingSurfaceFrame = screenFrame(frame, in: target, window: window)
            return target.convert(frame, to: nil)
        }
        return window.convertFromScreen(floatingSurfaceFrame)
    }

    /// The ring-sized source anchor at the document's safe top edge.
    private func floatingSourceAnchor(in window: NSWindow) -> Motion.MorphAnchor {
        let destination = floatingDestinationAnchor(in: window)
        let side = TaskProgressRing.morphSide
        if progressRing.window === window {
            let ring = progressRing.convert(progressRing.bounds, to: nil)
            let contentTop = window.contentView.map { $0.convert($0.bounds, to: nil).maxY }
                ?? destination.maxY
            return Motion.MorphAnchor(
                frame: NSRect(
                    x: ring.midX - side / 2,
                    y: contentTop - side,
                    width: side,
                    height: side
                ),
                cornerRadius: side / 2,
                tint: activeStyleSheet.accent.withAlphaComponent(0.10)
            )
        }
        return Motion.MorphAnchor(
            frame: NSRect(
                x: destination.maxX - side,
                y: destination.maxY - side,
                width: side,
                height: side
            ),
            cornerRadius: side / 2,
            tint: activeStyleSheet.accent.withAlphaComponent(0.10)
        )
    }

    /// Re-fits a settled surface to its window: the cap lives on the window,
    /// so a resize moves the ceiling and the body re-clamps (and the list
    /// scrolls instead of overrunning it).  During a flight the retarget path
    /// handles the re-aiming; this is the parked case.
    private func floatingHeightCap(in target: NSView) -> CGFloat {
        let availableHeight = max(0, target.bounds.height - target.safeAreaInsets.top)
        return max(
            40,
            min(
                FloatingPanelSurface.Top.windowHeightFraction * availableHeight,
                availableHeight
            ) - 2 * PanelMetrics.floatingMargin
        )
    }

    /// One frame formula for presentation, content refits, and window resize.
    /// `y` is derived from the target's flippedness once, so every path keeps
    /// the top edge under the toolbar and the trailing edge flush.
    func floatingFrame(
        for surface: FloatingPanelSurface,
        in target: NSView,
        width: CGFloat,
        cap: CGFloat
    ) -> NSRect {
        surface.prepareForMeasurement(width: width, height: cap)
        let fitted = surface.fittedContentHeight
        let desired = max(
            fitted,
            FloatingPanelSurface.Top.minimumContentHeight
        )
        let height = min(cap, desired)
        let margin = PanelMetrics.floatingMargin
        let topInset = target.safeAreaInsets.top
        let y = target.isFlipped
            ? topInset + margin
            : target.bounds.height - topInset - height - margin
        return NSRect(
            x: target.bounds.width - width - margin,
            y: y,
            width: width,
            height: height
        )
    }

    private func screenFrame(_ frame: NSRect, in view: NSView, window: NSWindow) -> NSRect {
        window.convertToScreen(view.convert(frame, to: nil))
    }

    private func refitFloatingSurface(animated: Bool = true) {
        guard let surface = floatingSurface, !surface.isDismissing,
              morphVessel == nil, let window, let target = window.contentView
        else { return }
        let width = min(
            surface.preferredWidth,
            max(200, target.bounds.width - 2 * PanelMetrics.floatingMargin)
        )
        let frame = floatingFrame(
            for: surface,
            in: target,
            width: width,
            cap: floatingHeightCap(in: target)
        )
        let resting = screenFrame(frame, in: target, window: window)
        let sliver = NSRect(
            x: resting.minX,
            y: resting.maxY - FloatingPanelSurface.Top.pourSliverHeight,
            width: resting.width,
            height: FloatingPanelSurface.Top.pourSliverHeight
        )
        surface.configureWindowFrames(
            resting: resting,
            sliver: sliver,
            contentHeight: frame.height
        )
        surface.retargetFrame(resting, animated: animated)
        floatingSurfaceFrame = resting
        surface.layoutSubtreeIfNeeded()
    }

    /// Task edits reshape the list's rows; a floating surface re-fits itself
    /// to the new content next turn, once the parse has repopulated the panel.
    /// Internal: the panel delegate lives in a sibling file.
    func refitFloatingSurfaceAfterContentChange() {
        refitFloatingSurface()
    }

    private func focusFloatingSurface(_ surface: FloatingPanelSurface) {
        guard let panelWindow = surface.window else { return }
        panelWindow.makeKey()
        if let host = surface.content as? InspectorHostView {
            host.focusForPresentation()
        } else {
            panelWindow.makeFirstResponder(surface.content)
        }
    }

    private func restoreFloatingPanelWindow() {
        guard let surface = floatingSurface,
              let panelWindow = floatingPanelWindow,
              panelWindow.parent === window,
              surface.window === panelWindow
        else { return }
        panelWindow.orderFrontRegardless()
        if !panelWindow.isKeyWindow { panelWindow.makeKey() }
    }

    private func restoreFloatingFocusAndClose() {
        guard floatingSurface != nil else { return }
        closeInspector()
    }

    /// The vessel is a child of the window's glass container's content view —
/// on macOS 26 that is the split, which is exactly where the container
/// merges descendant glass — and of the content view everywhere else.  Its
/// geometry is owned by the springs; the superview only decides the lanes
/// it may fly through.
    private func makeMorphVessel(in window: NSWindow) -> MorphVessel {
        let vessel = morphVessel ?? MorphVessel(frame: .zero)
        vessel.autoresizingMask = []
        morphVessel = vessel
        // A vessel that landed is detached but may still be held; re-seat it
        // rather than fly a body that is not in the hierarchy, which would
        // animate perfectly and draw nothing.
        guard vessel.superview == nil else { return vessel }
        let target = floatingSurfaceHost(in: window)
        target.addSubview(vessel)
        return vessel
    }

    func toggleTaskPanel() {
        // One floating inspector body owns Tasks, History, Document, and
        // Search. A second press closes only when Tasks is the active section.
        if floatingSurface != nil, inspectorHost?.selectedSection == .tasks {
            closeTaskPanel()
            return
        }
        let panel = taskPanel ?? TaskPanelView()
        if taskPanel == nil {
            panel.delegate = self
            panel.styleSheet = activeStyleSheet
            panel.onContentSizeChange = { [weak self] in self?.refitFloatingSurface() }
            panel.onImmediateContentSizeChange = { [weak self] in
                self?.refitFloatingSurface(animated: false)
            }
            taskPanel = panel
        }
        panel.tasks = markdownDocument.parsed.tasks
        panel.headings = markdownDocument.parsed.headings
        panel.onClose = { [weak self] in self?.closeTaskPanel() }
        // Build the final row model before the floating surface measures its
        // target. Measuring while the empty model is still installed reserves
        // the empty-state height and leaves dead space after the rows arrive.
        panel.reload()
        showInInspector(panel, section: .tasks)
        progressRing.isActive = true
    }

    /// Closes the panel from any of its doors — Esc, the header close button,
    /// a second ring press, or a click outside the glass.
    /// Internal, like `closeInspector`, for the closures and tests that reach
    /// for it.
    func closeTaskPanel() {
        guard taskPanel != nil else { return }
        // The ring settles first, so the glyph is already un-lit while the
        // glass pours back up toward the toolbar edge.
        progressRing.isActive = false
        closeInspector()
        refreshToolbarSelectionState()
    }


    /// `title` names the surface after the command that opened it; without one
    /// the header keeps the section's generic name.
    func installTrailing(_ view: NSView, title: String? = nil) {
        showInInspector(view, section: .context)
        if let title { inspectorHost?.setTitle(title, for: .context) }
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
            // The host is chrome like any panel and has to be born in the
            // document's theme; it used to be styled only on the next theme
            // change, so a window opened under a non-default theme drew its
            // inspector header in the default one until something moved.
            created.styleSheet = activeStyleSheet
            created.onClose = { [weak self] in
                self?.closeInspector()
            }
            inspectorHost = created
            host = created
        }
        if floatingSurface == nil {
            floatingFocusRestoreView = window?.firstResponder as? NSView
            // The floating body itself owns the arrival. The host must not
            // run its legacy content unfurl or a section switch would stage
            // rows separately from the glass.
            host.morphOwnsTransitions = true
            host.setContent(view, section: section)
            let surface = FloatingPanelSurface(styleSheet: activeStyleSheet, content: host)
            surface.onClose = { [weak self] in self?.closeInspector() }
            presentFloatingSurface(surface)
        } else {
            // Switching sections reuses the same glass body and header. The
            // document never enters a split-view resize path.
            host.morphOwnsTransitions = true
            host.setContent(view, section: section)
            floatingSurface?.layoutSubtreeIfNeeded()
            refitFloatingSurface()
            focusFloatingSurface(floatingSurface!)
        }
        if section == .tasks { progressRing.isActive = true }
        refreshToolbarSelectionState()
    }

    /// Closing is the arrival run backwards: the panel folds up toward the
    /// toolbar control that opened it, and only then does the pane give its
    /// width back to the document.  Collapsing first would make the panel
    /// vanish and the text jump in the same frame, which is the snap this
    /// replaces.
    func closeInspector() {
        guard floatingSurface != nil else {
            refreshToolbarSelectionState()
            return
        }
        progressRing.isActive = false
        let restore = floatingFocusRestoreView
        dismissFloatingSurface()
        if let restore, restore.window === window {
            window?.makeFirstResponder(restore)
        } else {
            window?.makeFirstResponder(primaryContainer.textView)
        }
        floatingFocusRestoreView = nil
        refreshToolbarSelectionState()
    }

    /// Keeps auxiliary windows (timeline, compare, lightbox) alive for as long
    /// as this document window is.
    func retainTimeline(_ controller: NSWindowController) {
        auxiliaryWindows.append(controller)
        // Selector form, so the observation can unregister itself.  The block
        // form dropped the controller but left its own registration installed
        // for the lifetime of the app — one more every time a timeline, compare,
        // or lightbox window was opened and closed.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(auxiliaryWindowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: controller.window
        )
    }

    @objc private func auxiliaryWindowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        NotificationCenter.default.removeObserver(
            self, name: NSWindow.willCloseNotification, object: window
        )
        auxiliaryWindows.removeAll { $0.window === window }
    }

    /// The host fills the pane, top to bottom.  The inspector used to offer a
    /// fit-to-content card mode for short panels: a required height constraint
    /// on the card reached the window's constraint-driven sizing
    /// (`_changeWindowFrameFromConstraintsIfNecessary`) and *resized the whole
    /// window* to the card's height when the panel opened.  Docked columns
    /// only — a panel never sizes the window.
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

    func showFindBar(replace: Bool, queryAfterFocus: FindQuery? = nil) {
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
            // A find bar is a compact tool, not a full-width strip. The stack's
            // `.centerX` alignment centres the pill; demand a settled width that
            // can give way to a narrow window (§9.4).
            let width = created.widthAnchor.constraint(equalToConstant: FindBarDensity.barWidth)
            width.priority = .defaultHigh
            width.isActive = true
            created.widthAnchor.constraint(
                lessThanOrEqualTo: barStack.widthAnchor,
                constant: -2 * PanelMetrics.inset
            ).isActive = true
            bar = created
            // Settle the pill into the shared surface vocabulary.
            created.wantsLayer = true
            created.alphaValue = 0
            created.layer?.setAffineTransform(
                CGAffineTransform(translationX: 0, y: 6).scaledBy(x: 0.97, y: 0.97)
            )
            barStack.layoutSubtreeIfNeeded()
            Motion.run(reduceMotion: activeStyleSheet.reduceMotion, duration: Motion.hover) { _ in
                created.animator().alphaValue = 1
                created.layer?.setAffineTransform(.identity)
            }
        }

        bar.showsReplace = replace
        // Keep ⌘F and ⌘E distinct: Find opens a clean search field, while Use
        // Selection for Find explicitly supplies the selected query. AppKit
        // can seed a newly focused field from the document selection, so the
        // normal path must not inherit either selection or a stale query.
        let requestedQuery = queryAfterFocus ?? FindQuery()
        bar.setQueryText(requestedQuery.text)
        if !requestedQuery.isEmpty {
            runFind(requestedQuery)
        }
        bar.focusSearchField(selectAll: false)
        // AppKit may seed the field once more as first responder activation
        // settles. Reassert the command's query on the next main-queue turn;
        // otherwise ⌘F becomes "find the selection" again in a live window.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self, weak bar] in
            guard let bar, bar.window != nil else { return }
            bar.setQueryText(requestedQuery.text)
            if let self, !requestedQuery.isEmpty, self.findBar === bar {
                self.runFind(requestedQuery)
            }
        }
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
        // Hold the pill so it can leave gracefully while the state tears down
        // now. `findBar` is nilled immediately so nothing can act on a gone
        // bar.
        let leaving = findBar

        searchInspector?.removeFromSuperview()
        inspectorHost?.removeContent(section: .search)
        searchInspector = nil
        findBar = nil
        searchResults = nil
        // Keep the query & matches so ⌘G/Find Next still advance after the bar
        // closes, and so reopening ⌘F does not start empty (#2). Only the
        // visible highlights are torn down.
        for pane in documentPanes {
            pane.textView.searchHits = []
            pane.textView.currentSearchHit = nil
        }
        refreshDensityBands()
        if inspectorHost?.hasContent != true { closeInspector() }
        else { refreshToolbarSelectionState() }

        // Exit reverses the same short settle. The stack keeps its space until
        // the material has left; Reduce Motion skips straight to removal.
        guard let leaving, leaving.superview != nil else { return }
        if activeStyleSheet.reduceMotion {
            retire(leaving)
        } else {
            Motion.run(reduceMotion: false, duration: Motion.hover) { _ in
                leaving.animator().alphaValue = 0
                leaving.layer?.setAffineTransform(
                    CGAffineTransform(translationX: 0, y: 6).scaledBy(x: 0.97, y: 0.97)
                )
            } completion: { [weak self] in
                self?.retire(leaving)
            }
        }
    }

    /// Drops the find pill out of the bar stack.
    ///
    /// Order and idempotence both matter.  `removeArrangedSubview(_:)` raises
    /// when the view is not currently arranged, and `removeFromSuperview()`
    /// already un-arranges it — so the old sequence (remove, then un-arrange)
    /// threw `NSInternalInconsistencyException` from inside
    /// `-[NSStackView _removeView:animated:removeFromViewHierarchy:]` and
    /// aborted the process every time the bar closed with animation enabled.
    /// Closing twice inside one fade must also be harmless, because Escape
    /// repeats faster than the 0.16 s exit.
    private func retire(_ bar: FindBarView) {
        if barStack.arrangedSubviews.contains(bar) {
            barStack.removeArrangedSubview(bar)
        }
        bar.removeFromSuperview()
        bar.alphaValue = 1
        bar.layer?.setAffineTransform(.identity)
    }

    var currentFindQuery: FindQuery { findSession.query }

    func applyFindQuery(_ query: FindQuery) { runFind(query) }

    func runFind(_ query: FindQuery, scrollToMatch: Bool = true, highlightAll: Bool = true) {
        findRefreshWorkItem?.cancel()
        let source = containerTextView
        findSession.update(query: query, in: markdownDocument.text, caret: source.topVisibleOffset)
        // A hit inside a folded or elided range forces that range visible; the
        // text view owns that rule (§14's four-way interaction).
        for pane in documentPanes {
            if highlightAll { pane.textView.searchHits = findSession.matches }
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
        // With the bar closed, ⌘G still advances but first re-checks the query
        // against the buffer so a stale match set cannot point at moved text.
        // Only the current match is highlighted — a closed bar shows "here",
        // not the full sweep it cleared on dismiss.
        if findBar == nil, !findSession.query.isEmpty {
            runFind(findSession.query, scrollToMatch: false, highlightAll: false)
        }
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
        // `.visible`: a jump to a target that is already on screen (a task in the
        // panel, a heading in the outline, a footnote below) must not move the
        // page at all — centring it yanks everything the reader was looking at
        // out from under them.  Off-screen targets get the minimal scroll that
        // brings them in, not a reframe.  Back/Forward keep `.center`: those
        // restore a *recorded* reading position, which is a deliberate reframe.
        source.scroll(toOffset: offset, position: .visible, animated: animated)
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
                primaryContainer.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),
            ])
            markdownDocument.state.splitViewEnabled = false
            return
        }

        // Two panes over the same buffer — the second primaryContainer shares the
        // document's storage, so an edit in one appears in the other with no
        // synchronisation code at all (§3.1 paying off).
        let second = MarkdownContainerView(storage: markdownDocument.storage)
        second.textView.markdownDelegate = self
        wireKeyEventHandler(second.textView)
        second.styleSheet = activeStyleSheet
        configureLocalAssetAccess(for: second.textView, documentURL: markdownDocument.url)
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
            split.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),
        ])
        rootView.layoutSubtreeIfNeeded()
        split.setPosition(max(1, split.bounds.width / 2), ofDividerAt: 0)
        splitViewContainer = split
        markdownDocument.state.splitViewEnabled = true
        if isFocusModeEnabled { installFocusDimmingView(in: second) }
        synchronizePanes(from: source)
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
        guard isFocusModeEnabled, !focusDimmingViews.isEmpty else { return }
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
        stopSpeaking()
        derivedUIRefreshWorkItem?.cancel()
        findRefreshWorkItem?.cancel()
        removeFocusDimmingViews(animated: false)
        removeFloatingSurface()
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
                focusModeApplied = true
            }
            closeTaskPanel()
            window?.toolbar?.isVisible = false
            toolbarGlassBand?.isHidden = true
            densityGutterView.isHidden = true
            breadcrumbView.isHidden = true
            refreshChangeSummaryTopInset()
            documentPanes.forEach { installFocusDimmingView(in: $0) }
            updateFocusDimmingViews()
        } else {
            guard focusModeApplied else {
                window?.toolbar?.isVisible = true
                toolbarGlassBand?.isHidden = false
                densityGutterView.isHidden = false
                breadcrumbView.isHidden = false
                refreshChangeSummaryTopInset()
                return
            }
            removeFocusDimmingViews(animated: animated)
            window?.toolbar?.isVisible = true
            toolbarGlassBand?.isHidden = false
            densityGutterView.isHidden = false
            breadcrumbView.isHidden = false
            refreshChangeSummaryTopInset()
            focusModeApplied = false
        }
        refreshToolbarSelectionState()
    }
}

// MARK: - Window delegate

extension DocumentWindowController: NSWindowDelegate {
    func windowDidBecomeKey(_ notification: Notification) {
        restoreInitialReadingPositionIfReady()
        restoreFloatingPanelWindow()
        refreshToolbarSelectionState()
    }

    /// Ordinary app switching is not dismissal. The surface keeps its state
    /// while another document is active, and its responder is restored when
    /// this window becomes key again.
    func windowDidResignKey(_ notification: Notification) {
        // Intentionally empty. Explicit close, Esc, the ring, or an outside
        // click owns dismissal; Cmd-Tab must not destroy work-in-progress.
    }

    func windowDidBecomeVisible(_ notification: Notification) {
        restoreInitialReadingPositionIfReady()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        markdownDocument.undoManager
    }

    func windowDidResize(_ notification: Notification) {
        updateFocusDimmingViews()
        refitFloatingSurface()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        if !isFocusModeEnabled { window?.toolbar?.isVisible = true }
        resettleDocumentSurface()
    }

    /// Leaving full screen restores the chrome the transition owns, and — like
    /// entering — resettles the document.  Without this the toolbar could come
    /// back hidden after a focus-mode round trip inside full screen.
    func windowDidExitFullScreen(_ notification: Notification) {
        if !isFocusModeEnabled { window?.toolbar?.isVisible = true }
        resettleDocumentSurface()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        resettleDocumentSurface()
    }

    func windowDidChangeBackingProperties(_ notification: Notification) {
        resettleDocumentSurface()
    }

    /// Re-primes the document after a transition that changed the window's
    /// size or surface out from under TextKit.
    ///
    /// TextKit 2 lays out lazily against a viewport it is told about.  A
    /// full-screen transition or a de-miniaturise hands the view a new bounds
    /// without a scroll gesture, so the viewport controller can be left
    /// holding fragments for geometry that no longer exists — which is how a
    /// window comes back from the Dock, or out of full screen, showing a blank
    /// or half-drawn page while the breadcrumb still names the right heading.
    /// A native scroll fixes it, which is precisely the tell that the layout
    /// pass, not the offset, is what went stale.
    private func resettleDocumentSurface() {
        rootView.layoutSubtreeIfNeeded()
        for pane in documentPanes {
            pane.layoutSubtreeIfNeeded()
            pane.textView.resizeToFitContent()
            pane.textView.prepareForDisplay()
            pane.textView.needsDisplay = true
            pane.scrollView.contentView.needsDisplay = true
        }
        updateBreadcrumbAndGutter()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmPendingChangesBeforeClose(markDiscardForWindowClose: true)
    }

    func windowWillClose(_ notification: Notification) {
        // The window is gone regardless of what torn down; deregistration must
        // always run or AppDelegate.`windowControllers` keeps a dead controller
        // that can never be removed (§ Adapts the session registry).
        defer { onClose?() }
        _ = documentWillClose()
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
