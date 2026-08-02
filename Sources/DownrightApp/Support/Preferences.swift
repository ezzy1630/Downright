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

        var typography: TypographyConfig = .default
        /// Text size is app-wide rather than per document (§7.1).
        var textSizeAdjustment: CGFloat = 0

        /// Defaults **off**: agents and code hate smart quotes (§6.4).
        var typographicSubstitution: Bool = false
        var showInvisibles: Bool = false
        var typewriterScrolling: Bool = false
        var focusMode: Bool = false

        /// Auto-collapse code blocks longer than this in Read mode (§5.1).
        var codeBlockCollapseThreshold: Int = 20
        /// The rendered document stays editable; Source is an explicit choice.
        var defaultMode: RenderMode = .live
        var restoreSession: Bool = true

        var externalEditor: ExternalEditor = .systemDefault
        var resolvePathTokens: Bool = true
        var siblingSidebarVisible: Bool = false
        /// Extra directories to scan for siblings, relative to the document (§8.7).
        var siblingScanDirectories: [String] = ["docs", "plans", ".claude", "notes", "specs"]

        var historyMaximumDays: Int = 30
        var historyMaximumMegabytes: Int = 500
        var watchFiles: Bool = true

        var vimKeys: Bool = false
        /// §14's recommendation: reveal markers at the primary caret only.
        var revealMarkersAtAllCursors: Bool = false
        /// Beyond this size Read mode switches to windowed rendering (§15 Q4).
        var largeFileThresholdMegabytes: Int = 5

        init() {}

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func get<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                (try? c.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? fallback
            }
            themeName = get(.themeName, "Paper Light")
            darkThemeName = get(.darkThemeName, "Warm Dark")
            followsSystemAppearance = get(.followsSystemAppearance, true)
            typography = get(.typography, TypographyConfig.default)
            textSizeAdjustment = get(.textSizeAdjustment, 0)
            typographicSubstitution = get(.typographicSubstitution, false)
            showInvisibles = get(.showInvisibles, false)
            typewriterScrolling = get(.typewriterScrolling, false)
            focusMode = get(.focusMode, false)
            codeBlockCollapseThreshold = get(.codeBlockCollapseThreshold, 20)
            defaultMode = get(.defaultMode, RenderMode.live).normalizedForEditing
            restoreSession = get(.restoreSession, true)
            externalEditor = get(.externalEditor, ExternalEditor.systemDefault)
            resolvePathTokens = get(.resolvePathTokens, true)
            siblingSidebarVisible = get(.siblingSidebarVisible, false)
            siblingScanDirectories = get(.siblingScanDirectories, ["docs", "plans", ".claude", "notes", "specs"])
            historyMaximumDays = get(.historyMaximumDays, 30)
            historyMaximumMegabytes = get(.historyMaximumMegabytes, 500)
            watchFiles = get(.watchFiles, true)
            vimKeys = get(.vimKeys, false)
            revealMarkersAtAllCursors = get(.revealMarkersAtAllCursors, false)
            largeFileThresholdMegabytes = get(.largeFileThresholdMegabytes, 5)
        }
    }

    private(set) var values: Values {
        didSet {
            guard values != oldValue else { return }
            persist()
            NotificationCenter.default.post(name: Preferences.didChange, object: self)
        }
    }

    static let didChange = Notification.Name("com.ezzyrappeport.downright.preferencesDidChange")

    private init() {
        if let data = try? Data(contentsOf: AppPaths.preferencesFile),
           let decoded = try? JSONDecoder().decode(Values.self, from: data) {
            values = decoded
        } else {
            values = Values()
            // First run: adopt whichever editor the user actually has, since
            // "System Default" for a .ts file is rarely what they want (§8.4).
            values.externalEditor = ExternalEditor.bestAvailable
        }
        SnapshotStore.shared.maximumAge = TimeInterval(values.historyMaximumDays) * 86_400
        SnapshotStore.shared.maximumBytes = values.historyMaximumMegabytes * 1024 * 1024
        KeybindingStore.shared.vimKeysEnabled = values.vimKeys
    }

    /// Single mutation point, so persistence and the change notification can
    /// never be forgotten at a call site.
    func update(_ mutate: (inout Values) -> Void) {
        var copy = values
        mutate(&copy)
        values = copy
        SnapshotStore.shared.maximumAge = TimeInterval(copy.historyMaximumDays) * 86_400
        SnapshotStore.shared.maximumBytes = copy.historyMaximumMegabytes * 1024 * 1024
        KeybindingStore.shared.vimKeysEnabled = copy.vimKeys
    }

    private func persist() {
        AppPaths.ensure(AppPaths.supportDirectory)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(values) else { return }
        try? data.write(to: AppPaths.preferencesFile, options: .atomic)
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
