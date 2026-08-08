import AppKit
import MarkdownCore

/// Where a scroll target lands in the viewport.
public enum ScrollPosition: Sendable {
    case top, center
    /// Scroll only if the target is currently off screen.
    case visible
}

/// What the pointer is over, for §7.1's context-menu table.
public struct ContextTarget {
    public enum Kind {
        /// Index into `ParsedDocument.headings`.
        case heading(Int)
        case codeBlock(NSRange)
        case pathToken(PathToken)
        case image(String)
        case link(String)
        case table(NSRange)
        case selection
        case plain
    }

    public var kind: Kind
    public var sourceRange: NSRange
    /// Source offset under the pointer when the menu was opened.  Actions
    /// such as table edits must use this hit, not the current caret.
    public var hitOffset: Int?

    public init(kind: Kind, sourceRange: NSRange, hitOffset: Int? = nil) {
        self.kind = kind
        self.sourceRange = sourceRange
        self.hitOffset = hitOffset
    }
}

/// Everything the text surface hands back to the app.
///
/// The render package owns no windows, no files, and no editor integrations —
/// it reports what happened in source coordinates and the app decides.  That
/// separation is what lets the same package drive the Quick Look extension
/// (§10) without dragging the app's world in with it.
@MainActor
public protocol MarkdownTextViewDelegate: AnyObject {
    func markdownTextView(_ view: MarkdownTextView, didActivateLink destination: String, at range: NSRange, modifiers: NSEvent.ModifierFlags)
    func markdownTextView(_ view: MarkdownTextView, didActivateImage source: String, at range: NSRange)
    func markdownTextView(_ view: MarkdownTextView, didActivatePathToken token: PathToken, at range: NSRange)
    func markdownTextView(_ view: MarkdownTextView, didToggleCheckboxAtMarkOffset offset: Int)
    func markdownTextView(_ view: MarkdownTextView, didActivateHeadingAnchor headingIndex: Int, modifiers: NSEvent.ModifierFlags)
    func markdownTextView(_ view: MarkdownTextView, didRequestHeadingLevel level: Int?, headingIndex: Int)
    func markdownTextView(_ view: MarkdownTextView, wantsContextMenuFor target: ContextTarget) -> NSMenu?
    /// Return false to draw a path token as missing (§8.4).
    func markdownTextView(_ view: MarkdownTextView, pathExistsFor token: PathToken) -> Bool
    func markdownTextViewDidChangeSelection(_ view: MarkdownTextView)
    func markdownTextViewDidScroll(_ view: MarkdownTextView)
    func markdownTextView(_ view: MarkdownTextView, didChangeSourceFocus focus: SourceFocus)
    /// Text was edited in Live mode.  The app owns the document and reparses.
    func markdownTextView(_ view: MarkdownTextView, didEdit range: NSRange, delta: Int)
    /// The view moved the reader within the same document on its own — today
    /// only a footnote jump.  The render package cannot reach jump history, so
    /// it reports the hop and the app decides whether Back should undo it.
    func markdownTextView(_ view: MarkdownTextView, didNavigateTo destination: Int)
    func markdownTextView(_ view: MarkdownTextView, didRequestTextSizeSteps steps: Int)
    func markdownTextViewDidRequestSmartTextZoom(_ view: MarkdownTextView)
}

/// Defaults so a host that only cares about links does not have to implement
/// the whole surface.
public extension MarkdownTextViewDelegate {
    func markdownTextView(_ view: MarkdownTextView, didActivateLink destination: String, at range: NSRange, modifiers: NSEvent.ModifierFlags) {}
    func markdownTextView(_ view: MarkdownTextView, didActivateImage source: String, at range: NSRange) {}
    func markdownTextView(_ view: MarkdownTextView, didActivatePathToken token: PathToken, at range: NSRange) {}
    func markdownTextView(_ view: MarkdownTextView, didToggleCheckboxAtMarkOffset offset: Int) {}
    func markdownTextView(_ view: MarkdownTextView, didActivateHeadingAnchor headingIndex: Int, modifiers: NSEvent.ModifierFlags) {}
    func markdownTextView(_ view: MarkdownTextView, didRequestHeadingLevel level: Int?, headingIndex: Int) {}
    func markdownTextView(_ view: MarkdownTextView, wantsContextMenuFor target: ContextTarget) -> NSMenu? { nil }
    func markdownTextView(_ view: MarkdownTextView, pathExistsFor token: PathToken) -> Bool { true }
    func markdownTextViewDidChangeSelection(_ view: MarkdownTextView) {}
    func markdownTextViewDidScroll(_ view: MarkdownTextView) {}
    func markdownTextView(_ view: MarkdownTextView, didChangeSourceFocus focus: SourceFocus) {}
    func markdownTextView(_ view: MarkdownTextView, didEdit range: NSRange, delta: Int) {}
    func markdownTextView(_ view: MarkdownTextView, didNavigateTo destination: Int) {}
    func markdownTextView(_ view: MarkdownTextView, didRequestTextSizeSteps steps: Int) {}
    func markdownTextViewDidRequestSmartTextZoom(_ view: MarkdownTextView) {}
}
