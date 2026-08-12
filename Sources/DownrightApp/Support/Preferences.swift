import AppKit
import MarkdownCore
import MarkdownRender

/// App-wide settings.  Everything here is a deliberate default, not an accident
/// — the ones that matter are called out in the spec and carry a note here.
final class Preferences {
    static let shared = Preferences()

    struct Values: Codable, Equatable {
        var themeName: String = "Paper Light"
        var darkThemeName: String = "Warm Dark"
        /// When true the light/dark theme pair follows the system appearance.
        var followsSystemAppearance: Bool = true
        /// Quick Look is a separate sandboxed process. Its default follows
        /// macOS, with an explicit override for readers who want a fixed mode.
        var previewAppearance: PreviewAppearance = .system

        var typography: TypographyConfig = .default
        /// Text size is app-wide rather than per document (§7.1).
        var textSizeAdjustment: CGFloat = 0

        /// Defaults **off**: agents and code hate smart quotes (§6.4).
        var typographicSubstitution: Bool = false
        var showInvisibles: Bool = false
        /// Source-wrapped prose reads as one paragraph while source bytes stay intact.
        var reflowHardWrappedParagraphs: Bool = true
        var typewriterScrolling: Bool = false
        var focusMode: Bool = false

        /// Auto-collapse code blocks longer than this in Read mode (§5.1).
        var codeBlockCollapseThreshold: Int = 20
        /// The rendered document stays editable; Source is an explicit choice.
        var defaultMode: RenderMode = .live
        var restoreSession: Bool = true

        var externalEditor: ExternalEditor = .systemDefault
        var resolvePathTokens: Bool = true
        /// Extra directories to scan for siblings, relative to the document (§8.7).
        var siblingScanDirectories: [String] = ["docs", "plans", ".claude", "notes", "specs"]

        var historyMaximumDays: Int = 30
        var historyMaximumMegabytes: Int = 500
        var watchFiles: Bool = true

        var vimKeys: Bool = false
        /// Off by default: autosave writes the document to disk on every change
        /// and during idle, which can interfere with agents also writing the
        /// same file.  Turn it on only when working alone.
        var autosaveEnabled: Bool = false
        /// §14's recommendation: reveal markers at the primary caret only.
        var revealMarkersAtAllCursors: Bool = false
        /// Defaults **off**.  DESIGN.md's "Avoid" list names a permanent status
        /// bar outright, and the two things such a bar would report are already
        /// answered elsewhere: word count and read time live in the density
        /// gutter's hover summary, and an unsaved document is marked in the
        /// window's own close button.  It stays available for anyone who wants
        /// a live line-and-column readout while editing, which nothing else in
        /// the app provides.
        var showStatusBar: Bool = false
        /// Beyond this size Read mode switches to windowed rendering (§15 Q4).
        var largeFileThresholdMegabytes: Int = 5

        /// How many times the app has been launched, counting this one.  The
        /// start window uses it to retire first-run affordances on a schedule
        /// rather than leaving them up forever.
        var launchCount: Int = 0
        /// Set the first time the tour is opened, from anywhere.
        var hasTakenTour: Bool = false
        /// Set once the first-run setup panel has been answered, either way.
        /// "Not now" is an answer: the panel does not come back uninvited.
        var hasAnsweredSetup: Bool = false
        /// Where the bundle was when LaunchServices and `pluginkit` were last
        /// told about it.  Both record an absolute path, so a moved or renamed
        /// app silently loses its Quick Look extensions until it re-registers.
        var lastRegisteredBundlePath: String = ""

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
            }
            themeName = get(.themeName, "Paper Light")
            darkThemeName = get(.darkThemeName, "Warm Dark")
            followsSystemAppearance = get(.followsSystemAppearance, true)
            previewAppearance = get(.previewAppearance, .system)
            typography = get(.typography, TypographyConfig.default)
            textSizeAdjustment = get(.textSizeAdjustment, 0)
            typographicSubstitution = get(.typographicSubstitution, false)
            showInvisibles = get(.showInvisibles, false)
            reflowHardWrappedParagraphs = get(.reflowHardWrappedParagraphs, true)
            typewriterScrolling = get(.typewriterScrolling, false)
            focusMode = get(.focusMode, false)
            codeBlockCollapseThreshold = get(.codeBlockCollapseThreshold, 20)
            defaultMode = get(.defaultMode, RenderMode.live).normalizedForEditing
            restoreSession = get(.restoreSession, true)
            externalEditor = get(.externalEditor, ExternalEditor.systemDefault)
            resolvePathTokens = get(.resolvePathTokens, true)
            siblingScanDirectories = get(.siblingScanDirectories, ["docs", "plans", ".claude", "notes", "specs"])
            historyMaximumDays = get(.historyMaximumDays, 30)
            historyMaximumMegabytes = get(.historyMaximumMegabytes, 500)
            watchFiles = get(.watchFiles, true)
            vimKeys = get(.vimKeys, false)
            autosaveEnabled = get(.autosaveEnabled, false)
            revealMarkersAtAllCursors = get(.revealMarkersAtAllCursors, false)
            showStatusBar = get(.showStatusBar, false)
            largeFileThresholdMegabytes = get(.largeFileThresholdMegabytes, 5)
            launchCount = get(.launchCount, 0)
            hasTakenTour = get(.hasTakenTour, false)
            hasAnsweredSetup = get(.hasAnsweredSetup, false)
            lastRegisteredBundlePath = get(.lastRegisteredBundlePath, "")
        }
    }

    /// How the settings file was read at launch.  "Missing" and "unreadable"
    /// are different events and must not share a code path: the first is the
    /// ordinary first run, the second is a file that still holds the user's
    /// settings and must never be quietly overwritten by defaults.
    enum Load: Equatable {
        case absent
        case loaded
        /// The file existed but could not be decoded.  The original was moved
        /// aside so the user can inspect or repair it.
        case recovered(backup: URL?)
    }

    private(set) var values: Values {
        didSet {
            guard values != oldValue else { return }
            persist()
            NotificationCenter.default.post(name: Preferences.didChange, object: self)
        }
    }

    /// What happened when the settings file was read.
    private(set) var load: Load = .absent

    /// True when this launch found no settings file at all — the signal the
    /// app uses to decide whether to offer the welcome document.
    var isFirstRun: Bool { load == .absent }

    /// Set when the settings file existed but could not be decoded.  Installed
    /// by the app so the fault reaches the user; assigning it after the fact
    /// reports immediately, which it must, because loading happens inside the
    /// singleton's initialiser.
    var onLoadFault: ((Load) -> Void)? {
        didSet {
            if case .recovered = load { onLoadFault?(load) }
        }
    }

    /// Last settings write failure, if any.  Settings changes remain available
    /// in memory; callers can surface this without losing the new values.
    private(set) var lastPersistenceError: Error?

    /// Called on the *first* failed write of a run of failures, never again
    /// until a write succeeds.  Dragging a stepper on a full disk is one fault,
    /// not one fault per increment.
    var onPersistenceFailure: ((Error) -> Void)?

    static let didChange = Notification.Name("com.ezzy.downright.preferencesDidChange")

    private init() {
        lastPersistenceError = nil
        let (loaded, load) = Preferences.read(contentsOf: AppPaths.preferencesFile)
        self.load = load
        if let loaded {
            values = loaded
        } else {
            values = Values()
            // No usable settings: adopt whichever editor the user actually has,
            // since "System Default" for a .ts file is rarely what they want
            // (§8.4).
            values.externalEditor = ExternalEditor.bestAvailable
        }
        PreviewAppearanceStore.write(
            appearance: values.previewAppearance,
            lightThemeName: values.themeName,
            darkThemeName: values.darkThemeName
        )
        SnapshotStore.shared.maximumAge = TimeInterval(values.historyMaximumDays) * 86_400
        SnapshotStore.shared.maximumBytes = values.historyMaximumMegabytes * 1024 * 1024
    }

    /// Reads the settings file, preserving a file that exists but cannot be
    /// decoded.  Returning the outcome rather than swallowing it is the whole
    /// point: silently reverting to defaults loses every setting the user has
    /// ever changed, and the next change writes that loss to disk.
    private static func read(contentsOf url: URL) -> (Values?, Load) {
        guard let data = try? Data(contentsOf: url) else { return (nil, .absent) }
        if let decoded = try? JSONDecoder().decode(Values.self, from: data) {
            return (decoded, .loaded)
        }
        return (nil, .recovered(backup: moveAside(url)))
    }

    /// Moves an undecodable settings file to `preferences.json.bad` so the next
    /// write does not destroy it.  Returns where it went, or nil if even that
    /// failed — in which case the caller still reports the fault.
    private static func moveAside(_ url: URL) -> URL? {
        let backup = url.appendingPathExtension("bad")
        let manager = FileManager.default
        try? manager.removeItem(at: backup)
        do {
            try manager.moveItem(at: url, to: backup)
            return backup
        } catch {
            return nil
        }
    }

    /// Single mutation point, so persistence and the change notification can
    /// never be forgotten at a call site.
    func update(_ mutate: (inout Values) -> Void) {
        var copy = values
        mutate(&copy)
        values = copy
        SnapshotStore.shared.maximumAge = TimeInterval(copy.historyMaximumDays) * 86_400
        SnapshotStore.shared.maximumBytes = copy.historyMaximumMegabytes * 1024 * 1024
    }

    private func persist() {
        AppPaths.ensure(AppPaths.supportDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(values)
            try data.write(to: AppPaths.preferencesFile, options: .atomic)
            PreviewAppearanceStore.write(
                appearance: values.previewAppearance,
                lightThemeName: values.themeName,
                darkThemeName: values.darkThemeName
            )
            lastPersistenceError = nil
        } catch {
            // Edge-triggered: report the first failure of a run and stay quiet
            // until a write succeeds again.  A stepper drag on a full disk is
            // dozens of writes and must not be dozens of warnings.
            let isFirstOfRun = lastPersistenceError == nil
            lastPersistenceError = error
            if isFirstOfRun { onPersistenceFailure?(error) }
        }
    }

    // MARK: - Derived

    /// Typography with the app-wide text size adjustment folded in (§7.1).
    var effectiveTypography: TypographyConfig {
        var typography = values.typography
        typography.bodySize = max(10, min(28, typography.bodySize + values.textSizeAdjustment))
        return typography
    }

    var largeFileThresholdBytes: Int { values.largeFileThresholdMegabytes * 1024 * 1024 }

    func themeName(for appearance: NSAppearance) -> String {
        guard values.followsSystemAppearance else { return values.themeName }
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return isDark ? values.darkThemeName : values.themeName
    }
}

enum ThemePreferenceSlot: Equatable {
    case light
    case dark
}

extension Preferences.Values {
    /// Theme choice and appearance mode are separate decisions. A palette
    /// selection must never silently stop the app following macOS.
    mutating func selectTheme(named name: String, for slot: ThemePreferenceSlot) {
        switch slot {
        case .light: themeName = name
        case .dark: darkThemeName = name
        }
    }
}
