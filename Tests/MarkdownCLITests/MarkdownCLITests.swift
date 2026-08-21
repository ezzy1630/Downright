import Foundation
import Testing
@testable import drdownright

struct MarkdownCLITests {
    @Test func defaultActionIsOpen() throws {
        let action = try MarkdownCLI.parse(["README.md"])
        #expect(action == .open(MarkdownCLI.OpenOptions(), paths: ["README.md"]))
    }

    @Test func commandsParseTheirOptions() throws {
        #expect(try MarkdownCLI.parse(["read", "--json", "-"]) == .read(json: true, paths: ["-"]))
        #expect(try MarkdownCLI.parse(["export", "-f", "html", "-o", "out.html", "doc.md"]) == .export(format: .html, output: "out.html", paths: ["doc.md"]))
        #expect(try MarkdownCLI.parse(["check", "--json", "--target", "github", "doc.md"])
            == .check(json: true, target: .gitHub, paths: ["doc.md"]))
        #expect(try MarkdownCLI.parse(["outline", "--json", "doc.md"])
            == .outline(json: true, paths: ["doc.md"]))

        var openOptions = MarkdownCLI.OpenOptions()
        openOptions.line = 42
        openOptions.review = true
        openOptions.edit = true
        #expect(try MarkdownCLI.parse(["open", "--line", "42", "--review", "doc.md"])
            == .open(openOptions, paths: ["doc.md"]))
        var revealOptions = MarkdownCLI.OpenOptions()
        revealOptions.reveal = true
        #expect(try MarkdownCLI.parse(["open", "--reveal", "doc.md"])
            == .open(revealOptions, paths: ["doc.md"]))
        #expect(try MarkdownCLI.parse(["doctor", "--json"]) == .doctor(json: true, appPath: nil))
        #expect(try MarkdownCLI.parse(["doctor", "--app", "/tmp/Downright.app"]) == .doctor(json: false, appPath: "/tmp/Downright.app"))
    }

    @Test func badArgumentsHaveActionableErrors() {
        #expect(throws: MarkdownCLI.ParseError.unknownOption("--wat")) {
            try MarkdownCLI.parse(["read", "--wat"])
        }
        #expect(throws: MarkdownCLI.ParseError.missingValue("-o")) {
            try MarkdownCLI.parse(["export", "-o"])
        }
        #expect(throws: MarkdownCLI.ParseError.missingValue("--line")) {
            try MarkdownCLI.parse(["open", "--line"])
        }
        #expect(throws: MarkdownCLI.ParseError.invalidLine("0")) {
            try MarkdownCLI.parse(["open", "--line", "0"])
        }
        #expect(throws: MarkdownCLI.ParseError.missingValue("--app")) {
            try MarkdownCLI.parse(["doctor", "--app"])
        }
    }

    @Test func htmlExportIsSelfContainedAndEscaped() {
        let html = MarkdownCLI.html(for: "# Hello <world>\n\n- [x] done\n\n`code`")
        #expect(html.contains("<h1>Hello &lt;world&gt;</h1>"))
        #expect(html.contains("<input type=\"checkbox\" disabled checked>"))
        #expect(html.contains("<code>code</code>"))
        #expect(!html.contains("http://") && !html.contains("https://"))
    }

    /// Regression: the writer joined paragraphs, code lines, and body blocks
    /// with the two characters `\` + `n` instead of a newline, so every
    /// multi-line paragraph and every code block exported as one line of text
    /// with visible `\n` garbage in it.
    @Test func htmlExportUsesRealNewlines() {
        let html = MarkdownCLI.html(for: "line one\nline two\n\n```swift\nlet a = 1\nlet b = 2\n```\n")
        #expect(html.contains("<p>line one<br>\nline two</p>"))
        #expect(html.contains(">let a = 1\nlet b = 2</code>"))
        #expect(!html.contains("\\n"), "no literal backslash-n may appear in the output")
    }

    @Test func htmlExportMakesUnsafeLinksInert() {
        let html = MarkdownCLI.html(for: """
        [relative](guide.md) [anchor](#part) [web](https://example.com) [mail](mailto:a@example.com)
        [script](JaVaScRiPt:alert(1)) [data](data:text/html,bad) [editor](vscode://file/tmp/a)
        """)

        #expect(html.contains("href=\"guide.md\""))
        #expect(html.contains("href=\"#part\""))
        #expect(html.contains("href=\"https://example.com\""))
        #expect(html.contains("href=\"mailto:a@example.com\""))
        #expect(!html.lowercased().contains("href=\"javascript:"))
        #expect(!html.lowercased().contains("href=\"data:"))
        #expect(!html.lowercased().contains("href=\"vscode:"))
    }

    @Test func htmlExportRejectsObfuscatedSchemes() {
        let html = MarkdownCLI.html(for: "[bad](javascript/foo:alert(1))")
        #expect(!html.contains("href=\"javascript/foo:alert(1)\""))
    }

    @Test func htmlExportNeutralizesLineBreakObfuscatedSchemes() {
        // Browsers strip tab, LF, and CR from anywhere inside a URL before
        // parsing it, so every destination below would reach the browser as a
        // live scheme unless the exporter normalizes before analyzing.
        let html = MarkdownCLI.html(for: """
        [tab](java\tscript:alert(1)) [newline](ja\nscript:alert(1)) [cr](j\rascript:alert(2))
        ![pixel](http\t://tracking.example/x.png)
        """)

        #expect(!html.lowercased().contains("href=\"javascript:"))
        #expect(!html.contains("\t"), "no raw tab may survive into an emitted URL")
        #expect(!html.contains("\r"), "no raw carriage return may survive into an emitted URL")
        #expect(!html.contains("<img "), "an obfuscated remote image source must not become a live img")

        let safe = MarkdownCLI.html(for: "[web](https://example.com) [rel](./a.md)")
        #expect(safe.contains("href=\"https://example.com\""))
        #expect(safe.contains("href=\"./a.md\""))
    }

    @Test func checkAndOutlineSupportDoubleDash() throws {
        #expect(try MarkdownCLI.parse(["check", "--", "-notes.md"])
            == .check(json: false, target: nil, paths: ["-notes.md"]))
        #expect(try MarkdownCLI.parse(["outline", "--", "-draft.md"])
            == .outline(json: false, paths: ["-draft.md"]))
    }

    @Test func outlineCalculatesLinesOnCRAndCRLF() {
        let cr = "Line 1\r# Heading 1\rLine 3\r## Heading 2\r"
        let outlineCR = MarkdownCLI.outline(for: cr)
        #expect(outlineCR.count == 2)
        #expect(outlineCR[0].line == 2)
        #expect(outlineCR[1].line == 4)

        let crlf = "Line 1\r\n# Heading 1\r\nLine 3\r\n## Heading 2\r\n"
        let outlineCRLF = MarkdownCLI.outline(for: crlf)
        #expect(outlineCRLF.count == 2)
        #expect(outlineCRLF[0].line == 2)
        #expect(outlineCRLF[1].line == 4)
    }

    @Test func htmlExportNeverRetainsExternalImageSources() {
        let html = MarkdownCLI.html(for: """
        ![relative](images/photo.png)
        ![web](https://tracker.example/pixel.png)
        ![data](data:image/svg+xml,bad)
        ![file](file:///private/etc/passwd)
        ![protocol](//tracker.example/pixel.png)
        ![absolute](/private/etc/passwd)
        ![traversal](../private/photo.png)
        ![encoded](%2e%2e/private/photo.png)
        """)

        #expect(html.contains("src=\"images/photo.png\""))
        #expect(!html.contains("src=\"https://"))
        #expect(!html.contains("src=\"data:"))
        #expect(!html.contains("src=\"file:"))
        #expect(!html.contains("src=\"//"))
        #expect(!html.contains("src=\"/private"))
        #expect(!html.contains("src=\"../"))
        #expect(!html.contains("src=\"%2e%2e"))
        #expect(html.components(separatedBy: "class=\"missing-image\"").count - 1 == 7)
    }

    @Test func settingsLoaderDistinguishesAbsentFromInvalidFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("down-settings-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let missing = root.appendingPathComponent("missing.json")
        #expect(try MarkdownCLI.loadSettings(at: missing).isEmpty)

        let malformed = root.appendingPathComponent("malformed.json")
        let malformedBytes = Data("{ not json".utf8)
        try malformedBytes.write(to: malformed)
        #expect(throws: MarkdownCLI.SettingsFileError.self) {
            try MarkdownCLI.loadSettings(at: malformed)
        }
        #expect(try Data(contentsOf: malformed) == malformedBytes)

        let array = root.appendingPathComponent("array.json")
        let arrayBytes = Data("[]".utf8)
        try arrayBytes.write(to: array)
        #expect(throws: MarkdownCLI.SettingsFileError.self) {
            try MarkdownCLI.loadSettings(at: array)
        }
        #expect(try Data(contentsOf: array) == arrayBytes)
    }

    @Test func settingsLoaderCapsReadsWithoutChangingTheFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("down-settings-large-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("settings.json")
        let bytes = Data(repeating: 0x20, count: 65)
        try bytes.write(to: url)

        #expect(throws: MarkdownCLI.SettingsFileError.self) {
            try MarkdownCLI.loadSettings(at: url, maximumBytes: 64)
        }
        #expect(try Data(contentsOf: url) == bytes)
    }

    @Test func settingsLoaderRejectsUnreadableFileKinds() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("down-settings-kind-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        #expect(throws: MarkdownCLI.SettingsFileError.self) {
            try MarkdownCLI.loadSettings(at: root)
        }
    }

    @Test func hookInstallFailsWithoutChangingMalformedSettings() throws {
        let original = Data("{ user-owned and damaged".utf8)
        try assertHookInstallRefuses(original)
    }

    @Test func hookInstallFailsWithoutChangingOversizedSettings() throws {
        let original = Data(repeating: 0x20, count: MarkdownCLI.maximumSettingsBytes + 1)
        try assertHookInstallRefuses(original)
    }

    @Test func hookInstallFailsWithoutChangingUnreadableSettings() throws {
        let root = try hookTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent(".claude/settings.json")
        let original = Data(#"{"permissions":{"allow":[]}}"#.utf8)
        try original.write(to: settings)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: settings.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        }

        let status = try runHookInstall(in: root)
        #expect(status != 0)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: settings.path)
        #expect(try Data(contentsOf: settings) == original)
    }

    @Test func healthFindingsAreDeterministic() {
        let markdown = "[broken](missing.md)\n"
        let first = MarkdownCLI.diagnostics(for: markdown)
        let second = MarkdownCLI.diagnostics(for: markdown)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test func outlineAndTargetChecksUseCoreParser() {
        let markdown = "# First\n\n## Child\n\n[^1]: note\n"
        #expect(MarkdownCLI.outline(for: markdown).map(\.title) == ["First", "Child"])
        #expect(MarkdownCLI.compatibilityDiagnostics(for: markdown, target: .commonMark)
            .contains { $0.capability == .footnotes })
        #expect(MarkdownCLI.renderTarget(named: "CommonMark") == .commonMark)
    }

    @Test func doctorPluginParsingOnlyAcceptsOurEnabledRegistration() {
        #expect(DownDoctor.pluginIsEnabled(
            listing: "+ com.ezzy.downright.quicklook(1.0)\n- com.other.quicklook(1.0)",
            identifier: "com.ezzy.downright.quicklook"
        ))
        #expect(!DownDoctor.pluginIsEnabled(
            listing: "- com.ezzy.downright.quicklook(1.0)",
            identifier: "com.ezzy.downright.quicklook"
        ))
        #expect(!DownDoctor.pluginIsEnabled(
            listing: "+ com.other.quicklook(1.0)",
            identifier: "com.ezzy.downright.quicklook"
        ))
    }

    @Test func folderCheckSkipsBuildTrees() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("down-check-folder-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".build", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "# Keep\n\n[missing](does-not-exist.md)\n".write(
            to: root.appendingPathComponent("keep.md"), atomically: true, encoding: .utf8
        )
        try "# Ignore\n\n[missing](also-missing.md)\n".write(
            to: root.appendingPathComponent(".build/ignore.md"), atomically: true, encoding: .utf8
        )

        let output = try runDown(["check", "--json", root.path], in: root)

        #expect(output.status == 1)
        #expect(output.stdout.contains("keep.md"))
        #expect(!output.stdout.contains("ignore.md"))
    }

    private func assertHookInstallRefuses(_ original: Data) throws {
        let root = try hookTestRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = root.appendingPathComponent(".claude/settings.json")
        try original.write(to: settings)

        #expect(try runHookInstall(in: root) != 0)
        #expect(try Data(contentsOf: settings) == original)
    }

    private func hookTestRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("down-hook-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude", isDirectory: true),
            withIntermediateDirectories: true
        )
        return root
    }

    private func runHookInstall(in directory: URL) throws -> Int32 {
        try runDown(["hook", "--install", "--scope", "project"], in: directory).status
    }

    private func runDown(_ arguments: [String], in directory: URL) throws -> (
        status: Int32, stdout: String
    ) {
        let process = Process()
        process.executableURL = try downExecutable()
        process.arguments = arguments
        process.currentDirectoryURL = directory
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    private func downExecutable() throws -> URL {
        let bundleStarts = ([
            URL(fileURLWithPath: CommandLine.arguments[0]),
            Bundle.main.bundleURL,
            Bundle.main.executableURL,
        ] as [URL?]).compactMap { $0 }
        let argumentStarts = CommandLine.arguments
            .filter { $0.hasPrefix("/") }
            .map { URL(fileURLWithPath: $0) }
        let starts = bundleStarts + argumentStarts
        for start in starts {
            var directory = start.deletingLastPathComponent()
            for _ in 0..<10 {
                let candidate = directory.appendingPathComponent("down")
                if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
                directory.deleteLastPathComponent()
            }
        }
        throw CocoaError(.fileNoSuchFile)
    }
}
