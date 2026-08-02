import Foundation
import drdownright

let arguments = Array(CommandLine.arguments.dropFirst())

func writeError(_ message: String, status: Int32) -> Never {
    FileHandle.standardError.write(Data("down: \(message)\n".utf8))
    exit(status)
}

func readInputs(_ paths: [String]) -> [(String, String)] {
    let requested = paths.isEmpty ? ["-"] : paths
    return requested.map { path in
        if path == "-" {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            guard !data.isEmpty else { writeError("stdin is empty", status: 66) }
            return ("stdin", String(decoding: data, as: UTF8.self))
        }
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            writeError("\(path): no such file", status: 66)
        }
        do { return (url.path, try String(contentsOf: url, encoding: .utf8)) }
        catch { writeError("\(path): cannot read UTF-8 Markdown (\(error.localizedDescription))", status: 65) }
    }
}

func expandedMarkdownPaths(_ paths: [String]) -> [String] {
    paths.flatMap { path -> [String] in
        guard path != "-" else { return [path] }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return [path]
        }
        guard let enumerator = FileManager.default.enumerator(atPath: path) else { return [] }
        return enumerator.compactMap { item in
            guard let item = item as? String else { return nil }
            let full = URL(fileURLWithPath: path).appendingPathComponent(item).path
            return MarkdownCLI.isMarkdownPath(full) ? full : nil
        }.sorted()
    }
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
    process.arguments = ["kMDItemCFBundleIdentifier == 'com.unrulyagency.downright'"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    guard (try? process.run()) != nil else { return nil }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map { URL(fileURLWithPath: String($0)) }
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
    let inputs = readInputs(expandedMarkdownPaths(paths))
    var findings = 0
    for (index, input) in inputs {
        let base = input == "stdin" ? nil : URL(fileURLWithPath: index).deletingLastPathComponent()
        let diagnostics = MarkdownCLI.diagnostics(for: input, baseURL: base)
        let compatibility = target.map { MarkdownCLI.compatibilityDiagnostics(for: input, target: $0) } ?? []
        findings += diagnostics.count + compatibility.count
        if json {
            var values = diagnostics.map {
                ["path": index, "id": $0.id, "severity": $0.severity.rawValue, "category": $0.category.rawValue, "message": $0.message, "location": $0.range.location] as [String: Any]
            }
            values += compatibility.map {
                [
                    "path": index,
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
            for diagnostic in diagnostics { print("\(index):\(diagnostic.range.location + 1): \(diagnostic.severity.rawValue): \(diagnostic.message) [\(diagnostic.id)]") }
            for diagnostic in compatibility {
                print("\(index):\(diagnostic.range.location + 1): warning: \(diagnostic.title) [target:\(target?.rawValue ?? "unknown")]")
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
case .open(let options, let paths):
    var paths = paths
    if paths.contains("-") {
        guard let piped = stdinFile() else { writeError("stdin is not available", status: 66) }
        paths = paths.filter { $0 != "-" }
        paths.append(piped.path)
    } else if let piped = stdinFile() {
        paths.append(piped.path)
    }
    guard !paths.isEmpty else { print(MarkdownCLI.usage()); exit(64) }
    for path in paths where !FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).path) {
        writeError("\(path): no such file", status: 66)
    }
    guard let app = locateApp() else {
        writeError("could not find Downright.app; install it in /Applications or run Scripts/bundle-app.sh", status: 69)
    }
    var openArguments = ["-a", app.path]
    if options.newWindow { openArguments.append("-n") }
    if options.background { openArguments.append("-g") }
    if options.wait { openArguments.append("-W") }
    openArguments.append(contentsOf: paths)
    if options.edit { openArguments.append(contentsOf: ["--args", "--mode", "live"]) }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = openArguments
    do { try process.run(); process.waitUntilExit(); exit(process.terminationStatus) }
    catch { writeError("failed to launch: \(error.localizedDescription)", status: 70) }
}
