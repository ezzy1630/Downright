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

/// A drag hovering over — or dropped on — the document surface.
///
/// The pasteboard is handed over undecoded on purpose.  Deciding what a
/// dropped file *means* is a question about a document on disk and a folder
/// beside it: whether the file is already inside the document's own directory,
/// whether it has to be copied in, what a portable destination for it looks
/// like.  This package has neither a document nor a filesystem, so it resolves
/// the one thing it does own — where in the *source* the pointer is — and
/// leaves everything else to the app (§10 keeps the Quick Look extension
/// buildable against exactly that boundary).
public struct DocumentDrop {
    public let pasteboard: NSPasteboard
    /// Source UTF-16 offset under the pointer, already converted out of
    /// TextKit's hybrid space by `DisplayMap`.
    ///
    /// This is the value the whole feature turns on, and it is dangerous
    /// because it is *usually* equal to the raw TextKit index: the layout map
    /// pads hidden marker runs out with zero-width joiners on purpose, so hit
    /// testing stays aligned on an ordinary page.  Where a substitution really
    /// does change length in the paragraph under the pointer — a footnote
    /// reference is four source characters drawn as one superscript — the two
    /// part company, and an insertion made from the wrong one lands mid-word.
    public let sourceOffset: Int

    public init(pasteboard: NSPasteboard, sourceOffset: Int) {
        self.pasteboard = pasteboard
        self.sourceOffset = sourceOffset
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
    func markdownTextView(_ view: MarkdownTextView, didActivateFrontMatterAt range: NSRange)
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
    /// Every scroll event, offered to the host before the scroll view sees
    /// it.  The document surface has no horizontal axis of its own, so a
    /// sideways gesture over it is the host's to claim — today the
    /// Document/Source swipe.  Return `true` to consume the event; a host that
    /// is still deciding must return `false` so ordinary scrolling never waits
    /// on it.
    func markdownTextView(_ view: MarkdownTextView, shouldClaimScrollGesture event: NSEvent) -> Bool
    /// Asked once when a drag arrives over the surface, and again nowhere
    /// else: the answer cannot change while one drag is in flight, and this
    /// question reaches the filesystem.  Returning `true` makes the view take
    /// the drag over from `NSTextView` — it stops offering to insert the
    /// pasteboard's text and starts drawing a drop caret instead.
    func markdownTextView(_ view: MarkdownTextView, canAcceptDrop drop: DocumentDrop) -> Bool
    /// The drag was released.  The app writes whatever files it needs to and
    /// makes exactly one undoable source mutation at `drop.sourceOffset`.
    /// Returning `false` reports the drop as failed, which is what AppKit
    /// needs in order to animate the item back to where it came from.
    func markdownTextView(_ view: MarkdownTextView, didAcceptDrop drop: DocumentDrop) -> Bool
    /// A force click, or the Quick Look command, landed on something.
    ///
    /// Return `true` only if the app actually opened a preview.  `false` means
    /// "not previewable", and the view then falls back to whatever AppKit
    /// would have done — for a force click that is the standard Look Up
    /// popover, which must keep working on an ordinary word.
    func markdownTextView(_ view: MarkdownTextView, wantsQuickLookFor target: ContextTarget) -> Bool
}

/// Defaults so a host that only cares about links does not have to implement
/// the whole surface.
public extension MarkdownTextViewDelegate {
    func markdownTextView(_ view: MarkdownTextView, didActivateLink destination: String, at range: NSRange, modifiers: NSEvent.ModifierFlags) {}
    func markdownTextView(_ view: MarkdownTextView, didActivateImage source: String, at range: NSRange) {}
    func markdownTextView(_ view: MarkdownTextView, didActivateFrontMatterAt range: NSRange) {}
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
    func markdownTextView(_ view: MarkdownTextView, shouldClaimScrollGesture event: NSEvent) -> Bool { false }
    func markdownTextView(_ view: MarkdownTextView, canAcceptDrop drop: DocumentDrop) -> Bool { false }
    func markdownTextView(_ view: MarkdownTextView, didAcceptDrop drop: DocumentDrop) -> Bool { false }
    func markdownTextView(_ view: MarkdownTextView, wantsQuickLookFor target: ContextTarget) -> Bool { false }
}
