import Foundation
import Testing

@testable import drdownright

/// The agent bridge is the one part of the CLI that runs inside somebody else's
/// tool, on somebody else's file, during somebody else's edit.  These tests hold
/// the two properties that follow from that: it never mangles a settings file it
/// did not write, and it never reports a target it should not open.
@Suite("Agent bridge")
struct AgentBridgeTests {
    // MARK: - Hook payloads

    @Test("A PostToolUse payload yields the edited file")
    func extractsFilePath() {
        let payload = Data(#"""
        {"hook_event_name":"PostToolUse","tool_name":"Write",
         "tool_input":{"file_path":"/tmp/notes.md","content":"hello"}}
        """#.utf8)
        #expect(AgentBridge.hookPayloadPaths(payload) == ["/tmp/notes.md"])
    }

    @Test("A notebook payload uses its own key")
    func extractsNotebookPath() {
        let payload = Data(#"{"tool_input":{"notebook_path":"/tmp/a.ipynb"}}"#.utf8)
        #expect(AgentBridge.hookPayloadPaths(payload) == ["/tmp/a.ipynb"])
    }

    @Test("A path echoed back in tool_response is found")
    func extractsResponsePath() {
        let payload = Data(#"{"tool_response":{"filePath":"/tmp/out.md"}}"#.utf8)
        #expect(AgentBridge.hookPayloadPaths(payload) == ["/tmp/out.md"])
    }

    @Test("The same path in input and response is reported once")
    func deduplicatesPaths() {
        let payload = Data(#"""
        {"tool_input":{"file_path":"/tmp/a.md"},"tool_response":{"filePath":"/tmp/a.md"}}
        """#.utf8)
        #expect(AgentBridge.hookPayloadPaths(payload) == ["/tmp/a.md"])
    }

    /// A hook that throws blocks the agent's turn, so every malformed input has
    /// to degrade to "nothing to do" rather than to an error.
    @Test("Malformed payloads yield nothing rather than failing", arguments: [
        "", "not json at all", "[]", "null", "{}", #"{"tool_input":null}"#,
        #"{"tool_input":{"file_path":""}}"#, #"{"tool_input":{"file_path":123}}"#,
    ])
    func malformedPayloadsAreEmpty(_ raw: String) {
        #expect(AgentBridge.hookPayloadPaths(Data(raw.utf8)).isEmpty)
    }

    // MARK: - Target filtering

    @Test("Only existing Markdown files become open targets")
    func filtersToExistingMarkdown() {
        let present: Set<String> = ["/w/notes.md", "/w/main.swift", "/w/deleted.md"]
        let exists: (String) -> Bool = { $0 != "/w/deleted.md" && present.contains($0) }
        let targets = AgentBridge.openableTargets(
            in: ["/w/notes.md", "/w/main.swift", "/w/deleted.md", "/w/missing.md"],
            fileExists: exists
        )
        #expect(targets == ["/w/notes.md"])
    }

    @Test("Every extension the app opens is accepted", arguments: [
        "md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd",
    ])
    func acceptsEveryMarkdownExtension(_ ext: String) {
        let path = "/w/doc.\(ext)"
        #expect(AgentBridge.openableTargets(in: [path], fileExists: { _ in true }) == [path])
    }

    @Test("Paths are expanded and standardised before use")
    func standardisesPaths() {
        let targets = AgentBridge.openableTargets(in: ["/w/./sub/../notes.md"], fileExists: { _ in true })
        #expect(targets == ["/w/notes.md"])
    }

    // MARK: - Settings merge

    @Test("Installing into an empty settings file creates the hook")
    func installsIntoEmptySettings() {
        let (settings, changed) = AgentBridge.installingHook(into: [:], executable: "/usr/local/bin/down")
        #expect(changed)
        let hooks = settings["hooks"] as? [String: Any]
        let postToolUse = hooks?["PostToolUse"] as? [[String: Any]]
        #expect(postToolUse?.count == 1)
        #expect(postToolUse?.first?["matcher"] as? String == AgentBridge.toolMatcher)
    }

    /// The file belongs to the user, not to us.  Unrelated keys and unrelated
    /// hooks have to survive an install untouched.
    @Test("Installing preserves unrelated settings and unrelated hooks")
    func installPreservesForeignContent() {
        let existing: [String: Any] = [
            "permissions": ["allow": ["Bash(ls:*)"]],
            "hooks": [
                "PostToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "echo mine"]]]],
                "PreToolUse": [["matcher": "Read", "hooks": [["type": "command", "command": "echo pre"]]]],
            ],
        ]
        let (settings, changed) = AgentBridge.installingHook(into: existing, executable: "down")
        #expect(changed)
        #expect(settings["permissions"] as? [String: [String]] == ["allow": ["Bash(ls:*)"]])
        let hooks = settings["hooks"] as? [String: Any]
        #expect((hooks?["PreToolUse"] as? [[String: Any]])?.count == 1)
        let postToolUse = hooks?["PostToolUse"] as? [[String: Any]] ?? []
        #expect(postToolUse.count == 2)
        #expect(postToolUse.first?["matcher"] as? String == "Bash")
    }

    @Test("Installed state is read back from the settings, not assumed")
    func reportsInstalledState() {
        #expect(!AgentBridge.isHookInstalled(in: [:], executable: "down"))
        let installed = AgentBridge.installingHook(into: [:], executable: "down").settings
        #expect(AgentBridge.isHookInstalled(in: installed, executable: "down"))
        // A hook installed from a different location is a different hook.
        #expect(!AgentBridge.isHookInstalled(in: installed, executable: "/opt/homebrew/bin/down"))
        let removed = AgentBridge.removingHook(from: installed, executable: "down").settings
        #expect(!AgentBridge.isHookInstalled(in: removed, executable: "down"))
    }

    @Test("Installing twice changes nothing the second time")
    func installIsIdempotent() {
        let first = AgentBridge.installingHook(into: [:], executable: "down")
        let second = AgentBridge.installingHook(into: first.settings, executable: "down")
        #expect(first.changed)
        #expect(!second.changed)
        let hooks = second.settings["hooks"] as? [String: Any]
        #expect((hooks?["PostToolUse"] as? [[String: Any]])?.count == 1)
    }

    /// Two installs from different locations are two different commands, so the
    /// idempotence check keys on the command rather than on the matcher.
    @Test("A different executable path installs as a separate hook")
    func differentExecutableIsDistinct() {
        let first = AgentBridge.installingHook(into: [:], executable: "/usr/local/bin/down")
        let second = AgentBridge.installingHook(into: first.settings, executable: "/opt/homebrew/bin/down")
        #expect(second.changed)
        let hooks = second.settings["hooks"] as? [String: Any]
        #expect((hooks?["PostToolUse"] as? [[String: Any]])?.count == 2)
    }

    /// Our hook is identified by its matcher *and* its command.  A foreign
    /// entry that runs `down notify` under another matcher is the user's own
    /// hook, so it must not count as installed and must not block our install.
    @Test("A foreign entry with our command under another matcher is not ours")
    func foreignMatcherWithSameCommandDoesNotBlockInstall() {
        let foreign: [String: Any] = [
            "hooks": ["PostToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "down notify"]]]]],
        ]
        #expect(!AgentBridge.isHookInstalled(in: foreign, executable: "down"))
        let (settings, changed) = AgentBridge.installingHook(into: foreign, executable: "down")
        #expect(changed)
        let postToolUse = (settings["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]
        #expect(postToolUse?.count == 2)
        #expect(AgentBridge.isHookInstalled(in: settings, executable: "down"))
    }

    @Test("Uninstalling leaves a foreign entry with the same command untouched")
    func uninstallPreservesForeignMatcherWithSameCommand() {
        let foreign: [String: Any] = [
            "hooks": ["PostToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "down notify"]]]]],
        ]
        let installed = AgentBridge.installingHook(into: foreign, executable: "down").settings
        let (settings, changed) = AgentBridge.removingHook(from: installed, executable: "down")
        #expect(changed)
        let postToolUse = (settings["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]
        #expect(postToolUse?.count == 1)
        #expect(postToolUse?.first?["matcher"] as? String == "Bash")
        #expect((postToolUse?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String == "down notify")
    }

    @Test("Uninstalling removes only our hook")
    func uninstallRemovesOnlyOurs() {
        let seeded: [String: Any] = [
            "hooks": ["PostToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "echo mine"]]]]],
        ]
        let installed = AgentBridge.installingHook(into: seeded, executable: "down")
        let (settings, changed) = AgentBridge.removingHook(from: installed.settings, executable: "down")
        #expect(changed)
        let postToolUse = (settings["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]
        #expect(postToolUse?.count == 1)
        #expect(postToolUse?.first?["matcher"] as? String == "Bash")
    }

    /// Uninstalling should leave no trace — an empty `PostToolUse` array or an
    /// empty `hooks` object is debris the user would have to clean up by hand.
    @Test("Uninstalling the only hook prunes the empty containers")
    func uninstallPrunesEmptyContainers() {
        let installed = AgentBridge.installingHook(into: ["permissions": ["allow": []]], executable: "down")
        let (settings, changed) = AgentBridge.removingHook(from: installed.settings, executable: "down")
        #expect(changed)
        #expect(settings["hooks"] == nil)
        #expect(settings["permissions"] != nil)
    }

    @Test("Uninstalling when nothing is installed reports no change")
    func uninstallIsSafeWhenAbsent() {
        #expect(!AgentBridge.removingHook(from: [:], executable: "down").changed)
        let foreign: [String: Any] = [
            "hooks": ["PostToolUse": [["matcher": "Bash", "hooks": [["type": "command", "command": "other"]]]]],
        ]
        #expect(!AgentBridge.removingHook(from: foreign, executable: "down").changed)
    }

    /// This file is usually in version control, so an unstable key order would
    /// turn every install into a noisy diff.
    @Test("Encoding is deterministic and newline-terminated")
    func encodingIsStable() throws {
        let settings = AgentBridge.installingHook(into: [:], executable: "down").settings
        let first = try AgentBridge.encode(settings)
        let second = try AgentBridge.encode(settings)
        #expect(first == second)
        #expect(first.last == 0x0A)
        let text = String(decoding: first, as: UTF8.self)
        #expect(!text.contains("\\/"))
    }

    @Test("The printed snippet is valid JSON containing the notify command")
    func snippetIsValidJSON() throws {
        let snippet = AgentBridge.hookSnippet(executable: "/usr/local/bin/down")
        let object = try JSONSerialization.jsonObject(with: Data(snippet.utf8)) as? [String: Any]
        let postToolUse = (object?["hooks"] as? [String: Any])?["PostToolUse"] as? [[String: Any]]
        let command = (postToolUse?.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String
        #expect(command == "/usr/local/bin/down notify")
    }

    @Test("Scope decides which settings file is written")
    func scopeResolvesSettingsPath() {
        let home = URL(fileURLWithPath: "/Users/x")
        let project = URL(fileURLWithPath: "/w/proj")
        #expect(AgentBridge.HookScope.user.settingsURL(home: home, workingDirectory: project).path
            == "/Users/x/.claude/settings.json")
        #expect(AgentBridge.HookScope.project.settingsURL(home: home, workingDirectory: project).path
            == "/w/proj/.claude/settings.json")
    }
}

/// The watcher's planning step decides what FSEvents is pointed at, which is the
/// part that goes wrong silently — a watch on the wrong path simply never fires.
@Suite("Agent watcher planning")
struct AgentWatcherPlanTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Agents write atomically — temp file, then rename over the target — which
    /// unlinks the inode any file-level watch was holding.  A file root must
    /// therefore resolve to its parent directory.
    @Test("A file root is watched through its parent directory")
    func fileRootWatchesParent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.md")
        try Data("# hi".utf8).write(to: file)

        let plan = AgentWatcher.plan(for: [file])
        #expect(plan.directories == [directory.standardizedFileURL.path])
        #expect(plan.allowedFiles == [file.standardizedFileURL.path])
    }

    @Test("A directory root is watched directly and allows everything under it")
    func directoryRootWatchesItself() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let plan = AgentWatcher.plan(for: [directory])
        #expect(plan.directories == [directory.standardizedFileURL.path])
        #expect(plan.allowedFiles.isEmpty)
    }

    /// Agents create files as well as rewrite them, so a target that does not
    /// exist yet still has to be watched.
    @Test("A file that does not exist yet is still watchable")
    func missingFileStillPlans() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("not-written-yet.md")

        let plan = AgentWatcher.plan(for: [file])
        #expect(plan.directories == [directory.standardizedFileURL.path])
        #expect(plan.allowedFiles == [file.standardizedFileURL.path])
    }

    @Test("Duplicate roots collapse to one watch")
    func duplicateRootsCollapse() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let a = directory.appendingPathComponent("a.md")
        let b = directory.appendingPathComponent("b.md")

        let plan = AgentWatcher.plan(for: [a, b])
        #expect(plan.directories.count == 1)
        #expect(plan.allowedFiles.count == 2)
    }

    /// Mixing a directory root with a file root must not let the file
    /// allow-list suppress everything the directory asked for.
    @Test("A directory root subsumes a file root's allow-list")
    func directoryRootSubsumesFileRoot() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("one.md")

        let plan = AgentWatcher.plan(for: [directory, file])
        #expect(plan.allowedFiles.isEmpty)
        #expect(AgentWatcher.accepts(directory.appendingPathComponent("other.md").path, plan: plan))
    }

    /// A folder of agent output churns constantly with lockfiles, build
    /// artefacts and `.DS_Store`; only Markdown should wake the app.
    @Test("Only Markdown paths are accepted")
    func rejectsNonMarkdown() {
        let plan = AgentWatcher.WatchPlan(directories: ["/w"], allowedFiles: [])
        #expect(AgentWatcher.accepts("/w/notes.md", plan: plan))
        #expect(AgentWatcher.accepts("/w/deep/nested/spec.mdx", plan: plan))
        #expect(!AgentWatcher.accepts("/w/.DS_Store", plan: plan))
        #expect(!AgentWatcher.accepts("/w/main.swift", plan: plan))
        #expect(!AgentWatcher.accepts("/w/package-lock.json", plan: plan))
    }

    @Test("A file allow-list rejects siblings in the same directory")
    func allowListRejectsSiblings() {
        let plan = AgentWatcher.WatchPlan(directories: ["/w"], allowedFiles: ["/w/notes.md"])
        #expect(AgentWatcher.accepts("/w/notes.md", plan: plan))
        #expect(!AgentWatcher.accepts("/w/other.md", plan: plan))
    }

    /// The signature is the guard against a feedback loop: opening a document
    /// updates the file's metadata, macOS reports that as a fresh event on the
    /// same path, and a watcher that trusted the event would open it again —
    /// forever.  Metadata must not move the signature.
    @Test("Opening a file does not change its signature")
    func metadataTouchLeavesSignatureAlone() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.md")
        try Data("# hi".utf8).write(to: file)

        let before = try #require(AgentWatcher.Signature(path: file.path))
        // Reading the document and restamping its metadata is what launching the
        // app does; both move atime/ctime and neither is a content change.
        _ = try Data(contentsOf: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
        let after = try #require(AgentWatcher.Signature(path: file.path))

        #expect(before == after)
    }

    @Test("Rewriting a file changes its signature")
    func rewriteChangesSignature() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("notes.md")
        try Data("# hi".utf8).write(to: file)
        let before = try #require(AgentWatcher.Signature(path: file.path))

        try Data("# hi, at a different length".utf8).write(to: file)
        let after = try #require(AgentWatcher.Signature(path: file.path))

        #expect(before != after)
    }

    @Test("A missing file has no signature, so it is never reported")
    func missingFileHasNoSignature() {
        #expect(AgentWatcher.Signature(path: "/nowhere/at/all/ghost.md") == nil)
    }
}

/// Parsing lives in the library so the agent surface can be exercised without
/// spawning a process, watching a folder, or launching the app.
@Suite("Agent command parsing")
struct AgentCommandParsingTests {
    @Test("notify defaults to background and opening")
    func notifyDefaults() throws {
        guard case .notify(let options) = try MarkdownCLI.parse(["notify"]) else {
            Issue.record("expected notify"); return
        }
        #expect(!options.focus)
        #expect(!options.dryRun)
    }

    @Test("notify accepts its flags")
    func notifyFlags() throws {
        guard case .notify(let options) = try MarkdownCLI.parse(["notify", "--focus", "--dry-run"]) else {
            Issue.record("expected notify"); return
        }
        #expect(options.focus)
        #expect(options.dryRun)
    }

    @Test("watch defaults to no paths and the standard debounce")
    func watchDefaults() throws {
        guard case .watch(let options, let paths) = try MarkdownCLI.parse(["watch"]) else {
            Issue.record("expected watch"); return
        }
        #expect(paths.isEmpty)
        #expect(options.debounce == AgentWatcher.defaultDebounce)
        #expect(!options.focus)
    }

    @Test("watch reads a debounce in milliseconds")
    func watchDebounce() throws {
        guard case .watch(let options, let paths) = try MarkdownCLI.parse(["watch", "--debounce", "750", "Docs"]) else {
            Issue.record("expected watch"); return
        }
        #expect(options.debounce == 0.75)
        #expect(paths == ["Docs"])
    }

    @Test("watch rejects a non-numeric debounce")
    func watchRejectsBadDebounce() {
        #expect(throws: MarkdownCLI.ParseError.self) {
            _ = try MarkdownCLI.parse(["watch", "--debounce", "soon"])
        }
    }

    @Test("watch requires a value for debounce")
    func watchRequiresDebounceValue() {
        #expect(throws: MarkdownCLI.ParseError.missingValue("--debounce")) {
            _ = try MarkdownCLI.parse(["watch", "--debounce"])
        }
    }

    @Test("watch passes paths after -- through untouched")
    func watchHonoursSeparator() throws {
        guard case .watch(_, let paths) = try MarkdownCLI.parse(["watch", "--", "--weird-name.md"]) else {
            Issue.record("expected watch"); return
        }
        #expect(paths == ["--weird-name.md"])
    }

    @Test("hook defaults to printing into the project scope")
    func hookDefaults() throws {
        guard case .hook(let options) = try MarkdownCLI.parse(["hook"]) else {
            Issue.record("expected hook"); return
        }
        #expect(options.mode == .print)
        #expect(options.scope == .project)
    }

    @Test("hook accepts install, uninstall and scope", arguments: [
        (["hook", "--install"], MarkdownCLI.HookOptions.Mode.install, AgentBridge.HookScope.project),
        (["hook", "--uninstall"], .uninstall, .project),
        (["hook", "--install", "--scope", "user"], .install, .user),
        (["hook", "--uninstall", "--scope", "USER"], .uninstall, .user),
    ])
    func hookFlags(_ argv: [String], _ mode: MarkdownCLI.HookOptions.Mode, _ scope: AgentBridge.HookScope) throws {
        guard case .hook(let options) = try MarkdownCLI.parse(argv) else {
            Issue.record("expected hook"); return
        }
        #expect(options.mode == mode)
        #expect(options.scope == scope)
    }

    @Test("hook rejects an unknown scope")
    func hookRejectsUnknownScope() {
        #expect(throws: MarkdownCLI.ParseError.self) {
            _ = try MarkdownCLI.parse(["hook", "--scope", "global"])
        }
    }

    @Test("The agent commands appear in the usage text")
    func usageDocumentsAgentCommands() {
        let usage = MarkdownCLI.usage()
        #expect(usage.contains("notify"))
        #expect(usage.contains("watch"))
        #expect(usage.contains("hook"))
    }

    /// `down README.md` must keep meaning "open this file", so the new
    /// subcommand names must not shadow a real path.
    @Test("A file argument still parses as open")
    func fileArgumentStillOpens() throws {
        guard case .open(_, let paths) = try MarkdownCLI.parse(["README.md"]) else {
            Issue.record("expected open"); return
        }
        #expect(paths == ["README.md"])
    }
}
