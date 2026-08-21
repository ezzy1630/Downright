import Foundation
import Testing
@testable import DownrightApp

@Suite(.serialized)
struct WelcomeTourTests {
    private var sourceURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/Welcome.md")
    }

    @Test
    func everyTourShortcutTokenNamesACommandInTheCommandTable() throws {
        let source = try String(contentsOf: sourceURL, encoding: .utf8)
        let tokens = WelcomeTour.tokens(in: source)
        #expect(!tokens.isEmpty)
        for token in tokens {
            let parts = token.split(separator: ":", maxSplits: 1).map(String.init)
            #expect(parts.count == 2, "malformed tour token: \(token)")
            guard parts.count == 2 else { continue }
            let command = try #require(Command(rawValue: parts[1]))
            if parts[0] == "shortcut" {
                // A user may intentionally clear this binding; that must not
                // make the tour fail to materialize.
                _ = KeybindingDefaults.table[command]
            } else {
                #expect(parts[0] == "command", "unknown tour token kind: \(token)")
            }
        }
        let rendered = try WelcomeTour.render(source, binding: { KeybindingDefaults.table[$0]?.first })
        #expect(!rendered.contains("{{"))
        let unbound = try WelcomeTour.render(source, binding: { _ in nil })
        #expect(unbound.contains("Unassigned"))
    }

    @Test
    func renderedTourUsesCustomizedBindings() throws {
        let rendered = try WelcomeTour.render(
            "Use {{shortcut:documentLens}} to open {{command:documentLens}}.",
            binding: { command in
                command == .documentLens ? KeyBinding("o", [.command, .shift]) : nil
            }
        )
        #expect(rendered == "Use ⇧⌘O to open Contents / Outline.")
    }

    @Test
    func invalidTourTokensFailClosed() throws {
        #expect(throws: WelcomeTour.Error.unknownCommand("missing")) {
            try WelcomeTour.render("{{shortcut:missing}}", binding: { _ in nil })
        }
        #expect(try WelcomeTour.render("{{shortcut:documentLens}}", binding: { _ in nil }) == "Unassigned")
        #expect(throws: WelcomeTour.Error.malformedToken("{{shortcut:documentLens")) {
            try WelcomeTour.render("{{shortcut:documentLens", binding: { _ in nil })
        }
    }
}
