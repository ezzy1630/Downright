import AppKit

extension NSView {
    /// Swaps `area` for a fresh one covering the current bounds.  `bounds` moves
    /// on every resize and a stale area keeps reporting the old rect, so every
    /// hovering view rebuilds one the same way — once, here.
    ///
    /// Kept internal and duplicated in the app target on purpose: MarkdownRender
    /// ships on its own, and a public `NSView` extension would be API it has to
    /// keep forever for a four-line convenience.
    func refreshTrackingArea(
        _ area: inout NSTrackingArea?,
        options: NSTrackingArea.Options
    ) {
        if let area { removeTrackingArea(area) }
        let replacement = NSTrackingArea(rect: bounds, options: options, owner: self)
        addTrackingArea(replacement)
        area = replacement
    }
}
