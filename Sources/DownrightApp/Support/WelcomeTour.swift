import Foundation

/// The bundled tour is written with command tokens instead of copied shortcut
/// glyphs. A tour opened after a remap must teach the current command.
enum WelcomeTour {
    enum Error: Swift.Error, Equatable {
        case malformedToken(String)
        case unknownCommand(String)
        case missingBinding(Command)
    }

    /// Renders `{{shortcut:commandName}}` and `{{command:commandName}}` tokens.
    /// A deliberately cleared binding is rendered as `Unassigned` so the
    /// bundled tour remains openable and truthful after a remap.
    static func render(
        _ source: String,
        binding: (Command) -> KeyBinding? = { KeybindingStore.shared.primaryBinding(for: $0) }
    ) throws -> String {
        var output = ""
        var cursor = source.startIndex
        while let start = source[cursor...].range(of: "{{") {
            output += source[cursor..<start.lowerBound]
            guard let end = source[start.upperBound...].range(of: "}}") else {
                throw Error.malformedToken(String(source[start.lowerBound...]))
            }
            let token = String(source[start.upperBound..<end.lowerBound])
            output += try replacement(for: token, binding: binding)
            cursor = end.upperBound
        }
        output += source[cursor...]
        return output
    }

    /// Finds every instructional token so resource tests can validate the
    /// tour against the command table without starting an app window.
    static func tokens(in source: String) -> [String] {
        var values: [String] = []
        var cursor = source.startIndex
        while let start = source[cursor...].range(of: "{{"),
              let end = source[start.upperBound...].range(of: "}}") {
            values.append(String(source[start.upperBound..<end.lowerBound]))
            cursor = end.upperBound
        }
        return values
    }

    private static func replacement(
        for token: String,
        binding: (Command) -> KeyBinding?
    ) throws -> String {
        let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, ["shortcut", "command"].contains(parts[0]) else {
            throw Error.malformedToken(token)
        }
        guard let command = Command(rawValue: parts[1]) else {
            throw Error.unknownCommand(parts[1])
        }
        switch parts[0] {
        case "shortcut":
            return binding(command)?.displayString ?? "Unassigned"
        case "command":
            return command.title
        default:
            throw Error.malformedToken(token)
        }
    }
}
