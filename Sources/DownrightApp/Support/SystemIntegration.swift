import AppKit
import UniformTypeIdentifiers

/// Everything Downright has to tell the rest of macOS about itself: which files
/// it opens, that its Quick Look extensions exist, and where `down` lives.
///
/// All of this used to live only in `Scripts/install.sh`, which runs for people
/// who build from source and for nobody else.  The shipping path — download the
/// DMG, drag to Applications, double-click — ran none of it, so the user who
/// matters most got no previews, no Finder thumbnails, no `down`, and no file
/// association.  The app performs its own installation now; the script stays
/// for the source path and calls the same steps in the same order.
enum SystemIntegration {

    // MARK: - Where the app is running from

    /// Gatekeeper runs an app launched straight from a DMG or from Downloads
    /// out of a randomised, read-only mount.  Nothing below this line can work
    /// from there: LaunchServices records a path that vanishes on eject,
    /// `pluginkit` will not take extensions from it, and a `down` symlink
    /// dangles within the hour.  Every step is gated on the app living
    /// somewhere permanent, and the setup panel leads with moving it.
    static var isTranslocated: Bool {
        Bundle.main.bundleURL.path.contains("/AppTranslocation/")
    }

    /// False for a bare `swift build` binary, whose "bundle" is a build
    /// directory.  Nothing here — moving, registering, symlinking — means
    /// anything for one of those, and offering to move it into Applications
    /// during development would be actively wrong.
    static var isAppBundle: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
    }

    static var isInApplicationsFolder: Bool {
        let path = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// True when the bundle sits somewhere the rest of this file can rely on.
    static var isPermanentlyInstalled: Bool { !isTranslocated && isInApplicationsFolder }

    /// Where a move would put the app, or nil when neither Applications folder
    /// can be written without a password.
    static var applicationsDestination: URL? {
        let manager = FileManager.default
        let home = manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications")
        for base in [URL(fileURLWithPath: "/Applications"), home] {
            guard manager.isWritableFile(atPath: base.path) else { continue }
            return base.appendingPathComponent("Downright.app")
        }
        return nil
    }

    /// Copies the running bundle into Applications, launches the copy, and
    /// terminates this process.
    ///
    /// Copy-then-relaunch rather than move-in-place: the executable, Sparkle,
    /// and both extensions are all mapped out of the current bundle, and
    /// pulling that out from under a live process is how an app dies halfway
    /// through installing itself.  The translocated original is on a read-only
    /// mount and cleans itself up when the image is ejected.
    /// `onRelaunchFailure` runs when the copy succeeded but the new instance
    /// would not start.  Quitting anyway in that case leaves the user staring
    /// at an empty screen with no idea whether anything worked.
    static func moveToApplications(onRelaunchFailure: @escaping (Error) -> Void) throws {
        guard let destination = applicationsDestination else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let manager = FileManager.default
        let source = Bundle.main.bundleURL

        if manager.fileExists(atPath: destination.path) {
            // An older build is being replaced on purpose.  The Trash keeps it
            // recoverable; `removeItem` would not, and this is running before
            // the user has any reason to trust us with a delete.
            try manager.trashItem(at: destination, resultingItemURL: nil)
        }
        try manager.copyItem(at: source, to: destination)

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: destination, configuration: configuration) { _, error in
            DispatchQueue.main.async {
                if let error {
                    onRelaunchFailure(error)
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - Default application

    /// The types Downright claims when the user says yes.
    ///
    /// Deliberately the plain-markdown family only.  `.mdx`, `.qmd`, and `.rmd`
    /// belong to toolchains people have already chosen — VS Code, Quarto,
    /// RStudio — and silently taking those is the behaviour that makes an app
    /// feel like something you have to defend against.  The bundle still
    /// declares them, so Downright appears in "Open With"; it just does not
    /// install itself as the default.  `.txt` is not claimed here or anywhere.
    static let claimedExtensions = ["md", "markdown", "mdown", "mkd"]

    static var claimedTypes: [UTType] {
        var types: [UTType] = []
        if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
        for ext in claimedExtensions {
            guard let type = UTType(filenameExtension: ext), !types.contains(type) else { continue }
            types.append(type)
        }
        return types
    }

    static var isDefaultMarkdownHandler: Bool {
        guard let markdown = claimedTypes.first,
              let handler = NSWorkspace.shared.urlForApplication(toOpen: markdown)
        else { return false }
        return handler.resolvingSymlinksInPath().standardizedFileURL
            == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Routes every claimed type here.  macOS puts its own confirmation in
    /// front of this on some releases; that is the system's call to make and
    /// the reason the panel's copy promises nothing about how it will look.
    /// Returns the first failure, if any.
    static func makeDefaultMarkdownHandler() async -> Error? {
        let bundle = Bundle.main.bundleURL
        var firstFailure: Error?
        for type in claimedTypes {
            let failure: Error? = await withCheckedContinuation { continuation in
                NSWorkspace.shared.setDefaultApplication(at: bundle, toOpen: type) { error in
                    continuation.resume(returning: error)
                }
            }
            if firstFailure == nil { firstFailure = failure }
        }
        return firstFailure
    }

    // MARK: - Command line tool

    static let commandLineNames = ["down", "md"]

    static var commandLineExecutable: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/down")
    }

    static var commandLineToolIsBundled: Bool {
        FileManager.default.isExecutableFile(atPath: commandLineExecutable.path)
    }

    struct CommandLineTarget {
        let directory: URL
        /// False when the directory works but no login shell will look in it
        /// without the user editing their PATH — which the panel then says out
        /// loud rather than reporting a success the terminal will contradict.
        let isOnPath: Bool
    }

    struct CommandLineResult {
        let directory: URL
        let linked: [String]
        /// Names left alone because something that is not ours already owns
        /// them.  Clobbering a stranger's `md` is not ours to do.
        let skipped: [String]
        let isOnPath: Bool
    }

    /// Directories `down` might already be installed into, most conventional
    /// first.  Also the search order for a new install.
    private static var commandLineSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/usr/local/bin"),
            URL(fileURLWithPath: "/opt/homebrew/bin"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin"),
        ]
    }

    /// What `path_helper` builds a login shell's PATH from.  Reading this
    /// rather than `ProcessInfo.environment["PATH"]` is the whole point: a GUI
    /// app launched by Finder inherits launchd's minimal PATH, so the
    /// environment this process can see says nothing about what the user's
    /// terminal will find.
    private static func loginPathDirectories() -> Set<String> {
        var result: Set<String> = []
        func absorb(_ url: URL) {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
            for line in text.split(separator: "\n") {
                let entry = line.trimmingCharacters(in: .whitespaces)
                if !entry.isEmpty { result.insert(entry) }
            }
        }
        absorb(URL(fileURLWithPath: "/etc/paths"))
        let fragments = try? FileManager.default.contentsOfDirectory(
            at: URL(fileURLWithPath: "/etc/paths.d"), includingPropertiesForKeys: nil
        )
        fragments?.forEach(absorb)
        return result
    }

    /// Somewhere `down` can go without an administrator prompt.
    ///
    /// A welcome panel that opens a password box is a welcome panel people
    /// cancel, so this looks for a directory that is already writable instead
    /// of escalating.  `/usr/local/bin` is the conventional home and is
    /// group-writable on a Mac whose owner is an admin; the Homebrew prefix and
    /// `~/.local/bin` cover the rest.
    static func commandLineDestination() -> CommandLineTarget? {
        let manager = FileManager.default
        let onPath = loginPathDirectories()

        for directory in commandLineSearchDirectories {
            var isDirectory: ObjCBool = false
            guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue,
                  manager.isWritableFile(atPath: directory.path)
            else { continue }
            return CommandLineTarget(directory: directory, isOnPath: onPath.contains(directory.path))
        }

        // Nothing that exists is writable.  `~/.local/bin` is the one place we
        // may create on the user's behalf.
        let fallback = manager.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin")
        guard (try? manager.createDirectory(at: fallback, withIntermediateDirectories: true)) != nil
        else { return nil }
        return CommandLineTarget(directory: fallback, isOnPath: onPath.contains(fallback.path))
    }

    /// True when a `down` symlink somewhere on the search path already points
    /// into *this* bundle.  A link into a different Downright.app counts as not
    /// installed, so moving the app repairs the link rather than reporting a
    /// success that no longer resolves.
    static var isCommandLineToolInstalled: Bool {
        let expected = commandLineExecutable.resolvingSymlinksInPath().path
        for directory in commandLineSearchDirectories {
            let link = directory.appendingPathComponent("down")
            guard let destination = try? FileManager.default
                .destinationOfSymbolicLink(atPath: link.path) else { continue }
            let resolved = URL(fileURLWithPath: destination).resolvingSymlinksInPath().path
            if resolved == expected { return true }
        }
        return false
    }

    static func installCommandLineTool() throws -> CommandLineResult {
        guard let target = commandLineDestination() else {
            throw CocoaError(.fileWriteNoPermission)
        }
        let manager = FileManager.default
        let executable = commandLineExecutable
        var linked: [String] = []
        var skipped: [String] = []

        for name in commandLineNames {
            let link = target.directory.appendingPathComponent(name)
            // `fileExists` follows symlinks, so it answers "no" for a link left
            // dangling by a deleted build — exactly the case that has to be
            // replaced.  Ask about the link itself.
            let existingLink = try? manager.destinationOfSymbolicLink(atPath: link.path)
            let occupied = existingLink != nil || manager.fileExists(atPath: link.path)

            if occupied {
                guard let existingLink, existingLink.contains("Downright.app/") else {
                    skipped.append(name)
                    continue
                }
                try manager.removeItem(at: link)
            }
            try manager.createSymbolicLink(at: link, withDestinationURL: executable)
            linked.append(name)
        }
        return CommandLineResult(
            directory: target.directory, linked: linked,
            skipped: skipped, isOnPath: target.isOnPath
        )
    }

    // MARK: - Quick Look

    static let previewExtensionIdentifier = "com.ezzy.downright.quicklook"
    static let thumbnailExtensionIdentifier = "com.ezzy.downright.thumbnail"

    private static var plugInsDirectory: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns")
    }

    /// False for a SwiftPM dev build, which cannot produce an `.appex` at all.
    /// The panel hides the Quick Look line entirely rather than reporting a
    /// failure the user has no way to act on.
    static var quickLookExtensionsAreBundled: Bool {
        FileManager.default.fileExists(
            atPath: plugInsDirectory.appendingPathComponent("DownrightQL.appex").path
        )
    }

    /// Whether `pluginkit` will let the preview extension run.
    ///
    /// The flag column reads backwards from the obvious: `+` means the user
    /// went and switched it on explicitly, `-` means explicitly off, and
    /// **blank — which is what a healthy extension shows — means available**.
    /// Testing for `+` reports every working install as broken.
    ///
    /// An unregistered identifier is not an error either: `pluginkit` prints
    /// "(no matches)" and exits 0, so the answer is in the output and never in
    /// the status code.
    static func isQuickLookPreviewEnabled() -> Bool {
        isEnabled(
            inPluginKitListing: run("/usr/bin/pluginkit", ["-m", "-v", "-i", previewExtensionIdentifier]),
            identifier: previewExtensionIdentifier
        )
    }

    /// Split out from the subprocess so the flag semantics above can be pinned
    /// by a test instead of rediscovered the next time this is touched.
    static func isEnabled(inPluginKitListing listing: String, identifier: String) -> Bool {
        guard let line = listing.split(separator: "\n")
            .first(where: { $0.contains(identifier) })
        else { return false }
        return !line.hasPrefix("-")
    }

    /// Registers the bundle with LaunchServices, offers both extensions to
    /// `pluginkit`, and reloads Quick Look.
    ///
    /// `resetThumbnailCache` is the expensive half: it discards every cached
    /// thumbnail on the system, not only ours.  It is what makes `.md` files
    /// the user already has pick up real icons instead of keeping the generic
    /// ones Finder drew for them months ago, so it runs once at setup and never
    /// on an ordinary launch.
    static func registerWithSystem(
        resetThumbnailCache: Bool, completion: @escaping (Bool) -> Void
    ) {
        let bundlePath = Bundle.main.bundleURL.path
        let extensions = [
            (path: plugInsDirectory.appendingPathComponent("DownrightQL.appex").path,
             identifier: previewExtensionIdentifier),
            (path: plugInsDirectory.appendingPathComponent("DownrightThumb.appex").path,
             identifier: thumbnailExtensionIdentifier),
        ]

        // All four tools block, and `qlmanage -r cache` takes seconds on a busy
        // machine.  None of it may run on the main thread during launch.
        DispatchQueue.global(qos: .userInitiated).async {
            run(lsregisterPath, ["-f", bundlePath])
            for item in extensions where FileManager.default.fileExists(atPath: item.path) {
                run("/usr/bin/pluginkit", ["-a", item.path])
                run("/usr/bin/pluginkit", ["-e", "use", "-i", item.identifier])
            }
            run("/usr/bin/qlmanage", ["-r"])
            if resetThumbnailCache { run("/usr/bin/qlmanage", ["-r", "cache"]) }

            let enabled = isQuickLookPreviewEnabled()
            DispatchQueue.main.async { completion(enabled) }
        }
    }

    /// The pane the user lands on when the automatic path did not take.
    static func openQuickLookSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.ExtensionsPreferences?extensionPointIdentifier=com.apple.quicklook.preview"
        )
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Running tools

    private static let lsregisterPath =
        "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Best-effort: every caller here treats a missing tool or a non-zero exit
    /// as "that step did not happen", and reports the outcome by re-checking
    /// the world rather than by trusting an exit code.
    @discardableResult
    private static func run(_ launchPath: String, _ arguments: [String]) -> String {
        guard FileManager.default.isExecutableFile(atPath: launchPath) else { return "" }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        // Read before waiting: a tool that fills the pipe buffer deadlocks
        // against a parent sitting in `waitUntilExit`.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
