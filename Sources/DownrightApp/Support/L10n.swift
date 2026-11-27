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
/// English source text serves as both the key and the canonical fallback, so
/// there is no duplicate `en.lproj/Localizable.strings` table.
enum L10n {
    static let supportedLanguages = ["en", "zh-Hans"]

    private static let lock = NSLock()
    private static var preferredLanguage: AppLanguage = .system
    private static var overrideLanguage: String?
    private static var cachedBundles: [String: Bundle] = [:]
    private static var cachedDecimalFormatters: [String: NumberFormatter] = [:]
    private static var cachedDateFormatters: [String: DateFormatter] = [:]
    private static var cachedTemplateDateFormatters: [String: DateFormatter] = [:]
    private static var cachedListFormatters: [String: ListFormatter] = [:]

    /// Read `DOWNRIGHT_LANGUAGE` once at process launch rather than querying
    /// the environment dictionary on every lookup.
    private static let rawEnvironmentLanguage: String? = {
        guard let raw = ProcessInfo.processInfo.environment["DOWNRIGHT_LANGUAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else {
            return nil
        }
        return raw
    }()

    private static let environmentLanguage: String? = {
        guard let raw = rawEnvironmentLanguage, raw.lowercased() != "system" else {
            return nil
        }
        return normalizedLanguage(raw)
    }()

    private static let hasEnvironmentLanguageOverride: Bool = rawEnvironmentLanguage != nil

    private static let formatSpecifierRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|j|z|t|L)?[@dDiuUxXoOfeEgGcCsSp%]"#
        )
    }()

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
        lprojPath(for: "zh-Hans", in: bundle) != nil || lprojPath(for: "en", in: bundle) != nil
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
    ///
    /// `syncAppleLanguages` is only `true` when the user actively changes the
    /// in-app picker, so launch never clobbers a per-app language configured
    /// in macOS System Settings while the in-app picker remains `.system`.
    static func setPreferredLanguage(_ language: AppLanguage, syncAppleLanguages: Bool = false) {
        lock.lock()
        preferredLanguage = language
        lock.unlock()

        guard syncAppleLanguages else { return }
        // Never mutate global process defaults when running under an explicit
        // environment override (for example, deterministic test runs).
        if hasEnvironmentLanguageOverride {
            return
        }
        if let code = language.localizationCode {
            UserDefaults.standard.set([code], forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        }
    }

    /// Runs `body` with an explicit localization active (e.g. `"en"`,
    /// `"zh-Hans"`, or `"pseudo"`). Intended for deterministic localization tests.
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

    /// Effective localization identifier currently active (`"en"`, `"zh-Hans"`, or `"pseudo"`).
    static var currentLanguage: String {
        lock.lock()
        let testOverride = overrideLanguage
        let configured = preferredLanguage
        lock.unlock()

        if let testOverride, !testOverride.isEmpty {
            return normalizedLanguage(testOverride)
        }
        if let env = environmentLanguage {
            return env
        }
        if let explicit = configured.localizationCode {
            return normalizedLanguage(explicit)
        }
        return resolveSystemLanguage(preferredLanguages: Locale.preferredLanguages)
    }

    static var isEnglish: Bool {
        currentLanguage == "en"
    }

    static var isPseudo: Bool {
        currentLanguage == "pseudo"
    }

    /// Locale matching the active in-app language for formatters and collation.
    static var locale: Locale {
        switch currentLanguage {
        case "zh-Hans": return Locale(identifier: "zh_Hans")
        default: return Locale(identifier: "en_US")
        }
    }

    /// Resolves macOS's preferred language list to a supported Downright language.
    ///
    /// Traditional Chinese tags (`zh-Hant`, `zh-TW`, `zh-HK`, `zh-MO`) are not
    /// silently mapped to `zh-Hans`; unless a user also lists `zh-Hans` ahead
    /// of English, they resolve to `"en"` (and can opt into Simplified Chinese
    /// via Settings → General → Language).
    static func resolveSystemLanguage(preferredLanguages: [String]) -> String {
        let matched = Bundle.preferredLocalizations(
            from: supportedLanguages,
            forPreferences: preferredLanguages
        )
        return normalizedLanguage(matched.first ?? "en")
    }

    static func normalizedLanguage(_ code: String) -> String {
        let lower = code.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lower == "pseudo" {
            return "pseudo"
        }
        if lower == "zh-hans" || lower.hasPrefix("zh-hans-") || lower == "zh-cn" || lower == "zh-sg" || lower == "zh" {
            return "zh-Hans"
        }
        return "en"
    }

    /// Pseudo-localizes an English template for visual truncation and unwrapped-text
    /// audits (`DOWNRIGHT_LANGUAGE=pseudo`).
    ///
    /// Wraps every string in `[...]` and pads visible text by ~40% while keeping
    /// printf format specifiers (`%@`, `%1$@`, `%lld`, `%%`, etc.) intact.
    static func pseudoLocalize(_ template: String) -> String {
        let ns = template as NSString
        let matches = formatSpecifierRegex.matches(
            in: template,
            range: NSRange(location: 0, length: ns.length)
        )
        var accented = ""
        var visibleCount = 0
        var cursor = 0

        func accentChunk(_ chunk: String) {
            for ch in chunk {
                visibleCount += 1
                switch ch {
                case "a": accented.append("á")
                case "e": accented.append("é")
                case "i": accented.append("ï")
                case "o": accented.append("ö")
                case "u": accented.append("ü")
                case "A": accented.append("Á")
                case "E": accented.append("É")
                case "I": accented.append("Ï")
                case "O": accented.append("Ö")
                case "U": accented.append("Ü")
                default: accented.append(ch)
                }
            }
        }

        for match in matches {
            if match.range.location > cursor {
                accentChunk(ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor)))
            }
            accented.append(ns.substring(with: match.range))
            cursor = match.range.upperBound
        }
        if cursor < ns.length {
            accentChunk(ns.substring(from: cursor))
        }

        let targetPad = max(2, Int(ceil(Double(max(1, visibleCount)) * 0.4)))
        let fillerUnit = "lorem ipsum dolor sit amet "
        var pad = ""
        while pad.count < targetPad {
            pad.append(fillerUnit)
        }
        let trimmedPad = String(pad.prefix(targetPad)).trimmingCharacters(in: .whitespaces)
        if trimmedPad.isEmpty {
            return "[\(accented) ~~]"
        }
        return "[\(accented) \(trimmedPad)]"
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
        if lang == "pseudo" {
            return pseudoLocalize(text)
        }
        return bundle(for: lang).localizedString(forKey: text, value: text, table: nil)
    }

    /// Looks up a disambiguated localized string (`"\(context)::\(text)"`),
    /// falling back to `text` when no translation exists.
    static func tr(_ text: String, context: String) -> String {
        let lang = currentLanguage
        if lang == "en" {
            return text
        }
        if lang == "pseudo" {
            return pseudoLocalize(text)
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

    // MARK: - Locale-aware formatters and collation

    /// Locale-aware collation for sorting user-visible titles (uses Pinyin order
    /// under `zh-Hans` regardless of the host macOS system locale).
    static func compareForDisplay(_ lhs: String, _ rhs: String) -> ComparisonResult {
        lhs.compare(rhs, options: [.caseInsensitive, .numeric], locale: locale)
    }

    static func formatNumber(_ value: Int) -> String {
        let activeLocale = locale
        let key = activeLocale.identifier
        lock.lock()
        let formatter: NumberFormatter
        if let cached = cachedDecimalFormatters[key] {
            formatter = cached
        } else {
            let f = NumberFormatter()
            f.numberStyle = .decimal
            f.locale = activeLocale
            cachedDecimalFormatters[key] = f
            formatter = f
        }
        let result = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        lock.unlock()
        return result
    }

    static func formatDate(
        _ date: Date,
        dateStyle: DateFormatter.Style = .medium,
        timeStyle: DateFormatter.Style = .short
    ) -> String {
        let activeLocale = locale
        let key = "\(activeLocale.identifier):\(dateStyle.rawValue):\(timeStyle.rawValue)"
        lock.lock()
        let formatter: DateFormatter
        if let cached = cachedDateFormatters[key] {
            formatter = cached
        } else {
            let f = DateFormatter()
            f.dateStyle = dateStyle
            f.timeStyle = timeStyle
            f.locale = activeLocale
            cachedDateFormatters[key] = f
            formatter = f
        }
        let result = formatter.string(from: date)
        lock.unlock()
        return result
    }

    static func formatDateTemplate(_ date: Date, template: String) -> String {
        let activeLocale = locale
        let key = "\(activeLocale.identifier):\(template)"
        lock.lock()
        let formatter: DateFormatter
        if let cached = cachedTemplateDateFormatters[key] {
            formatter = cached
        } else {
            let f = DateFormatter()
            f.locale = activeLocale
            f.setLocalizedDateFormatFromTemplate(template)
            cachedTemplateDateFormatters[key] = f
            formatter = f
        }
        let result = formatter.string(from: date)
        lock.unlock()
        return result
    }

    /// Formats a decimal file byte count following `L10n.locale` and `L10n.tr`
    /// instead of `ByteCountFormatter` (which ignores in-app language overrides).
    static func formatByteCount(_ byteCount: Int64) -> String {
        let clamped = max(0, byteCount)
        if clamped == 0 {
            return tr("Zero KB")
        }
        if clamped == 1 {
            return tr("1 byte")
        }
        if clamped < 1_000 {
            return tr("%@ bytes", formatNumber(Int(clamped)))
        }

        let value = Double(clamped)
        let activeLocale = locale
        func decimal(_ amount: Double, maxFractionDigits: Int) -> String {
            let key = "\(activeLocale.identifier):frac:\(maxFractionDigits)"
            lock.lock()
            let formatter: NumberFormatter
            if let cached = cachedDecimalFormatters[key] {
                formatter = cached
            } else {
                let f = NumberFormatter()
                f.numberStyle = .decimal
                f.minimumFractionDigits = 0
                f.maximumFractionDigits = maxFractionDigits
                f.locale = activeLocale
                cachedDecimalFormatters[key] = f
                formatter = f
            }
            let formatted = formatter.string(from: NSNumber(value: amount)) ?? String(format: "%.\(maxFractionDigits)f", amount)
            lock.unlock()
            return formatted
        }

        if clamped < 1_000_000 {
            return tr("%@ KB", decimal(value / 1_000, maxFractionDigits: 0))
        }
        if clamped < 1_000_000_000 {
            return tr("%@ MB", decimal(value / 1_000_000, maxFractionDigits: 1))
        }
        if clamped < 1_000_000_000_000 {
            return tr("%@ GB", decimal(value / 1_000_000_000, maxFractionDigits: 2))
        }
        return tr("%@ TB", decimal(value / 1_000_000_000_000, maxFractionDigits: 2))
    }

    static func formatList(_ items: [String]) -> String {
        guard !items.isEmpty else { return "" }
        let activeLocale = locale
        let key = activeLocale.identifier
        lock.lock()
        let formatter: ListFormatter
        if let cached = cachedListFormatters[key] {
            formatter = cached
        } else {
            let f = ListFormatter()
            f.locale = activeLocale
            cachedListFormatters[key] = f
            formatter = f
        }
        let result = formatter.string(from: items) ?? items.joined(separator: ", ")
        lock.unlock()
        return result
    }

    // MARK: - Domain display-name mappers

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
        switch option {
        case .headingLevels: return tr("Fix skipped heading levels")
        case .tablePipes: return tr("Align table pipes")
        case .blankLines: return tr("Collapse blank line runs")
        case .codeFenceLanguages: return tr("Add code fence languages")
        case .orderedListNumbers: return tr("Renumber ordered lists")
        case .listMarkers: return tr("Normalise list markers")
        case .trailingWhitespace: return tr("Trim trailing whitespace")
        }
    }

    static func zoomLevelTitle(_ level: ZoomLevel) -> String {
        switch level {
        case .h1: return tr("Top level")
        case .h2: return tr("Two levels")
        case .headings: return tr("All headings")
        case .skeleton: return tr("Skeleton")
        case .everything: return tr("Everything")
        }
    }

    /// Localized URL for the bundled tour, preferring a language-specific
    /// `Welcome.md` when present and falling back to the default English tour.
    static func localizedWelcomeTourURL(in bundle: Bundle = .main) -> URL? {
        let lang = currentLanguage
        if lang != "pseudo", let localized = bundle.url(
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
