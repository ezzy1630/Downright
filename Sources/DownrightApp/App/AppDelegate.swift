import AppKit
import MarkdownCore
import MarkdownRender

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
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferencesDidChange),
            name: Preferences.didChange, object: nil
        )
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

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows && windowControllers.isEmpty { showStartWindow() }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        NSUnregisterServicesProvider("Downright")
        saveSession()
        for controller in windowControllers { controller.documentWillClose() }
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
        open(URL(fileURLWithPath: filename))
        return true
    }

    @discardableResult
    func open(_ url: URL, mode: RenderMode? = nil) -> DocumentWindowController? {
        // One window per file: reopening a file you already have open should
        // raise it, not give you two buffers over the same bytes.
        if let existing = windowControllers.first(where: { $0.markdownDocument.url?.path == url.path }) {
            existing.showWindow(nil)
            return existing
        }

        let controller = DocumentWindowController()
        do {
            try controller.open(url, mode: mode ?? launchMode ?? Preferences.shared.values.defaultMode)
        } catch {
            presentOpenFailure(error, url: url)
            return nil
        }
        adopt(controller)
        SpotlightIndexer.indexOpenedDocument(at: url)
        startWindow?.close()
        startWindow = nil
        controller.showWindow(nil)
        return controller
    }

    func adopt(_ controller: DocumentWindowController) {
        windowControllers.append(controller)
        controller.onClose = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.windowControllers.removeAll { $0 === controller }
            self.saveSession()
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
        panel.message = "Open a markdown markdownDocument"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { open(url) }
    }

    private func showStartWindow() {
        if let startWindow {
            startWindow.showWindow(nil)
            startWindow.window?.makeKeyAndOrderFront(nil)
            return
        }
        let controller = StartWindowController(recents: DocumentStateStore.shared.recents(limit: 8))
        controller.onOpen = { [weak self] url in self?.open(url) }
        controller.onOpenPanel = { [weak self] in self?.showOpenPanel() }
        controller.onNew = { [weak self] in self?.newDocument() }
        startWindow = controller
        controller.showWindow(nil)
    }

    // MARK: - Session restore (§9.3)

    private struct SessionWindow: Codable {
        var path: String
        var frame: String
        var mode: String
    }

    private func saveSession() {
        let windows = windowControllers.compactMap { controller -> SessionWindow? in
            guard let url = controller.markdownDocument.url, let frame = controller.window?.frame else { return nil }
            return SessionWindow(
                path: url.path,
                frame: NSStringFromRect(frame),
                mode: controller.mode.rawValue
            )
        }
        guard let data = try? JSONEncoder().encode(windows) else { return }
        try? data.write(to: AppPaths.sessionFile, options: .atomic)
    }

    /// Every window reopens with its mode, zoom level, scroll position, fold
    /// state, and sidebar state (§9.3) — the per-document parts come back from
    /// `DocumentStateStore`, so only the window geometry lives in the session.
    @discardableResult
    private func restoreSession() -> Bool {
        guard let data = try? Data(contentsOf: AppPaths.sessionFile),
              let windows = try? JSONDecoder().decode([SessionWindow].self, from: data),
              !windows.isEmpty
        else { return false }

        var restored = 0
        for entry in windows {
            let url = URL(fileURLWithPath: entry.path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            guard let controller = open(url, mode: RenderMode(rawValue: entry.mode)) else { continue }
            controller.window?.setFrame(NSRectFromString(entry.frame), display: true)
            restored += 1
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
        guard let url = URL(string: "https://github.com/unrulyagency/downright") else { return }
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
        default: return false
        }
    }

    func newDocument() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = DocumentTypes.contentTypes
        panel.nameFieldStringValue = "Untitled.md"
        panel.message = "Create a markdown markdownDocument"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data("# \(url.deletingPathExtension().lastPathComponent)\n\n".utf8).write(to: url)
        open(url, mode: .live)
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
    }

    private var comparisonWindows: [CompareWindowController] = []
}

extension AppDelegate: CommandResponder {
    @objc func performDownrightCommand(_ sender: Any?) {
        guard let item = sender as? NSMenuItem, let command = MainMenu.command(for: item) else { return }
        _ = handleApplicationCommand(command)
    }
}
