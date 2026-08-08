import Foundation
import drdownright

/// The app's view of the agent hook that `down notify` installs.
///
/// State lives in the agent's own `settings.json`, never in our preferences.
/// That file is the thing the agent actually reads, and a user who edits it by
/// hand — or a project that checks one in — must not find the app disagreeing
/// with reality.  Every accessor re-reads it, so a Settings row states what is
/// true at the moment it is drawn, matching how the System Integration rows
/// already behave.
@available(macOS 14.0, *)
public enum AgentIntegration {
    /// Where the app installs the hook.
    ///
    /// User scope, deliberately.  A project-scoped install would write into a
    /// repository the user may not want it in, and may well commit — a checkbox
    /// in a setup panel is not consent to modify somebody's version control.
    public static var settingsURL: URL {
        AgentBridge.HookScope.user.settingsURL(
            home: URL(fileURLWithPath: NSHomeDirectory()),
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
    }

    /// The `down` the hook should invoke.
    ///
    /// A hook does not inherit an interactive shell's `PATH`, so an unqualified
    /// `down` can resolve when the user tests it in Terminal and then silently
    /// fail inside the agent.  Only an absolute path is trustworthy here.
    public static var executablePath: String? {
        ["/usr/local/bin/down", "/opt/homebrew/bin/down"]
            .first { FileManager.default.fileExists(atPath: $0) }
    }

    /// True when the agent's settings already run our hook.
    public static var isInstalled: Bool {
        isInstalled(settingsURL: settingsURL, executable: executablePath)
    }

    // Every operation has an explicit-location form underneath the ambient one.
    // Without it the only way to exercise this type is to write to the running
    // user's real `~/.claude/settings.json`, which is not something a test suite
    // may do — so the ambient API stays a one-line convenience and the logic is
    // tested against a temporary directory.

    static func isInstalled(settingsURL: URL, executable: String?) -> Bool {
        guard let executable else { return false }
        return AgentBridge.isHookInstalled(in: loadSettings(at: settingsURL), executable: executable)
    }

    public enum Failure: LocalizedError, Equatable {
        case commandLineToolMissing
        case cannotWrite(String)

        public var errorDescription: String? {
            switch self {
            case .commandLineToolMissing:
                return "Install the down command line tool first — the hook runs it."
            case .cannotWrite(let reason):
                return reason
            }
        }
    }

    /// - Returns: whether anything changed.  Installing over an existing hook is
    ///   a no-op rather than a duplicate.
    @discardableResult
    public static func install() throws -> Bool {
        try install(settingsURL: settingsURL, executable: executablePath)
    }

    @discardableResult
    static func install(settingsURL: URL, executable: String?) throws -> Bool {
        guard let executable else { throw Failure.commandLineToolMissing }
        let result = AgentBridge.installingHook(into: loadSettings(at: settingsURL), executable: executable)
        guard result.changed else { return false }
        try write(result.settings, to: settingsURL)
        return true
    }

    @discardableResult
    public static func uninstall() throws -> Bool {
        try uninstall(settingsURL: settingsURL, executable: executablePath)
    }

    @discardableResult
    static func uninstall(settingsURL: URL, executable: String?) throws -> Bool {
        guard let executable else { return false }
        let result = AgentBridge.removingHook(from: loadSettings(at: settingsURL), executable: executable)
        guard result.changed else { return false }
        try write(result.settings, to: settingsURL)
        return true
    }

    /// A settings file we cannot parse is treated as absent for reading, but
    /// `write` refuses to clobber it — see below.
    private static func loadSettings(at url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return object
    }

    private static func write(_ settings: [String: Any], to url: URL) throws {
        // Refuse to write over a file that exists but did not parse.  Treating
        // unreadable JSON as an empty object would silently replace a config the
        // user spent time on with one containing nothing but our hook.
        if let data = try? Data(contentsOf: url), !data.isEmpty,
           (try? JSONSerialization.jsonObject(with: data)) == nil {
            throw Failure.cannotWrite("\(url.path) is not valid JSON. Fix or move it, then try again.")
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AgentBridge.encode(settings).write(to: url, options: .atomic)
        } catch {
            throw Failure.cannotWrite(error.localizedDescription)
        }
    }
}
