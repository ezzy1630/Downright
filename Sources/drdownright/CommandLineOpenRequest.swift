import Foundation

/// A Launch Services request to open local files and set their presentation.
public struct CommandLineOpenRequest {
    private static let scheme = "downright-cli"

    public let urls: [URL]
    public let line: Int?
    public let edit: Bool
    public let review: Bool

    public init(urls: [URL], options: MarkdownCLI.OpenOptions) {
        self.urls = urls
        line = options.line
        edit = options.edit || options.review
        review = options.review
    }

    public var url: URL {
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "open"
        var items = urls.map { URLQueryItem(name: "file", value: $0.path) }
        if let line { items.append(URLQueryItem(name: "line", value: String(line))) }
        if edit { items.append(URLQueryItem(name: "edit", value: "1")) }
        if review { items.append(URLQueryItem(name: "review", value: "1")) }
        parts.queryItems = items
        return parts.url!
    }

    public init?(url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == Self.scheme, parts.host == "open", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems else { return nil }
        var urls: [URL] = []
        var line: Int?
        var edit = false
        var review = false
        for item in items {
            guard let value = item.value else { return nil }
            switch item.name {
            case "file":
                guard value.hasPrefix("/"), !value.contains("\0") else { return nil }
                urls.append(URL(fileURLWithPath: value).standardizedFileURL)
            case "line":
                guard line == nil, let number = Int(value), number > 0 else { return nil }
                line = number
            case "edit":
                guard !edit, value == "1" else { return nil }
                edit = true
            case "review":
                guard !review, value == "1" else { return nil }
                review = true
            default:
                return nil
            }
        }
        guard !urls.isEmpty else { return nil }
        self.urls = urls
        self.line = line
        self.edit = edit || review
        self.review = review
    }
}
