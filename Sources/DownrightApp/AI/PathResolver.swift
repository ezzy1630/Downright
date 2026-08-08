import AppKit
import Foundation
import MarkdownCore

/// Live path resolution (§8.4).
///
/// Agent docs are dense with file references, and the interesting case is not
/// the convenience of clicking one — it is the *other* case.  A completion
/// summary that claims to have touched `src/auth/session.ts` gets a dotted red
/// underline when that file isn't there.  That makes the document a trust
/// instrument rather than a convenience, which is why the miss is styled at
/// least as deliberately as the hit.
///
/// Requires being unsandboxed (§3.4): resolution walks up to the git root and
/// stats arbitrary paths with no file-picker ritual.
final class PathResolver {
    struct Resolution {
        var url: URL?
        var exists: Bool
        var isDirectory: Bool
        var line: Int?
    }

    /// Directory of the document being read.
    private let documentDirectory: URL
    /// Nearest enclosing git root, if any — the second search base.
    private let gitRoot: URL?
    private var cache: [String: Resolution] = [:]
    private let lock = NSLock()

    init(documentURL: URL?) {
        let directory = documentURL?.deletingLastPathComponent()
            ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        self.documentDirectory = directory
        self.gitRoot = PathResolver.findGitRoot(from: directory)
    }

    /// Invalidate after an external write — a file the agent just created
    /// should stop being underlined in red without reopening the document.
    func invalidate() {
        lock.lock(); cache.removeAll(); lock.unlock()
    }

    func resolve(_ token: PathToken) -> Resolution {
        lock.lock()
        if let hit = cache[token.rawPath] {
            lock.unlock()
            return Resolution(url: hit.url, exists: hit.exists, isDirectory: hit.isDirectory, line: token.line)
        }
        lock.unlock()

        let resolution = computeResolution(for: token)
        lock.lock(); cache[token.rawPath] = resolution; lock.unlock()
        return resolution
    }

    private func computeResolution(for token: PathToken) -> Resolution {
        let raw = token.rawPath
        var candidates: [URL] = []

        if raw.hasPrefix("/") {
            candidates.append(URL(fileURLWithPath: raw))
        } else if raw.hasPrefix("~") {
            candidates.append(URL(fileURLWithPath: (raw as NSString).expandingTildeInPath))
        } else {
            candidates.append(documentDirectory.appendingPathComponent(raw))
            if let gitRoot {
                candidates.append(gitRoot.appendingPathComponent(raw))
                // Agents habitually write paths relative to the repo root even
                // in a doc that lives in `docs/`, so also try the parent.
                candidates.append(gitRoot.appendingPathComponent("src").appendingPathComponent(raw))
            }
            candidates.append(documentDirectory.deletingLastPathComponent().appendingPathComponent(raw))
        }

        let fm = FileManager.default
        for candidate in candidates {
            var isDirectory: ObjCBool = false
            let standardized = candidate.standardizedFileURL
            if fm.fileExists(atPath: standardized.path, isDirectory: &isDirectory) {
                return Resolution(url: standardized, exists: true, isDirectory: isDirectory.boolValue, line: token.line)
            }
        }
        return Resolution(url: candidates.first?.standardizedFileURL, exists: false, isDirectory: false, line: token.line)
    }

    static func findGitRoot(from directory: URL) -> URL? {
        var current = directory.standardizedFileURL
        let fm = FileManager.default
        for _ in 0..<40 {
            if fm.fileExists(atPath: current.appendingPathComponent(".git").path) { return current }
            let parent = current.deletingLastPathComponent()
            if parent.path == current.path { break }
            current = parent
        }
        return nil
    }
}

// MARK: - Opening in an editor

/// The editors §8.4 names, plus `$EDITOR` as the escape hatch.
enum ExternalEditor: String, CaseIterable, Codable {
    case vscode, cursor, zed, xcode, sublime, bbedit, nova, systemDefault, envEditor

    var title: String {
        switch self {
        case .vscode: return "Visual Studio Code"
        case .cursor: return "Cursor"
        case .zed: return "Zed"
        case .xcode: return "Xcode"
        case .sublime: return "Sublime Text"
        case .bbedit: return "BBEdit"
        case .nova: return "Nova"
        case .systemDefault: return "System Default"
        case .envEditor: return "$EDITOR (Terminal)"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .vscode: return "com.microsoft.VSCode"
        case .cursor: return "com.todesktop.230313mzl4w4u92"
        case .zed: return "dev.zed.Zed"
        case .xcode: return "com.apple.dt.Xcode"
        case .sublime: return "com.sublimetext.4"
        case .bbedit: return "com.barebones.bbedit"
        case .nova: return "com.panic.Nova"
        case .systemDefault, .envEditor: return nil
        }
    }

    var isInstalled: Bool {
        guard let id = bundleIdentifier else { return true }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil
    }

    /// Editors that can be handed a line number via their URL scheme.
    ///
    /// The path has to be percent-encoded before it goes into the string.  A
    /// literal `#` or `?` in a directory name is a fragment or query delimiter
    /// to the URL parser, so the path silently truncates there and the editor
    /// opens the wrong file — or none.  A literal `%` or space can fail the
    /// parse outright, and `open(_:line:)` then falls back to
    /// `NSWorkspace.open(file)`, which loses the line number.  Assigning
    /// `URLComponents.path` encodes exactly the characters a path may not
    /// contain and leaves `/` and `:` alone, so the trailing `:42` the editors
    /// parse survives.
    func url(for file: URL, line: Int?) -> URL? {
        let scheme: String
        switch self {
        case .vscode: scheme = "vscode"
        case .cursor: scheme = "cursor"
        case .zed: scheme = "zed"
        default: return nil
        }
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = file.path + (line.map { ":\($0)" } ?? "")
        return components.url
    }

    func open(_ file: URL, line: Int?) {
        if let schemeURL = url(for: file, line: line) {
            NSWorkspace.shared.open(schemeURL)
            return
        }

        switch self {
        case .xcode:
            runTool("/usr/bin/xed", arguments: line.map { ["-l", String($0), file.path] } ?? [file.path])
        case .sublime:
            runTool("/usr/local/bin/subl", arguments: ["\(file.path)\(line.map { ":\($0)" } ?? "")"])
        case .bbedit:
            runTool("/usr/local/bin/bbedit", arguments: line.map { ["+\($0)", file.path] } ?? [file.path])
        case .nova:
            NSWorkspace.shared.open(file)
        case .envEditor:
            openInTerminalEditor(file, line: line)
        case .systemDefault:
            NSWorkspace.shared.open(file)
        case .vscode, .cursor, .zed:
            NSWorkspace.shared.open(file)
        }
    }

    private func runTool(_ path: String, arguments: [String]) {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            NSWorkspace.shared.open(URL(fileURLWithPath: arguments.last ?? "/"))
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        try? process.run()
    }

    private func openInTerminalEditor(_ file: URL, line: Int?) {
        // `$EDITOR` lands in the middle of a `do script` line, so it is a shell
        // vector the moment it contains a metacharacter.  Only a bare path
        // token of letters, digits, `/`, `.`, `-`, `_`, and `+` is accepted;
        // anything else — spaces, `;`, `$(`, quotes, `~`, `$` — falls back to
        // `vi`.  Quoting a richer value here would only defer the injection
        // question to the shell, so we refuse instead.
        let editor = ProcessInfo.processInfo.environment["EDITOR"].flatMap(sanitizedEditor) ?? "vi"
        let lineArg = line.map { "+\($0) " } ?? ""
        let command = "\(editor) \(lineArg)\(shellQuoted(file.path))"
        let script = """
        tell application "Terminal"
            activate
            do script "\(command.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
    }

    /// The characters a trusted `$EDITOR` token may contain.  A path like
    /// `/usr/bin/vi` or a bare `code` passes; `"/Applications/… with spaces"`,
    /// `sh -c '…'`, and every other shell construct is rejected.
    private static let editorPathCharacters = CharacterSet(
        charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789/._+-"
    )

    private func sanitizedEditor(_ raw: String) -> String? {
        guard !raw.isEmpty,
              raw.unicodeScalars.allSatisfy({ Self.editorPathCharacters.contains($0) })
        else { return nil }
        return raw
    }

    private func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// First installed editor, preferring the ones people actually run agents
    /// next to.
    static var bestAvailable: ExternalEditor {
        for candidate in [ExternalEditor.cursor, .vscode, .zed, .sublime, .nova, .bbedit, .xcode]
        where candidate.isInstalled {
            return candidate
        }
        return .systemDefault
    }
}
