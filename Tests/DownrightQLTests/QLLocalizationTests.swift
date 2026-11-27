import Foundation
import Testing
@testable import DownrightQL

@Suite(.serialized)
struct QLLocalizationTests {
    private static let formatSpecifierRegex = try! NSRegularExpression(
        pattern: #"%(?:(?<pos>\d+)\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?<len>hh|h|ll|l|j|z|t|L)?(?<conv>[@dDiuUxXoOfeEgGcCsSp%])"#
    )

    private func loadStrings(language: String) throws -> [String: String] {
        let root = QLL10n.resourceBundle
        let path = root.path(forResource: language, ofType: "lproj")
            ?? root.path(forResource: language.lowercased(), ofType: "lproj")
        let lprojPath = try #require(path, "Missing \(language).lproj in \(root.bundlePath)")
        let url = URL(fileURLWithPath: lprojPath).appendingPathComponent("Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

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

    @Test func quickLookLocalizationHasNoDuplicateEnglishTableAndTranslates() throws {
        let root = QLL10n.resourceBundle
        if let enLproj = root.path(forResource: "en", ofType: "lproj") {
            let enLocalizable = URL(fileURLWithPath: enLproj).appendingPathComponent("Localizable.strings")
            #expect(!FileManager.default.fileExists(atPath: enLocalizable.path))
        }

        let zh = try loadStrings(language: "zh-Hans")
        #expect(!zh.isEmpty)
        for (key, value) in zh {
            #expect(!value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(positionalSpecifiers(in: key) == positionalSpecifiers(in: value))
        }

        QLL10n.withLanguage("zh-Hans") {
            #expect(QLL10n.tr("Open in Downright") == "在 Downright 中打开")
            #expect(QLL10n.tr("Showing part of this large file") == "文件较大，当前仅预览开头部分")
            #expect(QLL10n.tr("Section %lld of %lld", 2, 5) == "第 2 / 5 节")
            #expect(QLL10n.formatNumber(12_345) == "12,345")
        }
        QLL10n.withLanguage("en") {
            #expect(QLL10n.tr("Open in Downright") == "Open in Downright")
        }
        QLL10n.withLanguage("pseudo") {
            let pseudo = QLL10n.tr("Section %lld of %lld", 2, 5)
            #expect(pseudo.hasPrefix("["))
            #expect(pseudo.hasSuffix("]"))
            #expect(pseudo.contains("2"))
            #expect(pseudo.contains("5"))
        }
    }

    @Test func quickLookFollowsSystemBeforeAppLaunchAndRespectsStoredLanguage() {
        // Cold start: host app has never launched, so PreviewAppearanceStore.language is nil.
        #expect(QLL10n.resolveLanguage(storedPreference: nil, preferredLanguages: ["zh-Hans-CN", "en-US"]) == "zh-Hans")
        #expect(QLL10n.resolveLanguage(storedPreference: nil, preferredLanguages: ["zh-Hant-TW", "en-US"]) == "en")
        #expect(QLL10n.resolveLanguage(storedPreference: nil, preferredLanguages: ["zh-Hant-HK"]) == "en")
        #expect(QLL10n.resolveLanguage(storedPreference: nil, preferredLanguages: ["en-US"]) == "en")

        // Explicit in-app selection overrides host system language.
        #expect(QLL10n.resolveLanguage(storedPreference: "zh-Hans", preferredLanguages: ["en-US"]) == "zh-Hans")
        #expect(QLL10n.resolveLanguage(storedPreference: "en", preferredLanguages: ["zh-Hans-CN"]) == "en")
        #expect(QLL10n.resolveLanguage(storedPreference: "system", preferredLanguages: ["zh-Hans-CN", "en-US"]) == "zh-Hans")
    }
}
