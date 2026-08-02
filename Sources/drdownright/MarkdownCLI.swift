import Foundation
import MarkdownCore

/// The command-line surface shared by `down` and the `md` alias.
///
/// Parsing and pure document operations live in a library so they can be
/// exercised without launching an app or touching the user's files.
public enum MarkdownCLI {
    public static let version = "1.0.0"

    public enum Action: Equatable, Sendable {
        case open(OpenOptions, paths: [String])
        case read(json: Bool, paths: [String])
        case export(format: ExportFormat, output: String?, paths: [String])
        case check(json: Bool, target: BuiltInRenderTarget?, paths: [String])
        case outline(json: Bool, paths: [String])
        case help
        case version
    }

    public struct OpenOptions: Equatable, Sendable {
        public var newWindow = false
        public var background = false
        public var wait = false
        public var edit = false

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
        case unexpectedArgument(String)

        public var description: String {
            switch self {
            case .unknownOption(let value): return "unknown option \(value)"
            case .missingValue(let value): return "missing value for \(value)"
            case .invalidFormat(let value): return "unsupported export format \(value)"
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
        case "open": return try parseOpen(Array(arguments.dropFirst()))
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
          … | down [command] -

        COMMANDS
          open       Open files in Downright (the default)
          read       Write Markdown source to stdout
          export     Write self-contained HTML to stdout or -o a file
          check      Run health and target checks (exit 1 when findings exist)
          outline    List document headings

        CHECK TARGETS
          downright, commonmark, github, obsidian, pandoc, multimarkdown,
          jekyll, hugo, quarto

        OPEN OPTIONS
          -n, --new         open each file in a new window
          -b, --background  do not bring Downright to the front
          -w, --wait        wait for the app to exit
          -e, --edit        open in Live mode instead of Read mode
          -h, --help        show this message
          -v, --version     show the version
        """
    }

    private static func parseOpen(_ arguments: [String]) throws -> Action {
        var options = OpenOptions()
        var paths: [String] = []
        var parsingOptions = true
        for argument in arguments {
            if parsingOptions, argument == "--" {
                parsingOptions = false
                continue
            }
            if parsingOptions {
                switch argument {
                case "-n", "--new": options.newWindow = true
                case "-b", "--background": options.background = true
                case "-w", "--wait": options.wait = true
                case "-e", "--edit": options.edit = true
                case "-h", "--help": return .help
                case "-v", "--version": return .version
                default:
                    if argument.hasPrefix("-") && argument.count > 1 {
                        throw ParseError.unknownOption(argument)
                    }
                    paths.append(argument)
                }
            } else {
                paths.append(argument)
            }
        }
        return .open(options, paths: paths)
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
        for argument in arguments {
            switch argument {
            case "--json": json = true
            case "-h", "--help": return .help
            case "-v", "--version": return .version
            default:
                if argument != "-", argument.hasPrefix("-") { throw ParseError.unknownOption(argument) }
                paths.append(argument)
            }
        }
        return .outline(json: json, paths: paths)
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
            body.append("<p>\(inline(paragraph.joined(separator: "\\n")))</p>")
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
                    body.append("<pre><code class=\"language-\(escape(codeLanguage))\">\(escape(codeLines.joined(separator: "\\n")))</code></pre>")
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
        if inCode { body.append("<pre><code>\(escape(codeLines.joined(separator: "\\n")))</code></pre>") }
        flushParagraph(); closeList()
        return "<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>\(escape(title))</title><style>body{font:16px/1.55 -apple-system,BlinkMacSystemFont,sans-serif;max-width:70ch;margin:3rem auto;padding:0 1rem;color:#222}pre{padding:1rem;background:#f3f3f3;overflow:auto}code{font-family:ui-monospace,monospace}blockquote{border-left:3px solid #aaa;padding-left:1rem;color:#555}img{max-width:100%}</style></head><body>\(body.joined(separator: "\\n"))</body></html>"
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
        let source = markdown as NSString
        var cursor = 0
        var line = 1
        return MarkdownParser.parse(markdown, options: .structureOnly).headings.map { heading in
            while cursor < min(heading.range.location, source.length) {
                if source.character(at: cursor) == 0x0A { line += 1 }
                cursor += 1
            }
            return OutlineItem(
                level: heading.level,
                title: heading.title,
                slug: heading.slug,
                location: heading.range.location,
                line: line
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
        result = result.replacingOccurrences(of: #"!\[([^\]]*)\]\(([^)]+)\)"#, with: "<img alt=\"$1\" src=\"$2\">", options: .regularExpression)
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\(([^)]+)\)"#, with: "<a href=\"$2\">$1</a>", options: .regularExpression)
        return result.replacingOccurrences(of: "\\n", with: "<br>\\n")
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
