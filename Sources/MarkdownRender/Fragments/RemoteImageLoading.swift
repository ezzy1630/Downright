// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import AppKit

/// Supplies web images to image fragments.
///
/// The render package never touches the network itself.  A host that wants
/// remote images installs a loader after an explicit user choice; Quick Look
/// never does. Only then do `https:` image
/// destinations stop rendering as blocked or inert.
public protocol RemoteImageLoading: AnyObject {
    /// A decoded image already in memory, or `nil`.  Called during layout and
    /// drawing, so it must not block.
    func cachedImage(for url: URL, maxPixelDimension: Int) -> NSImage?
    /// Whether a load of this URL has already failed.  Layout asks before
    /// starting a load, so a broken image is not refetched on every pass.
    func hasFailed(_ url: URL) -> Bool
    /// Starts a load, or joins one already in flight.  `completion` runs on
    /// the main queue with the image, or `nil` once the load has failed.
    func loadImage(for url: URL, maxPixelDimension: Int, completion: @escaping @MainActor (NSImage?) -> Void)
}
