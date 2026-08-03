import AppKit

/// Marker hiding for the physical-paragraph fallback (§6.1).
///
/// `NSTextContentStorageDelegate.textContentStorage(_:textParagraphWith:)` is
/// the documented substitution hook. Grouped prose is handled by
/// `MarkdownContentStorage`; this delegate keeps marker hiding safe while the
/// custom layout is suspended during edits (§3.1).
///
/// Everything downstream of this — caret placement, hit testing, selection,
/// scroll anchoring, editing — goes through `DisplayMap`, never through raw
/// offsets. See `DisplayMap.swift` for why that is not optional.
final class ParagraphSubstitution: NSObject, NSTextContentStorageDelegate {
    /// Replaced wholesale whenever the caret moves or the mode changes.
    var displayMap: DisplayMap = .identity
    func textContentStorage(
        _ textContentStorage: NSTextContentStorage,
        textParagraphWith range: NSRange
    ) -> NSTextParagraph? {
        guard !displayMap.isIdentity, let storage = textContentStorage.textStorage else { return nil }
        // Safety valve: between a text edit and the map rebuild the two are
        // briefly out of step.  Substituting against a stale paragraph
        // structure is the one way this mechanism can corrupt itself, so when
        // the shapes disagree we fall back to the storage and let the next
        // rebuild fix it.  A frame of unhidden markers beats a broken caret.
        guard displayMap.paragraphs.length == storage.length else { return nil }
        guard displayMap.paragraphs.paragraphRange(containing: range.location) == range else { return nil }
        guard let substituted = displayMap.displayString(forParagraphAt: range, in: storage) else { return nil }
        return NSTextParagraph(attributedString: substituted)
    }
}
