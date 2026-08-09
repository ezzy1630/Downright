import AppKit
import MarkdownCore

// The render layer's stable surface.  §3.2's "one text surface, three modes" is
// enforced here: a mode is a `DecorationPolicy` value, not a separate code
// path, so Read and Live literally cannot disagree about what the document is.

// MARK: - Modes

public enum RenderMode: String, Codable, Sendable, CaseIterable {
    case read, live, source

    /// Modes exposed by the app. `read` remains decodable so old document
    /// state keeps working, but it now migrates to the editable document view.
    public static let userFacingModes: [RenderMode] = [.live, .source]

    public var normalizedForEditing: RenderMode {
        self == .read ? .live : self
    }

    public var title: String {
        switch self {
        case .read: return "Read"
        case .live: return "Document"
        case .source: return "Source"
        }
    }

    public var policy: DecorationPolicy {
        switch self {
        case .read:
            return DecorationPolicy(
                showsInsertionPoint: false, hidesBlockMarkers: true, hidesInlineMarkers: true,
                revealsAtCaret: false, showsGutterMarkers: false, highlightsMarkers: false,
                rendersFragments: true, collapsesLongCodeBlocks: true
            )
        case .live:
            return DecorationPolicy(
                showsInsertionPoint: true, hidesBlockMarkers: true, hidesInlineMarkers: true,
                revealsAtCaret: true, showsGutterMarkers: true, highlightsMarkers: false,
                rendersFragments: true, collapsesLongCodeBlocks: false
            )
        case .source:
            return DecorationPolicy(
                showsInsertionPoint: true, hidesBlockMarkers: false, hidesInlineMarkers: false,
                revealsAtCaret: false, showsGutterMarkers: false, highlightsMarkers: true,
                rendersFragments: false, collapsesLongCodeBlocks: false
            )
        }
    }
}

/// Temporary source visibility inside the one editable document surface.
///
/// `RenderMode` remains the low-level decoration contract used by Quick Look,
/// previews, and tests.  The app presents one Document surface and moves into
/// these explicit, transient focus states only when the user asks to inspect
/// or edit raw Markdown.
public enum SourceFocus: Equatable, Sendable {
    case none
    case scoped(NSRange)
    case document

    public var range: NSRange? {
        guard case .scoped(let range) = self else { return nil }
        return range
    }
}

public struct DecorationPolicy: Sendable, Equatable {
    public var showsInsertionPoint: Bool
    /// `#`, `>`, `-`, `1.` removed from the text run.  In Live mode they
    /// reappear in the gutter (§6.1a) — never inline, which is what keeps the
    /// line height and horizontal origin stable.
    public var hidesBlockMarkers: Bool
    public var hidesInlineMarkers: Bool
    /// Per-span reveal of inline markers around the caret (§6.1b).
    public var revealsAtCaret: Bool
    /// When enabled, secondary insertion carets reveal their own inline
    /// markers too. The default keeps multi-caret edits reflow-free.
    public var revealsAtAllCursors: Bool
    public var showsGutterMarkers: Bool
    /// Source mode styles markers instead of hiding them.
    public var highlightsMarkers: Bool
    /// Math, mermaid, tables, images render as objects rather than source.
    public var rendersFragments: Bool
    public var collapsesLongCodeBlocks: Bool

    public init(
        showsInsertionPoint: Bool, hidesBlockMarkers: Bool, hidesInlineMarkers: Bool,
        revealsAtCaret: Bool, showsGutterMarkers: Bool, highlightsMarkers: Bool,
        rendersFragments: Bool, collapsesLongCodeBlocks: Bool,
        revealsAtAllCursors: Bool = false
    ) {
        self.showsInsertionPoint = showsInsertionPoint
        self.hidesBlockMarkers = hidesBlockMarkers
        self.hidesInlineMarkers = hidesInlineMarkers
        self.revealsAtCaret = revealsAtCaret
        self.revealsAtAllCursors = revealsAtAllCursors
        self.showsGutterMarkers = showsGutterMarkers
        self.highlightsMarkers = highlightsMarkers
        self.rendersFragments = rendersFragments
        self.collapsesLongCodeBlocks = collapsesLongCodeBlocks
    }
}

public enum MarkdownRevealPolicy: String, Codable, Sendable, CaseIterable {
    case never
    case primaryCaret
    case allCursors
}

/// Bounded renderer-owned controls for app controllers and extensions. The
/// renderer does not persist these values or depend on DownrightApp.
public struct MarkdownRenderConfiguration: Codable, Sendable, Equatable {
    public var showInvisibles: Bool
    public var revealPolicy: MarkdownRevealPolicy
    public var typographicSubstitution: Bool
    public var typewriterScrolling: Bool
    /// Presents source-wrapped prose as one visual paragraph without changing
    /// the Markdown bytes. Kept as a renderer setting so dogfooding has an
    /// escape hatch if a document relies on physical line boundaries.
    public var reflowHardWrappedParagraphs: Bool
    public var largeFileThresholdMegabytes: Int {
        didSet { largeFileThresholdMegabytes = min(1024, max(1, largeFileThresholdMegabytes)) }
    }
    public var codeCollapseThreshold: Int {
        didSet { codeCollapseThreshold = min(10_000, max(1, codeCollapseThreshold)) }
    }

    public init(
        showInvisibles: Bool = false,
        revealPolicy: MarkdownRevealPolicy = .primaryCaret,
        typographicSubstitution: Bool = false,
        typewriterScrolling: Bool = false,
        reflowHardWrappedParagraphs: Bool = true,
        codeCollapseThreshold: Int = RenderMetrics.codeCollapseLineCount,
        largeFileThresholdMegabytes: Int = 5
    ) {
        self.showInvisibles = showInvisibles
        self.revealPolicy = revealPolicy
        self.typographicSubstitution = typographicSubstitution
        self.typewriterScrolling = typewriterScrolling
        self.reflowHardWrappedParagraphs = reflowHardWrappedParagraphs
        self.codeCollapseThreshold = min(10_000, max(1, codeCollapseThreshold))
        self.largeFileThresholdMegabytes = min(1024, max(1, largeFileThresholdMegabytes))
    }
}

// MARK: - Custom attributes
//
// All decoration is carried as attributes on the text storage.  The §14 warning
// about TextKit 2 rendering attributes being unreliable is taken literally:
// nothing dynamic goes through `NSTextLayoutManager.addRenderingAttribute`.

extension NSAttributedString.Key {
    /// Marks a range as a syntax marker the display string omits.
    public static let drHidden = NSAttributedString.Key("drHidden")
    /// Marks a syntax marker that is currently *shown* (source mode, or
    /// revealed at the caret) so it can be dimmed rather than styled as text.
    public static let drMarker = NSAttributedString.Key("drMarker")
    /// `FragmentPayload` for ranges that render as an object.
    public static let drFragment = NSAttributedString.Key("drFragment")
    /// `BlockIdentity` of the owning block.
    public static let drBlock = NSAttributedString.Key("drBlock")
    /// Heading level, for the gutter and the breadcrumb.
    public static let drHeading = NSAttributedString.Key("drHeading")
    /// `String` link destination — ours, not `.link`, so we control activation.
    public static let drLink = NSAttributedString.Key("drLink")
    /// `PathToken`, with `drPathExists` deciding the styling (§8.4).
    public static let drPathToken = NSAttributedString.Key("drPathToken")
    public static let drPathExists = NSAttributedString.Key("drPathExists")
    /// `Bool` — checkbox state, for hit testing a click on the glyph.
    public static let drCheckbox = NSAttributedString.Key("drCheckbox")
    /// `ChangeKind.rawValue` for change highlighting (§8.1).
    public static let drChange = NSAttributedString.Key("drChange")
    /// `String` — text an external write removed, held on the character at the
    /// join point.  A deletion has no range of its own in the new buffer, so
    /// this is the only place the removed bytes survive for the reader (§8.1).
    public static let drChangeGhost = NSAttributedString.Key("drChangeGhost")
    /// Footnote or reference-link identifier, for hover popovers.
    public static let drReference = NSAttributedString.Key("drReference")
    /// Set on ranges elided by structural zoom (§5.2) or folding.
    public static let drElided = NSAttributedString.Key("drElided")
    /// `String` gutter marker text drawn in the left rail in Live mode.
    public static let drGutterMarker = NSAttributedString.Key("drGutterMarker")
    /// Search-hit marking, kept distinct from selection.
    public static let drSearchHit = NSAttributedString.Key("drSearchHit")
    public static let drCurrentSearchHit = NSAttributedString.Key("drCurrentSearchHit")
    /// Current word spoken by the system speech synthesizer.
    public static let drSpeechHighlight = NSAttributedString.Key("drSpeechHighlight")
    /// Inline-code content that receives a padded rounded background.
    public static let drInlineCode = NSAttributedString.Key("drInlineCode")
    /// Source range temporarily shown as a flat, monospaced editing region.
    public static let drSourceFocus = NSAttributedString.Key("drSourceFocus")
    /// Marks spaces and tabs when the host asks the renderer to show them.
    public static let drInvisible = NSAttributedString.Key("drInvisible")
}

// MARK: - Fragments

public enum FragmentKind: String, Sendable {
    case codeBlock, collapsedCodeBlock, table, inlineMath, blockMath, mermaid, image, thematicBreak, frontMatter, callout, listOrnament

    /// True when the fragment draws its own content instead of letting TextKit
    /// draw the element's glyphs.
    ///
    /// Anything painted *behind* text — a search hit, a changed word — has
    /// nothing to sit behind in one of these, because the characters it would
    /// have tinted are not on screen.  The tint then lands on the fragment's
    /// empty glyph box and comes out as a floating rectangle of colour with no
    /// text in it, which is exactly what those stray shaded squares were.
    public var replacesGlyphs: Bool {
        switch self {
        case .table, .collapsedCodeBlock, .blockMath, .mermaid, .image, .thematicBreak, .frontMatter:
            return true
        // Code keeps its glyphs (that is the point of it), and a callout, a list
        // ornament and inline math are chrome drawn *around* real text.
        case .codeBlock, .callout, .listOrnament, .inlineMath:
            return false
        }
    }
}

/// Payload attached to a range that draws as an object rather than as glyphs.
/// A class so it can ride along as an attribute value without copying.
public final class FragmentPayload: NSObject {
    public let kind: FragmentKind
    public var sourceRange: NSRange
    public let blockIdentity: BlockIdentity
    /// Fence language, mermaid diagram type, image path, LaTeX source …
    public let detail: String
    /// Table geometry, populated by the table fragment.
    public var tableData: TableData?
    public var isCollapsed: Bool = false

    public init(kind: FragmentKind, sourceRange: NSRange, blockIdentity: BlockIdentity, detail: String) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.blockIdentity = blockIdentity
        self.detail = detail
    }

    /// Carries absolute parser coordinates across the short interval between a
    /// source edit and the async parse that replaces this payload.
    ///
    /// `NSTextStorage` moves the attribute run itself when characters are
    /// inserted or removed. The object stored in that run is a reference type,
    /// though, so its ranges do not move with it. A length-changing edit above
    /// a table therefore used to leave the table drawing from the old offsets:
    /// leading cell text disappeared and trailing Markdown markers leaked.
    /// Project the old metadata over the same edit immediately; the fresh parse
    /// remains authoritative when it arrives.
    func projectSourceRanges(across edit: NSRange, insertedLength: Int) {
        sourceRange = Self.project(sourceRange, across: edit, insertedLength: insertedLength)
        guard var tableData else { return }
        tableData.delimiterRange = Self.project(
            tableData.delimiterRange, across: edit, insertedLength: insertedLength
        )
        tableData.rows = tableData.rows.map { row in
            TableRow(
                range: Self.project(row.range, across: edit, insertedLength: insertedLength),
                cells: row.cells.map { cell in
                    TableCell(
                        range: Self.project(cell.range, across: edit, insertedLength: insertedLength),
                        contentRange: Self.project(
                            cell.contentRange, across: edit, insertedLength: insertedLength
                        ),
                        inlines: cell.inlines.map {
                            Self.project($0, across: edit, insertedLength: insertedLength)
                        }
                    )
                },
                isHeader: row.isHeader
            )
        }
        self.tableData = tableData
    }

    private static func project(
        _ span: InlineSpan,
        across edit: NSRange,
        insertedLength: Int
    ) -> InlineSpan {
        InlineSpan(
            kind: span.kind,
            range: project(span.range, across: edit, insertedLength: insertedLength),
            contentRange: project(span.contentRange, across: edit, insertedLength: insertedLength),
            leadingMarkerRange: span.leadingMarkerRange.map {
                project($0, across: edit, insertedLength: insertedLength)
            },
            trailingMarkerRange: span.trailingMarkerRange.map {
                project($0, across: edit, insertedLength: insertedLength)
            },
            children: span.children.map {
                project($0, across: edit, insertedLength: insertedLength)
            }
        )
    }

    private static func project(
        _ range: NSRange,
        across edit: NSRange,
        insertedLength: Int
    ) -> NSRange {
        let delta = insertedLength - edit.length
        if range.upperBound <= edit.location { return range }
        if range.location >= edit.upperBound {
            return NSRange(location: max(0, range.location + delta), length: range.length)
        }

        // The edit intersects this semantic range. Preserve the part on each
        // side and let the replacement occupy the intersected interval.
        let prefix = max(0, edit.location - range.location)
        let suffix = max(0, range.upperBound - edit.upperBound)
        let location = min(range.location, edit.location)
        return NSRange(location: location, length: prefix + insertedLength + suffix)
    }
}

// MARK: - Theme (§11.2)
//
// JSON, not CSS (§11.2).  Colours may be literal hex or a reference to an
// `NSColor` system colour, so a theme that opts into system colours adapts to
// light/dark, the accent colour, and Increase Contrast for free.

public struct ThemeColor: Codable, Sendable, Equatable {
    public var raw: String

    public init(_ raw: String) { self.raw = raw }
    public init(from decoder: Decoder) throws {
        raw = try decoder.singleValueContainer().decode(String.self)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(raw)
    }

    /// `#rrggbb`, `#rrggbbaa`, or `system:<name>` naming an `NSColor` class
    /// property (`labelColor`, `controlAccentColor`, …).
    public func resolved() -> NSColor {
        if raw.hasPrefix("system:") {
            let name = String(raw.dropFirst("system:".count))
            if let c = NSColor.systemColorNamed(name) { return c }
            return .labelColor
        }
        return NSColor(hexString: raw) ?? .labelColor
    }
}

public enum ThemeAppearance: String, Codable, Sendable {
    case light, dark, auto
}

public struct ThemePalette: Codable, Sendable, Equatable {
    public var background: ThemeColor
    public var surface: ThemeColor
    public var text: ThemeColor
    public var textSecondary: ThemeColor
    public var textFaint: ThemeColor
    public var heading: ThemeColor
    public var marker: ThemeColor
    public var accent: ThemeColor
    public var link: ThemeColor
    public var rule: ThemeColor
    public var selection: ThemeColor
    public var codeBackground: ThemeColor
    public var inlineCodeBackground: ThemeColor
    public var codeRule: ThemeColor
    public var railTick: ThemeColor
    public var railTickCurrent: ThemeColor
    public var quoteRule: ThemeColor
    public var changeAdded: ThemeColor
    public var changeRemoved: ThemeColor
    public var changeModified: ThemeColor
    public var pathMissing: ThemeColor
    public var searchHit: ThemeColor
    public var searchHitCurrent: ThemeColor
    public var calloutNote: ThemeColor
    public var calloutWarning: ThemeColor
    public var calloutSuccess: ThemeColor
    public var calloutDanger: ThemeColor
}

public struct CodeTheme: Codable, Sendable, Equatable {
    public var keyword: ThemeColor
    public var string: ThemeColor
    public var number: ThemeColor
    public var comment: ThemeColor
    public var type: ThemeColor
    public var function: ThemeColor
    public var variable: ThemeColor
    public var constant: ThemeColor
    public var `operator`: ThemeColor
    public var punctuation: ThemeColor
    public var attribute: ThemeColor
    public var diffAdded: ThemeColor
    public var diffRemoved: ThemeColor
    public var diffHeader: ThemeColor
}

public struct TypographyConfig: Codable, Sendable, Equatable {
    public enum BodyPreset: String, Codable, Sendable, CaseIterable {
        case reading   // New York — Apple's serif
        case working   // SF Pro Text

        public var title: String { self == .reading ? "Reading" : "Working" }
    }

    public var preset: BodyPreset
    public var bodySize: CGFloat
    /// 1.2 / 1.25 / 1.333 — one ratio drives every heading size (§11.1).
    public var scaleRatio: CGFloat
    public var lineHeightMultiple: CGFloat
    /// Capped at 68–72 characters (§11.1).  The single most common thing
    /// markdown viewers get wrong.
    public var measureCharacters: CGFloat
    public var monoFamily: String
    /// Code size as a fraction of the body size.
    ///
    /// The default is the value that matches SF Mono's x-height to New York's,
    /// the same correction `mathScale` exists to make for formulas: at 0.92 the
    /// mono face's x-height was 7.78pt against the body's 7.53, so code read
    /// visibly *larger* than the prose around it while fitting fewer columns
    /// per line.  A monospace face should sit a shade under its prose
    /// companion, not over it.
    public var monoSizeAdjust: CGFloat
    public var monoLigatures: Bool
    /// Hanging punctuation and optical margin alignment (§11.1).
    public var opticalMargins: Bool
    /// Math is sized against the body font's x-height, not its point size —
    /// the reason most apps render formulas visibly too large (§11.3).
    public var mathScale: CGFloat

    /// `lineHeightMultiple` is 1.6, which the half-unit baseline grid resolves to
    /// 26pt at a 16pt body.  1.55 resolved to 24pt — 1.50 in practice, which is
    /// tight for a serif running to 70 characters: the eye loses the line it is
    /// returning to.  The next value a whole-unit grid could reach was 28pt,
    /// loose enough to stripe the page, which is why the grid gained half units
    /// before this number moved.
    public static let `default` = TypographyConfig(
        preset: .reading, bodySize: 16, scaleRatio: 1.25, lineHeightMultiple: 1.6,
        measureCharacters: 70, monoFamily: "SF Mono", monoSizeAdjust: 0.88,
        monoLigatures: false, opticalMargins: true, mathScale: 1.0
    )
}

public struct Theme: Codable, Sendable, Equatable {
    public var name: String
    public var appearance: ThemeAppearance
    public var palette: ThemePalette
    public var code: CodeTheme
    public var typography: TypographyConfig

    public init(name: String, appearance: ThemeAppearance, palette: ThemePalette, code: CodeTheme, typography: TypographyConfig) {
        self.name = name
        self.appearance = appearance
        self.palette = palette
        self.code = code
        self.typography = typography
    }
}

// MARK: - Colour helpers

extension NSColor {
    public convenience init?(hexString: String) {
        var s = hexString.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, let v = UInt64(s, radix: 16) else { return nil }
        let hasAlpha = s.count == 8
        let r = CGFloat((v >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = CGFloat((v >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = CGFloat((v >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? CGFloat(v & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }

    static func systemColorNamed(_ name: String) -> NSColor? {
        switch name {
        case "label", "labelColor": return .labelColor
        case "secondaryLabel", "secondaryLabelColor": return .secondaryLabelColor
        case "tertiaryLabel", "tertiaryLabelColor": return .tertiaryLabelColor
        case "quaternaryLabel", "quaternaryLabelColor": return .quaternaryLabelColor
        case "textBackground", "textBackgroundColor": return .textBackgroundColor
        case "controlBackground", "controlBackgroundColor": return .controlBackgroundColor
        case "underPageBackground", "underPageBackgroundColor": return .underPageBackgroundColor
        case "accent", "controlAccentColor": return .controlAccentColor
        case "selectedTextBackground", "selectedTextBackgroundColor": return .selectedTextBackgroundColor
        case "separator", "separatorColor": return .separatorColor
        case "link", "linkColor": return .linkColor
        case "systemRed": return .systemRed
        case "systemGreen": return .systemGreen
        case "systemBlue": return .systemBlue
        case "systemOrange": return .systemOrange
        case "systemYellow": return .systemYellow
        case "systemPurple": return .systemPurple
        case "systemTeal": return .systemTeal
        case "systemPink": return .systemPink
        case "systemGray": return .systemGray
        default: return nil
        }
    }
}
