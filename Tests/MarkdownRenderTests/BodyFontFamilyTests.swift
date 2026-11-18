import AppKit
import Foundation
import MarkdownCore
import Testing
@testable import MarkdownRender

/// The body font family setting (issue #61): a chosen installed family sets
/// prose and headings, code keeps its own face, and anything unusable falls
/// back to the preset.
///
/// Georgia (every face) and Papyrus (no bold, no italic) ship with macOS, so
/// the fixtures are real installed families rather than stand-ins.
@Suite("Body font family")
struct BodyFontFamilyTests {
    private let aqua = NSAppearance(named: .aqua)!

    private func sheet(family: String?, preset: TypographyConfig.BodyPreset = .reading) -> StyleSheet {
        var theme = Theme.fallback
        theme.typography.preset = preset
        theme.typography.bodyFamily = family
        return StyleSheet(theme: theme, appearance: aqua)
    }

    private func requireInstalled(_ family: String) throws {
        try #require(NSFontManager.shared.availableMembers(ofFontFamily: family) != nil, "\(family) ships with macOS")
    }

    private func traits(_ font: NSFont) -> NSFontDescriptor.SymbolicTraits {
        font.fontDescriptor.symbolicTraits
    }

    @Test func defaultCodeFaceIsSFMonoEvenWhenItIsNotANamedFamily() {
        // DESIGN.md: code is SF Mono.  Where SF Mono is not installed by name,
        // macOS still provides it as the system monospaced face; the chain must
        // reach that before any other installed monospace font.
        let name = sheet(family: nil).monoFont().fontName
        let system = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular).fontName
        #expect(name == "SFMono-Regular" || name == system, "resolved \(name)")
    }

    // MARK: Persistence

    @Test func typographyWrittenBeforeTheFieldDecodesToThePreset() throws {
        var legacy = TypographyConfig.default
        legacy.monoFamily = "Menlo"
        legacy.preset = .working
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any]
        )
        json.removeValue(forKey: "bodyFamily")
        let decoded = try JSONDecoder().decode(
            TypographyConfig.self, from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.bodyFamily == nil)
        #expect(decoded.monoFamily == "Menlo")
        #expect(decoded.preset == .working)
        #expect(TypographyConfig.default.bodyFamily == nil, "the default stays the preset's face")
    }

    @Test func aChosenFamilyRoundTripsAndTheDefaultWritesNoKey() throws {
        var chosen = TypographyConfig.default
        chosen.bodyFamily = "Georgia"
        let decoded = try JSONDecoder().decode(TypographyConfig.self, from: JSONEncoder().encode(chosen))
        #expect(decoded == chosen)

        let defaultJSON = String(decoding: try JSONEncoder().encode(TypographyConfig.default), as: UTF8.self)
        #expect(!defaultJSON.contains("bodyFamily"))
    }

    @Test func blankFamilyNamesMeanNoChoice() {
        var typography = TypographyConfig.default
        for blank in ["", "   ", "\n"] {
            typography.bodyFamily = blank
            #expect(typography.customBodyFamily == nil)
        }
        typography.bodyFamily = " Georgia "
        #expect(typography.customBodyFamily == "Georgia")
    }

    // MARK: Resolution

    @Test func noChoiceKeepsTodaysPresetFonts() {
        for preset in TypographyConfig.BodyPreset.allCases {
            let unset = sheet(family: nil, preset: preset)
            let blank = sheet(family: "", preset: preset)
            #expect(unset.bodyFont() == blank.bodyFont())
            for level in 1...6 { #expect(unset.headingFont(level: level) == blank.headingFont(level: level)) }
        }
        #expect(sheet(family: nil, preset: .reading).bodyFont().familyName == ".AppleSystemUIFontSerif")
        #expect(sheet(family: nil, preset: .working).bodyFont().familyName == ".AppleSystemUIFont")
    }

    @Test func aChosenFamilySetsBodyHeadingsAndEmphasisButNotCode() throws {
        try requireInstalled("Georgia")
        let preset = sheet(family: nil)
        let chosen = sheet(family: "Georgia")

        #expect(chosen.bodyFont().familyName == "Georgia")
        #expect(chosen.bodyFont().pointSize == preset.bodyFont().pointSize)
        #expect(!traits(chosen.bodyFont()).contains(.italic))
        for level in 1...6 {
            let heading = chosen.headingFont(level: level)
            #expect(heading.familyName == "Georgia", "H\(level)")
            #expect(heading.pointSize == preset.headingFont(level: level).pointSize, "H\(level) keeps the scale")
        }
        #expect(traits(chosen.headingFont(level: 1)).contains(.bold))
        #expect(traits(chosen.headingFont(level: 6)).contains(.italic), "H6 keeps its italic treatment")

        let bold = chosen.emphasisFont(bold: true, italic: false)
        let italic = chosen.emphasisFont(bold: false, italic: true)
        let both = chosen.emphasisFont(bold: true, italic: true)
        #expect(bold.fontName == "Georgia-Bold")
        #expect(italic.fontName == "Georgia-Italic")
        #expect(both.fontName == "Georgia-BoldItalic")

        #expect(chosen.monoFont() == preset.monoFont(), "code stays on the code font")
        #expect(chosen.monoFont().isFixedPitch)
    }

    @Test func measureAndMathTrackTheChosenFace() throws {
        try requireInstalled("Georgia")
        let preset = sheet(family: nil, preset: .working)
        let chosen = sheet(family: "Georgia", preset: .working)
        #expect(chosen.lineHeight == preset.lineHeight, "line metrics come from size and multiple, not the face")
        #expect(chosen.baselineGrid == preset.baselineGrid)
        #expect(chosen.averageCharacterWidth != preset.averageCharacterWidth)
        let characters = TypographyConfig.clampedMeasureCharacters(chosen.theme.typography.measureCharacters)
        #expect(abs(chosen.measureWidth - chosen.averageCharacterWidth * characters) < 0.001)
    }

    @Test func aMissingFamilyFallsBackToThePreset() {
        let missing = sheet(family: "Downright No Such Family")
        let preset = sheet(family: nil)
        #expect(missing.bodyFont() == preset.bodyFont())
        #expect(missing.measureWidth == preset.measureWidth)
        for level in 1...6 { #expect(missing.headingFont(level: level) == preset.headingFont(level: level)) }
        #expect(missing.emphasisFont(bold: true, italic: true) == preset.emphasisFont(bold: true, italic: true))
    }

    @Test func familiesWithoutBoldOrItalicDegradePerTrait() throws {
        try requireInstalled("Papyrus")
        let chosen = sheet(family: "Papyrus")
        let body = chosen.bodyFont()
        #expect(body.familyName == "Papyrus")

        let bold = chosen.emphasisFont(bold: true, italic: false)
        #expect(bold.familyName == "Papyrus", "no bold face: stay in the family rather than switch faces")
        #expect(bold.pointSize == body.pointSize)

        let italic = chosen.emphasisFont(bold: false, italic: true)
        #expect(italic.familyName == "Papyrus")
        #expect(italic.pointSize == body.pointSize)
        let matrix = CTFontGetMatrix(italic as CTFont)
        #expect(matrix.c > 0, "no italic face: the upright is slanted so emphasis still shows")
        #expect(abs(italic.ascender - body.ascender) < 0.01, "the slant must not rescale the face")

        let both = chosen.emphasisFont(bold: true, italic: true)
        #expect(both.familyName == "Papyrus")
        #expect(CTFontGetMatrix(both as CTFont).c > 0)
    }

    @Test func theCacheTokenChangesWithTheFace() throws {
        try requireInstalled("Georgia")
        #expect(StyleToken.of(sheet(family: nil)) != StyleToken.of(sheet(family: "Georgia")))
        #expect(StyleToken.of(sheet(family: nil)) == StyleToken.of(sheet(family: "")))
    }

    // MARK: Rendering

    @Test func aRenderSetsProseAndHeadingsInTheChosenFamily() throws {
        try requireInstalled("Georgia")
        let source = """
        # Title with *slant*

        Plain words, **strong words**, *soft words* and `code`.

        ```swift
        let x = 1
        ```
        """
        let storage = NSTextStorage(string: source)
        let engine = DecorationEngine(styleSheet: sheet(family: "Georgia"))
        engine.policy = RenderMode.read.policy
        _ = engine.decorate(storage, document: MarkdownParser.parse(source), dirty: .wholesale)

        let text = source as NSString
        func font(at needle: String, offset: Int = 0) throws -> NSFont {
            let location = text.range(of: needle).location
            try #require(location != NSNotFound, "\(needle) is in the sample")
            return try #require(storage.attribute(.font, at: location + offset, effectiveRange: nil) as? NSFont)
        }

        #expect(try font(at: "Title").familyName == "Georgia")
        #expect(try traits(font(at: "Title")).contains(.bold))
        let headingItalic = try font(at: "slant")
        #expect(headingItalic.familyName == "Georgia")
        #expect(traits(headingItalic).contains(.italic) && traits(headingItalic).contains(.bold))
        #expect(try font(at: "Plain").fontName == "Georgia")
        #expect(try font(at: "strong words").fontName == "Georgia-Bold")
        #expect(try font(at: "soft words").fontName == "Georgia-Italic")
        #expect(try font(at: "code`", offset: 0).isFixedPitch)
        #expect(try font(at: "let x").isFixedPitch)
        #expect(storage.string == source, "changing the face never rewrites source")
    }
}
