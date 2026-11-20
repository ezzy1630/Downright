import Foundation
import MarkdownRender

/// A reader profile changes presentation only. It never changes document text,
/// the selected theme, or the document's saved state.
enum ReaderProfileID: String, Codable, CaseIterable, Sendable {
    case documentation
    case longForm = "long-form"
    case academic
    case specification
    case github
    case presentation
}

enum ReaderTypographyScale: String, Codable, CaseIterable, Sendable {
    case compact
    case standard
    case large
    case extraLarge = "extra-large"

    var value: CGFloat {
        switch self {
        case .compact: 0.9
        case .standard: 1
        case .large: 1.12
        case .extraLarge: 1.25
        }
    }

    var title: String {
        switch self {
        case .compact: L10n.tr("Compact", context: "typographyScale")
        case .standard: L10n.tr("Standard", context: "typographyScale")
        case .large: L10n.tr("Large", context: "typographyScale")
        case .extraLarge: L10n.tr("Extra large", context: "typographyScale")
        }
    }
}

enum ReaderChromeDensity: String, Codable, CaseIterable, Sendable {
    case compact
    case comfortable
    case spacious

    var title: String {
        switch self {
        case .compact: L10n.tr("Compact", context: "chromeDensity")
        case .comfortable: L10n.tr("Comfortable", context: "chromeDensity")
        case .spacious: L10n.tr("Spacious", context: "chromeDensity")
        }
    }
}

enum ReaderMotionPreference: String, Codable, CaseIterable, Sendable {
    case followSystem = "follow-system"
    case reduced
    case full

    var title: String {
        switch self {
        case .followSystem: L10n.tr("Follow system")
        case .reduced: L10n.tr("Reduced")
        case .full: L10n.tr("Full")
        }
    }
}

struct ReaderProfile: Codable, Equatable, Hashable, Identifiable, Sendable {
    var id: String
    var name: String
    var isBuiltIn: Bool
    var typographyScale: ReaderTypographyScale
    var measureCharacters: CGFloat
    var chromeDensity: ReaderChromeDensity
    var motionPreference: ReaderMotionPreference

    init(
        id: String,
        name: String,
        isBuiltIn: Bool = false,
        typographyScale: ReaderTypographyScale = .standard,
        measureCharacters: CGFloat = 70,
        chromeDensity: ReaderChromeDensity = .comfortable,
        motionPreference: ReaderMotionPreference = .followSystem
    ) {
        self.id = id
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.typographyScale = typographyScale
        self.measureCharacters = TypographyConfig.clampedMeasureCharacters(measureCharacters)
        self.chromeDensity = chromeDensity
        self.motionPreference = motionPreference
    }

    var displayName: String {
        guard isBuiltIn else { return name }
        switch id {
        case ReaderProfileID.documentation.rawValue: return L10n.tr("Documentation", context: "readerProfile")
        case ReaderProfileID.longForm.rawValue: return L10n.tr("Long-form", context: "readerProfile")
        case ReaderProfileID.academic.rawValue: return L10n.tr("Academic", context: "readerProfile")
        case ReaderProfileID.specification.rawValue: return L10n.tr("Specification", context: "readerProfile")
        case ReaderProfileID.github.rawValue: return L10n.tr("GitHub", context: "readerProfile")
        case ReaderProfileID.presentation.rawValue: return L10n.tr("Presentation", context: "readerProfile")
        default: return name
        }
    }

    static let builtIns: [ReaderProfile] = [
        ReaderProfile(id: ReaderProfileID.documentation.rawValue, name: "Documentation", isBuiltIn: true, measureCharacters: 70),
        ReaderProfile(id: ReaderProfileID.longForm.rawValue, name: "Long-form", isBuiltIn: true, typographyScale: .large, measureCharacters: 68, chromeDensity: .compact),
        ReaderProfile(id: ReaderProfileID.academic.rawValue, name: "Academic", isBuiltIn: true, measureCharacters: 68),
        ReaderProfile(id: ReaderProfileID.specification.rawValue, name: "Specification", isBuiltIn: true, typographyScale: .compact, measureCharacters: 72, chromeDensity: .comfortable),
        ReaderProfile(id: ReaderProfileID.github.rawValue, name: "GitHub", isBuiltIn: true, measureCharacters: 72, chromeDensity: .compact),
        ReaderProfile(id: ReaderProfileID.presentation.rawValue, name: "Presentation", isBuiltIn: true, typographyScale: .extraLarge, measureCharacters: 68, chromeDensity: .spacious)
    ]

    static func custom(id: String = UUID().uuidString, name: String) -> ReaderProfile {
        ReaderProfile(id: id, name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Custom" : name)
    }
}

protocol ReaderProfileStore: AnyObject {
    func loadCustomProfiles() -> [ReaderProfile]
    func saveCustomProfiles(_ profiles: [ReaderProfile])
}

final class JSONReaderProfileStore: ReaderProfileStore {
    private let url: URL
    private let fileManager: FileManager

    init(url: URL, fileManager: FileManager = .default) {
        self.url = url
        self.fileManager = fileManager
    }

    func loadCustomProfiles() -> [ReaderProfile] {
        guard let data = try? Data(contentsOf: url),
              let profiles = try? JSONDecoder().decode([ReaderProfile].self, from: data)
        else { return [] }
        return profiles.filter { !$0.isBuiltIn }
    }

    func saveCustomProfiles(_ profiles: [ReaderProfile]) {
        let custom = profiles.filter { !$0.isBuiltIn }
        guard let data = try? JSONEncoder().encode(custom) else { return }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}

final class InMemoryReaderProfileStore: ReaderProfileStore {
    var profiles: [ReaderProfile]

    init(_ profiles: [ReaderProfile] = []) { self.profiles = profiles }

    func loadCustomProfiles() -> [ReaderProfile] { profiles }
    func saveCustomProfiles(_ profiles: [ReaderProfile]) { self.profiles = profiles }
}
