import Foundation

/// Everything the UI needs to know about one available update.  Deliberately a
/// plain value type: Sparkle's `SUAppcastItem` is translated once at the
/// driver boundary so the state machine, the pill, the panel, and the test
/// fakes all speak the same vocabulary.
struct UpdateMetadata: Equatable {
    /// `CFBundleVersion` of the target build — Sparkle's ordering key.
    var versionString: String
    /// Human-facing `CFBundleShortVersionString`.
    var displayVersionString: String
    var title: String?
    /// Inline release notes (Markdown, embedded in the appcast `<description>`).
    var itemDescription: String?
    /// Linked release notes URL (HTML) when the appcast uses `<releaseNotesLink>`.
    var releaseNotesURL: URL?
    /// Where "Learn More" goes for informational-only updates.
    var infoURL: URL?
    /// Byte size of the download, when the appcast provides it.
    var contentLength: UInt64
    var isInformationOnly: Bool
    var isMajorUpgrade: Bool
    var isCritical: Bool
    var minimumSystemVersion: String?
}

/// A failed update operation, reduced to what the panel actually needs:
/// a plain-language summary, an expandable technical detail, and whether
/// retrying is even meaningful.
struct UpdateFailure: Equatable {
    var message: String
    var technicalDetail: String?
    var code: Int
    var retryable: Bool

    static let generic = UpdateFailure(
        message: "Downright couldn't update.",
        technicalDetail: nil,
        code: -1,
        retryable: true
    )

    init(error: Error) {
        let nsError = error as NSError
        message = nsError.localizedDescription.isEmpty
            ? "Downright couldn't update."
            : nsError.localizedDescription
        technicalDetail = nsError.localizedRecoverySuggestion
            ?? nsError.localizedFailureReason
        code = nsError.code
        // The caller decides whether a retry is meaningful: "no update found"
        // and "authorization cancelled" are terminal paths that never reach
        // the failed state in the first place.
        retryable = true
    }

    init(message: String, technicalDetail: String?, code: Int, retryable: Bool) {
        self.message = message
        self.technicalDetail = technicalDetail
        self.code = code
        self.retryable = retryable
    }
}
