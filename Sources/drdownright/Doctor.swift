import AppKit
import Foundation
import UniformTypeIdentifiers

/// A diagnostic result that is safe to print in a terminal or serialize for a
/// support report. The doctor never repairs the machine; it only reports what
/// is installed and which integration contract is missing.
public enum DoctorStatus: String, Codable, Sendable {
    case pass
    case warning
    case failure
    case unavailable
}

public struct DoctorCheck: Codable, Equatable, Sendable {
    public let id: String
    public let status: DoctorStatus
    public let message: String
    public let details: [String]

    public init(id: String, status: DoctorStatus, message: String, details: [String] = []) {
        self.id = id
        self.status = status
        self.message = message
        self.details = details
    }
}

public struct DoctorReport: Codable, Equatable, Sendable {
    public let appPath: String?
    public let version: String?
    public let checks: [DoctorCheck]

    public var hasFailures: Bool {
        checks.contains { $0.status == .failure }
    }

    public init(appPath: String?, version: String?, checks: [DoctorCheck]) {
        self.appPath = appPath
        self.version = version
        self.checks = checks
    }
}

public enum DownDoctor {
    private struct CommandResult {
        let status: Int32
        let output: String
    }

    private static let appName = "Downright.app"
    private static let bundleIdentifier = "com.ezzy.downright"
    private static let previewIdentifier = "com.ezzy.downright.quicklook"
    private static let thumbnailIdentifier = "com.ezzy.downright.thumbnail"
    private static let markdownExtensions = ["md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd"]
    private static let commandDirectories = [
        "/usr/local/bin",
        "/opt/homebrew/bin",
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
    ]

    /// Runs every diagnostic without making a repair or asking for a password.
    public static func run(appPath: String? = nil) -> DoctorReport {
        let app = resolveApp(explicitPath: appPath)
        guard let app else {
            return DoctorReport(
                appPath: nil,
                version: nil,
                checks: [DoctorCheck(
                    id: "installed-app",
                    status: .failure,
                    message: "Downright.app was not found in /Applications, ~/Applications, or the current bundle.",
                    details: ["Install the signed app, then run down doctor again."]
                )]
            )
        }

        let info = infoDictionary(for: app)
        let version = info?["CFBundleShortVersionString"] as? String
        var checks: [DoctorCheck] = []

        checks.append(DoctorCheck(
            id: "installed-app",
            status: .pass,
            message: "Found \(app.path)",
            details: version.map { ["Version \($0)"] } ?? []
        ))
        checks.append(bundleCheck(app: app, info: info))
        checks.append(applicationLocationCheck(app: app))
        checks.append(signatureCheck(app: app))
        checks.append(gatekeeperCheck(app: app))
        checks.append(notarizationCheck(app: app))
        checks.append(commandLineCheck(app: app))
        checks.append(pluginCheck(app: app, name: "Quick Look preview", identifier: previewIdentifier, bundleName: "DownrightQL.appex"))
        checks.append(pluginCheck(app: app, name: "Finder thumbnail", identifier: thumbnailIdentifier, bundleName: "DownrightThumb.appex"))
        checks.append(defaultAssociationCheck(app: app))
        checks.append(utiCheck(info: info))
        checks.append(updateChannelCheck(info: info))

        return DoctorReport(appPath: app.path, version: version, checks: checks)
    }

    public static func json(_ report: DoctorReport) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try encoder.encode(report), as: UTF8.self)
    }

    public static func humanReadable(_ report: DoctorReport) -> String {
        var lines = ["Downright doctor"]
        if let appPath = report.appPath { lines.append("App: \(appPath)") }
        if let version = report.version { lines.append("Version: \(version)") }
        lines.append("")
        for check in report.checks {
            lines.append("[\(check.status.label)] \(check.id): \(check.message)")
            lines.append(contentsOf: check.details.map { "  - \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    /// Kept public so the parser semantics can be pinned without invoking
    /// LaunchServices or pluginkit in a test process.
    public static func pluginIsEnabled(listing: String, identifier: String) -> Bool {
        guard let line = listing.split(separator: "\n").first(where: { $0.contains(identifier) }) else {
            return false
        }
        return !line.trimmingCharacters(in: .whitespaces).hasPrefix("-")
    }

    private static func resolveApp(explicitPath: String?) -> URL? {
        let currentBundle = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .standardizedFileURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let candidates = [
            explicitPath.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) },
            URL(fileURLWithPath: "/Applications/\(appName)"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/\(appName)"),
            currentBundle.pathExtension == "app" ? currentBundle : nil,
        ].compactMap { $0 }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func infoDictionary(for app: URL) -> [String: Any]? {
        let infoURL = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let info = object as? [String: Any] else {
            return nil
        }
        return info
    }

    private static func bundleCheck(app: URL, info: [String: Any]?) -> DoctorCheck {
        guard let info else {
            return DoctorCheck(id: "bundle", status: .failure, message: "Info.plist could not be read.")
        }
        let identifier = info["CFBundleIdentifier"] as? String
        let executable = app.appendingPathComponent("Contents/MacOS/Downright")
        guard identifier == bundleIdentifier else {
            return DoctorCheck(id: "bundle", status: .failure, message: "Bundle identifier is \(identifier ?? "missing"), expected \(bundleIdentifier).")
        }
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            return DoctorCheck(id: "bundle", status: .failure, message: "The host executable is missing or not executable.")
        }
        return DoctorCheck(id: "bundle", status: .pass, message: "Bundle identity and host executable are present.")
    }

    private static func applicationLocationCheck(app: URL) -> DoctorCheck {
        let path = app.resolvingSymlinksInPath().path
        let homeApplications = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path + "/"
        if path.hasPrefix("/Applications/") || path.hasPrefix(homeApplications) {
            return DoctorCheck(id: "application-location", status: .pass, message: "Bundle is in an Applications folder.")
        }
        if path.contains("/AppTranslocation/") {
            return DoctorCheck(id: "application-location", status: .failure, message: "Bundle is running from App Translocation; Quick Look and CLI registration will not persist.", details: ["Move Downright.app to /Applications and run doctor again."])
        }
        return DoctorCheck(id: "application-location", status: .warning, message: "Bundle is outside an Applications folder.", details: ["A development bundle can work, but system integrations may not register permanently."])
    }

    private static func signatureCheck(app: URL) -> DoctorCheck {
        guard let result = run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", app.path]) else {
            return DoctorCheck(id: "code-signature", status: .unavailable, message: "codesign is not available on this machine.")
        }
        return result.status == 0
            ? DoctorCheck(id: "code-signature", status: .pass, message: "Code signature verifies.")
            : DoctorCheck(id: "code-signature", status: .failure, message: "Code signature verification failed.", details: [result.output.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty })
    }

    private static func gatekeeperCheck(app: URL) -> DoctorCheck {
        guard let result = run("/usr/sbin/spctl", ["--assess", "--type", "execute", "--verbose=4", app.path]) else {
            return DoctorCheck(id: "gatekeeper", status: .unavailable, message: "spctl is not available on this machine.")
        }
        return result.status == 0
            ? DoctorCheck(id: "gatekeeper", status: .pass, message: "Gatekeeper accepts the app.")
            : DoctorCheck(id: "gatekeeper", status: .warning, message: "Gatekeeper did not accept this bundle.", details: [result.output.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty })
    }

    private static func notarizationCheck(app: URL) -> DoctorCheck {
        guard let result = run("/usr/bin/xcrun", ["stapler", "validate", app.path]) else {
            return DoctorCheck(id: "notarization", status: .unavailable, message: "xcrun stapler is not available on this machine.")
        }
        return result.status == 0
            ? DoctorCheck(id: "notarization", status: .pass, message: "Notarization ticket validates.")
            : DoctorCheck(id: "notarization", status: .warning, message: "No valid stapled notarization ticket was found.", details: ["This is expected for an unsigned development bundle.", result.output.trimmingCharacters(in: .whitespacesAndNewlines)].filter { !$0.isEmpty })
    }

    private static func commandLineCheck(app: URL) -> DoctorCheck {
        let expected = app.appendingPathComponent("Contents/MacOS/down").resolvingSymlinksInPath().path
        var matches: [String] = []
        var foreign: [String] = []
        for directory in commandDirectories {
            for name in ["down", "md"] {
                let link = URL(fileURLWithPath: directory).appendingPathComponent(name)
                guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: link.path) else { continue }
                let resolved = URL(fileURLWithPath: destination, relativeTo: link.deletingLastPathComponent())
                    .resolvingSymlinksInPath().path
                if resolved == expected { matches.append(link.path) } else { foreign.append(link.path) }
            }
        }
        if matches.isEmpty {
            return DoctorCheck(id: "cli-path", status: .warning, message: "No down/md alias points to this app.", details: foreign.map { "Foreign or stale alias: \($0)" } + ["Install the CLI from Downright's setup panel to repair it."])
        }
        return DoctorCheck(id: "cli-path", status: .pass, message: "CLI aliases point to this app.", details: matches)
    }

    private static func pluginCheck(app: URL, name: String, identifier: String, bundleName: String) -> DoctorCheck {
        let path = app.appendingPathComponent("Contents/PlugIns/\(bundleName)")
        guard FileManager.default.fileExists(atPath: path.path) else {
            return DoctorCheck(id: identifier, status: .warning, message: "\(name) extension is not bundled.", details: ["The SwiftPM development bundle cannot provide the .appex integration."])
        }
        guard let result = run("/usr/bin/pluginkit", ["-m", "-v", "-i", identifier]) else {
            return DoctorCheck(id: identifier, status: .unavailable, message: "pluginkit is not available on this machine.")
        }
        guard pluginIsEnabled(listing: result.output, identifier: identifier) else {
            return DoctorCheck(id: identifier, status: .warning, message: "\(name) is bundled but not enabled by pluginkit.", details: ["Run the app's setup integration or reopen the signed app in /Applications."])
        }
        return DoctorCheck(id: identifier, status: .pass, message: "\(name) is bundled and enabled.")
    }

    private static func defaultAssociationCheck(app: URL) -> DoctorCheck {
        guard let markdown = UTType(filenameExtension: "md"),
              let handler = NSWorkspace.shared.urlForApplication(toOpen: markdown) else {
            return DoctorCheck(id: "default-markdown-app", status: .warning, message: "macOS has no default application for .md files.")
        }
        let expected = app.resolvingSymlinksInPath().standardizedFileURL
        let actual = handler.resolvingSymlinksInPath().standardizedFileURL
        if actual == expected {
            return DoctorCheck(id: "default-markdown-app", status: .pass, message: "Downright is the default .md application.")
        }
        return DoctorCheck(id: "default-markdown-app", status: .warning, message: "macOS currently opens .md files with \(handler.lastPathComponent).", details: ["The app still supports Open With; choose Downright if you want it as the default."])
    }

    private static func utiCheck(info: [String: Any]?) -> DoctorCheck {
        let documentTypes = info?["CFBundleDocumentTypes"] as? [[String: Any]] ?? []
        let extensions = Set(documentTypes
            .flatMap { $0["CFBundleTypeExtensions"] as? [String] ?? [] }
            .map { $0.lowercased() })
        let missing = markdownExtensions.filter { !extensions.contains($0) }
        if missing.isEmpty {
            return DoctorCheck(id: "markdown-types", status: .pass, message: "All advertised Markdown extensions are declared.", details: markdownExtensions.map { ".\($0)" })
        }
        return DoctorCheck(id: "markdown-types", status: .failure, message: "Bundle document types are missing advertised extensions.", details: missing.map { ".\($0)" })
    }

    private static func updateChannelCheck(info: [String: Any]?) -> DoctorCheck {
        let feed = info?["SUFeedURL"] as? String
        let key = info?["SUPublicEDKey"] as? String
        guard let feed, !feed.isEmpty else {
            return DoctorCheck(id: "update-channel", status: .warning, message: "Sparkle update feed is not configured in this bundle.")
        }
        guard let key, !key.isEmpty, !key.contains("PLACEHOLDER") else {
            return DoctorCheck(id: "update-channel", status: .warning, message: "Sparkle feed exists but its EdDSA public key is still a placeholder.", details: [feed])
        }
        return DoctorCheck(id: "update-channel", status: .pass, message: "Sparkle feed and public key are configured.", details: [feed])
    }

    private static func run(_ launchPath: String, _ arguments: [String]) -> CommandResult? {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        guard (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CommandResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

private extension DoctorStatus {
    var label: String {
        switch self {
        case .pass: return "PASS"
        case .warning: return "WARN"
        case .failure: return "FAIL"
        case .unavailable: return "N/A"
        }
    }
}
