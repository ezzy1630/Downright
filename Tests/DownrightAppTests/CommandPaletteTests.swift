import Foundation
import Testing
import MarkdownCore
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
        #expect(find?.scopeLabel == "Document / Source")
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
    @Test func queryPrefixesSelectQuickOpenProvider() {
        #expect(QuickOpenQuery("> format").filter == .commands)
        #expect(QuickOpenQuery("@head").filter == .symbols)
        #expect(QuickOpenQuery("#task fix").filter == .tasks)
        #expect(QuickOpenQuery("file: notes").filter == .files)
        #expect(QuickOpenQuery("asset: logo").filter == .assets)
        #expect(QuickOpenQuery("link: docs").filter == .links)
    }

    @Test func currentDocumentProviderReturnsHeadingsTasksLinksAndAssets() {
        let text = """
        # Plan

        - [ ] Write [docs](https://example.com).
        ![logo](images/logo.png)
        """
        let provider = CurrentDocumentQuickOpenProvider(document: MarkdownParser.parse(text))
        #expect(provider.results(for: QuickOpenQuery("@plan")).contains { $0.kind == .heading })
        #expect(provider.results(for: QuickOpenQuery("#task write")).contains { $0.kind == .task })
        #expect(provider.results(for: QuickOpenQuery("link: docs")).contains { $0.kind == .link })
        #expect(provider.results(for: QuickOpenQuery("asset: logo")).contains { $0.kind == .asset })
    }

    @Test func injectedWorkspaceFilesAndSymbolsJoinOneRankedList() {
        let url = URL(fileURLWithPath: "/tmp/notes.md")
        let symbol = QuickOpenResult(id: "symbol:1", kind: .symbol, title: "Project Symbol", action: .select(NSRange(location: 3, length: 2)))
        var model = CommandPaletteModel(
            entries: entries,
            providers: [WorkspaceQuickOpenProvider(files: [url], symbols: [symbol])]
        )
        model.updateQuery("file: notes")
        #expect(model.selectedResult?.kind == .workspaceFile)
        model.updateQuery("@project")
        #expect(model.quickResults.first?.id == "symbol:1")
    }

    @Test func quickOpenCommandActionPreservesCommandRecents() {
        var model = CommandPaletteModel(entries: entries)
        model.updateQuery("> find")
        guard case .command(.find) = model.selectedResult?.action else {
            Issue.record("command prefix must return a command action")
            return
        }
        model.record(.find)
        #expect(model.recentCommands.first == .find)
    }
}
