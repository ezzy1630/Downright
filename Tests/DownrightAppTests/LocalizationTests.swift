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
        pattern: #"%(?:(?<pos>\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?<len>hh|h|ll|l|j|z|t|L)?(?<conv>[@dDiuUxXoOfeEgGcCsSp%])"#
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

    /// Parses printf specifiers into `{1-based position: canonicalType}`, accepting
    /// positional specifiers (`%1$@`, `%2$lld`) for languages that reorder arguments.
    private func positionalSpecifiers(in text: String) -> [Int: String]? {
        let ns = text as NSString
        var result: [Int: String] = [:]
        var seq = 0
        var sawPositional = false
        var sawSequential = false
        for match in Self.formatSpecifierRegex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let conv = ns.substring(with: match.range(withName: "conv"))
            if conv == "%" { continue }
            let lenRange = match.range(withName: "len")
            let length = lenRange.location != NSNotFound ? ns.substring(with: lenRange) : ""
            let canonical: String
            switch conv {
            case "d", "i", "D": canonical = "\(length)d"
            case "u", "U", "x", "X", "o", "O": canonical = "\(length)u"
            case "f", "e", "E", "g", "G": canonical = "\(length)f"
            default: canonical = "\(length)\(conv)"
            }
            let posRange = match.range(withName: "pos")
            let position: Int
            if posRange.location != NSNotFound {
                sawPositional = true
                guard let parsed = Int(ns.substring(with: posRange)), parsed > 0 else { return nil }
                position = parsed
            } else {
                sawSequential = true
                seq += 1
                position = seq
            }
            if let existing = result[position], existing != canonical { return nil }
            result[position] = canonical
        }
        if sawPositional && sawSequential { return nil }
        return result
    }

    private func englishText(fromKey key: String) -> String {
        if let range = key.range(of: "::") {
            return String(key[range.upperBound...])
        }
        return key
    }

    @Test func zhHansTableHasNoDuplicateEnglishTableAndMatchesFormatSpecifiers() throws {
        // English keys are the source of truth and fallback; no duplicate en table may exist.
        let root = L10n.resourceBundle
        if let enLproj = root.path(forResource: "en", ofType: "lproj") {
            let enLocalizable = URL(fileURLWithPath: enLproj).appendingPathComponent("Localizable.strings")
            #expect(!FileManager.default.fileExists(atPath: enLocalizable.path))
        }

        let zh = try loadStrings(table: "Localizable", language: "zh-Hans")
        #expect(!zh.isEmpty)

        for (key, zhValue) in zh {
            #expect(!zhValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "Empty zh-Hans translation for \(key)")
            let enSpecs = try #require(
                positionalSpecifiers(in: englishText(fromKey: key)),
                "Invalid English format string in key \(key)"
            )
            let zhSpecs = try #require(
                positionalSpecifiers(in: zhValue),
                "Invalid zh-Hans format string for \(key): \(zhValue)"
            )
            #expect(
                enSpecs == zhSpecs,
                "Format specifier mismatch for \(key): en=\(enSpecs) zh=\(zhSpecs)"
            )
        }

        let enInfo = try loadStrings(table: "InfoPlist", language: "en")
        let zhInfo = try loadStrings(table: "InfoPlist", language: "zh-Hans")
        #expect(Set(enInfo.keys) == Set(zhInfo.keys))
    }

    @Test func formatSpecifierParityAcceptsPositionalReordering() throws {
        let english = try #require(positionalSpecifiers(in: "%@ of %lld items"))
        let reordered = try #require(positionalSpecifiers(in: "共 %2$lld 项中的 %1$@"))
        let mismatched = try #require(positionalSpecifiers(in: "共 %1$lld 项中的 %2$@"))
        #expect(english == reordered)
        #expect(english != mismatched)
        #expect(positionalSpecifiers(in: "%1$@ and %lld") == nil)
    }

    @Test func pseudoLocalizationBracketsPadsAndPreservesFormatSpecifiers() {
        L10n.withLanguage("pseudo") {
            #expect(L10n.currentLanguage == "pseudo")
            #expect(L10n.isPseudo)
            let simple = L10n.tr("Open File")
            #expect(simple.hasPrefix("["))
            #expect(simple.hasSuffix("]"))
            #expect(simple.count >= Int(Double("Open File".count) * 1.4))

            let formatted = L10n.tr("Section %lld of %lld", 2, 5)
            #expect(formatted.hasPrefix("["))
            #expect(formatted.hasSuffix("]"))
            #expect(formatted.contains("2"))
            #expect(formatted.contains("5"))

            let contextual = L10n.tr("System", context: "theme")
            #expect(contextual.hasPrefix("["))
            #expect(contextual.hasSuffix("]"))
        }
    }

    @Test func simplifiedChineseLocalizesMenusCommandsSettingsAndStartWindow() throws {
        _ = NSApplication.shared

        try L10n.withLanguage("zh-Hans") {
            #expect(Command.Menu.file.title == "文件")
            #expect(Command.Menu.edit.title == "编辑")
            #expect(Command.Menu.view.title == "显示")
            #expect(Command.exportPDF.title == "导出 PDF…")
            #expect(Command.preferences.title == "设置…")

            let menu = MainMenu.build()
            let topTitles = menu.items.compactMap { $0.submenu?.title }
            #expect(topTitles.contains("Downright"))
            #expect(topTitles.contains("文件"))
            #expect(topTitles.contains("编辑"))
            #expect(topTitles.contains("显示"))

            #expect(L10n.themeDisplayName("Paper Light") == "纸白浅色")
            #expect(L10n.themeDisplayName("Warm Dark") == "暖灰深色")
            #expect(L10n.themeDisplayName("Custom User Theme") == "Custom User Theme")

            #expect(SettingsPane.general.title == "通用")
            #expect(SettingsPane.appearance.title == "外观")
            #expect(SettingsPane.typography.title == "排版")

            let start = StartWindowController(recents: [])
            defer { start.close() }
            let content = try #require(start.window?.contentView)
            content.layoutSubtreeIfNeeded()
            let labels = buttons(in: content).compactMap { $0.accessibilityLabel() }
            #expect(labels.contains("打开文件"))
            #expect(labels.contains("新建文档"))
        }

        L10n.withLanguage("en") {
            #expect(Command.Menu.file.title == "File")
            #expect(Command.exportPDF.title == "Export PDF…")
            #expect(SettingsPane.general.title == "General")
            #expect(L10n.themeDisplayName("Paper Light") == "Paper Light")
        }
    }

    @Test func commandPaletteMatchesBothChineseAndEnglishAndSortsChineseByPinyin() {
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

            // Empty-query ordering sorts equal-score Chinese titles by Pinyin
            // ("查找…" chazhao < "打开…" dakai < "导出 PDF…" daochu < "设置…" shezhi < "新建…" xinjian),
            // never raw Unicode scalar order where "导出" would precede "打开".
            let sortingModel = CommandPaletteModel(
                commands: [.newDocument, .preferences, .exportPDF, .open, .find],
                bindings: { _ in [] }
            )
            let titles = sortingModel.results.map(\.title)
            #expect(titles == ["查找…", "打开…", "导出 PDF…", "设置…", "新建…"])
        }
    }

    @Test func keybindingsPaneSortsByMenuAndPinyinAndSearchesBilingually() {
        L10n.withLanguage("zh-Hans") {
            let sorted = KeybindingsPane.sortedCommands([.save, .open, .exportPDF, .newDocument])
            let titles = sorted.map(\.title)
            // Under File menu in Pinyin order: 保存 (baocun) < 打开… (dakai) < 导出 PDF… (daochu) < 新建… (xinjian)
            #expect(titles == ["保存", "打开…", "导出 PDF…", "新建…"])

            #expect(KeybindingsPane.filtered([.exportPDF, .open], query: "导出") == [.exportPDF])
            #expect(KeybindingsPane.filtered([.exportPDF, .open], query: "export pdf") == [.exportPDF])
        }
    }

    @Test func quickOpenFootnotesMatchBothChineseAndEnglishUnderChineseLocale() {
        let doc = MarkdownParser.parse("Text[^note]\n\n[^note]: Body\n")
        L10n.withLanguage("zh-Hans") {
            let provider = CurrentDocumentQuickOpenProvider(document: doc)
            var model = CommandPaletteModel(entries: [], providers: [provider])

            model.updateQuery("脚注")
            #expect(model.quickResults.contains { $0.kind == .footnote })

            model.updateQuery("footnote")
            #expect(model.quickResults.contains { $0.kind == .footnote })
        }
    }

    @Test func formattersFollowInAppLanguageOverride() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let yesterday = now.addingTimeInterval(-86_400)

        let relEn = L10n.withLanguage("en") { RelativeTime.long(yesterday, now: now) }
        let relZh = L10n.withLanguage("zh-Hans") { RelativeTime.long(yesterday, now: now) }
        #expect(relEn.lowercased().contains("yesterday"))
        #expect(relZh.contains("昨天"))

        let dateEn = L10n.withLanguage("en") { L10n.formatDate(now) }
        let dateZh = L10n.withLanguage("zh-Hans") { L10n.formatDate(now) }
        #expect(dateEn.contains("Nov"))
        #expect(dateZh.contains("年") && dateZh.contains("月"))

        let bytesZeroEn = L10n.withLanguage("en") { L10n.formatByteCount(0) }
        let bytesZeroZh = L10n.withLanguage("zh-Hans") { L10n.formatByteCount(0) }
        let bytesSmallEn = L10n.withLanguage("en") { L10n.formatByteCount(512) }
        let bytesSmallZh = L10n.withLanguage("zh-Hans") { L10n.formatByteCount(512) }
        let bytesMBEn = L10n.withLanguage("en") { L10n.formatByteCount(1_500_000) }
        let bytesMBZh = L10n.withLanguage("zh-Hans") { L10n.formatByteCount(1_500_000) }
        #expect(bytesZeroEn == "Zero KB")
        #expect(bytesZeroZh == "零 KB")
        #expect(bytesSmallEn == "512 bytes")
        #expect(bytesSmallZh == "512 字节")
        #expect(bytesMBEn == "1.5 MB")
        #expect(bytesMBZh == "1.5 MB")

        let listEn = L10n.withLanguage("en") { L10n.formatList(["A", "B", "C"]) }
        let listZh = L10n.withLanguage("zh-Hans") { L10n.formatList(["甲", "乙", "丙"]) }
        #expect(listEn.contains("and"))
        #expect(listZh.contains("、"))
    }

    @Test func localeNeutralOutputsNeverContainLocalizedUIUnderChinese() {
        L10n.withLanguage("zh-Hans") {
            let doc = MarkdownDocument()
            let parsed = MarkdownParser.parse("# Heading\n\n- [ ] Write docs\n- [x] Ship\n")
            #expect(doc.displayName == "Untitled")
            #expect(DocumentShareSource.snapshotFileName(url: nil, displayName: doc.displayName) == "Untitled.md")

            let worklist = TaskWorklist(tasks: parsed.tasks, headings: parsed.headings)
            #expect(worklist.statusReport.contains("1 of 2 done"))
            #expect(!worklist.statusReport.contains("已完成"))

            let html = HTMLExporter(
                document: parsed,
                theme: .fallback,
                title: doc.displayName
            ).html()
            #expect(html.contains("<title>Untitled</title>"))

            let diagnostics = UpdatePanelContent.diagnostics(
                coordinator: UpdateCoordinator.shared,
                failure: UpdateFailure(message: "Network timeout", technicalDetail: nil, code: -1001, retryable: true)
            )
            #expect(diagnostics.contains("Error: Network timeout"))
            #expect(diagnostics.contains("Code: -1001"))
        }
    }

    @Test func chineseIMECompositionDoesNotFilterOrCommitInPaletteFindAndSettings() throws {
        _ = NSApplication.shared

        // 1. Command Palette / Quick Open
        let palette = CommandPaletteView(
            styleSheet: .current,
            recentStore: UserDefaultsCommandPaletteRecentStore(),
            model: CommandPaletteModel(commands: [.exportPDF, .open, .preferences], bindings: { _ in [] })
        )
        let paletteRecorder = CommandPaletteRecorder()
        palette.delegate = paletteRecorder
        let paletteWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        paletteWindow.isReleasedWhenClosed = false
        paletteWindow.contentView = palette
        paletteWindow.makeKeyAndOrderFront(nil)
        defer { paletteWindow.close() }

        paletteWindow.makeFirstResponder(palette.searchFieldForTesting)
        let paletteEditor = try #require(palette.searchFieldForTesting.currentEditor() as? NSTextView)
        paletteEditor.setMarkedText(
            "daochu",
            selectedRange: NSRange(location: 6, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(paletteEditor.hasMarkedText())
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.searchFieldForTesting))
        #expect(palette.currentQueryForTesting.isEmpty, "Marked Pinyin text must not filter Command Palette")

        let returnEvent = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: paletteWindow.windowNumber,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36
        ))
        #expect(palette.handleKeyForTesting(returnEvent) == false, "Return during IME composition must reach the input method")
        #expect(paletteRecorder.chosenCount == 0, "Return during IME composition must not execute a command")

        paletteEditor.insertText("导出", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!paletteEditor.hasMarkedText())
        palette.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: palette.searchFieldForTesting))
        #expect(palette.currentQueryForTesting == "导出")

        // 2. Find Bar
        let findBar = FindBarView(styleSheet: .current)
        let findRecorder = FindBarRecorder()
        findBar.delegate = findRecorder
        let findWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        findWindow.isReleasedWhenClosed = false
        findWindow.contentView = findBar
        findWindow.makeKeyAndOrderFront(nil)
        defer { findWindow.close() }

        findWindow.makeFirstResponder(findBar.searchFieldForTesting)
        let findEditor = try #require(findBar.searchFieldForTesting.currentEditor() as? NSTextView)
        findEditor.setMarkedText(
            "chazhao",
            selectedRange: NSRange(location: 7, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(findEditor.hasMarkedText())
        findBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: findBar.searchFieldForTesting))
        #expect(findRecorder.queries.isEmpty, "Marked Pinyin text must not emit a Find query")
        let handledFindReturn = findBar.control(
            findBar.searchFieldForTesting,
            textView: findEditor,
            doCommandBy: #selector(NSResponder.insertNewline(_:))
        )
        #expect(handledFindReturn == false)
        #expect(findRecorder.advanceCount == 0)

        findEditor.insertText("查找", replacementRange: NSRange(location: NSNotFound, length: 0))
        findBar.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: findBar.searchFieldForTesting))
        #expect(findRecorder.queries.last == "查找")

        // 3. Settings / Keybindings Search
        let prefs = PreferencesWindowController()
        prefs.select(.keys)
        prefs.showWindow(nil)
        let prefsWindow = try #require(prefs.window)
        prefsWindow.isReleasedWhenClosed = false
        defer { prefs.close() }

        prefsWindow.makeFirstResponder(prefs.searchFieldForTesting)
        let prefsEditor = try #require(prefs.searchFieldForTesting.currentEditor() as? NSTextView)
        prefsEditor.setMarkedText(
            "daochu",
            selectedRange: NSRange(location: 6, length: 0),
            replacementRange: NSRange(location: NSNotFound, length: 0)
        )
        #expect(prefsEditor.hasMarkedText())
        prefs.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: prefs.searchFieldForTesting))
        #expect(prefs.activeSearchQueryForTesting.isEmpty, "Marked Pinyin text must not filter Settings/Keybindings")

        prefsEditor.insertText("导出", replacementRange: NSRange(location: NSNotFound, length: 0))
        prefs.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: prefs.searchFieldForTesting))
        #expect(prefs.activeSearchQueryForTesting == "导出")
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

    @Test func languageResolutionHandlesSimplifiedTraditionalAndPerAppFallback() {
        #expect(L10n.normalizedLanguage("zh-Hans") == "zh-Hans")
        #expect(L10n.normalizedLanguage("zh-Hans-CN") == "zh-Hans")
        #expect(L10n.normalizedLanguage("zh-CN") == "zh-Hans")
        #expect(L10n.normalizedLanguage("zh-SG") == "zh-Hans")
        #expect(L10n.normalizedLanguage("zh-Hant") == "en")
        #expect(L10n.normalizedLanguage("zh-Hant-TW") == "en")
        #expect(L10n.normalizedLanguage("zh-TW") == "en")
        #expect(L10n.normalizedLanguage("zh-HK") == "en")
        #expect(L10n.normalizedLanguage("zh-MO") == "en")
        #expect(L10n.normalizedLanguage("pseudo") == "pseudo")
        #expect(L10n.normalizedLanguage("en-US") == "en")
        #expect(L10n.normalizedLanguage("fr-FR") == "en")

        // System preferred language list resolution (including Traditional Chinese users).
        #expect(L10n.resolveSystemLanguage(preferredLanguages: ["zh-Hans-CN", "en-US"]) == "zh-Hans")
        #expect(L10n.resolveSystemLanguage(preferredLanguages: ["zh-Hant-TW", "en-US"]) == "en")
        #expect(L10n.resolveSystemLanguage(preferredLanguages: ["zh-Hant-TW"]) == "en")
        #expect(L10n.resolveSystemLanguage(preferredLanguages: ["zh-Hant-HK"]) == "en")
        #expect(L10n.resolveSystemLanguage(preferredLanguages: ["zh-HK"]) == "en")
        #expect(L10n.resolveSystemLanguage(preferredLanguages: ["zh-TW"]) == "en")
        #expect(L10n.resolveSystemLanguage(preferredLanguages: ["zh-Hant-TW", "zh-Hans-CN", "en-US"]) == "zh-Hans")
        #expect(L10n.resolveSystemLanguage(preferredLanguages: ["en-US", "zh-Hans-CN"]) == "en")
    }

    @Test func documentLensAndTrustTitlesLocalizeUnderChineseAndPseudo() {
        let doc = MarkdownParser.parse("# Title\n\n- [ ] Task\n")
        L10n.withLanguage("zh-Hans") {
            let model = DocumentLensModel(input: DocumentLensInput(document: doc))
            #expect(model.section(.structure).groups.first?.title == "文档")
            #expect(model.section(.tasks).groups.first?.title == "任务")
            #expect(model.section(.tasks).items.first?.detail == "待办")
            #expect(DocumentTrustState.standard.title == "标准")
            #expect(TrustEffect.openExternalLink.title == "打开外部链接")
        }
        L10n.withLanguage("pseudo") {
            let model = DocumentLensModel(input: DocumentLensInput(document: doc))
            let title = model.section(.structure).groups.first?.title ?? ""
            #expect(title.hasPrefix("[") && title.hasSuffix("]"))
        }
    }

    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        if let button = view as? NSButton { found.append(button) }
        for subview in view.subviews { found.append(contentsOf: buttons(in: subview)) }
        return found
    }
}

@MainActor
private final class CommandPaletteRecorder: CommandPaletteViewDelegate {
    var chosenCount = 0
    var cancelledCount = 0

    func commandPalette(_ view: CommandPaletteView, didChoose result: QuickOpenResult) {
        chosenCount += 1
    }

    func commandPaletteDidCancel(_ view: CommandPaletteView) {
        cancelledCount += 1
    }
}

@MainActor
private final class FindBarRecorder: FindBarDelegate {
    var queries: [String] = []
    var advanceCount = 0

    func findBar(_ view: FindBarView, didChange query: FindQuery) {
        queries.append(query.text)
    }

    func findBar(_ view: FindBarView, didRequestAdvance forward: Bool) {
        advanceCount += 1
    }

    func findBar(_ view: FindBarView, didRequestReplace replacement: String, all: Bool) {}

    func findBarDidRequestClose(_ view: FindBarView) {}
}
