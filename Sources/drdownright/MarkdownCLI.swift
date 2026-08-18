import Foundation
import MarkdownCore

/// The command-line surface shared by `down` and the `md` alias.
///
/// Parsing and pure document operations live in a library so they can be
/// exercised without launching an app or touching the user's files.
public enum MarkdownCLI {
    public static let version = "1.0.16"

    /// Settings are user-owned configuration. Bound reads so a special file or
    /// unexpectedly large document cannot make `down hook` consume unbounded
    /// memory, and never turn a read failure into an empty configuration.
    public static let maximumSettingsBytes = 1_048_576

    public enum SettingsFileError: Error, CustomStringConvertible, LocalizedError, Sendable {
        case unreadable(path: String, reason: String)
        case tooLarge(path: String, maximumBytes: Int)
        case invalidJSON(path: String)

        public var description: String {
            switch self {
            case .unreadable(let path, let reason):
                return "cannot read \(path): \(reason)"
            case .tooLarge(let path, let maximumBytes):
                return "cannot read \(path): settings exceed \(maximumBytes) bytes"
            case .invalidJSON(let path):
                return "cannot read \(path): settings must be a JSON object"
            }
        }

        public var errorDescription: String? { description }
    }

    public enum Action: Equatable, Sendable {
        case open(OpenOptions, paths: [String])
        case read(json: Bool, paths: [String])
        case export(format: ExportFormat, output: String?, paths: [String])
        case check(json: Bool, target: BuiltInRenderTarget?, paths: [String])
        case outline(json: Bool, paths: [String])
        case doctor(json: Bool, appPath: String?)
        case notify(NotifyOptions)
        case watch(WatchOptions, paths: [String])
        case hook(HookOptions)
        case help
        case version
    }

    public struct OpenOptions: Equatable, Sendable {
        public var newWindow = false
        public var background = false
        public var wait = false
        public var edit = false
        public var line: Int? = nil
        public var reveal = false
        public var review = false

        public init() {}
    }

    /// `down notify` — the agent hook endpoint.  Reads a hook payload on stdin
    /// and hands any Markdown file it names to Downright.
    public struct NotifyOptions: Equatable, Sendable {
        /// Bring Downright to the front.  Off by default: the whole point is to
        /// queue a change for review without pulling focus out of the terminal
        /// the agent is running in.
        public var focus = false
        /// Print the resolved paths instead of opening them, for wiring up a
        /// hook without launching anything.
        public var dryRun = false

        public init() {}
    }

    /// `down watch` — the no-hook fallback for agents with no hook system.
    public struct WatchOptions: Equatable, Sendable {
        public var focus = false
        public var debounce = AgentWatcher.defaultDebounce

        public init() {}
    }

    /// `down hook` — print or install the agent configuration that wires
    /// `down notify` in.
    public struct HookOptions: Equatable, Sendable {
        public enum Mode: String, Equatable, Sendable {
            case print
            case install
            case uninstall
        }

        public var mode: Mode = .print
        public var scope: AgentBridge.HookScope = .project

        public init() {}
    }

    public enum ExportFormat: String, CaseIterable, Sendable {
        case html

        public init?(argument: String) {
            self.init(rawValue: argument.lowercased())
        }
    }

    public enum ParseError: Error, Equatable, CustomStringConvertible, Sendable {
        case unknownOption(String)
        case missingValue(String)
        case invalidFormat(String)
        case invalidLine(String)
        case unexpectedArgument(String)

        public var description: String {
            switch self {
            case .unknownOption(let value): return "unknown option \(value)"
            case .missingValue(let value): return "missing value for \(value)"
            case .invalidFormat(let value): return "unsupported export format \(value)"
            case .invalidLine(let value): return "line must be a positive integer, got \(value)"
            case .unexpectedArgument(let value): return "unexpected argument \(value)"
            }
        }
    }

    public static func parse(_ arguments: [String]) throws -> Action {
        guard let first = arguments.first else { return .open(OpenOptions(), paths: []) }
        if first == "-h" || first == "--help" { return .help }
        if first == "-v" || first == "--version" { return .version }

        switch first {
        case "read": return try parseRead(Array(arguments.dropFirst()))
        case "export": return try parseExport(Array(arguments.dropFirst()))
        case "check": return try parseCheck(Array(arguments.dropFirst()))
        case "outline": return try parseOutline(Array(arguments.dropFirst()))
        case "doctor": return try parseDoctor(Array(arguments.dropFirst()))
        case "open": return try parseOpen(Array(arguments.dropFirst()))
        case "notify": return try parseNotify(Array(arguments.dropFirst()))
        case "watch": return try parseWatch(Array(arguments.dropFirst()))
        case "hook": return try parseHook(Array(arguments.dropFirst()))
        default: return try parseOpen(arguments)
        }
    }

    public static func usage() -> String {
        """
        down \(version) — open and inspect Markdown in Downright

        USAGE
          down [open options] [file ...]
          down read [--json] [file ...]
          down export [--format html] [-o path] [file ...]
          down check [--json] [--target name] [file or folder ...]
          down outline [--json] [file ...]
          down doctor [--json] [--app path]
          down notify [--focus] [--dry-run]
          down watch [--focus] [--debounce ms] [file or folder ...]
          down hook [--print | --install | --uninstall] [--scope user|project]
          … | down [command] -

        COMMANDS
          open       Open files in Downright (the default)
          read       Write Markdown source to stdout
          export     Write self-contained HTML to stdout or -o a file
          check      Run health and target checks (exit 1 when findings exist)
          outline    List document headings
          notify     Open the Markdown file named by an agent hook payload on
                     stdin.  Always exits 0 so a hook never blocks the agent.
          watch      Open Markdown files in the background as they change.  The
                     fallback for agents that have no hook system.
          hook       Print or install the agent configuration that runs `notify`

        CHECK TARGETS
          downright, commonmark, github, obsidian, pandoc, multimarkdown,
          jekyll, hugo, quarto

        OPEN OPTIONS
          -n, --new         open each file in a new window
          -b, --background  do not bring Downright to the front
          -w, --wait        wait for the app to exit
          -e, --edit        open in Live mode instead of Read mode
          --line N          open at one-based line N
          --reveal          reveal the file in Finder instead of opening it
          --review          open in Live mode with the Review panel visible
          -h, --help        show this message
          -v, --version     show the version

        AGENT OPTIONS
          --focus           bring Downright forward (default: stay in background)
          --dry-run         print what notify would open, without opening it
          --debounce ms     quiet period before reporting a burst (default 300)
          --scope           where `hook --install` writes: user or project

        AGENT SETUP
          down hook --install            wire this project's agent to Downright
          down hook --install --scope user   wire every project for this user
        """
    }

    private static func parseOpen(_ arguments: [String]) throws -> Action {
        var options = OpenOptions()
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--":
                paths.append(contentsOf: arguments[(index + 1)...])
                index = arguments.count
                continue
            case "-n", "--new": options.newWindow = true
            case "-b", "--background": options.background = true
            case "-w", "--wait": options.wait = true
            case "-e", "--edit": options.edit = true
            case "--line":
                index += 1
                guard index < arguments.count else { throw ParseError.missingValue(argument) }
                let value = arguments[index]
                guard let line = Int(value), line > 0 else {
                    throw ParseError.invalidLine(value)
                }
                options.line = line
            case "--reveal": options.reveal = true
            case "--review": options.review = true; options.edit = true
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default:
                if argument.hasPrefix("-") && argument.count > 1 {
                    throw ParseError.unknownOption(argument)
                }
                paths.append(argument)
            }
            index += 1
        }
        return .open(options, paths: paths)
    }

    private static func parseDoctor(_ arguments: [String]) throws -> Action {
        var json = false
        var appPath: String?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--json": json = true
            case "--app":
                index += 1
                guard index < arguments.count else { throw ParseError.missingValue("--app") }
                appPath = arguments[index]
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default: throw ParseError.unknownOption(arguments[index])
            }
            index += 1
        }
        return .doctor(json: json, appPath: appPath)
    }

    private static func parseRead(_ arguments: [String]) throws -> Action {
        var json = false
        var paths: [String] = []
        var parsingOptions = true
        for argument in arguments {
            if parsingOptions, argument == "--" { parsingOptions = false; continue }
            if !parsingOptions { paths.append(argument); continue }
            switch argument {
            case "--json": json = true
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default:
                if argument != "-", argument.hasPrefix("-") { throw ParseError.unknownOption(argument) }
                paths.append(argument)
            }
        }
        return .read(json: json, paths: paths)
    }

    private static func parseCheck(_ arguments: [String]) throws -> Action {
        var json = false
        var target: BuiltInRenderTarget?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": json = true
            case "--target":
                index += 1
                guard index < arguments.count else { throw ParseError.missingValue(argument) }
                guard let value = renderTarget(named: arguments[index]) else {
                    throw ParseError.unexpectedArgument("unknown render target \(arguments[index])")
                }
                target = value
            case "--":
                paths.append(contentsOf: arguments[(index + 1)...])
                index = arguments.count
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default:
                if argument != "-", argument.hasPrefix("-") { throw ParseError.unknownOption(argument) }
                paths.append(argument)
            }
            index += 1
        }
        return .check(json: json, target: target, paths: paths)
    }

    private static func parseOutline(_ arguments: [String]) throws -> Action {
        var json = false
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--json": json = true
            case "--":
                paths.append(contentsOf: arguments[(index + 1)...])
                index = arguments.count
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default:
                if argument != "-", argument.hasPrefix("-") { throw ParseError.unknownOption(argument) }
                paths.append(argument)
            }
            index += 1
        }
        return .outline(json: json, paths: paths)
    }

    private static func parseNotify(_ arguments: [String]) throws -> Action {
        var options = NotifyOptions()
        for argument in arguments {
            switch argument {
            case "--focus": options.focus = true
            case "--dry-run": options.dryRun = true
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default: throw ParseError.unknownOption(argument)
            }
        }
        return .notify(options)
    }

    private static func parseWatch(_ arguments: [String]) throws -> Action {
        var options = WatchOptions()
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--focus": options.focus = true
            case "--debounce":
                index += 1
                guard index < arguments.count else { throw ParseError.missingValue(argument) }
                guard let milliseconds = Double(arguments[index]), milliseconds >= 0 else {
                    throw ParseError.unexpectedArgument("--debounce expects milliseconds, got \(arguments[index])")
                }
                options.debounce = milliseconds / 1000
            case "--": paths.append(contentsOf: arguments[(index + 1)...]); index = arguments.count
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default:
                if argument.hasPrefix("-"), argument.count > 1 { throw ParseError.unknownOption(argument) }
                paths.append(argument)
            }
            index += 1
        }
        return .watch(options, paths: paths)
    }

    private static func parseHook(_ arguments: [String]) throws -> Action {
        var options = HookOptions()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--print": options.mode = .print
            case "--install": options.mode = .install
            case "--uninstall": options.mode = .uninstall
            case "--scope":
                index += 1
                guard index < arguments.count else { throw ParseError.missingValue(argument) }
                guard let scope = AgentBridge.HookScope(rawValue: arguments[index].lowercased()) else {
                    throw ParseError.unexpectedArgument("unknown scope \(arguments[index]); expected user or project")
                }
                options.scope = scope
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default: throw ParseError.unknownOption(argument)
            }
            index += 1
        }
        return .hook(options)
    }

    private static func parseExport(_ arguments: [String]) throws -> Action {
        var format: ExportFormat = .html
        var output: String?
        var paths: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--format", "-f":
                index += 1
                guard index < arguments.count else { throw ParseError.missingValue(argument) }
                guard let value = ExportFormat(argument: arguments[index]) else {
                    throw ParseError.invalidFormat(arguments[index])
                }
                format = value
            case "--output", "-o":
                index += 1
                guard index < arguments.count else { throw ParseError.missingValue(argument) }
                output = arguments[index]
            case "--": paths.append(contentsOf: arguments[(index + 1)...]); index = arguments.count
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default:
                if argument != "-", argument.hasPrefix("-") { throw ParseError.unknownOption(argument) }
                paths.append(argument)
            }
            index += 1
        }
        return .export(format: format, output: output, paths: paths)
    }

    /// A small, deterministic HTML writer for terminal exports. It deliberately
    /// emits no external resources, scripts, or network references.
    public static func html(for markdown: String, title: String = "Markdown") -> String {
        let lines = markdown.components(separatedBy: .newlines)
        var body: [String] = []
        var paragraph: [String] = []
        var inCode = false
        var codeLanguage = ""
        var codeLines: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            body.append("<p>\(inline(paragraph.joined(separator: "\n")))</p>")
            paragraph.removeAll(keepingCapacity: true)
        }
        var selfListKind: Character?
        func closeList() {
            guard let listKind = selfListKind else { return }
            body.append(listKind == "1" ? "</ol>" : "</ul>")
            selfListKind = nil
        }
        for line in lines {
            if inCode {
                if line.hasPrefix("```") {
                    body.append("<pre><code class=\"language-\(escape(codeLanguage))\">\(escape(codeLines.joined(separator: "\n")))</code></pre>")
                    codeLines.removeAll(keepingCapacity: true)
                    inCode = false
                } else { codeLines.append(line) }
                continue
            }
            if line.hasPrefix("```") {
                flushParagraph(); closeList(); inCode = true; codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces); continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flushParagraph(); closeList(); continue }
            if let heading = heading(line) { flushParagraph(); closeList(); body.append("<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>"); continue }
            if line.hasPrefix("> ") { flushParagraph(); closeList(); body.append("<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>"); continue }
            if line == "---" || line == "***" { flushParagraph(); closeList(); body.append("<hr>"); continue }
            if let item = listItem(line) {
                flushParagraph()
                let wanted: Character = item.ordered ? "1" : "u"
                if selfListKind != wanted { closeList(); body.append(item.ordered ? "<ol>" : "<ul>"); selfListKind = wanted }
                body.append("<li>\(item.checkbox.map { "<input type=\"checkbox\" disabled\($0 ? " checked" : "")> " } ?? "")\(inline(item.text))</li>")
                continue
            }
            paragraph.append(line)
        }
        if inCode { body.append("<pre><code>\(escape(codeLines.joined(separator: "\n")))</code></pre>") }
        flushParagraph(); closeList()
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(escape(title))</title><style>body{font:16px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;max-width:70ch;margin:3rem auto;padding:0 1rem;color:#222}pre{padding:1rem;background:#f3f3f3;overflow:auto}code{font-family:ui-monospace,monospace}blockquote{border-left:3px solid #aaa;padding-left:1rem;color:#555}img{max-width:100%}</style></head><body>\(body.joined(separator: "\n"))</body></html>"
    }

    public static func diagnostics(for markdown: String, baseURL: URL? = nil) -> [DocumentHealthDiagnostic] {
        let resolver: DocumentHealthResolver? = baseURL.map { base in
            DocumentHealthResolver { path in
                FileManager.default.fileExists(atPath: URL(fileURLWithPath: path, relativeTo: base).standardizedFileURL.path)
            }
        }
        return DocumentHealth.analyze(markdown, resolver: resolver)
    }

    public struct OutlineItem: Codable, Equatable, Sendable {
        public let level: Int
        public let title: String
        public let slug: String
        public let location: Int
        public let line: Int
    }

    public static func outline(for markdown: String) -> [OutlineItem] {
        let parsed = MarkdownParser.parse(markdown, options: .structureOnly)
        return parsed.headings.map { heading in
            OutlineItem(
                level: heading.level,
                title: heading.title,
                slug: heading.slug,
                location: heading.range.location,
                line: parsed.line(at: heading.range.location)
            )
        }
    }

    public static func compatibilityDiagnostics(
        for markdown: String,
        target: BuiltInRenderTarget
    ) -> [CompatibilityDiagnostic] {
        MarkdownCompatibility.diagnose(MarkdownParser.parse(markdown), for: target.profile).diagnostics
    }

    public static func renderTarget(named name: String) -> BuiltInRenderTarget? {
        let normalized = name.lowercased().replacingOccurrences(of: "-", with: "")
        return BuiltInRenderTarget.allCases.first {
            $0.rawValue.lowercased() == normalized
                || $0.displayName.lowercased().replacingOccurrences(of: "-", with: "") == normalized
        }
    }

    public static func isMarkdownPath(_ path: String) -> Bool {
        let supported = Set(["md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd"])
        return supported.contains(URL(fileURLWithPath: path).pathExtension.lowercased())
    }

    /// Loads a hook settings object without ever treating damaged input as an
    /// absent file. The caller may safely write only after this returns.
    public static func loadSettings(
        at url: URL,
        maximumBytes: Int = maximumSettingsBytes
    ) throws -> [String: Any] {
        guard maximumBytes >= 0 else {
            throw SettingsFileError.unreadable(
                path: url.path,
                reason: "maximum byte count must not be negative"
            )
        }
        let manager = FileManager.default
        let attributes: [FileAttributeKey: Any]
        do {
            attributes = try manager.attributesOfItem(atPath: url.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return [:]
        } catch {
            throw SettingsFileError.unreadable(path: url.path, reason: error.localizedDescription)
        }

        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SettingsFileError.unreadable(path: url.path, reason: "not a regular file")
        }
        if let size = attributes[.size] as? NSNumber, size.uint64Value > UInt64(maximumBytes) {
            throw SettingsFileError.tooLarge(path: url.path, maximumBytes: maximumBytes)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw SettingsFileError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        defer { try? handle.close() }

        let data: Data
        do {
            data = try handle.read(upToCount: maximumBytes + 1) ?? Data()
        } catch {
            throw SettingsFileError.unreadable(path: url.path, reason: error.localizedDescription)
        }
        guard data.count <= maximumBytes else {
            throw SettingsFileError.tooLarge(path: url.path, maximumBytes: maximumBytes)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let settings = object as? [String: Any]
        else {
            throw SettingsFileError.invalidJSON(path: url.path)
        }
        return settings
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func inline(_ value: String) -> String {
        var result = escape(value)
        result = result.replacingOccurrences(of: #"`([^`]+)`"#, with: "<code>$1</code>", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\*\*([^*]+)\*\*"#, with: "<strong>$1</strong>", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\*([^*]+)\*"#, with: "<em>$1</em>", options: .regularExpression)
        result = replacingMatches(in: result, pattern: #"!\[([^\]]*)\]\(([^)]+)\)"#) { captures in
            let alt = captures[0]
            let source = captures[1]
            guard imageSourceIsSafe(source) else {
                return "<span class=\"missing-image\" title=\"\(source)\">\(alt)</span>"
            }
            return "<img alt=\"\(alt)\" src=\"\(source)\">"
        }
        result = replacingMatches(in: result, pattern: #"\[([^\]]+)\]\(([^)]+)\)"#) { captures in
            let label = captures[0]
            let destination = captures[1]
            guard linkDestinationIsSafe(destination) else {
                return "<span title=\"\(destination)\">\(label)</span>"
            }
            return "<a href=\"\(destination)\">\(label)</a>"
        }
        return result.replacingOccurrences(of: "\n", with: "<br>\n")
    }

    private static let linkSchemeAllowlist: Set<String> = ["http", "https", "mailto"]

    private static func linkDestinationIsSafe(_ destination: String) -> Bool {
        let trimmed = destination.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard let colon = trimmed.firstIndex(of: ":") else { return true }
        let prefix = String(trimmed[..<colon])
        if prefix.rangeOfCharacter(from: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-.")).inverted) != nil {
            return !prefix.contains("javascript") && !prefix.contains("data") && !prefix.contains("vbscript")
        }
        return linkSchemeAllowlist.contains(prefix)
    }

    private static func imageSourceIsSafe(_ source: String) -> Bool {
        guard !source.hasPrefix("/"),
              !source.hasPrefix("\\"),
              !hasURLScheme(source)
        else { return false }
        let decoded = source.removingPercentEncoding ?? source
        let path = decoded
            .split(separator: "#", maxSplits: 1)[0]
            .split(separator: "?", maxSplits: 1)[0]
            .replacingOccurrences(of: "\\", with: "/")
        return !path.split(separator: "/", omittingEmptySubsequences: false).contains("..")
    }

    private static func hasURLScheme(_ source: String) -> Bool {
        guard let colon = source.firstIndex(of: ":") else { return false }
        let prefix = source[..<colon]
        guard !prefix.isEmpty else { return false }
        let scheme = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+-."))
        return prefix.unicodeScalars.allSatisfy { scheme.contains($0) }
    }

    private static func replacingMatches(
        in value: String,
        pattern: String,
        transform: ([String]) -> String
    ) -> String {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return value }
        let source = value as NSString
        let matches = expression.matches(
            in: value,
            range: NSRange(location: 0, length: source.length)
        )
        var result = value
        for match in matches.reversed() {
            let captures = (1..<match.numberOfRanges).map { index -> String in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: transform(captures))
        }
        return result
    }

    private static func heading(_ line: String) -> (level: Int, text: String)? {
        let prefix = line.prefix { $0 == "#" }
        guard (1...6).contains(prefix.count), line.dropFirst(prefix.count).first == " " else { return nil }
        return (prefix.count, String(line.dropFirst(prefix.count + 1)))
    }

    private static func listItem(_ line: String) -> (ordered: Bool, checkbox: Bool?, text: String)? {
        if let match = line.range(of: #"^\s*(\d+)[.)]\s+"#, options: .regularExpression) {
            return (true, nil, String(line[match.upperBound...]))
        }
        guard let match = line.range(of: #"^\s*[-*+]\s+"#, options: .regularExpression) else { return nil }
        let text = String(line[match.upperBound...])
        if text.hasPrefix("[x] ") || text.hasPrefix("[X] ") { return (false, true, String(text.dropFirst(4))) }
        if text.hasPrefix("[ ] ") { return (false, false, String(text.dropFirst(4))) }
        return (false, nil, text)
    }
}
