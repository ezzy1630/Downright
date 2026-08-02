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

/// Pure search and selection state for the command palette.
struct CommandPaletteModel {
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

    var results: [CommandPaletteEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            let byCommand = Dictionary(uniqueKeysWithValues: entries.map { ($0.command, $0) })
            let recent = recentCommands.compactMap { byCommand[$0] }
            let recentSet = Set(recent.map(\.command))
            return recent + entries.filter { !recentSet.contains($0.command) }
        }

        let scored: [(score: Int, entry: CommandPaletteEntry)] = entries.compactMap { entry in
            guard let score = PaletteFuzzyMatcher.score(trimmed, in: entry) else { return nil }
            return (score: score, entry: entry)
        }
        return scored
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                let leftRecent = recentCommands.firstIndex(of: lhs.entry.command) ?? .max
                let rightRecent = recentCommands.firstIndex(of: rhs.entry.command) ?? .max
                if leftRecent != rightRecent { return leftRecent < rightRecent }
                return lhs.entry.title.localizedStandardCompare(rhs.entry.title) == .orderedAscending
            }
            .map(\.entry)
    }

    var selectedEntry: CommandPaletteEntry? {
        let values = results
        guard values.indices.contains(selectedIndex) else { return nil }
        return values[selectedIndex]
    }

    /// One ranked list for commands and every injected Quick Open provider.
    var quickResults: [QuickOpenResult] {
        let parsed = QuickOpenQuery(query)
        var candidates: [QuickOpenResult] = []
        if parsed.filter == .all || parsed.filter == .commands {
            candidates += commandResults(for: parsed.terms).map { entry in
                QuickOpenResult(
                    id: "command:\(entry.command.rawValue)", kind: .command,
                    title: entry.title,
                    subtitle: [entry.binding, entry.scopeLabel].compactMap { $0 }.joined(separator: "  ·  "),
                    action: .command(entry.command)
                )
            }
        }
        candidates += providers.flatMap { $0.results(for: parsed) }
        let scored = candidates.map { result in
            (result: result, score: Self.matchScore(parsed.terms, result: result))
        }
        return scored
            .filter { parsed.terms.isEmpty || $0.score >= 0 }
            .sorted { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if case (.command, .command) = (lhs.result.kind, rhs.result.kind) {
                    let left = Self.recentRank(lhs.result, recents: recentCommands)
                    let right = Self.recentRank(rhs.result, recents: recentCommands)
                    if left != right { return left < right }
                }
                return lhs.result.title.localizedStandardCompare(rhs.result.title) == .orderedAscending
            }
            .map(\.result)
    }

    var selectedResult: QuickOpenResult? {
        let values = quickResults
        guard values.indices.contains(selectedIndex) else { return nil }
        return values[selectedIndex]
    }

    mutating func updateQuery(_ value: String) {
        query = value
        selectedIndex = 0
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
    }

    private static func unique(_ commands: [Command]) -> [Command] {
        var seen = Set<Command>()
        return commands.filter { seen.insert($0).inserted }
    }

    private func commandResults(for terms: String) -> [CommandPaletteEntry] {
        guard !terms.isEmpty else { return results }
        let scored: [(score: Int, entry: CommandPaletteEntry)] = entries.compactMap { entry in
            guard let score = PaletteFuzzyMatcher.score(terms, in: entry) else { return nil }
            return (score: score, entry: entry)
        }
        return scored.sorted { lhs, rhs in lhs.score > rhs.score }.map(\.entry)
    }

    private static func matchScore(_ terms: String, result: QuickOpenResult) -> Int {
        guard !terms.isEmpty else { return 0 }
        let text = "\(result.title) \(result.subtitle)".lowercased()
        let query = terms.lowercased()
        if text == query { return 1_000 }
        if text.hasPrefix(query) { return 800 - text.count }
        var cursor = text.startIndex
        var matched = 0
        for character in query {
            guard let index = text[cursor...].firstIndex(of: character) else { return -1 }
            matched += 1
            cursor = text.index(after: index)
        }
        return 300 + matched * 10 - text.count
    }

    private static func recentRank(_ result: QuickOpenResult, recents: [Command]) -> Int {
        guard case .command(let command) = result.action else { return .max }
        return recents.firstIndex(of: command) ?? .max
    }
}

private enum CommandPaletteSynonyms {
    static let values: [Command: [String]] = [
        .sourceMode: ["markdown", "raw", "editor", "edit source", "full source"],
        .outlineQuickOpen: ["headings", "jump", "go to", "contents"],
        .toggleSidebar: ["files", "documents", "siblings", "navigator"],
        .outlinePanel: ["headings", "contents", "navigation"],
        .taskPanel: ["tasks", "todo", "checkbox", "checklist"],
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
        .preferences: ["settings", "options", "configuration"],
        .showKeybindings: ["shortcuts", "keys", "keyboard"],
    ]
}

private enum PaletteFuzzyMatcher {
    static func score(_ query: String, in entry: CommandPaletteEntry) -> Int? {
        let terms = query.lowercased().split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard !terms.isEmpty else { return 0 }
        let candidates = ([entry.title] + entry.synonyms).map { $0.lowercased() }
        var total = 0
        for term in terms {
            guard let best = candidates.compactMap({ score(term, in: $0) }).max() else { return nil }
            total += best
        }
        return total
    }

    private static func score(_ query: String, in candidate: String) -> Int? {
        if candidate == query { return 1_000 }
        if candidate.hasPrefix(query) { return 800 - candidate.count }
        if candidate.split(separator: " ").contains(where: { $0.hasPrefix(query) }) {
            return 650 - candidate.count
        }

        var cursor = candidate.startIndex
        var matched = 0
        var contiguous = 0
        var bestContiguous = 0
        for character in query {
            guard let index = candidate[cursor...].firstIndex(of: character) else { return nil }
            matched += 1
            if index == cursor {
                contiguous += 1
                bestContiguous = max(bestContiguous, contiguous)
            } else {
                contiguous = 1
            }
            cursor = candidate.index(after: index)
        }
        return 300 + matched * 12 + bestContiguous * 8 - candidate.count
    }
}

private extension Int {
    func modulo(_ divisor: Int) -> Int {
        let value = self % divisor
        return value >= 0 ? value : value + divisor
    }
}
