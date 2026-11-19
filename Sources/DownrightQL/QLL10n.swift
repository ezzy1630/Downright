import Foundation

/// Lightweight localization helper for the sandboxed Quick Look extension.
enum QLL10n {
    static let supportedLanguages = ["en", "zh-Hans"]

    private static let lock = NSLock()
    private static var overrideLanguage: String?
    private static var cachedBundles: [String: Bundle] = [:]

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
        if let env = ProcessInfo.processInfo.environment["DOWNRIGHT_LANGUAGE"],
           !env.isEmpty, env.lowercased() != "system" {
            return normalizedLanguage(env)
        }
        let matched = Bundle.preferredLocalizations(
            from: supportedLanguages,
            forPreferences: Locale.preferredLanguages
        )
        return normalizedLanguage(matched.first ?? "en")
    }

    private static func normalizedLanguage(_ code: String) -> String {
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

    static func tr(_ text: String) -> String {
        let lang = currentLanguage
        if lang == "en" { return text }
        return bundle(for: lang).localizedString(forKey: text, value: text, table: nil)
    }

    static func tr(_ format: String, _ arguments: CVarArg...) -> String {
        let template = tr(format)
        return String(format: template, arguments: arguments)
    }
}
