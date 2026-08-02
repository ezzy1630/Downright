import AppKit
import Foundation
import MarkdownCore
import Testing
@testable import MarkdownRender

@Suite("Theming, typography and colour (§11.1, §11.2)")
final class ThemeTests {

    @Test func readerProfileCanOnlyAddReducedMotion() {
        let sheet = StyleSheet(
            theme: .fallback,
            appearance: NSAppearance(named: .aqua)!,
            reduceMotionOverride: true
        )
        #expect(sheet.reduceMotion)
    }

    private static let bundledNames = [
        "High Contrast", "Nord", "Paper Light", "Solarized Light", "System", "Warm Dark",
    ]

    private let aqua = NSAppearance(named: .aqua)!
    private let darkAqua = NSAppearance(named: .darkAqua)!

    /// `select(named:)` persists to `UserDefaults` by design, so each test puts
    /// the user's real preference back when it finishes.
    private let savedSelection = UserDefaults.standard.string(forKey: ThemeStore.selectionDefaultsKey)

    deinit {
        if let savedSelection {
            UserDefaults.standard.set(savedSelection, forKey: ThemeStore.selectionDefaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: ThemeStore.selectionDefaultsKey)
        }
    }

    private func store() -> ThemeStore { ThemeStore() }

    private func bundled() -> [Theme] {
        let names = Set(ThemeTests.bundledNames)
        return store().themes.filter { names.contains($0.name) }
    }

    private func expectClose(
        _ actual: CGFloat, _ expected: CGFloat, within tolerance: CGFloat, _ comment: Comment,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(abs(actual - expected) <= tolerance, "\(comment) — \(actual) vs \(expected)", sourceLocation: sourceLocation)
    }

    // MARK: - Bundled themes

    @Test("All six bundled themes decode")
    func allSixBundledThemesDecode() {
        #expect(bundled().map(\.name).sorted() == ThemeTests.bundledNames)
    }

    /// `ThemeColor.resolved()` falls back to `.labelColor` on a typo, which is
    /// the right runtime behaviour and would hide a broken shipped theme.
    @Test("Every colour in every bundled theme parses")
    func everyColourParses() {
        for theme in bundled() {
            #expect(theme.invalidColorPaths() == [], "\(theme.name) has unparseable colours")
            #expect(theme.allColors().count == 24 + 17, "\(theme.name): unexpected colour count")
            for (path, color) in theme.allColors() {
                #expect(color.validated() != nil, "\(theme.name).\(path) = \(color.raw)")
            }
        }
    }

    @Test("Essential bundled text roles meet semantic contrast")
    func essentialTextRolesMeetContrast() {
        for theme in bundled() {
            #expect(theme.semanticContrastFailures() == [], "\(theme.name) has low-contrast essential text")
        }
    }

    @Test("Bundled themes survive a JSON round trip")
    func bundledThemesRoundTrip() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for theme in bundled() {
            let restored = try decoder.decode(Theme.self, from: encoder.encode(theme))
            #expect(restored == theme, "\(theme.name) did not survive a JSON round trip")
        }
    }

    @Test("The System theme is built from system colours")
    func systemThemeUsesSystemColours() throws {
        let theme = try #require(bundled().first { $0.name == "System" })
        let references = theme.allColors().filter { $0.color.raw.hasPrefix("system:") }
        #expect(
            references.count == theme.allColors().count,
            "the System theme exists to track the user's accent colour and Increase Contrast (§11.2)"
        )
        #expect(theme.appearance == .auto)
    }

    @Test("Warm Dark is designed, not inverted")
    func warmDarkIsDesigned() throws {
        let theme = try #require(bundled().first { $0.name == "Warm Dark" })
        let background = try #require(theme.palette.background.validated()?.usingColorSpace(.sRGB))
        let text = try #require(theme.palette.text.validated()?.usingColorSpace(.sRGB))

        // Not black, and warm: red above blue (§11.2).
        #expect(background.redComponent > 0.02)
        #expect(background.redComponent > background.blueComponent)
        // Body text near 85% white, not pure white.
        #expect(text.redComponent < 0.95)
        #expect(text.redComponent > 0.70)
        #expect(text.redComponent > text.blueComponent)
    }

    @Test("Paper Light is warm")
    func paperLightIsWarm() throws {
        let theme = try #require(bundled().first { $0.name == "Paper Light" })
        let background = try #require(theme.palette.background.validated()?.usingColorSpace(.sRGB))
        #expect(background.redComponent > background.blueComponent)
        #expect(background.blueComponent < 1.0)
    }

    // MARK: - Store

    @Test("Selection moves the revision token")
    func selectionAndRevision() {
        let store = self.store()
        store.select(named: "Paper Light")
        let before = store.revision
        store.select(named: "Nord")
        #expect(store.current.name == "Nord")
        #expect(store.revision > before)

        // Selecting the same theme again is not a change.
        let steady = store.revision
        store.select(named: "Nord")
        #expect(store.revision == steady)

        // An unknown name is ignored rather than clearing the selection.
        store.select(named: "Nope")
        #expect(store.current.name == "Nord")
    }

    @Test("Observers fire on selection and stop on cancel")
    func observersFireAndCancel() {
        let store = self.store()
        store.select(named: "Paper Light")
        var seen: [String] = []
        let observation = store.observe { seen.append($0.name) }
        store.select(named: "Nord")
        store.select(named: "Solarized Light")
        #expect(seen == ["Nord", "Solarized Light"])

        observation.cancel()
        store.select(named: "Paper Light")
        #expect(seen == ["Nord", "Solarized Light"], "a cancelled observation still fired")
    }

    @Test("Export writes a decodable theme file")
    func exportRoundTrips() throws {
        let store = self.store()
        let theme = store.current
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-export-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }

        try store.export(theme, to: url)
        let restored = try JSONDecoder().decode(Theme.self, from: Data(contentsOf: url))
        #expect(restored == theme)
    }

    // MARK: - Typography (§11.1)

    @Test("Heading sizes follow the retuned document hierarchy")
    func headingSizesFollowTheScale() {
        for theme in bundled() {
            let sheet = StyleSheet(theme: theme, appearance: aqua)
            let sizes = (1...6).map { sheet.headingFont(level: $0).pointSize }
            for level in 1..<4 {
                #expect(sizes[level - 1] > sizes[level], "\(theme.name): H\(level) is not larger than H\(level + 1)")
            }
            let ratio = theme.typography.scaleRatio
            expectClose(sizes[0], theme.typography.bodySize * pow(ratio, 3), within: 0.001, "\(theme.name): H1")
            expectClose(sizes[1], theme.typography.bodySize * pow(ratio, 2), within: 0.001, "\(theme.name): H2")
            expectClose(sizes[2], theme.typography.bodySize * pow(ratio, 1.25), within: 0.001, "\(theme.name): H3")
            expectClose(sizes[3], theme.typography.bodySize * pow(ratio, 0.5), within: 0.001, "\(theme.name): H4")
            expectClose(sizes[4], theme.typography.bodySize, within: 0.001, "\(theme.name): H5")
            expectClose(sizes[5], theme.typography.bodySize, within: 0.001, "\(theme.name): H6")
        }
    }

    @Test("Measure lands in the 68–72 character range")
    func measureWidthIsCapped() {
        for theme in bundled() {
            let sheet = StyleSheet(theme: theme, appearance: aqua)
            #expect(sheet.averageCharacterWidth > 0)
            let characters = sheet.measureWidth / sheet.averageCharacterWidth
            #expect(characters >= 68 - 0.001, "\(theme.name): measure is \(characters) characters")
            #expect(characters <= 72 + 0.001, "\(theme.name): measure is \(characters) characters")
        }
    }

    @Test("A measure configured outside the range is clamped")
    func measureWidthClamps() throws {
        var theme = try #require(bundled().first)
        theme.typography.measureCharacters = 400
        var sheet = StyleSheet(theme: theme, appearance: aqua)
        expectClose(sheet.measureWidth / sheet.averageCharacterWidth, 72, within: 0.001, "clamped down to 72")

        theme.typography.measureCharacters = 10
        sheet = StyleSheet(theme: theme, appearance: aqua)
        expectClose(sheet.measureWidth / sheet.averageCharacterWidth, 68, within: 0.001, "clamped up to 68")
    }

    @Test("Line height and heading spacing sit on the baseline grid")
    func verticalRhythmIsOnTheGrid() {
        for theme in bundled() {
            let sheet = StyleSheet(theme: theme, appearance: aqua)
            #expect(sheet.baselineGrid > 0)
            expectClose(sheet.baselineGrid, sheet.baselineGrid.rounded(), within: 0.0001, "\(theme.name): whole-point grid")
            expectClose(
                sheet.lineHeight.truncatingRemainder(dividingBy: sheet.baselineGrid), 0, within: 0.001,
                "\(theme.name): line height on the grid"
            )
            for level in 1...6 {
                let spacing = sheet.headingSpacing(level: level)
                expectClose(
                    spacing.before.truncatingRemainder(dividingBy: sheet.baselineGrid), 0, within: 0.001,
                    "\(theme.name): H\(level) space before"
                )
                expectClose(
                    spacing.after.truncatingRemainder(dividingBy: sheet.baselineGrid), 0, within: 0.001,
                    "\(theme.name): H\(level) space after"
                )
            }
        }
    }

    @Test("Reading and Working pick different body faces")
    func presetsPickDifferentFaces() throws {
        var theme = try #require(bundled().first)
        theme.typography.preset = .working
        let working = StyleSheet(theme: theme, appearance: aqua).bodyFont()
        theme.typography.preset = .reading
        let reading = StyleSheet(theme: theme, appearance: aqua).bodyFont()
        #expect(reading.fontName != working.fontName, "Reading is a serif face, Working is SF Pro (§11.1)")
        #expect(reading.pointSize == theme.typography.bodySize)
    }

    @Test("The mono chain falls back and the ligature toggle bites")
    func monoFallbackAndLigatures() throws {
        var theme = try #require(bundled().first)
        theme.typography.monoFamily = "This Face Does Not Exist"
        let sheet = StyleSheet(theme: theme, appearance: aqua)
        let font = sheet.monoFont()
        #expect(font.isFixedPitch, "the mono fallback chain must end at a monospaced face")
        expectClose(
            font.pointSize, theme.typography.bodySize * theme.typography.monoSizeAdjust, within: 0.001,
            "mono size adjust"
        )
        #expect(sheet.monoFontAttributes()[.ligature] as? Int == 0)

        theme.typography.monoLigatures = true
        #expect(StyleSheet(theme: theme, appearance: aqua).monoFontAttributes()[.ligature] as? Int == 1)
    }

    @Test("Emphasis fonts carry their traits")
    func emphasisFonts() throws {
        let theme = try #require(bundled().first)
        let sheet = StyleSheet(theme: theme, appearance: aqua)
        #expect(sheet.emphasisFont(bold: true, italic: false).fontDescriptor.symbolicTraits.contains(.bold))
        #expect(sheet.emphasisFont(bold: false, italic: true).fontDescriptor.symbolicTraits.contains(.italic))
        let both = sheet.emphasisFont(bold: true, italic: true).fontDescriptor.symbolicTraits
        #expect(both.contains(.bold) && both.contains(.italic))
        #expect(sheet.emphasisFont(bold: false, italic: false) == sheet.bodyFont())
    }

    /// §11.3 — the point of sizing math against the x-height is that it lands
    /// near the body size rather than the 1.21× KaTeX default.
    @Test("Math sits optically against body text")
    func mathSizeIsOptical() {
        for theme in bundled() {
            let sheet = StyleSheet(theme: theme, appearance: aqua)
            let body = theme.typography.bodySize
            #expect(sheet.mathPointSize >= body * 0.89, "\(theme.name)")
            #expect(sheet.mathPointSize <= body * 1.11, "\(theme.name)")
        }
    }

    // MARK: - Colours

    @Test("Every style sheet colour resolves in both appearances")
    func everyStyleSheetColourResolves() {
        for theme in bundled() {
            for appearance in [aqua, darkAqua] {
                let sheet = StyleSheet(theme: theme, appearance: appearance)
                var colors: [NSColor] = [
                    sheet.background, sheet.surface, sheet.text, sheet.textSecondary, sheet.textFaint,
                    sheet.marker, sheet.accent, sheet.link, sheet.rule, sheet.codeBackground,
                    sheet.codeRule, sheet.quoteRule, sheet.pathMissing, sheet.searchHit,
                    sheet.searchHitCurrent, sheet.selection,
                ]
                colors += (1...6).map { sheet.headingColor(level: $0) }
                colors += CalloutKind.allCases.map { sheet.calloutColor($0) }
                colors += ChangeKind.allKinds.map { sheet.changeColor($0) }
                colors += SyntaxToken.allCases.map { sheet.codeColor($0) }
                for color in colors {
                    #expect(color.usingColorSpace(.sRGB) != nil, "\(theme.name): a colour failed to resolve")
                }
            }
        }
    }

    @Test("Heading colours soften with depth and clamp out of range")
    func headingColoursSoften() throws {
        let theme = try #require(bundled().first { $0.name == "Paper Light" })
        let sheet = StyleSheet(theme: theme, appearance: aqua)
        #expect(sheet.headingColor(level: 1) == sheet.headingColor(level: 3))
        #expect(sheet.headingColor(level: 3) != sheet.headingColor(level: 6))
        #expect(sheet.headingColor(level: 0) == sheet.headingColor(level: 1))
        #expect(sheet.headingColor(level: 99) == sheet.headingColor(level: 6))
    }

    @Test("Every callout kind has a colour and a real SF Symbol")
    func calloutSymbolsExist() throws {
        guard NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil) != nil else {
            return  // SF Symbols unavailable in this environment.
        }
        let theme = try #require(bundled().first)
        let sheet = StyleSheet(theme: theme, appearance: aqua)
        for kind in CalloutKind.allCases {
            let symbol = sheet.calloutSymbol(kind)
            #expect(!symbol.isEmpty, "\(kind) has no symbol")
            #expect(
                NSImage(systemSymbolName: symbol, accessibilityDescription: nil) != nil,
                "\(kind): \(symbol) is not an SF Symbol on this system"
            )
        }
    }

    @Test("Code and change colours come from the theme")
    func codeAndChangeColours() throws {
        let theme = try #require(bundled().first { $0.name == "Nord" })
        let sheet = StyleSheet(theme: theme, appearance: darkAqua)
        #expect(sheet.codeColor(.keyword) == theme.code.keyword.validated()?.usingColorSpace(.sRGB))
        #expect(sheet.codeColor(.diffAdded) == theme.code.diffAdded.validated()?.usingColorSpace(.sRGB))
        #expect(sheet.codeColor(.plain) == sheet.text)
        #expect(sheet.changeColor(.inserted) == theme.palette.changeAdded.validated()?.usingColorSpace(.sRGB))
        #expect(sheet.changeColor(.deleted) == theme.palette.changeRemoved.validated()?.usingColorSpace(.sRGB))
        #expect(sheet.changeColor(.modified) == theme.palette.changeModified.validated()?.usingColorSpace(.sRGB))
    }

    @Test("An invalid colour is detectable but still draws")
    func invalidColourIsDetectable() {
        let broken = ThemeColor("#ggg")
        #expect(broken.validated() == nil)
        #expect(broken.resolved() == .labelColor)
        #expect(ThemeColor("system:notAColour").validated() == nil)
        #expect(ThemeColor("system:controlAccentColor").validated() != nil)
        #expect(ThemeColor("#11223344").validated() != nil)
    }

    // MARK: - VS Code import (§11.2)

    private static let sampleVSCodeTheme = """
    {
      // A comment, because shipped themes are JSONC.
      "name": "Downright Import Fixture",
      "type": "dark",
      "colors": {
        "editor.background": "#101418",
        "editor.foreground": "#d0d6dd",
        "editor.selectionBackground": "#2a3a4a80",
        "textLink.foreground": "#7aa2f7",
        "editorError.foreground": "#e06c75",
        "editorWarning.foreground": "#e5c07b",
        "gitDecoration.addedResourceForeground": "#98c379",
        "unrelated.null": null,
      },
      "tokenColors": [
        { "scope": "comment", "settings": { "foreground": "#5c6370", "fontStyle": "italic" } },
        { "scope": ["string", "string.quoted.double"], "settings": { "foreground": "#98c379" } },
        { "scope": "keyword.control, storage.type", "settings": { "foreground": "#c678dd" } },
        { "scope": "constant.numeric", "settings": { "foreground": "#d19a66" } },
        { "scope": "entity.name.function", "settings": { "foreground": "#61afef" } },
        { "scope": "entity.name.type", "settings": { "foreground": "#e5c07b" } },
        { "scope": "markup.inserted", "settings": { "foreground": "#98c379" } },
        { "scope": "markup.deleted", "settings": { "foreground": "#e06c75" } },
      ]
    }
    """

    private func removeUserTheme(named name: String) {
        guard let directory = ThemeStore.userThemesDirectory,
              let contents = try? FileManager.default.contentsOfDirectory(
                  at: directory, includingPropertiesForKeys: nil
              )
        else { return }
        for file in contents where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file),
                  let theme = try? JSONDecoder().decode(Theme.self, from: data),
                  theme.name == name
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    @Test("A VS Code theme imports, maps its scopes, and installs")
    func vsCodeThemeImport() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-vscode-\(UUID().uuidString).json")
        try ThemeTests.sampleVSCodeTheme.write(to: url, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: url)
            removeUserTheme(named: "Downright Import Fixture")
        }

        let store = self.store()
        let theme = try store.importVSCodeTheme(at: url)

        #expect(theme.name == "Downright Import Fixture")
        #expect(theme.appearance == .dark)
        #expect(theme.palette.background.raw == "#101418")
        #expect(theme.palette.text.raw == "#d0d6dd")
        #expect(theme.palette.link.raw == "#7aa2f7")
        #expect(theme.palette.selection.raw == "#2a3a4a80", "translucent highlight colours keep their alpha")

        // TextMate scopes map onto the small `SyntaxToken` palette.
        #expect(theme.code.comment.raw == "#5c6370")
        #expect(theme.code.string.raw == "#98c379")
        #expect(theme.code.keyword.raw == "#c678dd")
        #expect(theme.code.number.raw == "#d19a66")
        #expect(theme.code.function.raw == "#61afef")
        #expect(theme.code.type.raw == "#e5c07b")
        #expect(theme.code.diffAdded.raw == "#98c379")
        #expect(theme.code.diffRemoved.raw == "#e06c75")

        // Colours the theme never states are derived, not left blank.
        #expect(theme.invalidColorPaths() == [])
        #expect(theme.palette.codeBackground.raw != theme.palette.background.raw)

        // Importing installs it, so it is selectable straight away.
        #expect(store.themes.contains { $0.name == theme.name })
        _ = StyleSheet(theme: theme, appearance: darkAqua)
    }

    @Test("Import rejects a file that is not a theme")
    func importRejectsNonThemes() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("downright-not-a-theme-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try "{\"unrelated\": 1}".write(to: url, atomically: true, encoding: .utf8)

        let store = self.store()
        #expect(throws: ThemeStoreError.notAVSCodeTheme) {
            _ = try store.importVSCodeTheme(at: url)
        }
    }

    @Test("The JSONC sanitiser leaves string content alone")
    func jsoncSanitizer() {
        let source = """
        {"a": "http://x/y // not a comment", /* dropped */ "b": [1, 2,], }
        """
        let cleaned = String(decoding: JSONCSanitizer.strip(Data(source.utf8)), as: UTF8.self)
        let object = (try? JSONSerialization.jsonObject(with: Data(cleaned.utf8))) as? [String: Any]
        #expect(object?["a"] as? String == "http://x/y // not a comment")
        #expect(object?["b"] as? [Int] == [1, 2])
    }

    @Test("Scope matching prefers the selector that generalises the query")
    func scopeMatching() {
        let entries = [
            VSCodeThemeImporter.ScopeEntry(selector: "comment", color: RGBA(hex: "#111111")!),
            VSCodeThemeImporter.ScopeEntry(selector: "comment.line.double-slash", color: RGBA(hex: "#222222")!),
            VSCodeThemeImporter.ScopeEntry(selector: "string", color: RGBA(hex: "#333333")!),
        ]
        #expect(VSCodeThemeImporter.foreground(for: "comment", in: entries)?.hexString == "#111111")
        #expect(
            VSCodeThemeImporter.foreground(for: "comment.line.double-slash", in: entries)?.hexString == "#222222"
        )
        #expect(VSCodeThemeImporter.foreground(for: "keyword", in: entries) == nil)
    }
}

extension ChangeKind {
    /// `ChangeKind` is not `CaseIterable` in `MarkdownCore`; the tests need the
    /// full set to prove every change colour resolves.
    fileprivate static let allKinds: [ChangeKind] = [.inserted, .deleted, .modified]
}
