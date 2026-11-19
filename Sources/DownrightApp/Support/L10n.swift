import Foundation
import MarkdownCore
import MarkdownRender

/// User-facing interface language preference.
///
/// `.system` follows macOS's preferred language list (including per-app
/// language overrides in System Settings → Language & Region). Choosing an
/// explicit language overrides it for Downright's own strings and updates
/// `AppleLanguages` so system panels follow on the next launch.
enum AppLanguage: String, Codable, CaseIterable {
    case system = "system"
    case english = "en"
    case simplifiedChinese = "zh-Hans"

    var title: String {
        switch self {
        case .system: return L10n.tr("System Default", context: "language")
        case .english: return "English"
        case .simplifiedChinese: return "简体中文"
        }
    }

    var localizationCode: String? {
        switch self {
        case .system: return nil
        case .english: return "en"
        case .simplifiedChinese: return "zh-Hans"
        }
    }
}

/// Centralized localization lookup for `DownrightApp`.
///
/// Works identically in both build pipelines:
/// - Bundled `.app` artifacts (`Scripts/bundle-xcode-app.sh` and
///   `Scripts/bundle-app.sh`), where `.lproj` localization directories live
///   directly inside `Bundle.main`.
/// - SwiftPM test runs (`Scripts/test.sh`), where resources live in
///   `Bundle.module`.
///
/// English source text serves as both the default fallback and the key in
/// `Localizable.strings`, so untranslated strings always degrade to valid
/// English instead of raw key identifiers.
enum L10n {
    static let supportedLanguages = ["en", "zh-Hans"]

    private static let lock = NSLock()
    private static var preferredLanguage: AppLanguage = .system
    private static var overrideLanguage: String?
    private static var cachedBundles: [String: Bundle] = [:]

    /// Resource bundle holding `.lproj` directories.
    static var resourceBundle: Bundle {
        if hasLocalizations(in: .main) {
            return .main
        }
        #if SWIFT_PACKAGE
        if hasLocalizations(in: .module) {
            return .module
        }
        #endif
        return .main
    }

    private static func hasLocalizations(in bundle: Bundle) -> Bool {
        lprojPath(for: "en", in: bundle) != nil || lprojPath(for: "zh-Hans", in: bundle) != nil
    }

    private static func lprojPath(for code: String, in bundle: Bundle) -> String? {
        if let exact = bundle.path(forResource: code, ofType: "lproj") {
            return exact
        }
        let lower = code.lowercased()
        if lower != code, let lowered = bundle.path(forResource: lower, ofType: "lproj") {
            return lowered
        }
        return nil
    }

    /// Updates the in-process preferred language from `Preferences`.
    static func setPreferredLanguage(_ language: AppLanguage, syncAppleLanguages: Bool = false) {
        lock.lock()
        preferredLanguage = language
        lock.unlock()

        guard syncAppleLanguages else { return }
        // Never mutate global process defaults when running under an explicit
        // environment override (for example, deterministic test runs).
        if let env = ProcessInfo.processInfo.environment["DOWNRIGHT_LANGUAGE"], !env.isEmpty {
            return
        }
        if let code = language.localizationCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Runs `body` with an explicit localization active (e.g. `"en"` or
    /// `"zh-Hans"`). Intended for deterministic localization tests.
    static func withLanguage<T>(_ language: String?, _ body: () throws -> T) rethrows -> T {
        lock.lock()
        let previous = overrideLanguage
        overrideLanguage = language
        lock.unlock()
        defer {
            lock.lock()
            overrideLanguage = previous
            lock.unlock()
        }
        return try body()
    }

    /// Effective localization identifier currently active (`"en"` or `"zh-Hans"`).
    static var currentLanguage: String {
        lock.lock()
        let testOverride = overrideLanguage
        let configured = preferredLanguage
        lock.unlock()

        if let testOverride, !testOverride.isEmpty {
            return normalizedLanguage(testOverride)
        }
        if let env = ProcessInfo.processInfo.environment["DOWNRIGHT_LANGUAGE"],
           !env.isEmpty, env.lowercased() != "system" {
            return normalizedLanguage(env)
        }
        if let explicit = configured.localizationCode {
            return normalizedLanguage(explicit)
        }
        let matched = Bundle.preferredLocalizations(
            from: supportedLanguages,
            forPreferences: Locale.preferredLanguages
        )
        return normalizedLanguage(matched.first ?? "en")
    }

    static var isEnglish: Bool {
        currentLanguage == "en"
    }

    static func normalizedLanguage(_ code: String) -> String {
        let lower = code.lowercased()
        if lower == "zh-hans" || lower.hasPrefix("zh-hans-") || lower == "zh-cn" || lower == "zh-sg" || lower == "zh" {
            return "zh-Hans"
        }
        return "en"
    }

    private static func bundle(for language: String) -> Bundle {
        let code = normalizedLanguage(language)
        lock.lock()
        if let cached = cachedBundles[code] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let root = resourceBundle
        let resolved: Bundle
        if let path = lprojPath(for: code, in: root),
           let localized = Bundle(path: path) {
            resolved = localized
        } else {
            resolved = root
        }

        lock.lock()
        cachedBundles[code] = resolved
        lock.unlock()
        return resolved
    }

    /// Looks up a localized string using the English text as the key.
    static func tr(_ text: String) -> String {
        let lang = currentLanguage
        if lang == "en" {
            return text
        }
        let localized = bundle(for: lang).localizedString(forKey: text, value: text, table: nil)
        return localized
    }

    /// Looks up a disambiguated localized string (`"\(context)::\(text)"`),
    /// falling back to `text` when no translation exists.
    static func tr(_ text: String, context: String) -> String {
        let lang = currentLanguage
        if lang == "en" {
            return text
        }
        let key = "\(context)::\(text)"
        let sentinel = "__DOWNRIGHT_MISSING__"
        let localized = bundle(for: lang).localizedString(forKey: key, value: sentinel, table: nil)
        return localized == sentinel ? text : localized
    }

    /// Looks up a localized format string and formats it with `arguments`.
    static func tr(_ format: String, _ arguments: CVarArg...) -> String {
        let template = tr(format)
        return String(format: template, arguments: arguments)
    }

    /// Looks up a disambiguated localized format string and formats it.
    static func tr(_ format: String, context: String, _ arguments: CVarArg...) -> String {
        let template = tr(format, context: context)
        return String(format: template, arguments: arguments)
    }

    /// Translates built-in theme names for UI presentation only.
    ///
    /// Persistent theme identifiers in `Preferences.values.themeName` and
    /// `ThemeStore` stay canonical English so saved preferences remain stable.
    static func themeDisplayName(_ canonicalName: String) -> String {
        switch canonicalName {
        case "System": return tr("System", context: "theme")
        case "Paper Light": return tr("Paper Light", context: "theme")
        case "Warm Dark": return tr("Warm Dark", context: "theme")
        case "Solarized Light": return tr("Solarized Light", context: "theme")
        case "Nord": return tr("Nord", context: "theme")
        case "High Contrast": return tr("High Contrast", context: "theme")
        default: return canonicalName
        }
    }

    static func renderModeTitle(_ mode: RenderMode) -> String {
        switch mode {
        case .read: return tr("Read", context: "renderMode")
        case .live: return tr("Document", context: "renderMode")
        case .source: return tr("Source", context: "renderMode")
        }
    }

    static func previewAppearanceTitle(_ appearance: PreviewAppearance) -> String {
        switch appearance {
        case .system: return tr("System", context: "appearance")
        case .light: return tr("Light", context: "appearance")
        case .dark: return tr("Dark", context: "appearance")
        }
    }

    static func bodyPresetTitle(_ preset: TypographyConfig.BodyPreset) -> String {
        switch preset {
        case .reading: return tr("Reading", context: "typographyPreset")
        case .working: return tr("Working", context: "typographyPreset")
        }
    }

    static func measureTitle(_ value: CGFloat) -> String {
        value == TypographyConfig.fullWidthMeasure
            ? tr("Full width")
            : tr("%lld characters", Int(TypographyConfig.clampedMeasureCharacters(value)))
    }

    static func tidyOptionTitle(_ option: TidyRule) -> String {
        tr(option.title)
    }

    static func zoomLevelTitle(_ level: ZoomLevel) -> String {
        tr(level.title)
    }

    /// Localized URL for the bundled tour, preferring a language-specific
    /// `Welcome.md` when present and falling back to the default English tour.
    static func localizedWelcomeTourURL(in bundle: Bundle = .main) -> URL? {
        let lang = currentLanguage
        if let localized = bundle.url(
            forResource: "Welcome",
            withExtension: "md",
            subdirectory: nil,
            localization: lang
        ) {
            return localized
        }
        return bundle.url(forResource: "Welcome", withExtension: "md")
    }
}
