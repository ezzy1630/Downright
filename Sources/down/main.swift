import AppKit
import Foundation
import drdownright

let arguments = Array(CommandLine.arguments.dropFirst())

func writeError(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("down: \(message)\n".utf8))
    exit(status)
}

func readInputs(_ paths: [String], maximumBytes: Int? = nil) -> [(String, String)] {
    let requested = paths.isEmpty ? ["-"] : paths
    return requested.map { path in
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty else { writeError("stdin is empty", status: 66) }
            if let maximumBytes, data.count > maximumBytes {
                writeError("stdin exceeds the \(maximumBytes / 1_024 / 1_024) MB check limit", status: 65)
            }
            return ("stdin", String(decoding: data, as: UTF8.self))
        }
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            writeError("\(path): no such file", status: 66)
        }
        if let maximumBytes,
           let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > maximumBytes {
            writeError("\(path): file exceeds the \(maximumBytes / 1_024 / 1_024) MB check limit", status: 65)
        }
        do { return (url.path, try String(contentsOf: url, encoding: .utf8)) }
        catch { writeError("\(path): cannot read UTF-8 Markdown (\(error.localizedDescription))", status: 65) }
    }
}

func expandedMarkdownPaths(_ paths: [String]) -> [String] {
    let ignoredDirectories: Set<String> = [
        ".git", ".build", "node_modules", "DerivedData", ".swiftpm",
    ]
    let maximumFiles = 1_000
    var results: [String] = []
    for path in paths {
        guard path != "-" else { results.append(path); continue }
        let expanded = (path as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), isDirectory.boolValue else {
            results.append(path)
            continue
        }
        guard let enumerator = FileManager.default.enumerator(atPath: expanded) else { continue }
        while let item = enumerator.nextObject() as? String {
            let name = (item as NSString).lastPathComponent
            if ignoredDirectories.contains(name) {
                enumerator.skipDescendants()
                continue
            }
            let full = URL(fileURLWithPath: expanded).appendingPathComponent(item).path
            guard MarkdownCLI.isMarkdownPath(full) else { continue }
            results.append(full)
            if results.count > maximumFiles {
                writeError("folder check exceeds the \(maximumFiles)-file limit", status: 65)
            }
        }
    }
    return results.sorted()
}

func stdinFile() -> URL? {
    guard isatty(FileHandle.standardInput.fileDescriptor) == 0 else { return nil }
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard !data.isEmpty else { return nil }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Downright", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("stdin-\(UUID().uuidString).md")
    do { try data.write(to: url, options: .atomic); return url }
    catch { writeError("cannot create stdin document: \(error.localizedDescription)", status: 70) }
}

func locateApp() -> URL? {
    let candidates = [
        "/Applications/Downright.app",
        "\(NSHomeDirectory())/Applications/Downright.app",
        FileManager.default.currentDirectoryPath + "/.build/bundle/Downright.app",
    ]
    if let path = candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) {
        return URL(fileURLWithPath: path)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    process.arguments = ["kMDItemCFBundleIdentifier == 'com.ezzy.downright'"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map { URL(fileURLWithPath: String($0)) }
}

/// Launches Downright for a set of files, returning the `open` exit status.
///
/// Shared by `open`, `notify`, and `watch` so the three agree on how the app is
/// located and what "background" means.
@discardableResult
func launch(_ paths: [String], options: MarkdownCLI.OpenOptions) -> Int32 {
    guard !paths.isEmpty, let app = locateApp() else { return 69 }
    var openArguments = ["-a", app.path]
    if options.newWindow { openArguments.append("-n") }
    if options.background { openArguments.append("-g") }
    if options.wait { openArguments.append("-W") }
    openArguments.append("--")
    openArguments.append(contentsOf: paths)
    var appArguments: [String] = []
    if options.edit { appArguments.append(contentsOf: ["--mode", "live"]) }
    if let line = options.line { appArguments.append(contentsOf: ["--downright-line", String(line)]) }
    if options.review { appArguments.append("--downright-review") }
    if !appArguments.isEmpty { openArguments.append(contentsOf: ["--args"] + appArguments) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = openArguments
    do { try process.run(); process.waitUntilExit(); return process.terminationStatus }
    catch { return 70 }
}

/// Reveals files in Finder without requiring Downright to be installed.
@discardableResult
func reveal(_ paths: [String]) -> Int32 {
    guard !paths.isEmpty else { return 64 }
    guard !paths.contains("-") else {
        writeError("--reveal requires file paths, not stdin", status: 64)
    }
    let urls = paths.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
    for url in urls where !FileManager.default.fileExists(atPath: url.path) {
        writeError("\(url.path): no such file", status: 66)
    }
    NSWorkspace.shared.activateFileViewerSelecting(urls)
    return 0
}

/// The command an installed hook should run.
///
/// A hook does not inherit an interactive shell's `PATH`, so `down` alone can
/// resolve in a terminal and then fail silently inside the agent.  Prefer the
/// stable install locations, and fall back to this process's own absolute path.
func resolvedExecutable() -> String {
    let installed = ["/usr/local/bin/down", "/opt/homebrew/bin/down"]
    if let path = installed.first(where: { FileManager.default.fileExists(atPath: $0) }) { return path }
    let argv0 = CommandLine.arguments.first ?? "down"
    if argv0.hasPrefix("/") { return argv0 }
    let resolved = URL(fileURLWithPath: argv0, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
    return FileManager.default.fileExists(atPath: resolved.path) ? resolved.standardizedFileURL.path : "down"
}

let action: MarkdownCLI.Action
do { action = try MarkdownCLI.parse(arguments) }
catch let error as MarkdownCLI.ParseError { writeError(error.description, status: 64) }
catch { writeError(error.localizedDescription, status: 64) }

switch action {
case .help:
    print(MarkdownCLI.usage())
case .version:
    print("down \(MarkdownCLI.version)")
case .read(let json, let paths):
    let inputs = readInputs(paths)
    if json {
        let values = inputs.map { ["path": $0.0, "markdown": $0.1] }
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]) else { writeError("cannot encode JSON", status: 70) }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    } else {
        for (index, input) in inputs.enumerated() {
            if index > 0 { print("\n", terminator: "") }
            print(input.1, terminator: input.1.hasSuffix("\n") ? "" : "\n")
        }
    }
case .export(_, let output, let paths):
    let inputs = readInputs(paths)
    let html = inputs.count == 1
        ? MarkdownCLI.html(for: inputs[0].1, title: URL(fileURLWithPath: inputs[0].0).deletingPathExtension().lastPathComponent)
        : MarkdownCLI.html(for: inputs.map { $0.1 }.joined(separator: "\n\n"), title: "Markdown export")
    let data = Data(html.utf8)
    if let output, output != "-" {
        do { try data.write(to: URL(fileURLWithPath: output), options: .atomic) }
        catch { writeError("cannot write \(output): \(error.localizedDescription)", status: 73) }
    } else { FileHandle.standardOutput.write(data) }
case .check(let json, let target, let paths):
    let inputs = readInputs(expandedMarkdownPaths(paths), maximumBytes: 10 * 1_024 * 1_024)
    var findings = 0
    for (path, content) in inputs {
        let base = path == "stdin" ? nil : URL(fileURLWithPath: path).deletingLastPathComponent()
        let diagnostics = MarkdownCLI.diagnostics(for: content, baseURL: base)
        let compatibility = target.map { MarkdownCLI.compatibilityDiagnostics(for: content, target: $0) } ?? []
        findings += diagnostics.count + compatibility.count
        if json {
            var values = diagnostics.map {
                ["path": path, "id": $0.id, "severity": $0.severity.rawValue, "category": $0.category.rawValue, "message": $0.message, "location": $0.range.location] as [String: Any]
            }
            values += compatibility.map {
                [
                    "path": path,
                    "id": $0.id,
                    "severity": $0.severity.rawValue,
                    "category": "compatibility",
                    "target": target?.rawValue ?? "",
                    "message": $0.title,
                    "location": $0.range.location,
                ] as [String: Any]
            }
            guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]) else { writeError("cannot encode JSON", status: 70) }
            FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            for diagnostic in diagnostics { print("\(path):\(diagnostic.range.location + 1): \(diagnostic.severity.rawValue): \(diagnostic.message) [\(diagnostic.id)]") }
            for diagnostic in compatibility {
                print("\(path):\(diagnostic.range.location + 1): warning: \(diagnostic.title) [target:\(target?.rawValue ?? "unknown")]")
            }
        }
    }
    if findings > 0 { exit(1) }
case .outline(let json, let paths):
    let inputs = readInputs(paths)
    for input in inputs {
        let outline = MarkdownCLI.outline(for: input.1)
        if json {
            guard let data = try? JSONEncoder().encode(outline) else { writeError("cannot encode JSON", status: 70) }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            for heading in outline {
                print("\(input.0):\(heading.line): \(String(repeating: "  ", count: max(0, heading.level - 1)))\(heading.title) #\(heading.slug)")
            }
        }
    }
case .doctor(let json, let appPath):
    let report = DownDoctor.run(appPath: appPath)
    if json {
        guard let output = try? DownDoctor.json(report) else { writeError("cannot encode doctor report", status: 70) }
        print(output)
    } else {
        print(DownDoctor.humanReadable(report))
    }
    exit(report.hasFailures ? 1 : 0)
case .open(let options, let paths):
    if options.reveal {
        exit(reveal(paths))
    }
    var paths = paths
    if paths.contains("-") {
        guard let piped = stdinFile() else { writeError("stdin is not available", status: 66) }
        paths = paths.filter { $0 != "-" }
        paths.append(piped.path)
    } else if paths.isEmpty, let piped = stdinFile() {
        paths.append(piped.path)
    }
    guard !paths.isEmpty else { print(MarkdownCLI.usage()); exit(64) }
    for path in paths where !FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).path) {
        writeError("\(path): no such file", status: 66)
    }
    guard locateApp() != nil else {
        writeError("could not find Downright.app; install it in /Applications or run Scripts/bundle-app.sh", status: 69)
    }
    exit(launch(paths, options: options))

case .notify(let options):
    // A hook runs inside the agent's turn.  Every failure path here exits 0:
    // an unreadable payload, a missing app, or a path that is not Markdown are
    // all "nothing to review", and none of them justify failing somebody's edit.
    let data = isatty(FileHandle.standardInput.fileDescriptor) == 0
        ? FileHandle.standardInput.readDataToEndOfFile()
        : Data()
    let targets = AgentBridge.openableTargets(in: AgentBridge.hookPayloadPaths(data))
    guard !targets.isEmpty else { exit(0) }
    if options.dryRun {
        for target in targets { print(target) }
        exit(0)
    }
    var openOptions = MarkdownCLI.OpenOptions()
    openOptions.background = !options.focus
    launch(targets, options: openOptions)
    exit(0)

case .watch(let options, let paths):
    let roots = (paths.isEmpty ? [FileManager.default.currentDirectoryPath] : paths)
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardizedFileURL }
    for root in roots where !FileManager.default.fileExists(atPath: root.deletingLastPathComponent().path) {
        writeError("\(root.path): no such file or folder", status: 66)
    }
    guard locateApp() != nil else {
        writeError("could not find Downright.app; install it in /Applications or run Scripts/bundle-app.sh", status: 69)
    }
    var openOptions = MarkdownCLI.OpenOptions()
    openOptions.background = !options.focus
    let watcher = AgentWatcher(roots: roots, debounce: options.debounce) { urls in
        for url in urls {
            FileHandle.standardError.write(Data("down: opening \(url.path)\n".utf8))
        }
        launch(urls.map(\.path), options: openOptions)
    }
    guard watcher.start() else {
        writeError("could not watch \(roots.map(\.path).joined(separator: ", "))", status: 70)
    }
    let scope = roots.map { $0.lastPathComponent }.joined(separator: ", ")
    FileHandle.standardError.write(Data("down: watching \(scope) — Markdown changes open in Downright. ^C to stop.\n".utf8))
    dispatchMain()

case .hook(let options):
    let executable = resolvedExecutable()
    switch options.mode {
    case .print:
        print(AgentBridge.hookSnippet(executable: executable))
    case .install, .uninstall:
        let url = options.scope.settingsURL(
            home: URL(fileURLWithPath: NSHomeDirectory()),
            workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        )
        let existing: [String: Any]
        do {
            existing = try MarkdownCLI.loadSettings(at: url)
        } catch {
            writeError(error.localizedDescription, status: 65)
        }
        let result = options.mode == .install
            ? AgentBridge.installingHook(into: existing, executable: executable)
            : AgentBridge.removingHook(from: existing, executable: executable)
        guard result.changed else {
            print(options.mode == .install
                ? "Already installed in \(url.path)"
                : "No Downright hook found in \(url.path)")
            exit(0)
        }
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try AgentBridge.encode(result.settings).write(to: url, options: .atomic)
        } catch {
            writeError("cannot write \(url.path): \(error.localizedDescription)", status: 73)
        }
        print(options.mode == .install
            ? "Installed in \(url.path) — agent edits to Markdown now open in Downright."
            : "Removed from \(url.path).")
    }
}
