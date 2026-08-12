import AppKit
import Foundation

/// Appearance and theme names shared by the app and its sandboxed Quick Look
/// extension.  Quick Look is a separate process, so the ordinary app defaults
/// domain is not visible there; the small app-group store keeps this setting
/// explicit instead of making the extension guess from the last document.
public enum PreviewAppearance: String, CaseIterable, Codable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    public var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Deliberately tiny bridge between the host app and Quick Look. Quick Look is
/// sandboxed and a local/ad-hoc build cannot carry an App Group without a
/// provisioning profile, so these namespaced values live in the macOS global
/// preferences domain. Missing or malformed values mean System.
public enum PreviewAppearanceStore {
    public static let appearanceKey = "com.ezzy.downright.quickLook.appearance"
    public static let lightThemeKey = "com.ezzy.downright.quickLook.lightTheme"
    public static let darkThemeKey = "com.ezzy.downright.quickLook.darkTheme"

    private static func value(forKey key: String) -> String? {
        CFPreferencesCopyValue(
            key as CFString,
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        ) as? String
    }

    public static var appearance: PreviewAppearance {
        guard let raw = value(forKey: appearanceKey),
              let value = PreviewAppearance(rawValue: raw) else { return .system }
        return value
    }

    public static func themeName(for appearance: NSAppearance) -> String? {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return value(forKey: isDark ? darkThemeKey : lightThemeKey)
    }

    public static func write(
        appearance: PreviewAppearance,
        lightThemeName: String,
        darkThemeName: String
    ) {
        let values = [
            appearanceKey: appearance.rawValue,
            lightThemeKey: lightThemeName,
            darkThemeKey: darkThemeName,
        ]
        for (key, value) in values {
            CFPreferencesSetValue(
                key as CFString,
                value as CFString,
                kCFPreferencesAnyApplication,
                kCFPreferencesCurrentUser,
                kCFPreferencesAnyHost
            )
        }
        CFPreferencesSynchronize(
            kCFPreferencesAnyApplication,
            kCFPreferencesCurrentUser,
            kCFPreferencesAnyHost
        )
    }
}
