import UniformTypeIdentifiers

/// The UTIs from §10, in one place so the open panel, the drag destination, and
/// the Quick Look extension can never disagree about what this app opens.
enum DocumentTypes {
    static let fileExtensions = ["md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd"]

    static var contentTypes: [UTType] {
        var types: [UTType] = []
        if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
        for ext in fileExtensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        types.append(.plainText)
        return types
    }

    static func isMarkdown(_ pathExtension: String) -> Bool {
        fileExtensions.contains(pathExtension.lowercased())
    }

    /// Extensions LaunchServices *executes* when asked to "open" them, rather
    /// than presenting a document: application bundles and Terminal-run
    /// scripts. A path link or token resolving to one of these must never
    /// hand the target to `NSWorkspace.open` — the documented contract is
    /// "open in your editor", not "run whatever this document points at".
    private static let executableExtensions: Set<String> = [
        "app", "bundle", "appex", "xpc", "plugin", "kext",
        "prefpane", "qlgenerator", "workflow", "action",
        "command", "term", "terminal", "tool",
    ]

    /// Whether opening `url` through LaunchServices would run code instead of
    /// showing a document. Directories are judged by their bundle extension;
    /// plain files by a known executing extension or an executable bit with
    /// no document extension at all (an extension-less compiled tool or
    /// `chmod +x` script).
    static func executesWhenOpened(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return false
        }
        let pathExtension = url.pathExtension.lowercased()
        if isDirectory.boolValue {
            return executableExtensions.contains(pathExtension)
        }
        if executableExtensions.contains(pathExtension) {
            return true
        }
        // An executable-bit file with no extension at all is a raw binary or
        // a chmod'ed script; either way "open" means run.
        return pathExtension.isEmpty && FileManager.default.isExecutableFile(atPath: url.path)
    }
}
