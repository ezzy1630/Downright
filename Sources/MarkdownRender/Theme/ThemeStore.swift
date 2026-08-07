import AppKit
import Foundation

/// Themes: the six bundled ones, plus anything the user drops in
/// `~/Library/Application Support/Downright/Themes`, hot-reloading while it is
/// being edited (§11.2).
///
/// Mutation is main-thread confined — the directory watcher hops to main before
/// touching state, and observers are always called there.  The decoration
/// engine should snapshot a `StyleSheet` on main and pass *that* to background
/// work rather than reading the store off-thread.
public final class ThemeStore {
    public static let shared = ThemeStore()

    /// Bundled first, then user-only themes; both alphabetical.  A user theme
    /// whose `name` matches a bundled one replaces it in place, which is how
    /// "edit a copy of Paper Light" works without a second entry appearing.
    public private(set) var themes: [Theme] = []

    /// Monotonic token bumped on every theme change; fragment caches compare
    /// against it (§11.2, `FragmentPayload.cachedThemeToken`).
    public private(set) var revision: Int = 1

    public var current: Theme {
        themes.first { $0.name == selectedName } ?? themes.first ?? .fallback
    }

    private var bundledThemes: [Theme] = []
    private var userThemes: [Theme] = []
    private var selectedName: String
    private var observers: [ObjectIdentifier: (Theme) -> Void] = [:]
    private var watcher: DirectoryWatcher?

    /// Internal rather than private so tests can save and restore the user's
    /// real preference around exercising `select(named:)`.
    static let selectionDefaultsKey = "downright.theme.selected"

    public init() {
        selectedName = UserDefaults.standard.string(forKey: ThemeStore.selectionDefaultsKey) ?? "Paper Light"
        bundledThemes = ThemeStore.loadBundledThemes()
        rebuild()
        reloadUserThemes()
    }

    // MARK: - Selection

    public func select(named name: String) {
        guard themes.contains(where: { $0.name == name }), name != selectedName else { return }
        selectedName = name
        UserDefaults.standard.set(name, forKey: ThemeStore.selectionDefaultsKey)
        bumpAndNotify()
    }

    // MARK: - Loading

    /// User themes live in ~/Library/Application Support/Downright/Themes.
    public func reloadUserThemes() {
        guard let directory = ThemeStore.userThemesDirectory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        userThemes = ThemeStore.loadThemes(in: directory)
        startWatching(directory)
        rebuild()
        bumpAndNotify()
    }

    private func rebuild() {
        var overrides: [String: Theme] = [:]
        for theme in userThemes { overrides[theme.name] = theme }
        let bundledNames = Set(bundledThemes.map(\.name))
        let bundled = bundledThemes
            .map { overrides[$0.name] ?? $0 }
            .sorted { $0.name < $1.name }
        let userOnly = userThemes
            .filter { !bundledNames.contains($0.name) }
            .sorted { $0.name < $1.name }
        themes = bundled + userOnly
    }

    /// SwiftPM's generated `Bundle.module` looks for the resource bundle beside
    /// `Bundle.main.bundleURL` and then falls back to an absolute path inside
    /// the build directory.  Neither is right once the code ships: a macOS
    /// bundle keeps resources in `Contents/Resources`, so `Bundle.module`
    /// resolves only via the build-directory fallback — which exists on the
    /// machine that compiled it and nowhere else.  Inside the sandboxed Quick
    /// Look extension it is unreachable even there, and the fallback traps.
    ///
    /// So resolve the bundle against the layouts we actually ship before
    /// deferring to `Bundle.module` for `swift run` and `swift test`.
    private static let resourceBundle: Bundle = {
        let name = "Downright_MarkdownRender.bundle"
        let token = Bundle(for: BundleToken.self)
        let roots = [
            Bundle.main.resourceURL,       // Downright.app, DownrightQL.appex
            token.resourceURL,
            token.bundleURL.deletingLastPathComponent(),
            Bundle.main.bundleURL,
        ]
        for root in roots.compactMap({ $0 }) {
            if let bundle = Bundle(url: root.appendingPathComponent(name)) {
                return bundle
            }
        }
        return .module
    }()

    private static func loadBundledThemes() -> [Theme] {
        guard let urls = resourceBundle.urls(forResourcesWithExtension: "json", subdirectory: "Themes") else {
            return []
        }
        return decode(urls)
    }

    private static func loadThemes(in directory: URL) -> [Theme] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return decode(contents.filter { $0.pathExtension.lowercased() == "json" })
    }

    /// A theme that fails to decode is skipped rather than surfaced: with hot
    /// reload the file is very often half-written, and the next event brings
    /// the good version a moment later.
    private static func decode(_ urls: [URL]) -> [Theme] {
        let decoder = JSONDecoder()
        return urls
            .filter { !$0.lastPathComponent.hasPrefix(".") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? decoder.decode(Theme.self, from: data)
            }
    }

    public static var userThemesDirectory: URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Downright/Themes", isDirectory: true)
    }

    // MARK: - Hot reload (§11.2)

    private func startWatching(_ directory: URL) {
        guard watcher == nil else { return }
        watcher = DirectoryWatcher(url: directory) { [weak self] in
            guard let self, let directory = ThemeStore.userThemesDirectory else { return }
            self.userThemes = ThemeStore.loadThemes(in: directory)
            self.rebuild()
            self.bumpAndNotify()
        }
    }

    /// Hot-reload: fires whenever the selected theme's file changes on disk (§11.2).
    public func observe(_ handler: @escaping (Theme) -> Void) -> ThemeObservation {
        let observation = ThemeObservation(store: self)
        observers[ObjectIdentifier(observation)] = handler
        return observation
    }

    func removeObserver(_ observation: ThemeObservation) {
        observers.removeValue(forKey: ObjectIdentifier(observation))
    }

    private func bumpAndNotify() {
        revision &+= 1
        let theme = current
        for handler in observers.values { handler(theme) }
    }

    // MARK: - Import / export

    /// Imports a VS Code / Shiki theme and installs it as a user theme, so code
    /// blocks and mermaid diagrams end up sharing one palette (§11.2).
    @discardableResult
    public func importVSCodeTheme(at url: URL) throws -> Theme {
        guard let data = try? Data(contentsOf: url) else { throw ThemeStoreError.unreadable(url) }
        let theme = try VSCodeThemeImporter.theme(from: data, fallbackName: url.deletingPathExtension().lastPathComponent)
        guard let directory = ThemeStore.userThemesDirectory else {
            throw ThemeStoreError.userThemesUnavailable
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try export(theme, to: directory.appendingPathComponent(ThemeStore.slug(theme.name) + ".json"))
        reloadUserThemes()
        return theme
    }

    public func export(_ theme: Theme, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(theme).write(to: url, options: .atomic)
    }

    static func slug(_ name: String) -> String {
        let allowed = name.lowercased().map { character -> Character in
            character.isLetter || character.isNumber ? character : "-"
        }
        let collapsed = String(allowed).split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return collapsed.isEmpty ? "theme" : collapsed
    }

}

extension Theme {
    /// The theme to draw with when nothing else is available — a broken install
    /// rather than a supported state, but the app must still render something
    /// legible.  Built entirely from system colours so it is correct in both
    /// appearances without a file behind it.
    public static let fallback = Theme(
        name: "System",
        appearance: .auto,
        palette: ThemePalette(
            background: ThemeColor("system:textBackground"), surface: ThemeColor("system:controlBackground"),
            text: ThemeColor("system:label"), textSecondary: ThemeColor("system:secondaryLabel"),
            textFaint: ThemeColor("system:tertiaryLabel"), heading: ThemeColor("system:label"),
            marker: ThemeColor("system:quaternaryLabel"), accent: ThemeColor("system:accent"),
            link: ThemeColor("system:link"), rule: ThemeColor("system:separator"),
            selection: ThemeColor("system:selectedTextBackground"),
            codeBackground: ThemeColor("system:controlBackground"),
            inlineCodeBackground: ThemeColor("system:controlBackground"),
            codeRule: ThemeColor("system:separator"),
            railTick: ThemeColor("system:tertiaryLabel"), railTickCurrent: ThemeColor("system:label"),
            quoteRule: ThemeColor("system:quaternaryLabel"), changeAdded: ThemeColor("system:systemGreen"),
            changeRemoved: ThemeColor("system:systemRed"), changeModified: ThemeColor("system:systemOrange"),
            pathMissing: ThemeColor("system:systemRed"), searchHit: ThemeColor("system:systemYellow"),
            searchHitCurrent: ThemeColor("system:systemOrange"), calloutNote: ThemeColor("system:systemBlue"),
            calloutWarning: ThemeColor("system:systemOrange"), calloutSuccess: ThemeColor("system:systemGreen"),
            calloutDanger: ThemeColor("system:systemRed")
        ),
        code: CodeTheme(
            keyword: ThemeColor("system:systemPink"), string: ThemeColor("system:systemRed"),
            number: ThemeColor("system:systemBlue"), comment: ThemeColor("system:systemGreen"),
            type: ThemeColor("system:systemTeal"), function: ThemeColor("system:systemBlue"),
            variable: ThemeColor("system:label"), constant: ThemeColor("system:systemPurple"),
            operator: ThemeColor("system:secondaryLabel"), punctuation: ThemeColor("system:tertiaryLabel"),
            attribute: ThemeColor("system:systemOrange"), diffAdded: ThemeColor("system:systemGreen"),
            diffRemoved: ThemeColor("system:systemRed"), diffHeader: ThemeColor("system:secondaryLabel")
        ),
        typography: .default
    )
}

public final class ThemeObservation {
    private weak var store: ThemeStore?

    fileprivate init(store: ThemeStore) { self.store = store }

    /// Dropping the token cancels the observation, so a caller that forgets to
    /// retain it leaks nothing.
    deinit { cancel() }

    public func cancel() {
        store?.removeObserver(self)
        store = nil
    }
}

public enum ThemeStoreError: LocalizedError, Equatable {
    case unreadable(URL)
    case notAVSCodeTheme
    case userThemesUnavailable

    public var errorDescription: String? {
        switch self {
        case .unreadable(let url): return "Could not read \(url.lastPathComponent)."
        case .notAVSCodeTheme: return "That file is not a VS Code colour theme."
        case .userThemesUnavailable: return "The Downright themes folder is unavailable."
        }
    }
}

// MARK: - Directory watching

/// A coarse vnode watch on the user themes directory.  Coarse on purpose: the
/// reload re-reads every file anyway, so per-file watches would cost descriptors
/// for no benefit, and an editor that saves by rename would defeat them.
final class DirectoryWatcher {
    private let url: URL
    private let onChange: () -> Void
    private let queue = DispatchQueue(label: "com.downright.theme-watch")
    private var source: DispatchSourceFileSystemObject?
    private var descriptor: CInt = -1
    private var pending: DispatchWorkItem?

    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url
        self.onChange = onChange
        start()
    }

    deinit { stop() }

    private func start() {
        descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // A rename or delete invalidates the descriptor: an editor that
            // saves atomically replaces the directory entry, and the watch has
            // to follow the new one or it goes quiet forever.
            if source.data.contains(.rename) || source.data.contains(.delete) {
                self.restart()
            }
            self.scheduleReload()
        }
        source.setCancelHandler { [descriptor] in close(descriptor) }
        self.source = source
        source.resume()
    }

    private func restart() {
        stop()
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.start() }
    }

    private func stop() {
        source?.cancel()
        source = nil
        descriptor = -1
    }

    /// One save produces a burst of events; coalescing keeps the reload — and
    /// therefore the full redecorate it triggers — to one per burst.
    private func scheduleReload() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onChange() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}

/// Anchors `Bundle(for:)` to whichever bundle this module was loaded from.
private final class BundleToken {}
