import Foundation

/// The result of resolving a Markdown image destination without touching the
/// filesystem beyond canonical path resolution.  A caller may inject a trust
/// decision for destinations that are not safe relative assets.
public struct LocalAssetRequest: Sendable, Equatable {
    public let url: URL
    public let isSafeRelative: Bool

    public init(url: URL, isSafeRelative: Bool) {
        self.url = url
        self.isSafeRelative = isSafeRelative
    }
}

/// Local image policy shared by the app renderer and Quick Look.  Rendering is
/// deliberately a pure decision point: an unsafe destination is blocked, not
/// prompted for, while an app host may inject an already-granted trust check.
public enum LocalAssetPolicy {
    /// Resolves a Markdown destination and canonicalizes symlinks before any
    /// image loader sees it. Non-file URLs are never local image requests.
    public static func request(raw: String, documentURL: URL?) -> LocalAssetRequest? {
        guard !raw.isEmpty, let documentURL,
              let document = canonicalFileURL(documentURL) else { return nil }

        let relative = !raw.hasPrefix("/") && !raw.hasPrefix("~") && !raw.contains("://")
        let hasTraversal = raw.split(separator: "/", omittingEmptySubsequences: false)
            .contains("..")

        let candidate: URL
        if raw.contains("://") {
            guard let parsed = URL(string: raw), parsed.isFileURL else { return nil }
            candidate = parsed
        } else if raw.hasPrefix("~") {
            candidate = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        } else if raw.hasPrefix("/") {
            candidate = URL(fileURLWithPath: raw)
        } else {
            candidate = URL(fileURLWithPath: raw, relativeTo: document.deletingLastPathComponent())
        }

        guard let canonical = canonicalFileURL(candidate) else { return nil }
        let safeRelative = relative && !hasTraversal
            && isWithin(canonical, document.deletingLastPathComponent())
        return LocalAssetRequest(url: canonical, isSafeRelative: safeRelative)
    }

    public static func allows(
        _ request: LocalAssetRequest,
        authorizer: ((URL) -> Bool)? = nil
    ) -> Bool {
        request.isSafeRelative || authorizer?(request.url) == true
    }

    /// Public for app-side trust wiring and policy tests. Returns a canonical
    /// file URL even when the final asset is missing, while resolving any
    /// existing symlink in its path.
    public static func canonicalFileURL(_ url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        return url.standardizedFileURL.resolvingSymlinksInPath().standardizedFileURL
    }

    public static func isWithin(_ child: URL, _ root: URL) -> Bool {
        guard let child = canonicalFileURL(child), let root = canonicalFileURL(root) else {
            return false
        }
        let childParts = child.pathComponents
        let rootParts = root.pathComponents
        guard childParts.count >= rootParts.count else { return false }
        return Array(childParts.prefix(rootParts.count)) == rootParts
    }
}
