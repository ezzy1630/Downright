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

    enum HandoffError: LocalizedError {
        case payloadTooLarge

        var errorDescription: String? {
            "The open request exceeds \(CommandLineOpenRequest.maximumPayloadBytes / 1024) KiB after encoding. Open fewer files at a time."
        }
    }

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

    /// When `down` runs inside an App Sandbox (for example spawned by a
    /// sandboxed app or agent), the system temporary directory is that
    /// container's `Data/tmp`, which the app cannot find on its own.  Name
    /// the container in the URL only in that exact case.
    public static var callerContainer: String? {
        guard let id = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"],
              isValidContainerID(id) else { return nil }
        let path = handoffDirectory.standardizedFileURL.path
        return path.hasSuffix("/Library/Containers/\(id)/Data/tmp") ? id : nil
    }

    /// Writes the request to a new owner-only file and returns the URL to
    /// deliver.  Call `discardHandoff(_:)` if delivery fails.
    public func handoffURL(directory: URL = handoffDirectory, container: String? = callerContainer) throws -> URL {
        let payload = Array(payloadURL.absoluteString.utf8)
        guard payload.count <= Self.maximumPayloadBytes else { throw HandoffError.payloadTooLarge }
        let id = UUID().uuidString
        let file = Self.handoffFile(id: id, in: directory)
        // O_EXCL + O_NOFOLLOW: never reuse or follow something already there.
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
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
            + (container.map { [URLQueryItem(name: "container", value: $0)] } ?? [])
        return parts.url!
    }

    /// Removes the handoff file behind a URL that was never delivered.
    public static func discardHandoff(_ url: URL, directory: URL = handoffDirectory) {
        guard let handoff = handoff(in: url) else { return }
        unlink(handoffFile(id: handoff.id, in: directory).path)
    }

    /// Reads and consumes the request behind a delivered URL.  Returns nil
    /// for any URL whose one-shot file is missing, expired, not a private
    /// regular file owned by this user, or malformed.  A sandboxed caller's
    /// file is looked up only in `<home>/Library/Containers/<id>/Data/tmp`.
    public static func receive(
        _ url: URL, directory: URL = handoffDirectory, containers: URL = userContainersDirectory,
        now: Date = Date()
    ) -> CommandLineOpenRequest? {
        guard let handoff = handoff(in: url) else { return nil }
        let source = handoff.container.map {
            containers.appendingPathComponent($0, isDirectory: true)
                .appendingPathComponent("Data/tmp", isDirectory: true)
        } ?? directory
        let path = handoffFile(id: handoff.id, in: source).path
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

    /// The real user's `~/Library/Containers`, from the password database
    /// rather than `$HOME`, which a sandboxed process sees as its container.
    public static var userContainersDirectory: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) }
            ?? NSHomeDirectory()
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent("Library/Containers", isDirectory: true)
    }

    static func isValidContainerID(_ id: String) -> Bool {
        guard (1...255).contains(id.utf8.count), !id.hasPrefix("."), !id.contains("..") else { return false }
        return id.unicodeScalars.allSatisfy {
            ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                || $0 == "." || $0 == "-" || $0 == "_"
        }
    }

    private static func handoff(in url: URL) -> (id: String, container: String?)? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme == scheme, parts.host == "open", parts.path.isEmpty,
              parts.user == nil, parts.password == nil, parts.port == nil, parts.fragment == nil,
              let items = parts.queryItems, (1...2).contains(items.count)
        else { return nil }
        var id: String?
        var container: String?
        for item in items {
            guard let value = item.value else { return nil }
            switch item.name {
            case "request" where id == nil:
                guard let uuid = UUID(uuidString: value), uuid.uuidString == value else { return nil }
                id = value
            case "container" where container == nil:
                guard isValidContainerID(value) else { return nil }
                container = value
            default:
                return nil
            }
        }
        return id.map { ($0, container) }
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
