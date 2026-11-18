import Darwin
import Foundation

/// A request from `down` to a running Downright: open local files and set
/// their presentation (line, Live mode, Review).
///
/// Launch Services delivers it as a `downright-cli:` URL, but any app or web
/// page can open such a URL.  So the URL carries only a random handoff ID;
/// the request itself travels in a one-shot file the CLI creates with
/// owner-only permissions in the user's private temporary directory.  A URL
/// that did not come from `down` names no such file and is ignored.
public struct CommandLineOpenRequest {
    static let scheme = "downright-cli"
    private static let handoffLifetime: TimeInterval = 120
    private static let maximumPayloadBytes = 256 * 1024

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

    // MARK: Handoff

    /// The per-user temporary directory (`/var/folders/…/T`), from the system
    /// rather than `$TMPDIR`, so the CLI and the app agree on it.
    public static var handoffDirectory: URL {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
        let length = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard length > 0, length <= buffer.count else { return FileManager.default.temporaryDirectory }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
    }

    /// Writes the request to a new owner-only file and returns the URL to
    /// deliver.  Call `discardHandoff(_:)` if delivery fails.
    public func handoffURL(directory: URL = handoffDirectory) throws -> URL {
        let id = UUID().uuidString
        let file = Self.handoffFile(id: id, in: directory)
        // O_EXCL + O_NOFOLLOW: never reuse or follow something already there.
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        let payload = Array(payloadURL.absoluteString.utf8)
        var written = 0
        while written < payload.count {
            let result = payload[written...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard result > 0 else {
                unlink(file.path)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            written += result
        }
        var parts = URLComponents()
        parts.scheme = Self.scheme
        parts.host = "open"
        parts.queryItems = [URLQueryItem(name: "request", value: id)]
        return parts.url!
    }

    /// Removes the handoff file behind a URL that was never delivered.
    public static func discardHandoff(_ url: URL, directory: URL = handoffDirectory) {
        guard let id = handoffID(in: url) else { return }
        unlink(handoffFile(id: id, in: directory).path)
    }

    /// Reads and consumes the request behind a delivered URL.  Returns nil
    /// for any URL whose one-shot file is missing, expired, not a private
    /// regular file owned by this user, or malformed.
    public static func receive(
        _ url: URL, directory: URL = handoffDirectory, now: Date = Date()
    ) -> CommandLineOpenRequest? {
        guard let id = handoffID(in: url) else { return nil }
        let path = handoffFile(id: id, in: directory).path
        let descriptor = Darwin.open(path, O_RDONLY | O_NOFOLLOW)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        // One shot: consume it whatever it contains.
        unlink(path)
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFREG,
              status.st_uid == getuid(),
              status.st_mode & 0o077 == 0,
              status.st_size > 0, status.st_size <= maximumPayloadBytes
        else { return nil }
        let modified = Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec))
        guard abs(now.timeIntervalSince(modified)) <= handoffLifetime else { return nil }
        var bytes = [UInt8](repeating: 0, count: Int(status.st_size))
        guard read(descriptor, &bytes, bytes.count) == bytes.count,
              let string = String(bytes: bytes, encoding: .utf8),
              let payload = URL(string: string)
        else { return nil }
        return CommandLineOpenRequest(payloadURL: payload)
    }

    private static func handoffID(in url: URL) -> String? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == scheme, parts.host == "open", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, items.count == 1, items[0].name == "request",
              let value = items[0].value, let uuid = UUID(uuidString: value), uuid.uuidString == value
        else { return nil }
        return value
    }

    private static func handoffFile(id: String, in directory: URL) -> URL {
        directory.appendingPathComponent("downright-cli-\(id).request", isDirectory: false)
    }

    // MARK: Payload

    var payloadURL: URL {
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

    init?(payloadURL url: URL) {
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
