import Foundation
import Testing
@testable import DownrightApp

@Suite(.serialized)
struct CommandPaletteTests {
    private let entries = [
        CommandPaletteEntry(
            command: .find,
            title: "Find…",
            synonyms: ["search", "locate"],
            binding: "⌘F",
            scopes: [.read, .live, .source]
        ),
        CommandPaletteEntry(
            command: .frontMatterEditor,
            title: "Front Matter…",
            synonyms: ["metadata", "yaml"],
            binding: nil,
            scopes: [.read, .live, .source]
        ),
        CommandPaletteEntry(
            command: .tableEditor,
            title: "Edit Table…",
            synonyms: ["grid", "cells"],
            binding: "⌥T",
            scopes: [.read, .live, .source]
        ),
    ]

    @Test func titleAndSynonymSearchMatchAllTerms() {
        var model = CommandPaletteModel(entries: entries)
        model.updateQuery("yaml")
        #expect(model.results.map(\.command) == [.frontMatterEditor])

        model.updateQuery("edit cells")
        #expect(model.results.map(\.command) == [.tableEditor])
    }

    @Test func fuzzySearchRanksPrefixBeforeLooseMatch() {
        var model = CommandPaletteModel(entries: entries)
        model.updateQuery("find")
        #expect(model.results.first?.command == .find)
        model.updateQuery("fm")
        #expect(model.results.first?.command == .frontMatterEditor)
    }

    @Test func recentCommandsLeadEmptyQueryAndTieBreakSearch() {
        var model = CommandPaletteModel(entries: entries, recentCommands: [.tableEditor, .find])
        #expect(model.results.map(\.command) == [.tableEditor, .find, .frontMatterEditor])
        model.updateQuery("e")
        #expect(model.results.first?.command == .tableEditor)
        model.record(.frontMatterEditor)
        model.updateQuery("")
        #expect(model.results.first?.command == .frontMatterEditor)
    }

    @Test func selectionWrapsAndQueryResetsSelection() {
        var model = CommandPaletteModel(entries: entries)
        model.moveSelection(by: -1)
        #expect(model.selectedIndex == 2)
        model.moveSelection(by: 1)
        #expect(model.selectedIndex == 0)
        model.select(index: 2)
        model.updateQuery("find")
        #expect(model.selectedIndex == 0)
        #expect(model.selectedEntry?.command == .find)
    }

    @Test func entryExposesBindingAndScopeForAccessibleRows() {
        let model = CommandPaletteModel(entries: entries)
        let find = model.entries.first { $0.command == .find }
        #expect(find?.binding == "⌘F")
        #expect(find?.scopeLabel == "Read / Live / Source")
        #expect(model.entries.first { $0.command == .frontMatterEditor }?.binding == nil)
    }

    @Test func recentStoreDeduplicatesAndLimitsHistory() {
        let suite = "CommandPaletteTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = UserDefaultsCommandPaletteRecentStore(defaults: defaults, limit: 2)
        store.record(.find)
        store.record(.tableEditor)
        store.record(.find)
        #expect(store.recentCommands() == [.find, .tableEditor])
        defaults.removePersistentDomain(forName: suite)
    }
}
