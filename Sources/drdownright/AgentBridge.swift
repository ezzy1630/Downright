import Foundation

/// The agent side of the CLI: the small amount of pure logic that lets a coding
/// agent hand a freshly-written Markdown file to Downright.
///
/// The product thesis is that markdown is increasingly written by machines and
/// read by people, and the expensive moment is the handover — the agent rewrites
/// a file, and you find out by scrolling back to a document you had already read.
/// `down notify` closes that gap: the agent tells Downright the instant it writes,
/// and the app's existing external-change review surface does the rest.
///
/// Everything here is pure so it can be tested without an agent, a file system
/// watcher, or a running app.  The impure parts (watching, launching) live in the
/// `down` executable.
public enum AgentBridge {
    // MARK: - Hook payloads

    /// The tool names worth reacting to.  A hook that fires on `Read` or `Bash`
    /// would wake the app for work that never touched a byte on disk.
    public static let toolMatcher = "Write|Edit|MultiEdit|NotebookEdit"

    /// Extracts the file a hook payload is reporting on.
    ///
    /// Claude Code delivers hook input as JSON on stdin, with the tool's own
    /// arguments under `tool_input`.  The key differs per tool (`file_path` for
    /// the editing tools, `notebook_path` for notebooks) and some tools echo the
    /// resolved path back under `tool_response`, so this checks each known
    /// location rather than assuming one shape.
    ///
    /// Returns `nil` for malformed input by design.  A hook that throws blocks
    /// the agent's turn, and no markdown file is worth stalling a coding session
    /// over — the caller treats `nil` as "nothing to do" and exits 0.
    public static func hookPayloadPaths(_ data: Data) -> [String] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return []
        }
        var found: [String] = []
        func collect(_ container: Any?) {
            guard let container = container as? [String: Any] else { return }
            for key in ["file_path", "filePath", "notebook_path", "notebookPath", "path"] {
                if let value = container[key] as? String, !value.isEmpty { found.append(value) }
            }
        }
        collect(root["tool_input"])
        collect(root["tool_response"])
        collect(root)

        var seen = Set<String>()
        return found.filter { seen.insert($0).inserted }
    }

    /// Narrows hook paths to Markdown files that actually exist on disk.
    ///
    /// The existence check is not defensive padding: `Edit` fires its hook after
    /// the write, but a tool that failed still emits a payload, and asking
    /// `open` to launch the app for a path that is not there produces a Finder
    /// error dialog in front of somebody who is not even looking at the app.
    public static func openableTargets(
        in paths: [String],
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [String] {
        paths.compactMap { path -> String? in
            let expanded = (path as NSString).expandingTildeInPath
            let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path
            guard MarkdownCLI.isMarkdownPath(standardized), fileExists(standardized) else { return nil }
            return standardized
        }
    }

    // MARK: - Hook installation

    /// Where a generated hook is written.
    public enum HookScope: String, CaseIterable, Sendable {
        /// `~/.claude/settings.json` — every project this user opens.
        case user
        /// `.claude/settings.json` under the current project.
        case project

        public var relativePath: String {
            switch self {
            case .user: return ".claude/settings.json"
            case .project: return ".claude/settings.json"
            }
        }

        public func settingsURL(home: URL, workingDirectory: URL) -> URL {
            switch self {
            case .user: return home.appendingPathComponent(relativePath)
            case .project: return workingDirectory.appendingPathComponent(relativePath)
            }
        }
    }

    /// The shell command a hook runs.  `notify` reads the payload on stdin, so
    /// the hook needs no `jq`, no shell quoting, and no per-tool special casing.
    public static func hookCommand(executable: String = "down") -> String {
        let quoted = executable.contains(" ") ? "\"\(executable)\"" : executable
        return "\(quoted) notify"
    }

    /// One `PostToolUse` entry in Claude Code's settings schema.
    public static func hookEntry(executable: String = "down") -> [String: Any] {
        [
            "matcher": toolMatcher,
            "hooks": [["type": "command", "command": hookCommand(executable: executable)]],
        ]
    }

    /// Whether these settings already run our hook.
    ///
    /// The agent's `settings.json` is the only source of truth for this — not a
    /// stored preference — because it is the file the agent actually reads, and
    /// a user who edits it by hand or checks one into a project must not find
    /// the app disagreeing with reality.
    public static func isHookInstalled(in settings: [String: Any], executable: String = "down") -> Bool {
        let command = hookCommand(executable: executable)
        let entries = (settings["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]] ?? []
        return entries.contains { entry in
            // Our hook is identified by its matcher *and* its command.  A
            // foreign entry that happens to run `down notify` under another
            // matcher must not count as installed — matching on the command
            // alone would block a needed install and let uninstall delete it.
            entry["matcher"] as? String == toolMatcher
                && (entry["hooks"] as? [[String: Any]] ?? [])
                    .compactMap { $0["command"] as? String }
                    .contains(command)
        }
    }

    /// Merges the Downright hook into an existing settings object.
    ///
    /// Idempotent, and deliberately additive: a user's `settings.json` is their
    /// own file with their own hooks in it, so this preserves every unrelated
    /// key, appends rather than replaces the `PostToolUse` array, and returns
    /// the input unchanged when an equivalent hook is already installed.
    public static func installingHook(
        into settings: [String: Any],
        executable: String = "down"
    ) -> (settings: [String: Any], changed: Bool) {
        guard !isHookInstalled(in: settings, executable: executable) else { return (settings, false) }
        var settings = settings
        var hooks = settings["hooks"] as? [String: Any] ?? [:]
        var postToolUse = hooks["PostToolUse"] as? [[String: Any]] ?? []

        postToolUse.append(hookEntry(executable: executable))
        hooks["PostToolUse"] = postToolUse
        settings["hooks"] = hooks
        return (settings, true)
    }

    /// Removes a previously installed Downright hook, pruning any matcher group
    /// left empty so uninstalling does not leave debris behind.
    public static func removingHook(
        from settings: [String: Any],
        executable: String = "down"
    ) -> (settings: [String: Any], changed: Bool) {
        var settings = settings
        guard var hooks = settings["hooks"] as? [String: Any],
              let postToolUse = hooks["PostToolUse"] as? [[String: Any]]
        else { return (settings, false) }

        let command = hookCommand(executable: executable)
        var changed = false
        var remaining: [[String: Any]] = []
        for var entry in postToolUse {
            // Only entries under our matcher are ours to edit.  A foreign entry
            // with the same command string is the user's own hook and must
            // survive an uninstall untouched.
            guard entry["matcher"] as? String == toolMatcher else {
                remaining.append(entry)
                continue
            }
            let commands = entry["hooks"] as? [[String: Any]] ?? []
            let kept = commands.filter { ($0["command"] as? String) != command }
            if kept.count != commands.count { changed = true }
            guard !kept.isEmpty else { continue }
            entry["hooks"] = kept
            remaining.append(entry)
        }
        guard changed else { return (settings, false) }

        if remaining.isEmpty { hooks.removeValue(forKey: "PostToolUse") } else { hooks["PostToolUse"] = remaining }
        if hooks.isEmpty { settings.removeValue(forKey: "hooks") } else { settings["hooks"] = hooks }
        return (settings, true)
    }

    /// Serialises a settings object back to disk-ready JSON.
    ///
    /// Sorted keys and pretty printing are not cosmetic: this file is usually
    /// under version control, and an unstable key order would make every hook
    /// install produce a meaningless diff.
    public static func encode(_ settings: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0A)
        return data
    }

    /// The snippet printed by `down hook --print`, for anyone wiring an agent
    /// that is not Claude Code, or who would rather paste it themselves.
    public static func hookSnippet(executable: String = "down") -> String {
        let object: [String: Any] = ["hooks": ["PostToolUse": [hookEntry(executable: executable)]]]
        guard let data = try? encode(object), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text.trimmingCharacters(in: .newlines)
    }
}
