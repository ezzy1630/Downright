import AppKit
import MarkdownCore
import MarkdownRender

enum DocumentOpenDisposition {
    /// Join the active document window's native tab group when one exists.
    case tab
    /// Keep the document in a separate window.
    case window
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [DocumentWindowController] = []
    private var preferencesWindow: NSWindowController?
    private var startWindow: StartWindowController?
    private let servicesProvider = DownrightServicesProvider()
    /// Set by `down --edit`; applies to the documents opened in this launch only.
    private var launchMode: RenderMode?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        AppPaths.prepareAll()
        parseLaunchArguments()
        NSApp.mainMenu = MainMenu.build()
        ThemeStore.shared.select(named: Preferences.shared.themeName(for: NSApp.effectiveAppearance))
        IntegrationRegistry.shared.openHandler = { [weak self] url in
            _ = self?.open(url)
        }
        NSRegisterServicesProvider(servicesProvider, "Downright")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Start the Sparkle updater after launch, as the spec requires.  Dev
        // bundles without the Sparkle Info.plist block make this a no-op.
        UpdateCoordinator.shared.start()
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: Preferences.didChange, object: nil
        )
        Preferences.shared.onPersistenceFailure = { [weak self] error in
            DispatchQueue.main.async {
                self?.presentPreferenceWriteFailure(error)
            }
        }
        // History pruning at launch rather than on a timer: it touches the disk
        // and there is no reason to do it while the user is reading (§8.3).
        DispatchQueue.global(qos: .utility).async { SnapshotStore.shared.prune() }

        guard windowControllers.isEmpty else { return }
        // Paths on the command line, for running straight out of `.build`
        // during development.  Launch Services never routes these through
        // `application(_:open:)`, so without this the binary silently falls
        // through to the open panel.
        if openCommandLineFiles() { return }
        if Preferences.shared.values.restoreSession, restoreSession() { return }
        showStartWindow()
    }

    @discardableResult
    private func openCommandLineFiles() -> Bool {
        var opened = 0
        var arguments = ProcessInfo.processInfo.arguments.dropFirst().makeIterator()
        while let argument = arguments.next() {
            // `-NSDocumentRevisionsDebugMode YES` and friends arrive here too.
            if argument.hasPrefix("-") {
                if argument == "--mode" { _ = arguments.next() }
                continue
            }
            let url = URL(fileURLWithPath: argument).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            if open(url) != nil { opened += 1 }
        }
        return opened > 0
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && windowControllers.isEmpty { showStartWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSUnregisterServicesProvider("Downright")
        saveSession()
        for controller in windowControllers { controller.documentWillClose() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // A failed close-time write must cancel termination.  Otherwise macOS
        // tears down the process after the alert and the unsaved buffer is lost.
        for controller in windowControllers where controller.markdownDocument.isDirty {
            guard controller.saveDocument() else { return .terminateCancel }
        }
        return .terminateNow
    }

    private func parseLaunchArguments() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--mode"), index + 1 < arguments.count else { return }
        launchMode = RenderMode(rawValue: arguments[index + 1])
    }

    // MARK: - Opening

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { open(url) }
    }

    func application(_ sender: NSApplication, openFile filename: String) -> Bool {
        open(URL(fileURLWithPath: filename)) != nil
    }

    @discardableResult
    func open(
        _ url: URL,
        mode: RenderMode? = nil,
        disposition: DocumentOpenDisposition = .tab,
        tabbingWith explicitHost: NSWindow? = nil
    ) -> DocumentWindowController? {
        // One window per file: reopening a file you already have open should
        // raise it, not give you two buffers over the same bytes.
        if let existing = windowControllers.first(where: {
            $0.markdownDocument.url?.resolvingSymlinksInPath().standardizedFileURL
                == url.resolvingSymlinksInPath().standardizedFileURL
        }) {
            existing.showWindow(nil)
            existing.window?.makeKeyAndOrderFront(nil)
            dismissStartWindow()
            return existing
        }

        let tabHost: NSWindow? = switch disposition {
        case .tab:
            explicitHost ?? activeDocumentWindow
        case .window:
            nil
        }
        let controller = DocumentWindowController()
        do {
            try controller.open(url, mode: mode ?? launchMode ?? Preferences.shared.values.defaultMode)
        } catch {
            presentOpenFailure(error, url: url)
            // Keep or restore the start window when nothing else is open, including
            // race-deleted recent files clicked while the start window was still up.
            if windowControllers.isEmpty { showStartWindow() }
            return nil
        }
        adopt(controller)
        SpotlightIndexer.indexOpenedDocument(at: url)
        dismissStartWindow()
        controller.showWindow(nil)
        if let tabHost, let window = controller.window, tabHost !== window {
            tabHost.addTabbedWindow(window, ordered: .above)
        }
        controller.window?.makeKeyAndOrderFront(nil)
        return controller
    }

    private var activeDocumentWindow: NSWindow? {
        if let key = NSApp.keyWindow,
           windowControllers.contains(where: { $0.window === key }) {
            return key
        }
        return windowControllers.compactMap(\.window).last(where: \.isVisible)
    }

    func adopt(_ controller: DocumentWindowController) {
        windowControllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
            self.scheduleSessionSave()
        }
    }

    private func presentOpenFailure(_ error: Error, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn't open \(url.lastPathComponent)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = DocumentTypes.contentTypes
        panel.message = "Open a Markdown document"
        guard panel.runModal() == .OK else {
            startWindow?.window?.makeKeyAndOrderFront(nil)
            return
        }
        for url in panel.urls { open(url) }
    }

    private func showStartWindow() {
        let recents = DocumentStateStore.shared.recents(limit: StartWindowController.recentDisplayLimit)
        if let startWindow {
            startWindow.reloadRecents(recents)
            startWindow.window?.alphaValue = 1
            startWindow.showWindow(nil)
            startWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = StartWindowController(recents: recents)
        controller.onOpen = { [weak self] url in self?.open(url) }
        controller.onOpenPanel = { [weak self] in self?.showOpenPanel() }
        controller.onNew = { [weak self] in self?.newDocument() }
        controller.onClearRecents = { [weak self] in self?.clearRecentDocuments(nil) }
        startWindow = controller
        controller.showWindow(nil)
    }

    /// Fades the start window out in parallel with the document content fade-up.
    private func dismissStartWindow() {
        guard let controller = startWindow else { return }
        startWindow = nil
        let animated = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        controller.dismiss(animated: animated)
    }

    // MARK: - Session restore (§9.3)

    private struct SessionWindow: Codable {
        var path: String
        var frame: String
        var mode: String
        var tabGroup: Int?
        var tabOrder: Int?
        var selectedTab: Bool?
    }

    private func saveSession() {
        var groupIDs: [ObjectIdentifier: Int] = [:]
        var nextGroupID = 0
        let windows = windowControllers.compactMap { controller -> SessionWindow? in
            guard let url = controller.markdownDocument.url, let frame = controller.window?.frame else { return nil }
            let groupID: Int?
            let tabOrder: Int?
            let selected: Bool?
            if let group = controller.window?.tabGroup {
                let identity = ObjectIdentifier(group)
                if groupIDs[identity] == nil {
                    groupIDs[identity] = nextGroupID
                    nextGroupID += 1
                }
                groupID = groupIDs[identity]
                tabOrder = controller.window.flatMap { group.windows.firstIndex(of: $0) }
                selected = group.selectedWindow === controller.window
            } else {
                groupID = nil
                tabOrder = nil
                selected = nil
            }
            return SessionWindow(
                path: url.path,
                frame: NSStringFromRect(frame),
                mode: controller.mode.rawValue,
                tabGroup: groupID,
                tabOrder: tabOrder,
                selectedTab: selected
            )
        }
        guard let data = try? JSONEncoder().encode(windows) else { return }
        try? data.write(to: AppPaths.sessionFile, options: .atomic)
    }

    /// Every window reopens with its mode, zoom level, scroll position, fold
    /// state, and sidebar state (§9.3) — the per-document parts come back from
    /// `DocumentStateStore`, so only the window geometry lives in the session.
    /// Closing several windows in a row rewrites the whole session file each
    /// time; coalesce to one write once the burst settles.
    private var sessionSaveWorkItem: DispatchWorkItem?

    private func scheduleSessionSave() {
        sessionSaveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.sessionSaveWorkItem = nil
            self?.saveSession()
        }
        sessionSaveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    @discardableResult
    private func restoreSession() -> Bool {
        guard let data = try? Data(contentsOf: AppPaths.sessionFile),
              let windows = try? JSONDecoder().decode([SessionWindow].self, from: data),
              !windows.isEmpty
        else { return false }

        var restored = 0
        var groupHosts: [Int: NSWindow] = [:]
        var selectedWindows: [NSWindow] = []
        let ordered = windows.sorted {
            if $0.tabGroup != $1.tabGroup {
                return ($0.tabGroup ?? Int.max) < ($1.tabGroup ?? Int.max)
            }
            return ($0.tabOrder ?? 0) < ($1.tabOrder ?? 0)
        }
        for entry in ordered {
            let url = URL(fileURLWithPath: entry.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let host = entry.tabGroup.flatMap { groupHosts[$0] }
            guard let controller = open(
                url,
                mode: RenderMode(rawValue: entry.mode),
                disposition: host == nil ? .window : .tab,
                tabbingWith: host
            ) else { continue }
            controller.window?.setFrame(NSRectFromString(entry.frame), display: true)
            if let group = entry.tabGroup, groupHosts[group] == nil, let window = controller.window {
                groupHosts[group] = window
            }
            if entry.selectedTab == true, let window = controller.window {
                selectedWindows.append(window)
            }
            restored += 1
        }
        for window in selectedWindows {
            window.tabGroup?.selectedWindow = window
        }
        return restored > 0
    }

    // MARK: - Menu actions

    @objc func openRecentDocument(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        open(URL(fileURLWithPath: path))
    }

    @objc func clearRecentDocuments(_ sender: Any?) {
        DocumentStateStore.shared.clearRecents()
        startWindow?.reloadRecents([])
    }

    @objc func selectTheme(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        ThemeStore.shared.select(named: name)
        Preferences.shared.update { values in
            let isDark = ThemeStore.shared.current.appearance == .dark
            if isDark { values.darkThemeName = name } else { values.themeName = name }
            values.followsSystemAppearance = false
        }
    }

    @objc func importTheme(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.message = "Choose a VS Code or Shiki theme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let theme = try ThemeStore.shared.importVSCodeTheme(at: url)
            ThemeStore.shared.select(named: theme.name)
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "Couldn't import that theme"
            alert.runModal()
        }
    }

    @objc func revealThemesFolder(_ sender: Any?) {
        AppPaths.ensure(AppPaths.themesDirectory)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: AppPaths.themesDirectory.path)
    }

    @objc func openProjectPage(_ sender: Any?) {
        guard let url = URL(string: "https://github.com/ezzy1630/Downright") else { return }
        NSWorkspace.shared.open(url)
    }

    @objc func showPreferences(_ sender: Any?) {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindowController()
        }
        preferencesWindow?.showWindow(nil)
        preferencesWindow?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func preferencesDidChange() {
        if Preferences.shared.values.followsSystemAppearance {
            ThemeStore.shared.select(named: Preferences.shared.themeName(for: NSApp.effectiveAppearance))
        }
        if let menu = NSApp.mainMenu { MainMenu.refreshKeyEquivalents(in: menu) }
    }

    // MARK: - Command routing

    /// Commands with no document — everything else is handled by the window
    /// controller further down the responder chain.
    func handleApplicationCommand(_ command: Command) -> Bool {
        switch command {
        case .newDocument: newDocument(); return true
        case .open: showOpenPanel(); return true
        case .preferences, .showKeybindings: showPreferences(nil); return true
        case .reloadTheme: ThemeStore.shared.reloadUserThemes(); return true
        case .toggleVimKeys:
            Preferences.shared.update { $0.vimKeys.toggle() }
            return true
        case .compareFiles: showComparePanel(); return true
        case .checkForUpdates: UpdateCoordinator.shared.checkForUpdates(); return true
        default: return false
        }
    }

    func newDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = DocumentTypes.contentTypes
        panel.nameFieldStringValue = "Untitled.md"
        panel.message = "Create a Markdown document"
        panel.prompt = "Create"
        // Cancel leaves the start window key and unchanged — do not dismiss it.
        guard panel.runModal() == .OK, let url = panel.url else {
            startWindow?.window?.makeKeyAndOrderFront(nil)
            return
        }
        do {
            try Data("# \(url.deletingPathExtension().lastPathComponent)\n\n".utf8)
                .write(to: url, options: .atomic)
        } catch {
            presentWriteFailure(error, url: url)
            startWindow?.window?.makeKeyAndOrderFront(nil)
            return
        }
        open(url, mode: .live)
    }

    private func presentWriteFailure(_ error: Error, url: URL) {
        let alert = NSAlert()
        alert.messageText = "Couldn't create \(url.lastPathComponent)"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func presentPreferenceWriteFailure(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = "Couldn't save Downright Settings"
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }

    private func showComparePanel() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = DocumentTypes.contentTypes
        panel.message = "Choose two files to compare"
        guard panel.runModal() == .OK, panel.urls.count == 2 else { return }
        let controller = CompareWindowController(left: panel.urls[0], right: panel.urls[1])
        controller.showWindow(nil)
        comparisonWindows.append(controller)
        // A Compare window is a temporary surface; drop its controller the moment
        // the window closes so repeated comparisons do not accumulate objects
        // (and their notification observers) for the app's lifetime.
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: controller.window,
            queue: .main
        ) { [weak self, weak controller] _ in
            // Remove the observer unconditionally so the cycle always unwinds,
            // even if the owner is gone by the time the window closes.
            if let token { NotificationCenter.default.removeObserver(token) }
            guard let self, let controller else { return }
            self.comparisonWindows.removeAll { $0 === controller }
        }
    }

    private var comparisonWindows: [CompareWindowController] = []
}

extension AppDelegate: CommandResponder {
    @objc func performDownrightCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = MainMenu.command(for: item) else { return }
        _ = handleApplicationCommand(command)
    }
}
