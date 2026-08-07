import AppKit
import MarkdownCore
import MarkdownRender

enum DocumentOpenDisposition {
    /// Join the active document window's native tab group when one exists.
    case tab
    /// Keep the document in a separate window.
    case window
}

/// Whether two URLs name the same file.
///
/// A case-sensitive path comparison is wrong on the case-insensitive volumes
/// most Macs use: `README.md` and `readme.md` are one file, and opening both
/// gives two buffers writing over each other.  Ask the file system for identity
/// when it can answer, and fold case when it cannot.
enum FileIdentity {
    static func sameFile(_ lhs: URL, _ rhs: URL) -> Bool {
        let left = lhs.resolvingSymlinksInPath().standardizedFileURL
        let right = rhs.resolvingSymlinksInPath().standardizedFileURL
        if let a = identifier(of: left), let b = identifier(of: right) {
            return a.isEqual(b)
        }
        return left.path.compare(right.path, options: .caseInsensitive) == .orderedSame
    }

    /// Inode identity, available only for a file that exists right now.
    private static func identifier(of url: URL) -> (any NSObjectProtocol)? {
        try? url.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier
    }
}

/// The bundled tour.
///
/// Opening it must not touch the reader's own files, so the bundle copy is
/// materialised in a temporary folder and opened from there: the tour stays
/// editable — poking at it is half the point — and nothing lands on disk that
/// the reader has to clean up.
enum WelcomeDocument {
    static var bundled: URL? {
        Bundle.main.url(forResource: "Welcome", withExtension: "md")
    }

    static var isAvailable: Bool { bundled != nil }

    static func materialize() throws -> URL {
        guard let bundled else {
            throw CocoaError(.fileNoSuchFile)
        }
        let manager = FileManager.default
        let folder = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("Downright Tour", isDirectory: true)
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let copy = folder.appendingPathComponent("Welcome to Downright.md")
        // A fresh copy every time: the tour should read the same on the second
        // visit as on the first, whatever the reader typed into it.
        try? manager.removeItem(at: copy)
        try manager.copyItem(at: bundled, to: copy)
        return copy
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var windowControllers: [DocumentWindowController] = []
    private var preferencesWindow: NSWindowController?
    private var startWindow: StartWindowController?
    private let servicesProvider = DownrightServicesProvider()
    /// Set by `down --edit`; applies to the documents opened in this launch only.
    private var launchMode: RenderMode?
    private var appearanceObservation: NSKeyValueObservation?

    // MARK: - Lifecycle

    func applicationWillFinishLaunching(_ notification: Notification) {
        reportUnavailableStorage(AppPaths.prepareAll())
        parseLaunchArguments()
        NSApp.mainMenu = MainMenu.build()
        applySelectedTheme()
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
        // "Follow system appearance" has to mean *while running*, not "at the
        // next launch".  Nothing else watches the system flipping to Dark.
        appearanceObservation = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applySelectedTheme() }
        }
        Preferences.shared.onLoadFault = { [weak self] load in
            guard case .recovered(let backup) = load else { return }
            self?.reportSettingsRecovery(backup: backup)
        }
        Preferences.shared.onPersistenceFailure = { [weak self] error in
            DispatchQueue.main.async {
                self?.reportSettingsWriteFailure(error)
            }
        }
        // The store refuses to overwrite a file it could not read, so the user
        // is the only one who can fix it — which means they have to be told.
        KeybindingStore.shared.onLoadFailure = { [weak self] error in
            self?.reportKeybindingsLoadFailure(error)
        }
        // History pruning at launch rather than on a timer: it touches the disk
        // and there is no reason to do it while the user is reading (§8.3).
        DispatchQueue.global(qos: .utility).async { SnapshotStore.shared.prune() }

        defer { flushWarnings() }
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
        // One policy for unsaved work: ask.  Quitting used to write every dirty
        // buffer to disk without a word while closing a window offered
        // Save / Discard / Cancel — the same intent with opposite consequences,
        // and the silent one commits edits to a file an agent may also be
        // writing.  A failed save still cancels termination, or macOS tears the
        // process down after the alert and the buffer is lost.
        for controller in windowControllers where controller.markdownDocument.isDirty {
            controller.window?.makeKeyAndOrderFront(nil)
            guard controller.confirmPendingChangesBeforeClose(markDiscardForWindowClose: true) else {
                return .terminateCancel
            }
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
            guard let open = $0.markdownDocument.url else { return false }
            return FileIdentity.sameFile(open, url)
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
        let controller = StartWindowController(recents: recents, guide: guideOffer(recents: recents))
        controller.onOpen = { [weak self] url in self?.open(url) }
        controller.onOpenPanel = { [weak self] in self?.showOpenPanel() }
        controller.onNew = { [weak self] in self?.newDocument() }
        controller.onOpenGuide = { [weak self] in self?.openWelcomeDocument() }
        controller.onClearRecents = { [weak self] in self?.clearRecentDocuments(nil) }
        startWindow = controller
        controller.showWindow(nil)
    }

    /// A first launch — no settings file and nothing opened before — is the one
    /// moment the tour is more useful than the open panel, so it leads there.
    /// After that it stays available as a quiet third action.
    private func guideOffer(recents: [RecentDocument]) -> StartGuideOffer {
        guard WelcomeDocument.isAvailable else { return .unavailable }
        return Preferences.shared.isFirstRun && recents.isEmpty ? .primary : .secondary
    }

    func openWelcomeDocument() {
        do {
            open(try WelcomeDocument.materialize(), mode: .live)
        } catch {
            warn(
                "Couldn't open the tour",
                "The welcome document couldn't be prepared. \(error.localizedDescription)"
            )
            startWindow?.window?.makeKeyAndOrderFront(nil)
            flushWarnings()
        }
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
        var missing: [String] = []
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
            guard FileManager.default.fileExists(atPath: url.path) else {
                missing.append(url.lastPathComponent)
                continue
            }
            let host = entry.tabGroup.flatMap { groupHosts[$0] }
            guard let controller = open(
                url,
                mode: RenderMode(rawValue: entry.mode),
                disposition: host == nil ? .window : .tab,
                tabbingWith: host
            ) else { continue }
            if let frame = AppDelegate.reachableFrame(NSRectFromString(entry.frame)) {
                controller.window?.setFrame(frame, display: true)
            }
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
        reportSkippedSessionFiles(missing)
        return restored > 0
    }

    /// A saved frame, moved onto an attached screen when the screen it was
    /// recorded on has gone away.
    ///
    /// Restoring a session captured with an external display otherwise puts
    /// every window somewhere nobody can reach, and because Downright quits
    /// with its last window there is no obvious way back.  Returns nil for a
    /// frame that carries no usable size, so the window keeps its own.
    static func reachableFrame(_ frame: NSRect) -> NSRect? {
        guard frame.width >= 1, frame.height >= 1 else { return nil }
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return frame }
        // The title bar is the handle: if that strip is on a screen, the window
        // can be moved, resized, and closed by hand.
        let titleBar = NSRect(x: frame.minX, y: frame.maxY - 24, width: frame.width, height: 24)
        if screens.contains(where: { $0.visibleFrame.intersects(titleBar) }) { return frame }

        let target = (NSScreen.main ?? screens[0]).visibleFrame
        let size = NSSize(
            width: min(frame.width, target.width),
            height: min(frame.height, target.height)
        )
        return NSRect(
            x: target.midX - size.width / 2,
            y: target.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
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
        let pickedIsDark = ThemeStore.shared.themes.first { $0.name == name }?.appearance == .dark
        let systemIsDark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        Preferences.shared.update { values in
            if pickedIsDark == systemIsDark {
                // The pick agrees with the current system appearance, so it is
                // a choice about that half of the pair.  Following stays on:
                // the user never asked to stop.
                if pickedIsDark { values.darkThemeName = name } else { values.themeName = name }
            } else {
                // Picking against the system appearance only makes sense as a
                // decision to stop following it — otherwise the next flip would
                // undo the choice that was just made.
                values.themeName = name
                values.followsSystemAppearance = false
            }
        }
        // `update` posts the change, and `preferencesDidChange` is the single
        // place that decides which theme is current.
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
        showPreferences(selecting: nil)
    }

    /// Opens Settings, optionally on a named pane.  "Keyboard Shortcuts…" has
    /// to land on Keys, not on whichever pane was open last.
    func showPreferences(selecting pane: SettingsPane?) {
        let controller = preferencesWindow as? PreferencesWindowController ?? PreferencesWindowController()
        preferencesWindow = controller
        if let pane { controller.select(pane) }
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    /// The one place that decides which theme is current.  Reading it back from
    /// preferences on every change — rather than only while the theme pair
    /// follows the system — is what makes the Appearance popups take effect
    /// without a relaunch.
    private func applySelectedTheme() {
        ThemeStore.shared.select(named: Preferences.shared.themeName(for: NSApp.effectiveAppearance))
    }

    @objc private func preferencesDidChange() {
        applySelectedTheme()
        if let menu = NSApp.mainMenu { MainMenu.refreshKeyEquivalents(in: menu) }
    }

    // MARK: - Command routing

    /// Commands with no document — everything else is handled by the window
    /// controller further down the responder chain.
    func handleApplicationCommand(_ command: Command) -> Bool {
        switch command {
        case .newDocument: newDocument(); return true
        case .open: showOpenPanel(); return true
        // No document to close, so ⌘W means the window in front — the start
        // window included, which otherwise ignored the key entirely.
        case .close: NSApp.keyWindow?.performClose(nil); return true
        case .preferences: showPreferences(selecting: nil); return true
        case .showKeybindings: showPreferences(selecting: .keys); return true
        case .reloadTheme: ThemeStore.shared.reloadUserThemes(); return true
        case .toggleVimKeys:
            Preferences.shared.update { $0.vimKeys.toggle() }
            return true
        case .compareFiles: showComparePanel(); return true
        // The palette has no menu validation in front of it, so it honours the
        // same precondition the menu item does.
        case .checkForUpdates:
            guard UpdateCoordinator.shared.canCheckForUpdates else { return true }
            UpdateCoordinator.shared.checkForUpdates()
            return true
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

    // MARK: - Warnings

    /// Something the user needs to know that must never stop them reading.
    private struct Warning {
        var title: String
        var message: String
    }

    private var pendingWarnings: [Warning] = []
    private var isPresentingWarning = false

    /// Queues a warning.  Sheets are window-modal, so they inform without
    /// blocking; a fault raised before any window exists waits for one rather
    /// than seizing the app during launch.
    private func warn(_ title: String, _ message: String) {
        pendingWarnings.append(Warning(title: title, message: message))
        flushWarnings()
    }

    private func flushWarnings() {
        guard !isPresentingWarning, !pendingWarnings.isEmpty else { return }
        guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: \.isVisible) else { return }
        let warning = pendingWarnings.removeFirst()
        isPresentingWarning = true
        let alert = NSAlert()
        alert.messageText = warning.title
        alert.informativeText = warning.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window) { [weak self] _ in
            guard let self else { return }
            self.isPresentingWarning = false
            self.flushWarnings()
        }
    }

    private func reportSettingsWriteFailure(_ error: Error) {
        warn(
            "Downright can't save your settings",
            """
            Your changes are in effect for now, but they won't survive a restart until \
            Downright can write to its settings file. \(error.localizedDescription)
            """
        )
    }

    private func reportKeybindingsLoadFailure(_ error: Error) {
        warn(
            "Your keyboard shortcuts file couldn't be read",
            """
            Downright is using its default shortcuts. Your file at \
            \(AppPaths.keybindingsFile.path) was left untouched so you can repair it; \
            recording a shortcut in Settings replaces it. \(error.localizedDescription)
            """
        )
    }

    private func reportSettingsRecovery(backup: URL?) {
        let whereItWent = backup.map { "The old file is kept as \($0.lastPathComponent)." }
            ?? "The old file couldn't be kept."
        warn(
            "Your settings file couldn't be read",
            "Downright has started from its defaults. \(whereItWent)"
        )
    }

    private func reportUnavailableStorage(_ failures: [AppPaths.PreparationFailure]) {
        guard !failures.isEmpty else { return }
        let lost = failures.map { "• \($0.purpose.featureDescription)" }.joined(separator: "\n")
        warn(
            "Downright can't use its support folder",
            """
            Until this is fixed, Downright can't save:

            \(lost)

            \(failures[0].error.localizedDescription)
            """
        )
    }

    private func reportSkippedSessionFiles(_ names: [String]) {
        guard !names.isEmpty else { return }
        let list = names.prefix(6).map { "• \($0)" }.joined(separator: "\n")
        let more = names.count > 6 ? "\n• and \(names.count - 6) more" : ""
        warn(
            names.count == 1 ? "One file from your last session is gone" : "Some files from your last session are gone",
            "These weren't reopened because they're no longer where they were:\n\n\(list)\(more)"
        )
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

extension AppDelegate: NSMenuItemValidation {
    /// The app delegate is the last responder to see a command item, so what
    /// it answers is the no-document state: Save and Print… must be disabled
    /// with only the start window up, not enabled and silently inert.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        MainMenu.validate(
            menuItem,
            in: .applicationOnly(canCheckForUpdates: UpdateCoordinator.shared.canCheckForUpdates)
        )
    }
}
