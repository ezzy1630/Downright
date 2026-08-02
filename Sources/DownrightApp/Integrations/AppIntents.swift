import Foundation

#if canImport(AppIntents)
import AppIntents

/// Opens one user-selected Markdown file in the running app.  App Intents are
/// deliberately thin: all file policy and routing lives in the registry.
@available(macOS 14.0, *)
public struct OpenMarkdownIntent: AppIntent {
    public static let title: LocalizedStringResource = "Open Markdown in Downright"
    public static let description = IntentDescription("Open a Markdown document in Downright.")
    public static let openAppWhenRun = true

    @Parameter(title: "File path")
    public var path: String

    public init() {}

    public init(path: String) {
        self.path = path
    }

    public func perform() async throws -> some IntentResult {
        guard let url = NativeIntegrationPolicy.normalizedPath(path) else {
            throw OpenMarkdownIntentError.unsupportedFile
        }
        let opened = await MainActor.run { IntegrationRegistry.shared.open(url) }
        guard opened else { throw OpenMarkdownIntentError.unavailable }
        return .result()
    }
}

@available(macOS 14.0, *)
public enum OpenMarkdownIntentError: LocalizedError {
    case unsupportedFile
    case unavailable

    public var errorDescription: String? {
        switch self {
        case .unsupportedFile: "Choose a Markdown file."
        case .unavailable: "Downright could not open that file."
        }
    }
}

@available(macOS 14.0, *)
public struct DownrightShortcuts: AppShortcutsProvider {
    public static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenMarkdownIntent(),
            phrases: ["Open a file in \(.applicationName)"],
            shortTitle: "Open Markdown",
            systemImageName: "doc.text"
        )
    }
}
#endif
