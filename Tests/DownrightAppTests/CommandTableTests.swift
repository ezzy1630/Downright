import AppKit
import Foundation
import MarkdownCore
import Testing
@testable import DownrightApp

/// The command table is the single source of truth for menus, shortcuts, and
/// the palette (§7.2).  These tests hold it to that: a command that exists is
/// reachable, sits where it says it sits, and carries a shortcut that survives
/// a round trip through the keybindings file.
@Suite(.serialized)
@MainActor
struct CommandTableTests {

    // MARK: - The menu bar is derived from the table

    private struct Placement {
        var command: Command
        /// Title of the top-level menu the item was found under.
        var menuTitle: String
    }

    private func placements() -> [Placement] {
        // `MainMenu.build()` assigns NSApp.servicesMenu and friends.
        _ = NSApplication.shared
        var found: [Placement] = []
        func walk(_ menu: NSMenu, under title: String) {
            for item in menu.items {
                if let command = MainMenu.command(for: item) {
                    found.append(Placement(command: command, menuTitle: title))
                }
                if let submenu = item.submenu { walk(submenu, under: title) }
            }
        }
        for item in MainMenu.build().items {
            guard let submenu = item.submenu else { continue }
            walk(submenu, under: submenu.title)
        }
        return found
    }

    /// The one test that stops the menu table from drifting away from the
    /// command table again — commands reachable only from the palette, menus
    /// whose groups were never iterated, and items duplicated across two menus
    /// are all the same failure.
    @Test func everyCommandAppearsInExactlyOneMenu() {
        let counts = placements().reduce(into: [Command: Int]()) { $0[$1.command, default: 0] += 1 }
        for command in Command.allCases {
            let count = counts[command] ?? 0
            if MainMenu.commandsHiddenFromMenuBar.contains(command) {
                #expect(count == 0, "\(command.rawValue) is on the hidden list but appears in a menu")
            } else {
                #expect(count == 1, "\(command.rawValue) appears in \(count) menus, expected 1")
            }
        }
    }

    /// The keybinding editor prints `Command.menu` in its "Menu" column, so a
    /// command placed elsewhere makes Settings lie to the user.
    @Test func everyCommandSitsInTheMenuItAdvertises() {
        for placement in placements() {
            #expect(
                placement.menuTitle == placement.command.menu.title,
                "\(placement.command.rawValue) says \(placement.command.menu.title), found under \(placement.menuTitle)"
            )
        }
    }

    /// Window and Help used to be hand-built, so anything declared for them
    /// vanished.  Application was not even a case.
    @Test func applicationWindowAndHelpMenusComeFromTheTable() {
        let byMenu = Dictionary(grouping: placements(), by: \.menuTitle).mapValues { $0.map(\.command) }
        #expect(byMenu["Downright"]?.contains(.checkForUpdates) == true)
        #expect(byMenu["Downright"]?.contains(.preferences) == true)
        #expect(byMenu["Window"]?.contains(.splitView) == true)
        #expect(byMenu["Window"]?.contains(.pinWindow) == true)
        for command in Command.allCases where command.menu == .help {
            #expect(byMenu["Help"]?.contains(command) == true, "\(command.rawValue) is declared for Help")
        }
    }

    /// "Check for Updates…" was a hardcoded item with its own target, so it
    /// ignored rebinding and duplicated the title literal.
    @Test func checkForUpdatesIsAnOrdinaryCommandItem() {
        _ = NSApplication.shared
        let appMenu = MainMenu.build().items.compactMap(\.submenu).first { $0.title == "Downright" }
        let item = appMenu?.items.first { $0.title == Command.checkForUpdates.title }
        #expect(item != nil)
        #expect(MainMenu.command(for: item ?? NSMenuItem()) == .checkForUpdates)
    }

    @Test func contentsOutlineKeepsOneCanonicalCommandAndPaletteNames() {
        #expect(Command.documentLens.title == "Contents / Outline")
        let model = CommandPaletteModel(commands: [.documentLens], bindings: { _ in [] })
        #expect(model.results.map(\.command) == [.documentLens])
        var outline = model
        outline.updateQuery("outline")
        #expect(outline.results.map(\.command) == [.documentLens])
        var contents = model
        contents.updateQuery("contents")
        #expect(contents.results.map(\.command) == [.documentLens])
    }

    /// The standard items the Edit and Window menus were missing.
    @Test func standardMenuItemsExistWithTheirMacOSChords() {
        _ = NSApplication.shared
        var titles: [String: (String, NSEvent.ModifierFlags)] = [:]
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                titles[item.title] = (item.keyEquivalent, item.keyEquivalentModifierMask)
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(MainMenu.build())

        #expect(titles["Paste and Match Style"]?.0 == "v")
        #expect(titles["Paste and Match Style"]?.1 == [.command, .shift])
        #expect(titles["Paste as Markdown"]?.0 == "")
        #expect(titles["Page Setup…"]?.0 == "p")
        #expect(titles["Page Setup…"]?.1 == [.command, .shift])
        #expect(titles["Enter Full Screen"]?.0 == "f")
        #expect(titles["Enter Full Screen"]?.1 == [.control, .command])
        for expected in [
            "Delete", "Find", "Spelling and Grammar", "Substitutions", "Transformations", "Speech",
            "Downright Help", "Markdown Reference", "Report an Issue", "Star Downright on GitHub",
            "Support Downright",
        ] {
            #expect(titles[expected] != nil, "the menu bar is missing \(expected)")
        }
    }

    @Test func supportMenuItemOpensGitHubSponsors() {
        _ = NSApplication.shared
        let helpMenu = MainMenu.build().items.compactMap(\.submenu).first { $0.title == "Help" }
        let item = helpMenu?.items.first { $0.title == "Support Downright" }
        #expect(item?.representedObject as? String == "https://github.com/sponsors/ezzy1630")
        #expect(item?.target === HelpLinkTarget.shared)
    }

    // MARK: - Key binding serialisation (the file-destroying bug)

    private static let everyModifierCombination: [NSEvent.ModifierFlags] = {
        let parts: [NSEvent.ModifierFlags] = [.command, .shift, .option, .control]
        return (0..<16).map { mask in
            parts.enumerated().reduce(into: NSEvent.ModifierFlags()) { flags, entry in
                if mask & (1 << entry.offset) != 0 { flags.insert(entry.element) }
            }
        }
    }()

    private static let everyKey = [
        "+", "-", "=", "left", "right", "up", "down", "space", "tab", "return",
        "backslash", "[", "]", ",", "0", "a",
    ]

    @Test func everyKeyAndModifierCombinationRoundTripsThroughJSON() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for key in Self.everyKey {
            for modifiers in Self.everyModifierCombination {
                let binding = KeyBinding(key, modifiers)
                let data = try encoder.encode(binding)
                let decoded = try decoder.decode(KeyBinding.self, from: data)
                #expect(decoded == binding, "\(binding.serialized) did not survive JSON")
                #expect(decoded.key == key)
            }
        }
    }

    /// `KeyBinding("+", .command).serialized == "cmd++"`, which the old parser
    /// read back as "no key at all".
    @Test func legacyStringFormRoundTripsIncludingPlus() throws {
        for key in Self.everyKey {
            for modifiers in Self.everyModifierCombination {
                let binding = KeyBinding(key, modifiers)
                let parsed = try #require(
                    KeyBinding(parsing: binding.serialized), "failed to parse \(binding.serialized)"
                )
                #expect(parsed == binding)
            }
        }
        #expect(KeyBinding(parsing: "cmd++") == KeyBinding("+", .command))
        #expect(KeyBinding(parsing: "+") == KeyBinding("+"))
        #expect(KeyBinding(parsing: "shift+cmd++") == KeyBinding("+", [.command, .shift]))
    }

    /// Files written by older builds hold a plain string.
    @Test func legacyStringBindingsStillDecode() throws {
        let data = Data(#"{"overrides":{"save":["opt+cmd+s"]},"vimKeysEnabled":true}"#.utf8)
        guard case .loaded(let vim, let overrides) = KeybindingLoad.decode(data) else {
            Issue.record("a legacy string file must still load")
            return
        }
        #expect(vim)
        #expect(overrides[.save] == [KeyBinding("s", [.command, .option])])
    }

    /// The whole point: recording ⌘⇧+ must not cost the user every other
    /// override and their vim setting.
    @Test func aPlusOverrideSurvivesAWriteAndReadCycle() throws {
        let stored = KeybindingLoad.Stored(
            vimKeysEnabled: true,
            overrides: [
                Command.increaseTextSize.rawValue: [KeyBinding("+", [.command, .shift])],
                Command.save.rawValue: [KeyBinding("s", .command)],
            ]
        )
        let data = try JSONEncoder().encode(stored)
        guard case .loaded(let vim, let overrides) = KeybindingLoad.decode(data) else {
            Issue.record("a `+` binding must not make the file undecodable")
            return
        }
        #expect(vim)
        #expect(overrides[.increaseTextSize] == [KeyBinding("+", [.command, .shift])])
        #expect(overrides[.save] == [KeyBinding("s", .command)])
    }

    @Test func missingFileIsAbsentAndBadFileIsUnreadable() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandTableTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let missing = directory.appendingPathComponent("keybindings.json")
        guard case .absent = KeybindingLoad.read(contentsOf: missing) else {
            Issue.record("a missing file is the normal first run, not a failure")
            return
        }

        try Data("{ this is not json".utf8).write(to: missing)
        guard case .unreadable = KeybindingLoad.read(contentsOf: missing) else {
            Issue.record("a corrupt file must be reported, not silently replaced by defaults")
            return
        }

        // An unknown modifier name is corruption too: dropping it would change
        // what the user's shortcut does without telling them.
        try Data(#"{"overrides":{"save":[{"key":"s","modifiers":["hyper"]}]},"vimKeysEnabled":false}"#.utf8)
            .write(to: missing)
        guard case .unreadable = KeybindingLoad.read(contentsOf: missing) else {
            Issue.record("an unknown modifier must not decode")
            return
        }
    }

    // MARK: - Preconditions drive menu validation

    @Test func menuValidationFollowsPreconditions() {
        let none = CommandContext.applicationOnly(canCheckForUpdates: false)
        #expect(Command.open.isEnabled(in: none))
        #expect(Command.preferences.isEnabled(in: none))
        #expect(!Command.save.isEnabled(in: none))
        #expect(!Command.printDocument.isEnabled(in: none))
        #expect(!Command.exportPDF.isEnabled(in: none))
        #expect(!Command.checkForUpdates.isEnabled(in: none))
        #expect(Command.checkForUpdates.isEnabled(in: .applicationOnly(canCheckForUpdates: true)))

        let unsaved = CommandContext(hasDocument: true)
        #expect(Command.save.isEnabled(in: unsaved))
        #expect(Command.printDocument.isEnabled(in: unsaved))
        #expect(!Command.revealInFinder.isEnabled(in: unsaved))
        #expect(!Command.versionTimeline.isEnabled(in: unsaved))
        #expect(!Command.exportSelectionAsImage.isEnabled(in: unsaved))

        let saved = CommandContext(hasDocument: true, documentHasFile: true, hasSelection: true)
        #expect(Command.revealInFinder.isEnabled(in: saved))
        #expect(Command.versionTimeline.isEnabled(in: saved))
        #expect(Command.exportSelectionAsImage.isEnabled(in: saved))
        #expect(Command.useSelectionForFind.isEnabled(in: saved))
    }

    @Test func validationOnlyClaimsItemsThatCarryACommand() {
        let plain = NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        #expect(MainMenu.validate(plain, in: .applicationOnly(canCheckForUpdates: false)))
        #expect(!MainMenu.validate(MainMenu.commandItem(.save), in: .applicationOnly(canCheckForUpdates: false)))
    }

    // MARK: - Shortcuts

    /// The reverse index keeps the first claim and drops the rest silently, so
    /// a collision inside one scope is a shortcut that quietly stops working.
    @Test func defaultBindingsDoNotCollideWithinAScope() {
        let resolved = KeybindingDefaults.table
        for scope in CommandScope.allCases {
            var claimed: [KeyBinding: Command] = [:]
            for command in Command.allCases where command.scopes.contains(scope) {
                for binding in resolved[command] ?? [] {
                    if let owner = claimed[binding] {
                        Issue.record("\(binding.displayString) is claimed by \(owner.rawValue) and \(command.rawValue) in .\(scope.rawValue)")
                    }
                    claimed[binding] = command
                }
            }
        }
    }

    /// Chords macOS reserves, which the app used to take.
    @Test func macOSConventionChordsAreLeftAlone() {
        let reserved: [(KeyBinding, String)] = [
            (KeyBinding("f", [.control, .command]), "Enter Full Screen"),
            (KeyBinding("p", [.command, .shift]), "Page Setup"),
            (KeyBinding("v", [.command, .shift]), "Paste and Match Style"),
            (KeyBinding("t", .command), "New Tab"),
            (KeyBinding("t", [.command, .shift]), "Reopen Closed Tab"),
            (KeyBinding("d", .command), "Duplicate"),
            (KeyBinding("up", .option), "moveParagraphBackward:"),
            (KeyBinding("down", .option), "moveParagraphForward:"),
        ]
        let all = KeybindingDefaults.table.flatMap { $0.value }
        for (binding, owner) in reserved {
            #expect(!all.contains(binding), "\(binding.displayString) belongs to \(owner)")
        }
        // ⌘0 is Actual Size on macOS.
        #expect(KeybindingDefaults.table[.resetTextSize] == [KeyBinding("0", .command)])
    }

    /// Every command the user is likely to reach for daily has a keyboard path
    /// (§7.2, "give every action a keyboard path where it saves time").
    @Test func highFrequencyActionsHaveBindings() {
        for command in [
            Command.toggleTaskAtCaret, .indentList, .outdentList,
            .nextHeading, .previousHeading, .zoomLevel1, .zoomLevel5, .zoomIn, .zoomOut,
        ] {
            #expect(
                KeybindingDefaults.table[command]?.isEmpty == false,
                "\(command.rawValue) has no binding"
            )
        }
        // Heading jumps and structural zoom must work with a caret in the
        // document, not only in Read mode.
        for command in [Command.nextHeading, .previousHeading, .zoomLevel3] {
            #expect(command.scopes.contains(.live))
            let primary = KeybindingDefaults.table[command]?.first
            #expect(primary?.modifiers.contains(.command) == true)
        }
    }

    // MARK: - Palette ranking

    private func paletteModel(providers: [any QuickOpenProvider] = []) -> CommandPaletteModel {
        CommandPaletteModel(commands: Command.allCases, bindings: { _ in [] }, providers: providers)
    }

    /// Scoring used to run over `"\(title) \(subtitle)"`, and every command's
    /// subtitle ends in "Document", so `doc` matched essentially everything.
    @Test func quickResultsDoNotMatchTheRenderedSubtitle() {
        var model = paletteModel()
        model.updateQuery("doc")
        let commands = commands(in: model)
        #expect(commands.count < Command.allCases.count / 4)
        #expect(!commands.contains(.save))
        #expect(!commands.contains(.printDocument))
        #expect(commands.contains(.documentLens))
        #expect(commands.contains(.documentHealth))
    }

    /// The score the matcher computed used to be discarded and recomputed from
    /// rendered text; results now carry it, so the list is ordered by the
    /// ranking that actually ran.
    @Test func quickResultsCarryTheirScoreAndStaySorted() {
        var model = paletteModel()
        model.updateQuery("timeline")
        let scores = model.quickResults.map(\.score)
        #expect(scores.first ?? 0 > 0)
        #expect(scores == scores.sorted(by: >))
        #expect(Set(commands(in: model)) == [.versionTimeline])
    }

    /// Recency was computed in one code path and dropped in the one that ran.
    @Test func recencyBreaksTiesInTheListThatIsActuallyShown() {
        // Same matched prefix, so the two entries score identically and only
        // the tie-break can separate them.
        let entries = [
            CommandPaletteEntry(command: .documentLens, title: "Outline A", synonyms: [], binding: nil, scopes: [.live]),
            CommandPaletteEntry(command: .taskPanel, title: "Outline B", synonyms: [], binding: nil, scopes: [.live]),
        ]
        var model = CommandPaletteModel(entries: entries)
        model.updateQuery("outline")
        #expect(model.quickResults.map(\.score).allSatisfy { $0 == model.quickResults[0].score })
        #expect(commands(in: model).first == .documentLens)

        model.record(.taskPanel)
        #expect(commands(in: model).first == .taskPanel)
    }

    private func commands(in model: CommandPaletteModel) -> [Command] {
        model.quickResults.compactMap { result in
            guard case .command(let command) = result.action else { return nil }
            return command
        }
    }

    /// `#` had no producer, so `.headings` was unreachable and the provider's
    /// handling of it was dead code.
    @Test func hashPrefixFiltersHeadings() {
        #expect(QuickOpenQuery("#intro").filter == .headings)
        #expect(QuickOpenQuery("#intro").terms == "intro")
        #expect(QuickOpenQuery("#task fix").filter == .tasks)
        #expect(QuickOpenQuery("#tasks").filter == .tasks)

        let document = MarkdownParser.parse("# Intro\n\n- [ ] ship it\n")
        let provider = CurrentDocumentQuickOpenProvider(document: document)
        let headings = provider.results(for: QuickOpenQuery("#intro"))
        #expect(headings.allSatisfy { $0.kind == .heading })
        #expect(headings.contains { $0.title == "Intro" })
    }

    @Test func providerResultsMatchSearchTextButNotSubtitle() {
        let url = URL(fileURLWithPath: "/tmp/notes/design.md")
        var model = paletteModel(providers: [RecentFilesQuickOpenProvider(files: [url])])
        model.updateQuery("file: notes")
        #expect(model.quickResults.contains { $0.action == .open(url) })
    }
}
