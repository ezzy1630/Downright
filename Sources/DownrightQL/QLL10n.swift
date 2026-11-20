import Foundation
import MarkdownRender

/// Lightweight localization helper for the sandboxed Quick Look extension.
///
/// English keys in source serve as the canonical fallback; only non-English
/// `.lproj/Localizable.strings` tables are bundled.
enum QLL10n {
    static let supportedLanguages = ["en", "zh-Hans"]

    private static let lock = NSLock()
    private static var overrideLanguage: String?
    private static var cachedBundles: [String: Bundle] = [:]
    private static var cachedDecimalFormatters: [String: NumberFormatter] = [:]

    /// Read `DOWNRIGHT_LANGUAGE` once at extension launch rather than on every lookup.
    private static let environmentLanguage: String? = {
        guard let raw = ProcessInfo.processInfo.environment["DOWNRIGHT_LANGUAGE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              raw.lowercased() != "system" else {
            return nil
        }
        return normalizedLanguage(raw)
    }()

    private static let formatSpecifierRegex: NSRegularExpression = {
        try! NSRegularExpression(
            pattern: #"%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|h|ll|l|j|z|t|L)?[@dDiuUxXoOfeEgGcCsSp%]"#
        )
    }()

    static var resourceBundle: Bundle {
        if hasLocalizations(in: .main) {
            return .main
        }
        #if SWIFT_PACKAGE && !DOWNRIGHT_QL_BUNDLE_MAIN_ONLY
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

    static var currentLanguage: String {
        lock.lock()
        let testOverride = overrideLanguage
        lock.unlock()

        if let testOverride, !testOverride.isEmpty {
            return normalizedLanguage(testOverride)
        }
        if let env = environmentLanguage {
            return env
        }
        return resolveLanguage(
            storedPreference: PreviewAppearanceStore.language,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    static var locale: Locale {
        switch currentLanguage {
        case "zh-Hans": return Locale(identifier: "zh_Hans")
        default: return Locale(identifier: "en_US")
        }
    }

    /// Resolves Quick Look's language given the shared preference (which is `nil`
    /// before Downright has ever launched) and macOS's preferred language list.
    static func resolveLanguage(storedPreference: String?, preferredLanguages: [String]) -> String {
        if let stored = storedPreference?.trimmingCharacters(in: .whitespacesAndNewlines),
           !stored.isEmpty,
           stored.lowercased() != "system" {
            return normalizedLanguage(stored)
        }
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

    static func tr(_ text: String) -> String {
        let lang = currentLanguage
        if lang == "en" { return text }
        if lang == "pseudo" { return pseudoLocalize(text) }
        return bundle(for: lang).localizedString(forKey: text, value: text, table: nil)
    }

    static func tr(_ format: String, _ arguments: CVarArg...) -> String {
        let template = tr(format)
        return String(format: template, arguments: arguments)
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
}
