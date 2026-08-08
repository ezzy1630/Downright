import Foundation

/// Resource limits shared by the preview controller and its tests.  Keeping
/// the decision pure prevents a large file from accidentally taking the
/// extension down before AppKit has a chance to show a fallback.
@available(macOS 14.0, *)
public enum QuickLookPolicy {
    public static let memoryCeilingBytes = 60 * 1024 * 1024
    public static let largeFileThresholdBytes = 2 * 1024 * 1024
    public static let prefixBlockCount = 60
    /// Bounded head read for oversized files — enough bytes to render the first
    /// `prefixBlockCount` blocks without ever loading the whole file.
    public static let prefixReadLimitBytes = 8 * 1024 * 1024
    /// Below this width the 72pt document map leaves too little useful measure.
    public static let minimumDensityGutterWidth: CGFloat = 520

    public enum Presentation: Equatable, Sendable {
        case full
        case prefix(blockCount: Int)
    }

    public static func presentation(forByteCount byteCount: Int) -> Presentation {
        byteCount > largeFileThresholdBytes ? .prefix(blockCount: prefixBlockCount) : .full
    }
}
