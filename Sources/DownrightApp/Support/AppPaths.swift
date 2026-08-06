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

    @discardableResult
    static func ensure(_ directory: URL) -> URL {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func prepareAll() {
        for dir in [supportDirectory, historyDirectory, stateDirectory, themesDirectory] {
            ensure(dir)
        }
    }
}
