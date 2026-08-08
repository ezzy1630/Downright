import AppKit
import Foundation
import Testing

@testable import DownrightApp
@testable import drdownright

/// The app half of the agent hook.
///
/// Every test here works against a temporary settings file.  The ambient API
/// reads `~/.claude/settings.json`, and a suite that exercised it would be
/// editing the running user's real agent configuration.
@Suite(.serialized)
@MainActor
struct AgentIntegrationTests {
    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("downright-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let executable = "/usr/local/bin/down"

    // MARK: - Location

    /// User scope, not project scope: a project-scoped install would write into
    /// a repository the user may not want it in, and may well commit.
    @Test("The hook is installed for the user, not the project")
    func settingsPathIsUserScoped() {
        let path = AgentIntegration.settingsURL.path
        #expect(path.hasSuffix("/.claude/settings.json"))
        #expect(path.hasPrefix(NSHomeDirectory()))
    }

    // MARK: - Round trip

    @Test("Installing then uninstalling leaves the file as it was found")
    func installUninstallRoundTrip() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let original: [String: Any] = ["permissions": ["allow": ["Bash(ls:*)"]]]
        try AgentBridge.encode(original).write(to: url)

        #expect(!AgentIntegration.isInstalled(settingsURL: url, executable: executable))
        #expect(try AgentIntegration.install(settingsURL: url, executable: executable))
        #expect(AgentIntegration.isInstalled(settingsURL: url, executable: executable))
        #expect(try AgentIntegration.uninstall(settingsURL: url, executable: executable))
        #expect(!AgentIntegration.isInstalled(settingsURL: url, executable: executable))

        let after = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        #expect(after?["permissions"] != nil)
        #expect(after?["hooks"] == nil)
    }

    @Test("Installing twice reports the second attempt as no change")
    func installIsIdempotent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")

        #expect(try AgentIntegration.install(settingsURL: url, executable: executable))
        #expect(try AgentIntegration.install(settingsURL: url, executable: executable) == false)
    }

    @Test("Uninstalling when nothing is installed is not an error")
    func uninstallWhenAbsent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        #expect(try AgentIntegration.uninstall(settingsURL: url, executable: executable) == false)
    }

    /// Installing into a directory that does not exist yet is the common case:
    /// a user who has never configured an agent has no `.claude` folder.
    @Test("A missing settings directory is created")
    func createsMissingDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("nested/.claude/settings.json")

        #expect(try AgentIntegration.install(settingsURL: url, executable: executable))
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    // MARK: - Refusals

    /// The hook stores an absolute path to `down`; with no CLI there is nothing
    /// to point at, and writing a hook that cannot run would be worse than
    /// refusing.
    @Test("Installing without the command line tool refuses")
    func installRequiresTheCommandLineTool() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")

        #expect(throws: AgentIntegration.Failure.commandLineToolMissing) {
            _ = try AgentIntegration.install(settingsURL: url, executable: nil)
        }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(!AgentIntegration.isInstalled(settingsURL: url, executable: nil))
    }

    /// Treating unreadable JSON as an empty object would silently replace a
    /// config the user spent time on with one containing nothing but our hook.
    @Test("A settings file that is not valid JSON is never overwritten")
    func refusesToClobberUnparseableSettings() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        let damaged = "{ this is not json"
        try Data(damaged.utf8).write(to: url)

        #expect(throws: (any Error).self) {
            _ = try AgentIntegration.install(settingsURL: url, executable: executable)
        }
        #expect(String(data: try Data(contentsOf: url), encoding: .utf8) == damaged)
    }

    @Test("An empty settings file is treated as absent, not as damage")
    func emptyFileInstallsCleanly() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("settings.json")
        try Data().write(to: url)

        #expect(try AgentIntegration.install(settingsURL: url, executable: executable))
        #expect(AgentIntegration.isInstalled(settingsURL: url, executable: executable))
    }

    // MARK: - Setup panel

    /// Every other step is a registration the app makes on its own behalf.  The
    /// agent hook edits another tool's configuration file, so it is the one step
    /// that has to be asked for rather than opted out of.
    @Test("The agent step is the only one that does not start ticked")
    func agentStepIsNotPreselected() {
        #expect(!SetupWindowController.Step.agentIntegration.isPreselected)
        for step in SetupWindowController.Step.allCases where step != .agentIntegration {
            #expect(step.isPreselected)
        }
    }

    @Test("Every setup step describes what it will do")
    func everyStepExplainsItself() {
        for step in SetupWindowController.Step.allCases {
            #expect(!step.title.isEmpty)
            #expect(!step.detail.isEmpty)
            #expect(!step.icon.isEmpty)
        }
    }

    /// The detail line is where the user learns the hook touches a file outside
    /// this app, which is the fact that makes the step worth declining.
    @Test("The agent step names the file it edits")
    func agentStepNamesTheFileItEdits() {
        #expect(SetupWindowController.Step.agentIntegration.detail.contains("settings.json"))
    }
}
