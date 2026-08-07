import Foundation

/// Where Downright keeps its state.  Unsandboxed (§3.4), so these are real
/// paths in Application Support rather than a container.
enum AppPaths {
    static let bundleIdentifier = "com.ezzy.downright"

    static var supportDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Downright", isDirectory: true)
    }

    /// Content-addressed snapshot store for local time-travel (§8.3).
    static var historyDirectory: URL {
        supportDirectory.appendingPathComponent("history", isDirectory: true)
    }

    /// Per-document reading state: scroll position, mode, zoom, folds (§8.2).
    static var stateDirectory: URL {
        supportDirectory.appendingPathComponent("state", isDirectory: true)
    }

    static var themesDirectory: URL {
        supportDirectory.appendingPathComponent("Themes", isDirectory: true)
    }

    static var preferencesFile: URL {
        supportDirectory.appendingPathComponent("preferences.json")
    }

    static var keybindingsFile: URL {
        supportDirectory.appendingPathComponent("keybindings.json")
    }

    static var sessionFile: URL {
        supportDirectory.appendingPathComponent("session.json")
    }

    /// What a support directory is for, in the words the user would use.  When
    /// the directory cannot be created the warning has to name the feature that
    /// stops working, not the path that failed.
    enum Purpose: CaseIterable {
        case support, history, state, themes

        var directory: URL {
            switch self {
            case .support: return supportDirectory
            case .history: return historyDirectory
            case .state: return stateDirectory
            case .themes: return themesDirectory
            }
        }

        /// Reads as the tail of "Downright can't save …".
        var featureDescription: String {
            switch self {
            case .support: return "your settings, keyboard shortcuts, or the last session"
            case .history: return "version history, so change review has nothing to compare against"
            case .state: return "reading positions, folds, or the recent files list"
            case .themes: return "imported themes"
            }
        }
    }

    /// A directory Downright could not create, and what that costs the user.
    struct PreparationFailure {
        var purpose: Purpose
        var error: Error
    }

    static func create(_ directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Best-effort creation for call sites that are about to write anyway and
    /// will report their own write failure.  Callers that need to know use
    /// `create(_:)`.
    @discardableResult
    static func ensure(_ directory: URL) -> URL {
        try? create(directory)
        return directory
    }

    /// Creates every directory the app needs and reports the ones it could not.
    /// A failure here disables a whole feature for the rest of the session, so
    /// the caller is expected to say so rather than let it fail silently.
    static func prepareAll() -> [PreparationFailure] {
        Purpose.allCases.compactMap { purpose in
            do {
                try create(purpose.directory)
                return nil
            } catch {
                return PreparationFailure(purpose: purpose, error: error)
            }
        }
    }
}
