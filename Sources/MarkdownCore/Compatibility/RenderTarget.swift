import Foundation

/// Markdown features whose spelling or semantics vary between renderers.
public enum MarkdownCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case tables
    case taskLists
    case strikethrough
    case footnotes
    case math
    case mermaid
    case calloutsAlerts
    case wikilinks
    case frontMatter
    case rawHTML
    case headingAttributes
}

/// A stable, Codable set of renderer capabilities.
public struct MarkdownCapabilities: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: UInt64

    public init(rawValue: UInt64) { self.rawValue = rawValue }

    public static let tables = Self(rawValue: 1 << 0)
    public static let taskLists = Self(rawValue: 1 << 1)
    public static let strikethrough = Self(rawValue: 1 << 2)
    public static let footnotes = Self(rawValue: 1 << 3)
    public static let math = Self(rawValue: 1 << 4)
    public static let mermaid = Self(rawValue: 1 << 5)
    public static let calloutsAlerts = Self(rawValue: 1 << 6)
    public static let wikilinks = Self(rawValue: 1 << 7)
    public static let frontMatter = Self(rawValue: 1 << 8)
    public static let rawHTML = Self(rawValue: 1 << 9)
    public static let headingAttributes = Self(rawValue: 1 << 10)

    public static let all: Self = [
        .tables, .taskLists, .strikethrough, .footnotes, .math, .mermaid,
        .calloutsAlerts, .wikilinks, .frontMatter, .rawHTML, .headingAttributes,
    ]

    public func contains(_ capability: MarkdownCapability) -> Bool {
        contains(Self(capability))
    }

    public init(_ capability: MarkdownCapability) {
        switch capability {
        case .tables: self = .tables
        case .taskLists: self = .taskLists
        case .strikethrough: self = .strikethrough
        case .footnotes: self = .footnotes
        case .math: self = .math
        case .mermaid: self = .mermaid
        case .calloutsAlerts: self = .calloutsAlerts
        case .wikilinks: self = .wikilinks
        case .frontMatter: self = .frontMatter
        case .rawHTML: self = .rawHTML
        case .headingAttributes: self = .headingAttributes
        }
    }

    public var capabilities: [MarkdownCapability] {
        MarkdownCapability.allCases.filter(contains)
    }

    private enum CodingKeys: String, CodingKey { case capabilities }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(capabilities, forKey: .capabilities)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self = try container.decode([MarkdownCapability].self, forKey: .capabilities)
            .reduce(into: Self()) { $0.insert(Self($1)) }
    }
}

/// The named renderer families shipped by Downright.
public enum BuiltInRenderTarget: String, Codable, CaseIterable, Sendable {
    case downright
    case commonMark
    case gitHub
    case obsidian
    case pandoc
    case multiMarkdown
    case jekyll
    case hugo
    case quarto

    public var displayName: String {
        switch self {
        case .downright: return "Downright"
        case .commonMark: return "CommonMark"
        case .gitHub: return "GitHub"
        case .obsidian: return "Obsidian"
        case .pandoc: return "Pandoc"
        case .multiMarkdown: return "MultiMarkdown"
        case .jekyll: return "Jekyll"
        case .hugo: return "Hugo"
        case .quarto: return "Quarto"
        }
    }

    public var capabilities: MarkdownCapabilities {
        switch self {
        case .downright:
            return .all
        case .commonMark:
            return [.rawHTML]
        case .gitHub:
            return [.tables, .taskLists, .strikethrough, .footnotes, .math, .mermaid,
                    .calloutsAlerts, .rawHTML]
        case .obsidian:
            return [.tables, .taskLists, .strikethrough, .footnotes, .math, .mermaid,
                    .calloutsAlerts, .wikilinks, .frontMatter, .rawHTML]
        case .pandoc:
            return [.tables, .taskLists, .strikethrough, .footnotes, .math, .frontMatter,
                    .rawHTML, .headingAttributes]
        case .multiMarkdown:
            return [.tables, .taskLists, .strikethrough, .footnotes, .math, .frontMatter,
                    .rawHTML]
        case .jekyll:
            return [.tables, .taskLists, .strikethrough, .footnotes, .frontMatter, .rawHTML,
                    .headingAttributes]
        case .hugo:
            return [.tables, .taskLists, .strikethrough, .footnotes, .frontMatter, .rawHTML]
        case .quarto:
            return [.tables, .taskLists, .strikethrough, .footnotes, .math, .mermaid,
                    .calloutsAlerts, .frontMatter, .rawHTML, .headingAttributes]
        }
    }

    public var profile: RenderTargetProfile {
        RenderTargetProfile(builtIn: self, capabilities: capabilities)
    }
}

/// A renderer configuration. Custom profiles are intentionally data-only so
/// they can be saved and loaded without coupling compatibility to the app.
public struct RenderTargetProfile: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public let name: String
    public let capabilities: MarkdownCapabilities
    public let builtIn: BuiltInRenderTarget?

    public init(name: String, capabilities: MarkdownCapabilities) {
        self.id = "custom:\(name)"
        self.name = name
        self.capabilities = capabilities
        self.builtIn = nil
    }

    public init(builtIn: BuiltInRenderTarget, capabilities: MarkdownCapabilities? = nil) {
        self.id = builtIn.rawValue
        self.name = builtIn.displayName
        self.capabilities = capabilities ?? builtIn.capabilities
        self.builtIn = builtIn
    }

    public static let downright = BuiltInRenderTarget.downright.profile
    public static let commonMark = BuiltInRenderTarget.commonMark.profile
    public static let gitHub = BuiltInRenderTarget.gitHub.profile
    public static let obsidian = BuiltInRenderTarget.obsidian.profile
    public static let pandoc = BuiltInRenderTarget.pandoc.profile
    public static let multiMarkdown = BuiltInRenderTarget.multiMarkdown.profile
    public static let jekyll = BuiltInRenderTarget.jekyll.profile
    public static let hugo = BuiltInRenderTarget.hugo.profile
    public static let quarto = BuiltInRenderTarget.quarto.profile

    public static func custom(name: String, capabilities: MarkdownCapabilities) -> Self {
        Self(name: name, capabilities: capabilities)
    }

    public static var builtIns: [RenderTargetProfile] {
        BuiltInRenderTarget.allCases.map(\.profile)
    }
}
