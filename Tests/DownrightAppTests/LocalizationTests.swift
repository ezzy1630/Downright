import AppKit
import Foundation
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct LocalizationTests {

    private static let formatSpecifierRegex = try! NSRegularExpression(
        pattern: #"%(?:\d+\$)?(?:ll|l)?[@dDiuUxXoOfeEgGcCsSp]"#
    )

    private func loadStrings(table: String, language: String) throws -> [String: String] {
        let root = L10n.resourceBundle
        let path = root.path(forResource: language, ofType: "lproj")
            ?? root.path(forResource: language.lowercased(), ofType: "lproj")
        let lprojPath = try #require(path, "Missing \(language).lproj in \(root.bundlePath)")
        let url = URL(fileURLWithPath: lprojPath).appendingPathComponent("\(table).strings")
        let dict = try #require(
            NSDictionary(contentsOf: url) as? [String: String],
            "Could not load \(table).strings for \(language)"
        )
        return dict
    }

    private func specifiers(in text: String) -> [String] {
        let scrubbed = text.replacingOccurrences(of: "%%", with: "")
        let ns = scrubbed as NSString
        return Self.formatSpecifierRegex
            .matches(in: scrubbed, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    @Test func englishAndChineseTablesMatchKeysAndFormatSpecifiers() throws {
        let en = try loadStrings(table: "Localizable", language: "en")
        let zh = try loadStrings(table: "Localizable", language: "zh-Hans")

        #expect(!en.isEmpty)
        #expect(Set(en.keys) == Set(zh.keys), "en and zh-Hans Localizable.strings keys drifted")

        for (key, enValue) in en {
            let zhValue = try #require(zh[key])
            #expect(!zhValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty zh-Hans translation for \(key)")
            #expect(
                specifiers(in: enValue) == specifiers(in: zhValue),
                "Format specifier mismatch for \(key): en=\(specifiers(in: enValue)) zh=\(specifiers(in: zhValue))"
            )
        }

        let enInfo = try loadStrings(table: "InfoPlist", language: "en")
        let zhInfo = try loadStrings(table: "InfoPlist", language: "zh-Hans")
        #expect(Set(enInfo.keys) == Set(zhInfo.keys))
    }

    @Test func simplifiedChineseLocalizesMenusCommandsSettingsAndStartWindow() throws {
        _ = NSApplication.shared

        try L10n.withLanguage("zh-Hans") {
            #expect(Command.Menu.file.title == "文件")
            #expect(Command.Menu.edit.title == "编辑")
            #expect(Command.Menu.view.title == "显示")
            #expect(Command.exportPDF.title == "导出 PDF…")
            #expect(Command.preferences.title == "设置…")

            // Menu bar still maps every command cleanly when localized.
            let menu = MainMenu.build()
            let topTitles = menu.items.compactMap { $0.submenu?.title }
            #expect(topTitles.contains("Downright"))
            #expect(topTitles.contains("文件"))
            #expect(topTitles.contains("编辑"))
            #expect(topTitles.contains("显示"))

            // Built-in theme display names localize without altering persistent identifiers.
            #expect(L10n.themeDisplayName("Paper Light") == "纸白浅色")
            #expect(L10n.themeDisplayName("Warm Dark") == "暖灰深色")
            #expect(L10n.themeDisplayName("Custom User Theme") == "Custom User Theme")

            // Settings pane labels localize cleanly.
            #expect(SettingsPane.general.title == "通用")
            #expect(SettingsPane.appearance.title == "外观")
            #expect(SettingsPane.typography.title == "排版")

            // Start window renders localized primary actions.
            let start = StartWindowController(recents: [])
            defer { start.close() }
            let content = try #require(start.window?.contentView)
            content.layoutSubtreeIfNeeded()
            let labels = buttons(in: content).compactMap { $0.accessibilityLabel() }
            #expect(labels.contains("打开文件"))
            #expect(labels.contains("新建文档"))
        }

        // Switching back to English restores canonical strings.
        L10n.withLanguage("en") {
            #expect(Command.Menu.file.title == "File")
            #expect(Command.exportPDF.title == "Export PDF…")
            #expect(SettingsPane.general.title == "General")
            #expect(L10n.themeDisplayName("Paper Light") == "Paper Light")
        }
    }

    @Test func commandPaletteMatchesBothChineseAndEnglishTitlesInChineseLocale() {
        L10n.withLanguage("zh-Hans") {
            var model = CommandPaletteModel(commands: [.exportPDF, .documentLens, .preferences], bindings: { _ in [] })

            model.updateQuery("导出")
            #expect(model.results.map(\.command).contains(.exportPDF))

            model.updateQuery("export pdf")
            #expect(model.results.map(\.command).contains(.exportPDF))

            model.updateQuery("目录")
            #expect(model.results.map(\.command).contains(.documentLens))

            model.updateQuery("outline")
            #expect(model.results.map(\.command).contains(.documentLens))
        }
    }

    @Test func preferencesValuesDecodeLegacyJSONWithoutLanguageField() throws {
        let legacyJSON = Data(#"{"themeName":"Paper Light","restoreSession":false}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.Values.self, from: legacyJSON)
        #expect(decoded.language == .system)
        #expect(decoded.themeName == "Paper Light")
        #expect(decoded.restoreSession == false)

        var updated = decoded
        updated.language = .simplifiedChinese
        let roundTripped = try JSONDecoder().decode(
            Preferences.Values.self,
            from: JSONEncoder().encode(updated)
        )
        #expect(roundTripped.language == .simplifiedChinese)
    }

    @Test func normalizedLanguageMapsChineseVariantsToSimplifiedChinese() {
        #expect(L10n.normalizedLanguage("zh-Hans") == "zh-Hans")
        #expect(L10n.normalizedLanguage("zh-Hans-CN") == "zh-Hans")
        #expect(L10n.normalizedLanguage("zh-CN") == "zh-Hans")
        #expect(L10n.normalizedLanguage("en-US") == "en")
        #expect(L10n.normalizedLanguage("fr-FR") == "en")
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for subview in view.subviews { found.append(contentsOf: buttons(in: subview)) }
        return found
    }
}
