import AppKit
import Foundation

/// VS Code / Shiki theme import (§11.2).
///
/// Worth the effort for one specific reason: `beautiful-mermaid-swift` speaks
/// Shiki, so importing a VS Code theme is what makes code blocks and mermaid
/// diagrams share a single palette — the consistency §11.2 calls out as rare
/// and immediately noticeable.
enum VSCodeThemeImporter {

    static func theme(from data: Data, fallbackName: String) throws -> Theme {
        // Published themes are JSONC far more often than JSON: comments and
        // trailing commas both appear in shipped extensions.  Refusing them
        // would make the feature useless on exactly the files people have.
        let decoder = JSONDecoder()
        guard let raw = try? decoder.decode(VSCodeThemeFile.self, from: JSONCSanitizer.strip(data)) else {
            throw ThemeStoreError.notAVSCodeTheme
        }
        guard raw.colors != nil || raw.tokenColors != nil else { throw ThemeStoreError.notAVSCodeTheme }

        let colors = raw.colors?.values ?? [:]
        let scopes = raw.scopeEntries()

        let background = RGBA(colors["editor.background"]) ?? RGBA(hex: raw.isDark ? "#1e1e1e" : "#ffffff")!
        let text = RGBA(colors["editor.foreground"]) ?? raw.defaultForeground ?? RGBA(hex: raw.isDark ? "#d4d4d4" : "#1f1f1f")!

        let code = codeTheme(scopes: scopes, colors: colors, text: text, background: background)
        let palette = self.palette(colors: colors, text: text, background: background, code: code)

        let declaredName = raw.name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return Theme(
            name: declaredName.isEmpty ? fallbackName : declaredName,
            appearance: raw.appearance(background: background),
            palette: palette,
            code: code,
            typography: .default
        )
    }

    // MARK: - Code theme

    /// TextMate scopes to ask for, per token, most specific first.  The first
    /// query that any of the theme's selectors answers wins.
    private static let scopeQueries: [(SyntaxToken, [String])] = [
        (.keyword, ["keyword.control", "keyword", "storage.type", "storage.modifier", "storage"]),
        (.string, ["string.quoted", "string"]),
        (.number, ["constant.numeric"]),
        (.comment, ["comment"]),
        (.type, ["entity.name.type", "support.type", "entity.name.class", "support.class"]),
        (.function, ["entity.name.function", "support.function", "meta.function-call"]),
        (.variable, ["variable.other", "variable"]),
        (.constant, ["constant.language", "constant.character", "constant"]),
        (.operator, ["keyword.operator"]),
        (.punctuation, ["punctuation", "meta.brace"]),
        (.attribute, ["entity.other.attribute-name", "meta.decorator", "storage.type.annotation"]),
        (.diffAdded, ["markup.inserted"]),
        (.diffRemoved, ["markup.deleted"]),
        (.diffHeader, ["meta.diff.header", "markup.changed", "meta.diff.range"]),
    ]

    private static func codeTheme(
        scopes: [ScopeEntry], colors: [String: String], text: RGBA, background: RGBA
    ) -> CodeTheme {
        var found: [SyntaxToken: RGBA] = [:]
        for (token, queries) in scopeQueries {
            for query in queries {
                if let color = foreground(for: query, in: scopes) { found[token] = color; break }
            }
        }
        func color(_ token: SyntaxToken, _ fallback: @autoclosure () -> RGBA) -> ThemeColor {
            ThemeColor((found[token] ?? fallback()).hexString)
        }
        let added = RGBA(colors["gitDecoration.addedResourceForeground"])
            ?? RGBA(colors["editorGutter.addedBackground"]) ?? RGBA(hex: "#3f9c53")!
        let removed = RGBA(colors["gitDecoration.deletedResourceForeground"])
            ?? RGBA(colors["editorGutter.deletedBackground"]) ?? RGBA(hex: "#c1554d")!
        return CodeTheme(
            keyword: color(.keyword, text),
            string: color(.string, text),
            number: color(.number, text),
            comment: color(.comment, text.blended(with: background, 0.45)),
            type: color(.type, found[.keyword] ?? text),
            function: color(.function, found[.type] ?? text),
            variable: color(.variable, text),
            constant: color(.constant, found[.number] ?? text),
            operator: color(.operator, text.blended(with: background, 0.20)),
            punctuation: color(.punctuation, text.blended(with: background, 0.30)),
            attribute: color(.attribute, found[.function] ?? text),
            diffAdded: color(.diffAdded, added),
            diffRemoved: color(.diffRemoved, removed),
            diffHeader: color(.diffHeader, found[.comment] ?? text.blended(with: background, 0.40))
        )
    }

    // MARK: - Palette

    private static func palette(
        colors: [String: String], text: RGBA, background: RGBA, code: CodeTheme
    ) -> ThemePalette {
        func value(_ keys: String...) -> RGBA? {
            for key in keys {
                if let color = RGBA(colors[key]) { return color }
            }
            return nil
        }
        let accent = value("focusBorder", "textLink.foreground", "button.background")
            ?? RGBA(code.keyword.raw) ?? text
        let added = RGBA(code.diffAdded.raw) ?? text
        let removed = RGBA(code.diffRemoved.raw) ?? text
        let error = value("editorError.foreground", "errorForeground") ?? removed
        let warning = value("editorWarning.foreground") ?? RGBA(hex: "#c9a227")!

        return ThemePalette(
            background: ThemeColor(background.hexString),
            surface: ThemeColor((value("editorWidget.background", "sideBar.background")
                ?? background.blended(with: text, 0.05)).hexString),
            text: ThemeColor(text.hexString),
            textSecondary: ThemeColor((value("descriptionForeground")
                ?? text.blended(with: background, 0.30)).hexString),
            textFaint: ThemeColor(text.blended(with: background, 0.55).hexString),
            heading: ThemeColor(text.hexString),
            marker: ThemeColor(text.blended(with: background, 0.65).hexString),
            accent: ThemeColor(accent.hexString),
            link: ThemeColor((value("textLink.foreground") ?? accent).hexString),
            rule: ThemeColor((value("panel.border", "editorGroup.border")
                ?? background.blended(with: text, 0.18)).hexString),
            selection: ThemeColor((value("editor.selectionBackground")
                ?? accent.blended(with: background, 0.70)).hexString),
            // A code block is a tint plus a left rule, never a bordered card
            // (§11.3), so the editor background is *derived* from the page
            // background rather than copied — copying it would make code blocks
            // invisible on a theme whose editor and page are the same colour.
            codeBackground: ThemeColor(background.blended(with: text, 0.05).hexString),
            codeRule: ThemeColor(background.blended(with: text, 0.20).hexString),
            quoteRule: ThemeColor(background.blended(with: text, 0.30).hexString),
            changeAdded: ThemeColor(added.hexString),
            changeRemoved: ThemeColor(removed.hexString),
            changeModified: ThemeColor((value("gitDecoration.modifiedResourceForeground") ?? warning).hexString),
            pathMissing: ThemeColor(error.hexString),
            searchHit: ThemeColor((value("editor.findMatchHighlightBackground")
                ?? accent.blended(with: background, 0.65)).hexString),
            searchHitCurrent: ThemeColor((value("editor.findMatchBackground") ?? accent).hexString),
            calloutNote: ThemeColor((value("editorInfo.foreground") ?? accent).hexString),
            calloutWarning: ThemeColor(warning.hexString),
            calloutSuccess: ThemeColor(added.hexString),
            calloutDanger: ThemeColor(error.hexString)
        )
    }

    // MARK: - Scope matching

    struct ScopeEntry {
        var selector: String
        var color: RGBA
    }

    /// TextMate selector semantics, reduced to what a colour lookup needs: a
    /// selector describes a scope when either is a dotted prefix of the other.
    /// A selector that *generalises* the query (`comment` for
    /// `comment.line`) beats one that narrows it, and an exact match beats both.
    static func foreground(for scope: String, in entries: [ScopeEntry]) -> RGBA? {
        var best: (score: Int, color: RGBA)?
        for entry in entries {
            guard let score = score(selector: entry.selector, scope: scope) else { continue }
            if best == nil || score > best!.score { best = (score, entry.color) }
        }
        return best?.color
    }

    private static func score(selector: String, scope: String) -> Int? {
        if selector == scope { return 1000 }
        let depth = selector.split(separator: ".").count
        if scope.hasPrefix(selector + ".") { return 100 + depth }
        if selector.hasPrefix(scope + ".") { return 50 - depth }
        return nil
    }
}

// MARK: - File shape

private struct VSCodeThemeFile: Decodable {
    var name: String?
    var type: String?
    var colors: LenientStringMap?
    var tokenColors: [TokenColor]?

    struct TokenColor: Decodable {
        var scope: Scope?
        var settings: Settings?

        struct Settings: Decodable {
            var foreground: String?
            var fontStyle: String?
        }

        /// `scope` is a single selector, a comma-separated list of them, or an
        /// array of either.  All three appear in shipped themes.
        struct Scope: Decodable {
            var selectors: [String]

            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                let raw: [String]
                if let single = try? container.decode(String.self) {
                    raw = [single]
                } else {
                    raw = (try? container.decode([String].self)) ?? []
                }
                selectors = raw
                    .flatMap { $0.split(separator: ",") }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            }
        }
    }

    var isDark: Bool { (type ?? "dark").lowercased().contains("light") == false }

    /// A `tokenColors` entry with no scope carries the editor's default
    /// foreground; some themes set it there and nowhere else.
    var defaultForeground: RGBA? {
        for entry in tokenColors ?? [] where entry.scope?.selectors.isEmpty ?? true {
            if let color = RGBA(entry.settings?.foreground) { return color }
        }
        return nil
    }

    func scopeEntries() -> [VSCodeThemeImporter.ScopeEntry] {
        var entries: [VSCodeThemeImporter.ScopeEntry] = []
        for token in tokenColors ?? [] {
            guard let color = RGBA(token.settings?.foreground) else { continue }
            for selector in token.scope?.selectors ?? [] {
                entries.append(.init(selector: selector, color: color))
            }
        }
        return entries
    }

    func appearance(background: RGBA) -> ThemeAppearance {
        switch (type ?? "").lowercased() {
        case "light", "hc-light": return .light
        case "dark", "hc-black": return .dark
        default: return background.relativeLuminance < 0.5 ? .dark : .light
        }
    }
}

/// Decodes `{"key": "#value"}` while tolerating non-string and null entries,
/// which real themes contain.
private struct LenientStringMap: Decodable {
    var values: [String: String] = [:]

    private struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { self.intValue = intValue; stringValue = String(intValue) }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: AnyKey.self)
        for key in container.allKeys {
            if let value = try? container.decode(String.self, forKey: key) {
                values[key.stringValue] = value
            }
        }
    }
}

// MARK: - Colour arithmetic

/// Straight sRGB components, so the importer can derive the colours a VS Code
/// theme does not define without going through `NSColor` (and therefore without
/// needing an appearance to resolve against).
struct RGBA {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat

    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        // `#rgb` and `#rgba` shorthands expand by doubling each nibble.
        if text.count == 3 || text.count == 4 {
            text = text.map { "\($0)\($0)" }.joined()
        }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        r = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        g = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        b = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        a = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
    }

    init?(_ hex: String?) {
        guard let hex else { return nil }
        self.init(hex: hex)
    }

    /// `t` of the way from `self` to `other`.
    func blended(with other: RGBA, _ t: CGFloat) -> RGBA {
        var copy = self
        copy.r += (other.r - r) * t
        copy.g += (other.g - g) * t
        copy.b += (other.b - b) * t
        copy.a = 1
        return copy
    }

    var relativeLuminance: CGFloat { 0.2126 * r + 0.7152 * g + 0.0722 * b }

    var hexString: String {
        func byte(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        let base = String(format: "#%02x%02x%02x", byte(r), byte(g), byte(b))
        return a >= 0.999 ? base : base + String(format: "%02x", byte(a))
    }
}

// MARK: - JSONC

/// Strips `//` and `/* */` comments and trailing commas, leaving byte offsets
/// intact by overwriting with spaces.  Shipped VS Code themes are JSONC often
/// enough that a strict parser is not usable on them.
enum JSONCSanitizer {
    static func strip(_ data: Data) -> Data {
        var bytes = [UInt8](data)
        let n = bytes.count
        var i = 0
        var inString = false
        while i < n {
            let c = bytes[i]
            if inString {
                if c == 0x5C { i += 2; continue }          // backslash escape
                if c == 0x22 { inString = false }
                i += 1
                continue
            }
            if c == 0x22 { inString = true; i += 1; continue }
            if c == 0x2F, i + 1 < n, bytes[i + 1] == 0x2F { // //
                while i < n, bytes[i] != 0x0A { bytes[i] = 0x20; i += 1 }
                continue
            }
            if c == 0x2F, i + 1 < n, bytes[i + 1] == 0x2A { // /*
                bytes[i] = 0x20
                bytes[i + 1] = 0x20
                i += 2
                while i < n {
                    if bytes[i] == 0x2A, i + 1 < n, bytes[i + 1] == 0x2F {
                        bytes[i] = 0x20
                        bytes[i + 1] = 0x20
                        i += 2
                        break
                    }
                    if bytes[i] != 0x0A { bytes[i] = 0x20 }
                    i += 1
                }
                continue
            }
            if c == 0x2C {                                  // trailing comma
                var j = i + 1
                while j < n, bytes[j] == 0x20 || bytes[j] == 0x09 || bytes[j] == 0x0A || bytes[j] == 0x0D { j += 1 }
                if j < n, bytes[j] == 0x7D || bytes[j] == 0x5D { bytes[i] = 0x20 }
            }
            i += 1
        }
        return Data(bytes)
    }
}
