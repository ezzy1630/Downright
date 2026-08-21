import AppKit

/// A small, typed description of one command shown by the palette.
struct CommandPaletteEntry: Identifiable, Equatable {
    let command: Command
    let title: String
    let synonyms: [String]
    let binding: String?
    let scopes: [CommandScope]

    var id: Command { command }

    var scopeLabel: String {
        var seen = Set<String>()
        return scopes.map(\.paletteTitle).filter { seen.insert($0).inserted }.joined(separator: " / ")
    }

    /// Everything a query is allowed to match.  The rendered subtitle
    /// ("⌘⇧K  ·  Document") is deliberately absent: searching it made `doc`
    /// match nearly every command in the app.
    var searchCandidates: [String] { [title] + synonyms }
}

extension CommandScope {
    var paletteTitle: String {
        switch self {
        case .read, .live: return "Document"
        case .source: return "Source"
        }
    }
}

/// A persistence seam for command history.  The palette does not know where
/// history lives, which keeps tests deterministic and avoids disk work while
/// the user types.
protocol CommandPaletteRecentStore: AnyObject {
    func recentCommands() -> [Command]
    func record(_ command: Command)
}

final class UserDefaultsCommandPaletteRecentStore: CommandPaletteRecentStore {
    private let defaults: UserDefaults
    private let key: String
    private let limit: Int

    init(
        defaults: UserDefaults = .standard,
        key: String = "commandPalette.recentCommands",
        limit: Int = 12
    ) {
        self.defaults = defaults
        self.key = key
        self.limit = max(1, limit)
    }

    func recentCommands() -> [Command] {
        guard let values = defaults.array(forKey: key) as? [String] else { return [] }
        return values.compactMap(Command.init(rawValue:))
    }

    func record(_ command: Command) {
        var values = recentCommands().filter { $0 != command }
        values.insert(command, at: 0)
        defaults.set(values.prefix(limit).map(\.rawValue), forKey: key)
    }
}

/// Fuzzy search for the palette.
///
/// There is one matcher in the app: `FuzzyMatcher`, the dynamic program the
/// outline panel already uses, which scores word boundaries, prefixes, and
/// consecutive runs and reports the positions it matched.  This wrapper only
/// decides *which strings* a query is allowed to see and how several terms
/// combine.
enum PaletteSearch {
    /// Best score across `candidates`; nil when the query matches none of them.
    /// An empty query matches everything with score 0.
    static func score(_ query: String, in candidates: [String]) -> Int? {
        let terms = query.lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .map(String.init)
        guard !terms.isEmpty else { return 0 }
        let haystacks = candidates.filter { !$0.isEmpty }
        guard !haystacks.isEmpty else { return nil }

        // Every term must land somewhere, so `edit cells` finds the command
        // whose title and synonyms together cover both words.
        var total = 0
        for term in terms {
            let best = haystacks.compactMap { FuzzyMatcher.match(needle: term, in: $0)?.score }.max()
            guard let best else { return nil }
            total += best
        }
        return total
    }
}

/// Pure search and selection state for the command palette.
struct CommandPaletteModel {
    private final class PaletteResultCache {
        var resultsQuery: String?
        var results: [CommandPaletteEntry]?
        var quickQuery: String?
        var quickResults: [QuickOpenResult]?

        func invalidate() {
            resultsQuery = nil
            results = nil
            quickQuery = nil
            quickResults = nil
        }
    }

    private let cache = PaletteResultCache()

    private(set) var entries: [CommandPaletteEntry]
    private(set) var recentCommands: [Command]
    private(set) var providers: [any QuickOpenProvider]
    private(set) var selectedIndex: Int = 0
    private(set) var query = ""

    init(
        entries: [CommandPaletteEntry],
        recentCommands: [Command] = [],
        providers: [any QuickOpenProvider] = []
    ) {
        self.entries = entries
        self.recentCommands = Self.unique(recentCommands)
        self.providers = providers
    }

    init(
        commands: [Command] = Command.allCases,
        bindings: (Command) -> [KeyBinding] = { KeybindingStore.shared.bindings(for: $0) },
        recentCommands: [Command] = [],
        providers: [any QuickOpenProvider] = []
    ) {
        self.init(
            entries: commands.map { command in
                CommandPaletteEntry(
                    command: command,
                    title: command.title,
                    synonyms: CommandPaletteSynonyms.values[command] ?? [],
                    binding: bindings(command).first?.displayString,
                    scopes: CommandScope.allCases.filter { command.scopes.contains($0) }
                )
            },
            recentCommands: recentCommands,
            providers: providers
        )
    }

    // MARK: - Ranking

    /// A candidate and the numbers it is ordered by.  One ordering serves both
    /// result lists, so the palette cannot rank one way and the quick-open
    /// list another — which is how recency used to be dropped on the path that
    /// actually ran.
    private struct Ranked<Value> {
        var value: Value
        var score: Int
        var command: Command?
        var title: String
    }

    /// Score, then recency, then title.
    private static func ordered<Value>(_ items: [Ranked<Value>], recents: [Command]) -> [Value] {
        items.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            let left = lhs.command.flatMap { recents.firstIndex(of: $0) } ?? .max
            let right = rhs.command.flatMap { recents.firstIndex(of: $0) } ?? .max
            if left != right { return left < right }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
        .map(\.value)
    }

    private static func rankedEntries(
        _ entries: [CommandPaletteEntry], query: String
    ) -> [Ranked<CommandPaletteEntry>] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return entries.compactMap { entry in
            guard let score = PaletteSearch.score(trimmed, in: entry.searchCandidates) else { return nil }
            return Ranked(value: entry, score: score, command: entry.command, title: entry.title)
        }
    }

    // MARK: - Results

    var results: [CommandPaletteEntry] {
        if cache.results == nil || cache.resultsQuery != query {
            cache.results = Self.computeResults(entries: entries, recentCommands: recentCommands, query: query)
            cache.resultsQuery = query
        }
        return cache.results!
    }

    private static func computeResults(
        entries: [CommandPaletteEntry], recentCommands: [Command], query: String
    ) -> [CommandPaletteEntry] {
        ordered(rankedEntries(entries, query: query), recents: recentCommands)
    }

    var selectedEntry: CommandPaletteEntry? {
        let values = results
        guard values.indices.contains(selectedIndex) else { return nil }
        return values[selectedIndex]
    }

    /// One ranked list for commands and every injected Quick Open provider.
    var quickResults: [QuickOpenResult] {
        if cache.quickResults == nil || cache.quickQuery != query {
            cache.quickResults = Self.computeQuickResults(
                entries: entries, recentCommands: recentCommands, providers: providers, query: query
            )
            cache.quickQuery = query
        }
        return cache.quickResults!
    }

    private static func computeQuickResults(
        entries: [CommandPaletteEntry],
        recentCommands: [Command],
        providers: [any QuickOpenProvider],
        query: String
    ) -> [QuickOpenResult] {
        let parsed = QuickOpenQuery(query)
        var candidates: [Ranked<QuickOpenResult>] = []

        if parsed.filter == .all || parsed.filter == .commands {
            // Commands keep the score the entry matcher computed, synonyms and
            // all; re-scoring them against rendered text would throw it away.
            candidates += rankedEntries(entries, query: parsed.terms).map { ranked in
                let entry = ranked.value
                let result = QuickOpenResult(
                    id: "command:\(entry.command.rawValue)", kind: .command,
                    title: entry.title,
                    subtitle: [entry.binding, entry.scopeLabel].compactMap { $0 }.joined(separator: "  ·  "),
                    searchText: entry.synonyms.joined(separator: " "),
                    action: .command(entry.command),
                    score: ranked.score
                )
                return Ranked(value: result, score: ranked.score, command: entry.command, title: entry.title)
            }
        }

        // Providers list; they do not rank.  One function scores everything so
        // a heading and a command compete on the same scale.
        for result in providers.flatMap({ $0.results(for: parsed) }) {
            guard let score = PaletteSearch.score(parsed.terms, in: [result.title, result.searchText]) else {
                continue
            }
            let total = score + result.score
            candidates.append(
                Ranked(value: result.scored(total), score: total, command: nil, title: result.title)
            )
        }

        let ranked: [QuickOpenResult] = ordered(candidates, recents: recentCommands)
        guard parsed.terms.isEmpty, parsed.filter == .all else { return ranked }
        let recentRank = Dictionary(
            uniqueKeysWithValues: recentCommands.enumerated().map {
                ("command:\($0.element.rawValue)", $0.offset)
            }
        )
        return ranked.sorted(by: { (lhs: QuickOpenResult, rhs: QuickOpenResult) -> Bool in
            let leftRecent = recentRank[lhs.id] ?? Int.max
            let rightRecent = recentRank[rhs.id] ?? Int.max
            if leftRecent != rightRecent { return leftRecent < rightRecent }
            let leftKind = QuickOpenProviderKind.allCases.firstIndex(of: lhs.kind) ?? Int.max
            let rightKind = QuickOpenProviderKind.allCases.firstIndex(of: rhs.kind) ?? Int.max
            if leftKind != rightKind { return leftKind < rightKind }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        })
    }

    var selectedResult: QuickOpenResult? {
        let values = quickResults
        guard values.indices.contains(selectedIndex) else { return nil }
        return values[selectedIndex]
    }

    // MARK: - Selection

    mutating func updateQuery(_ value: String) {
        guard query != value else { return }
        query = value
        selectedIndex = 0
        cache.invalidate()
    }

    mutating func moveSelection(by offset: Int) {
        let count = quickResults.count
        guard count > 0 else { selectedIndex = 0; return }
        selectedIndex = (selectedIndex + offset).modulo(count)
    }

    mutating func select(index: Int) {
        guard quickResults.indices.contains(index) else { return }
        selectedIndex = index
    }

    mutating func record(_ command: Command) {
        recentCommands.removeAll { $0 == command }
        recentCommands.insert(command, at: 0)
        cache.invalidate()
    }

    private static func unique(_ commands: [Command]) -> [Command] {
        var seen = Set<Command>()
        return commands.filter { seen.insert($0).inserted }
    }
}

private enum CommandPaletteSynonyms {
    static let values: [Command: [String]] = [
        .sourceMode: ["markdown", "raw", "editor", "edit source", "full source"],
        .documentLens: ["contents", "outline", "headings", "document lens", "table of contents"],
        .taskPanel: ["tasks", "todo", "checkbox", "checklist"],
        .toggleTaskAtCaret: ["check", "tick", "checkbox", "done"],
        .frontMatterEditor: ["metadata", "yaml", "toml", "properties"],
        .tableEditor: ["tables", "grid", "cells", "rows", "columns"],
        .assetDoctor: ["images", "links", "missing files", "media"],
        .find: ["search", "locate"],
        .findReplace: ["search and replace", "substitute"],
        .tidyDocument: ["format", "clean", "lint", "fix"],
        .copyAsMarkdown: ["copy source", "markdown"],
        .copyAsRichText: ["copy formatted", "rich text"],
        .copyAsPlainText: ["copy text", "plain"],
        .revealInFinder: ["show file", "folder", "locate"],
        .versionTimeline: ["history", "versions", "snapshots", "revert"],
        .preferences: ["settings", "options", "configuration"],
        .showKeybindings: ["shortcuts", "keys", "keyboard"],
        .checkForUpdates: ["update", "updates", "upgrade", "refresh"],
    ]
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let value = self % divisor
        return value >= 0 ? value : value + divisor
    }
}
