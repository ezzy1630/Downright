import Foundation

// `down` — the terminal launcher (§3.4).
//
// Deliberately tiny and dependency-free: it finds Downright.app and hands it
// files.  Being unsandboxed is what makes this possible at all, and piping is
// what makes it worth having — `claude -p … | down` or `down PLAN.md` is how
// you actually end up in the app.

let toolVersion = "1.0.0"

func printUsage() {
    print("""
    down \(toolVersion) — open markdown in Downright

    USAGE
      down [options] [file ...]
      … | down [options]              read markdown from stdin

    OPTIONS
      -n, --new         open each file in a new window
      -b, --background  do not bring Downright to the front
      -w, --wait        wait for the app to exit
      -e, --edit        open in Live mode instead of Read mode
      -h, --help        show this message
      -v, --version     show the version

    EXAMPLES
      down PLAN.md
      down docs/*.md
      claude -p "summarise this repo" | down
    """)
}

struct Options {
    var newWindow = false
    var background = false
    var wait = false
    var edit = false
    var files: [URL] = []
}

func parseArguments(_ arguments: [String]) -> Options? {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        switch argument {
        case "-h", "--help":
            printUsage()
            return nil
        case "-v", "--version":
            print("down \(toolVersion)")
            return nil
        case "-n", "--new": options.newWindow = true
        case "-b", "--background": options.background = true
        case "-w", "--wait": options.wait = true
        case "-e", "--edit": options.edit = true
        case "--":
            for rest in arguments[(index + 1)...] {
                options.files.append(URL(fileURLWithPath: rest).standardizedFileURL)
            }
            index = arguments.count
        default:
            if argument.hasPrefix("-"), argument.count > 1 {
                FileHandle.standardError.write(Data("down: unknown option \(argument)\n".utf8))
                exit(64)
            }
            options.files.append(URL(fileURLWithPath: argument).standardizedFileURL)
        }
        index += 1
    }
    return options
}

/// Markdown arriving on stdin becomes a real file in a temp directory, because
/// the app models documents as files on disk — that is what makes watching,
/// history, and sibling scanning work identically for piped input (§8).
func fileFromStandardInput() -> URL? {
    guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { return nil }

    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Downright", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let stamp = ISO8601DateFormatter().string(from: Date())
        .replacingOccurrences(of: ":", with: "-")
    let url = directory.appendingPathComponent("stdin-\(stamp).md")
    try? data.write(to: url)
    return url
}

func locateApp() -> URL? {
    let candidates = [
        "/Applications/Downright.app",
        "\(NSHomeDirectory())/Applications/Downright.app",
        FileManager.default.currentDirectoryPath + "/.build/bundle/Downright.app",
    ]
    for path in candidates where FileManager.default.fileExists(atPath: path) {
        return URL(fileURLWithPath: path)
    }

    // Fall back to Spotlight, which knows about copies anywhere on disk.
    let query = Process()
    query.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    query.arguments = ["kMDItemCFBundleIdentifier == 'com.unrulyagency.downright'"]
    let pipe = Pipe()
    query.standardOutput = pipe
    query.standardError = FileHandle.nullDevice
    guard (try? query.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    query.waitUntilExit()
    let path = String(decoding: data, as: UTF8.self)
        .split(separator: "\n").first.map(String.init)
    return path.map { URL(fileURLWithPath: $0) }
}

// MARK: - Main

guard let options = parseArguments(Array(CommandLine.arguments.dropFirst())) else { exit(0) }

var files = options.files
if let piped = fileFromStandardInput() { files.append(piped) }

guard !files.isEmpty else {
    printUsage()
    exit(64)
}

for file in files where !FileManager.default.fileExists(atPath: file.path) {
    FileHandle.standardError.write(Data("down: \(file.path): no such file\n".utf8))
    exit(66)
}

guard let app = locateApp() else {
    FileHandle.standardError.write(Data("""
    down: could not find Downright.app.
          Install it in /Applications, or run Scripts/bundle-app.sh from the source tree.

    """.utf8))
    exit(69)
}

var arguments = ["-a", app.path]
if options.newWindow { arguments.append("-n") }
if options.background { arguments.append("-g") }
if options.wait { arguments.append("-W") }
arguments.append(contentsOf: files.map(\.path))

// Mode is passed out of band; the app reads it once at launch and applies it to
// the documents opened in that same activation.
if options.edit {
    arguments.append(contentsOf: ["--args", "--mode", "live"])
}

let open = Process()
open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
open.arguments = arguments
do {
    try open.run()
    open.waitUntilExit()
    exit(open.terminationStatus)
} catch {
    FileHandle.standardError.write(Data("down: failed to launch: \(error.localizedDescription)\n".utf8))
    exit(70)
}
