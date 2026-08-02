import Foundation

enum DocumentTrustState: String, Codable, CaseIterable, Sendable {
    case standard
    case trustedFolder
    case rawSource

    var title: String {
        switch self {
        case .standard: "Standard"
        case .trustedFolder: "Trusted Folder"
        case .rawSource: "Raw Source"
        }
    }
}

enum TrustEffect: String, Codable, CaseIterable, Hashable, Sendable {
    case openExternalLink
    case readLocalAsset
    case launchPathOrEditor
    case automationAppIntent

    var title: String {
        switch self {
        case .openExternalLink: "Open an external link"
        case .readLocalAsset: "Read a local asset"
        case .launchPathOrEditor: "Open a path or editor"
        case .automationAppIntent: "Run an app or automation intent"
        }
    }
}

enum TrustScope: String, Codable, CaseIterable, Sendable {
    case file
    case folder
}

enum TrustDecision: String, Codable, Sendable {
    case allow
    case deny
    case ask
}

struct TrustTarget: Sendable, Equatable {
    let displayName: String
    let canonicalPath: String?
    let externalURL: String?

    init(displayName: String, canonicalPath: String? = nil, externalURL: String? = nil) {
        self.displayName = displayName
        self.canonicalPath = canonicalPath
        self.externalURL = externalURL
    }
}

struct TrustRequest: Sendable, Equatable {
    let effect: TrustEffect
    let target: TrustTarget
    let documentPath: String?

    init(effect: TrustEffect, target: TrustTarget, documentURL: URL? = nil) {
        self.effect = effect
        self.target = target
        self.documentPath = documentURL.flatMap(DocumentTrust.canonicalFilePath)?.path
    }
}

struct TrustGrant: Codable, Hashable, Sendable {
    let scope: TrustScope
    let canonicalPath: String
    let effects: Set<TrustEffect>

    init(scope: TrustScope, canonicalPath: String, effects: Set<TrustEffect>) {
        self.scope = scope
        self.canonicalPath = canonicalPath
        self.effects = effects
    }
}

/// Pure policy evaluation.  It has no file reads and never invokes an effect.
struct DocumentTrust: Sendable {
    let state: DocumentTrustState
    let grants: [TrustGrant]

    init(state: DocumentTrustState = .standard, grants: [TrustGrant] = []) {
        self.state = state
        self.grants = grants
    }

    func decision(for request: TrustRequest) -> TrustDecision {
        guard state != .rawSource else { return .deny }
        guard let scopePath = request.target.canonicalPath ?? request.documentPath else { return .ask }
        let target = URL(fileURLWithPath: scopePath)
        let matching = grants.contains { grant in
            guard grant.effects.contains(request.effect) else { return false }
            let root = URL(fileURLWithPath: grant.canonicalPath)
            switch grant.scope {
            case .file:
                return target.path == root.path
            case .folder:
                return DocumentTrust.isWithin(target, root)
            }
        }
        return matching ? .allow : .ask
    }

    static func canonicalFilePath(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    static func isWithin(_ child: URL, _ root: URL) -> Bool {
        let childParts = child.standardizedFileURL.pathComponents
        let rootParts = root.standardizedFileURL.pathComponents
        guard childParts.count >= rootParts.count else { return false }
        return Array(childParts.prefix(rootParts.count)) == rootParts
    }
}
