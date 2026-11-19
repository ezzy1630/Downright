import Foundation
import Testing
@testable import DownrightQL

@Suite(.serialized)
struct QLLocalizationTests {
    private func loadStrings(language: String) throws -> [String: String] {
        let root = QLL10n.resourceBundle
        let path = root.path(forResource: language, ofType: "lproj")
            ?? root.path(forResource: language.lowercased(), ofType: "lproj")
        let lprojPath = try #require(path, "Missing \(language).lproj in \(root.bundlePath)")
        let url = URL(fileURLWithPath: lprojPath).appendingPathComponent("Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    @Test func quickLookLocalizationTablesMatchAndTranslate() throws {
        let en = try loadStrings(language: "en")
        let zh = try loadStrings(language: "zh-Hans")
        #expect(!en.isEmpty)
        #expect(Set(en.keys) == Set(zh.keys))

        QLL10n.withLanguage("zh-Hans") {
            #expect(QLL10n.tr("Open in Downright") == "在 Downright 中打开")
            #expect(QLL10n.tr("Showing part of this large file") == "文件较大，当前仅预览开头部分")
            #expect(QLL10n.tr("Section %lld of %lld", 2, 5) == "第 2 / 5 节")
        }
        QLL10n.withLanguage("en") {
            #expect(QLL10n.tr("Open in Downright") == "Open in Downright")
        }
    }
}
