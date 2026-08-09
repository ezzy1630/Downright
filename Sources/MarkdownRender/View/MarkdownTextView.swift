import AppKit
import MarkdownCore

/// Accessibility geometry is demand-driven. Resolving every rendered object's
/// frame during each parse commit forces TextKit to lay out the entire document
/// on the typing path, even though VoiceOver may never query those objects.
private final class FragmentAccessibilityElement: NSAccessibilityElement {
    weak var textView: MarkdownTextView?
    let sourceOffset: Int

    init(textView: MarkdownTextView, sourceOffset: Int) {
        self.textView = textView
        self.sourceOffset = sourceOffset
        super.init()
    }

    override func accessibilityFrameInParentSpace() -> NSRect {
        textView?.rect(forOffset: sourceOffset) ?? .zero
    }
}

/// A height update request. Structural updates keep the document height
/// correct, but semantic parse results wait for an idle gap so typing never
/// forces a full TextKit layout on the main actor.
enum ContentResizeRequest: Equatable, Hashable {
    case semantic
    case lineCount
    case scrollRepair
    case viewport
    case immediate
}

enum ContentResizePolicy {
    static let semanticIdleDelay: TimeInterval = 0.080
    static let lineCountIdleDelay: TimeInterval = 0.040

    static func merge(_ current: ContentResizeRequest?, with next: ContentResizeRequest)
        -> ContentResizeRequest {
        guard let current else { return next }
        let rank: [ContentResizeRequest: Int] = [
            .semantic: 0, .scrollRepair: 1, .lineCount: 2, .viewport: 3, .immediate: 4,
        ]
        return rank[next, default: 0] >= rank[current, default: 0] ? next : current
    }

    static func idleDelay(for request: ContentResizeRequest) -> TimeInterval {
        switch request {
        case .semantic: return semanticIdleDelay
        case .lineCount, .scrollRepair: return lineCountIdleDelay
        case .viewport, .immediate: return 0
        }
    }
}

/// One text surface with an editable document view and explicit source view.
///
/// Not a viewer with an edit button and not an editor with a preview pane: a
/// single `NSTextView` on TextKit 2 over a single `NSTextStorage`, with three
/// decoration policies.  Switching modes preserves scroll and selection
/// because nothing is rebuilt — the same layout manager keeps laying out the
/// same bytes with a different set of substitutions.
///
/// Three rules run through the whole file:
///
///  * **Source offsets are the only truth.**  Everything public speaks them.
///    TextKit hands back hybrid offsets (see `DisplayMap`) and every one of
///    them is converted at the boundary, including in the editing path — an
///    unconverted offset used for an insertion is how a WYSIWYG editor
///    corrupts a file, and §3.1 says that must be structurally impossible.
///
///  * **The AppKit layer is owned directly** (§14).  No SwiftUI in the text
///    surface, and no `addRenderingAttribute` for anything dynamic.
///
///  * **Read mode has no insertion caret but every pointer interaction stays
///    live** (§3.2, §5): clicking, selecting, dragging, folding, following
///    links, ticking checkboxes.
public final class MarkdownTextView: NSTextView {

    // MARK: - Public surface

    public weak var markdownDelegate: MarkdownTextViewDelegate?
    private var textMagnificationAccumulator: CGFloat = 0

    /// Host hook for the command/keybinding layer.  Invoked before the view's
    /// own key handling on every `keyDown`; return `true` to claim the event
    /// (a binding the host resolved and ran).  The host decides the scope from
    /// the view's current editability, so bare read-mode letters only fire when
    /// there is no caret to swallow them (§7.2).
    public var keyEventHandler: ((NSEvent) -> Bool)?

    public private(set) var parsedDocument: ParsedDocument = .empty

    /// Instant, and preserves scroll position and selection (§3.2).
    public var mode: RenderMode = .live {
        didSet {
            guard mode != oldValue else { return }
            let anchor = captureViewportAnchor()
            let selection = sourceSelectedRanges
            if mode == .source {
                sourceFocus = .document
            } else if sourceFocus == .document {
                sourceFocus = .none
            }
            engine.policy = effectivePolicy
            engine.codeCollapseLineCount = configuration.codeCollapseThreshold
            fragmentContext.mode = mode
            fragmentContext.sourceFocusRange = sourceFocus.range
            applyModeChrome()
            // Leave the responsive measure alone. `applyMeasure()` would snap
            // back to the theme width and the container would re-centre on the
            // next layout, which makes the left rail jump on Document↔Source.
            rebuildEverything()
            requestContentResize(.viewport, anchor: anchor)
            setSourceSelectedRanges(selection)
            restoreViewport(to: anchor)
            markdownDelegate?.markdownTextView(self, didChangeSourceFocus: sourceFocus)
        }
    }

    public var configuration = MarkdownRenderConfiguration() {
        didSet {
            guard configuration != oldValue else { return }
            let anchor = captureViewportAnchor()
            let selection = sourceSelectedRanges
            engine.policy = effectivePolicy
            engine.codeCollapseLineCount = configuration.codeCollapseThreshold
            applyTypographicSubstitution()
            let invisiblesOnly = configuration.showInvisibles != oldValue.showInvisibles
                && configuration.revealPolicy == oldValue.revealPolicy
                && configuration.typographicSubstitution == oldValue.typographicSubstitution
                && configuration.typewriterScrolling == oldValue.typewriterScrolling
                && configuration.reflowHardWrappedParagraphs == oldValue.reflowHardWrappedParagraphs
                && configuration.codeCollapseThreshold == oldValue.codeCollapseThreshold
                && configuration.largeFileThresholdMegabytes == oldValue.largeFileThresholdMegabytes
            if invisiblesOnly {
                applyInvisibles()
            } else {
                rebuildEverything()
                applyInvisibles()
            }
            requestContentResize(.viewport, anchor: anchor)
            setSourceSelectedRanges(selection)
            restoreViewport(to: anchor)
        }
    }

    /// Transient raw-Markdown visibility.  Never persisted by the render
    /// layer; hosts decide how its toolbar/menu affordance is presented.
    public internal(set) var sourceFocus: SourceFocus = .none

    public var styleSheet: StyleSheet {
        didSet {
            let anchor = captureViewportAnchor()
            inlineCodeBandCache.removeAll(keepingCapacity: true)
            invisibleGlyphCache.removeAll(keepingCapacity: true)
            engine.styleSheet = styleSheet
            fragmentContext.styleSheet = styleSheet
            fragmentContext.invalidateDerivedLayout()
            applyMeasure()
            applyModeChrome()
            // Font / measure changes need a full geometry rebuild. Colour-only
            // theme swaps only need attributes and fragment restyles.
            let geometryChanged =
                oldValue.lineHeight != styleSheet.lineHeight
                || oldValue.measureWidth != styleSheet.measureWidth
                || oldValue.baselineGrid != styleSheet.baselineGrid
                || oldValue.mathPointSize != styleSheet.mathPointSize
            if geometryChanged {
                rebuildEverything()
            } else {
                restyleAttributesPreservingGeometry()
            }
            requestContentResize(.viewport, anchor: anchor)
        }
    }

    /// §5.2.  A level change is an elision change, nothing more.
    public var zoomLevel: ZoomLevel = .everything {
        didSet {
            guard zoomLevel != oldValue else { return }
            expandedElisionRanges.removeAll(keepingCapacity: true)
            let previousHeight = frame.height
            refreshElision()
            // The display map has changed and TextKit 2 only lays out lazily.
            // Resolve the new document height *now* so the frame is not left
            // stale until the first scroll, and so the transition can spring
            // from the old extent to the new one (§5.2).
            animateStructuralZoomHeight(from: previousHeight)
        }
    }

    public var foldedHeadingSlugs: Set<String> = [] {
        didSet {
            guard foldedHeadingSlugs != oldValue else { return }
            refreshElision()
        }
    }

    /// Setting hits unfolds any heading whose section contains one.
    ///
    /// This is the single deliberate exception to `ElisionPlan`'s "render-time
    /// override, never a state change" rule: a fold is a gesture the user made
    /// and expects to see undone when a match lands inside it (§7.2, §9.4).
    /// Zoom is *not* touched, because zoom is a view of the document rather
    /// than a per-section decision, and `ElisionPlan` forces zoom-elided ranges
    /// visible without disturbing the level.
    public var searchHits: [NSRange] = [] {
        didSet {
            let previous = overlayRanges
            overlayRanges = searchHits
            unfoldHeadingsContaining(searchHits)
            refreshElision()
            reapplyOverlays(invalidating: previous + searchHits, invalidateFragments: false)
        }
    }

    public var currentSearchHit: NSRange? {
        didSet {
            guard currentSearchHit != oldValue else { return }
            reapplyOverlays(invalidating: [oldValue, currentSearchHit].compactMap { $0 })
        }
    }

    /// Source range for the word that Voice speech is reading now.
    public var speechHighlight: NSRange? {
        didSet {
            guard speechHighlight != oldValue else { return }
            reapplyOverlays(invalidating: [oldValue, speechHighlight].compactMap { $0 })
        }
    }

    /// One external change, as the document surface needs to draw it (§8.1).
    ///
    /// `visited` is presentation, not filtering: a change the reader has already
    /// looked at dims but stays on the page, because a review queue that erases
    /// itself as you walk it is not a queue.  `deletedText` is what makes a
    /// deletion drawable at all — the removed bytes are by definition not in the
    /// buffer, so the mark has to carry them.
    public struct ChangeMark {
        public var kind: ChangeKind
        public var range: NSRange
        public var words: [NSRange]
        public var visited: Bool
        public var deletedText: String

        public init(
            kind: ChangeKind,
            range: NSRange,
            words: [NSRange],
            visited: Bool = false,
            deletedText: String = ""
        ) {
            self.kind = kind
            self.range = range
            self.words = words
            self.visited = visited
            self.deletedText = deletedText
        }
    }

    /// Change marks from §8.1.
    public var changeMarks: [ChangeMark] = [] {
        didSet {
            let invalidated = oldValue.map(\.range) + changeMarks.map(\.range)
            reapplyOverlays(invalidating: invalidated)
            gutterRail?.needsDisplay = true
        }
    }

    /// Directory relative image and diagram paths resolve against (§3.4).
    public var documentURL: URL? {
        didSet {
            fragmentContext.documentURL = documentURL
            invalidateAllFragments()
        }
    }

    /// Reveal raw Markdown for a logical selection or block without changing
    /// the presentation of surrounding content.  Scope expands to paragraph
    /// boundaries so TextKit never has one paragraph in two coordinate modes.
    public func focusSource(in requestedRange: NSRange) {
        guard mode != .source, parsedDocument.length > 0 else { return }
        let anchor = captureViewportAnchor()
        let lower = max(0, min(requestedRange.location, parsedDocument.length))
        let upper = max(lower, min(requestedRange.upperBound, parsedDocument.length))
        let first = paragraphIndex.paragraphRange(containing: lower)
        let lastOffset = max(lower, upper - 1)
        let last = paragraphIndex.paragraphRange(containing: lastOffset)
        let expanded = first.union(last)
        guard sourceFocus != .scoped(expanded) else { return }
        sourceFocus = .scoped(expanded)
        fragmentContext.sourceFocusRange = expanded
        refreshSourceAccessibility()
        rebuildEverything()
        requestContentResize(.viewport, anchor: anchor)
        setSourceSelectedRanges([requestedRange])
        NSAccessibility.post(element: self, notification: .announcementRequested,
                             userInfo: [.announcement: "Markdown source editor"])
        markdownDelegate?.markdownTextView(self, didChangeSourceFocus: sourceFocus)
    }

    public func focusEntireSource() {
        guard mode != .source else { return }
        mode = .source
    }

    public func clearSourceFocus() {
        switch sourceFocus {
        case .none:
            return
        case .document:
            mode = .live
        case .scoped:
            let anchor = captureViewportAnchor()
            sourceFocus = .none
            fragmentContext.sourceFocusRange = nil
            refreshSourceAccessibility()
            rebuildEverything()
            requestContentResize(.viewport, anchor: anchor)
            markdownDelegate?.markdownTextView(self, didChangeSourceFocus: sourceFocus)
        }
    }

    // MARK: - Internals

    let engine: DecorationEngine
    let fragmentContext: FragmentContext
    private let substitution = ParagraphSubstitution()
    private var fragmentProvider: FragmentProvider!
    private let contentStorage: MarkdownContentStorage
    private let markdownLayoutManager: NSTextLayoutManager

    /// Fully collapsed hidden set for the current document and policy, from
    /// which the caret-aware set is derived by subtraction (§12).
    private var baseHiddenRanges: [NSRange] = []
    /// The fully collapsed map for the document, rebuilt only when the text,
    /// the policy, or the parse changes.  Every caret move is an override on
    /// top of this rather than a rebuild of it (§12).
    private var baseDisplayMap: DisplayMap = .identity
    /// `baseDisplayMap` in layout space, cached beside it.
    ///
    /// Deriving this walks every substitution in the document and builds an
    /// attributed string for each, so it is far too expensive to redo on a
    /// caret move.  It does not have to be: a reveal only ever *drops* entries
    /// from one paragraph, so the layout map for a reveal is the same
    /// subsetting applied to this cache (§12).
    private var baseLayoutMap: DisplayMap = .identity
    var paragraphIndex: ParagraphIndex = .empty
    private var displayMap: DisplayMap = .identity
    private var hardWrapRanges: [NSRange] = []
    private var hardWrapSubstitutions: [DisplaySubstitution] = []
    private var elision: ElisionPlan = .none
    private var expandedElisionRanges: [NSRange] = []

    private var isApplyingSelection = false
    private var isPerformingSourceEdit = false
    /// A local edit should leave the caret in charge of the camera while its
    /// asynchronous parse result catches up.
    var shouldFollowCaretAfterLocalEdit = false
    /// AppKit sends many selection updates while a drag is in flight. Do not
    /// rebuild substitutions or scroll the document until that gesture ends.
    var isTrackingMouseSelection = false
    /// True while AppKit is deciding whether a mouse-down becomes a caret or
    /// a drag selection.  Marker reveal waits for mouse-up, preventing the
    /// first character of a drag from flashing into source and moving.
    var suppressesCaretReveal = false
    /// Paragraph currently carrying the §6.1c anchor shift, so it can be put
    /// back when the caret leaves.
    private var anchoredParagraph: NSRange?
    /// Paragraph the last reveal applied to, so the next one knows exactly
    /// which range's substitutions changed.
    private var revealParagraph: NSRange?
    /// Whether the previous elision plan was the identity, so a document with
    /// no zoom and no folds never pays for an attribute sweep.
    private var elisionWasIdentity = true
    private var overlayRanges: [NSRange] = []
    /// Changes whose every word lives inside an object fragment, so the prose
    /// highlight had nothing to paint and a rule stands in for it.
    private var objectChangeMarks: [ChangeMark] = []
    private var fragmentAccessibilityElements: [NSAccessibilityElement] = []
    private var pathExistence: [PathToken: Bool] = [:]
    private var codeCollapseOverrides: [Int: Bool] = [:]
    /// Inline-code backgrounds are geometry, not text attributes. Cache their
    /// bands between background passes and discard them whenever layout can
    /// move. The draw path only populates entries intersecting the dirty
    /// viewport, so a long document does not measure every code span on every
    /// repaint.
    private var inlineCodeBandCache: [NSRange: [CGRect]] = [:]
    private var invisibleGlyphCache: [Int: NSRect] = [:]
    /// Fingerprint of the layout the cached rectangles were measured against.
    ///
    /// Those caches hold *absolute* rectangles, and TextKit 2 resolves layout
    /// lazily: one measured while the content above it was still an estimate is
    /// wrong the moment that content is really laid out.  Keyed by range alone,
    /// such an entry survived forever — so an inline-code pill stayed painted
    /// where the text used to be, and the pill belonging to the span actually on
    /// screen was never drawn, because the stale entry answered for it.
    ///
    /// The document's usage height is the signal: it moves whenever an estimate
    /// is replaced by real layout, which is precisely when the rectangles below
    /// it shift.
    private struct LayoutFingerprint: Equatable {
        var height: CGFloat
        var width: CGFloat
        /// See `FragmentContext.layoutGeneration`.  Height and width alone
        /// cannot see a reflow that preserves the document's total height, and
        /// that reflow leaves every cached band a line away from its text.
        var generation: Int
    }
    private var bandCacheFingerprint: LayoutFingerprint?
    private var invisiblesApplied = false
    private var hoverTracking: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?
    private var resignKeyObserver: NSObjectProtocol?
    private var pendingResizeRequest: ContentResizeRequest?
    private var resizeWorkItem: DispatchWorkItem?
    var copiedCodeFeedbackWorkItem: DispatchWorkItem?
    /// The one per-view driver for the document surface's motion: the short
    /// checkbox confirm pop (§7.1) and the scroll inertia coast share a
    /// display link so the lifecycle rules are written once — park when the
    /// view leaves its window, park in `deinit` (§11.4).
    private var motionDriver: Motion.SpringDriver?
    var checkboxPulseDisplayLink: CADisplayLink?
    private var resizeGeneration: UInt = 0
    private var pendingResizeAnchor: ViewportAnchor?
    /// One-shot camera lock for semantic controls such as checkboxes. Their
    /// edit changes source bytes but is not a navigation request.
    private var nextDocumentUpdateViewportY: CGFloat?
    private var resizeNeedsRepair = false
    /// Presentation already applied to storage. Keeping this lifecycle explicit
    /// prevents Document-mode parse commits from sweeping `.drSourceFocus`
    /// across the entire document when no source presentation is active.
    private var appliedSourceFocus: SourceFocus = .none
    /// A frame shrink was deferred because the viewport was pinned to the bottom
    /// (shrinking there would clamp the clip view and drop the page).  The
    /// scroll observer clears this and settles the frame once the viewport
    /// moves away from the bottom edge.
    private var pendingShrinkRepair = false
    /// Coalesced scroll handler: during a momentum scroll the bounds change
    /// notification fires 30–60×/s, but the gutter, breadcrumb, and density
    /// rail only need to update once per display refresh. We coalesce via
    /// `DispatchQueue.main.async` so rapid-fire events fold into a single
    /// callback per frame.
    private var scrollCoalesceWorkItem: DispatchWorkItem?
    private var scrollCoalesceGeneration: UInt = 0

    private var effectivePolicy: DecorationPolicy {
        var policy = mode.policy
        policy.revealsAtCaret = configuration.revealPolicy != .never
        policy.revealsAtAllCursors = configuration.revealPolicy == .allCursors
        return policy
    }

    // Test seam for the scheduler. It does not expose the view's layout
    // internals to the app target.
    var pendingResizeRequestForTesting: ContentResizeRequest? { pendingResizeRequest }
    var cachedLayoutElementCountForTesting: Int { contentStorage.cachedElementCountForTesting }
    var lastFragmentInvalidationRangeForTesting: NSRange?
    /// Heading under the pointer, for the gutter's anchor glyph (§7.1).
    var hoveredHeadingIndex: Int?
    /// Link span under the pointer.  Drawn as a transient underline in
    /// `draw(_:)` rather than a storage attribute, because the decoration pass
    /// wipes attributes on every reflow and an underline that vanishes while
    /// the pointer is still sitting on it reads as a bug (§7.1).
    var hoveredLinkRange: NSRange?
    /// Set while an input method is composing.  Substitutions are suspended in
    /// that paragraph so the hybrid and source spaces coincide and AppKit's own
    /// marked-text machinery stays correct.
    var composingParagraph: NSRange?
    /// Bumped by `update(document:dirty:)` so an edit can tell whether the app
    /// already reparsed inside the delegate callback.
    var updateGeneration = 0

    /// The rail that draws block markers (§6.1a).  Owned by the container but
    /// told when to redraw from here, because this is where the geometry is.
    weak var gutterRail: GutterRailView?

    // MARK: - Construction

    public convenience init(frame: NSRect, storage: NSTextStorage) {
        self.init(frame: frame, storage: storage, styleSheet: MarkdownTextView.fallbackStyleSheet())
    }

    public init(frame: NSRect, storage: NSTextStorage, styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.engine = DecorationEngine(styleSheet: styleSheet)
        self.fragmentContext = FragmentContext(styleSheet: styleSheet)

        contentStorage = MarkdownContentStorage()
        markdownLayoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: styleSheet.measureWidth,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        markdownLayoutManager.textContainer = container
        contentStorage.addTextLayoutManager(markdownLayoutManager)
        contentStorage.textStorage = storage
        contentStorage.delegate = substitution

        super.init(frame: frame, textContainer: container)

        fragmentProvider = FragmentProvider(context: fragmentContext)
        markdownLayoutManager.delegate = fragmentProvider
        fragmentContext.textView = self

        isVerticallyResizable = true
        isHorizontallyResizable = false
        autoresizingMask = [.width]
        allowsUndo = true
        isRichText = true
        importsGraphics = false
        usesFontPanel = false
        usesFindBar = false
        drawsBackground = true
        // §6.4: agents and code hate smart quotes, so typographic substitution
        // is off by default and the app turns it on if the user asks.
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        smartInsertDeleteEnabled = false
        isIncrementalSearchingEnabled = false
        textContainerInset = NSSize(width: RenderMetrics.revealSlack, height: RenderMetrics.verticalInset)
        setAccessibilityElement(true)
        setAccessibilityRole(.textArea)
        setAccessibilityCustomActions([
            NSAccessibilityCustomAction(name: "Open link at caret") { [weak self] in
                self?.activateLinkAtCaret() ?? false
            },
            NSAccessibilityCustomAction(name: "Copy code block") { [weak self] in
                self?.copyCodeBlockForAccessibility() ?? false
            },
        ])

        engine.policy = effectivePolicy
        engine.codeCollapseLineCount = configuration.codeCollapseThreshold
        applyTypographicSubstitution()
        fragmentContext.mode = mode
        applyMeasure()
        applyModeChrome()
        rebuildParagraphIndex()
    }

    /// Downright never archives its text surface; it is always constructed
    /// programmatically from the storage the document owns.
    public required init?(coder: NSCoder) { nil }

    deinit {
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let resignKeyObserver { NotificationCenter.default.removeObserver(resignKeyObserver) }
        resizeWorkItem?.cancel()
        scrollCoalesceWorkItem?.cancel()
        copiedCodeFeedbackWorkItem?.cancel()
        // Repeating 60fps timers on the main run loop would otherwise keep
        // firing forever after the view is gone: their blocks only ever
        // invalidate themselves while `self` is still alive, and the display
        // link itself retains its target.
        motionDriver?.park()
    }

    /// Used only by the convenience initialiser, so a text view can always be
    /// constructed — in tests, and in the Quick Look extension before the
    /// theme store has resolved anything (§10).
    public static func fallbackStyleSheet() -> StyleSheet {
        StyleSheet(theme: .fallback, appearance: NSAppearance.currentDrawing())
    }

    // MARK: - Document updates

    private func sourceScopes(for dirty: DirtySet) -> [NSRange] {
        guard !dirty.isWholesale, let storage = textStorage else { return [] }
        let whole = NSRange(location: 0, length: storage.length)
        return RangeSet.normalized(dirty.ranges.compactMap { range in
            NSIntersectionRange(range, whole).length > 0 ? NSIntersectionRange(range, whole) : nil
        })
    }

    /// Re-decorates only what the AST diff says changed (§3.5).
    public func update(document: ParsedDocument, dirty: DirtySet) {
        let selection = sourceSelectedRanges
        let anchor = captureViewportAnchor()
        let lockedViewportY = nextDocumentUpdateViewportY
        nextDocumentUpdateViewportY = nil
        let followsLocalEdit = shouldFollowCaretAfterLocalEdit
        let followsCaret = followsLocalEdit && configuration.typewriterScrolling
        shouldFollowCaretAfterLocalEdit = false
        let currentMode = mode
        let isInitialUpdate = updateGeneration == 0
        let oldParagraphCount = paragraphIndex.starts.count
        let isWholesaleUpdate = isInitialUpdate || dirty.isWholesale
        let dirtyScopes = isWholesaleUpdate ? [] : sourceScopes(for: dirty)
        parsedDocument = document
        hoveredLinkRange = nil
        inlineCodeBandCache.removeAll(keepingCapacity: true)
        invisibleGlyphCache.removeAll(keepingCapacity: true)
        updateGeneration &+= 1
        if isWholesaleUpdate { pathExistence.removeAll(keepingCapacity: true) }
        fragmentContext.frontMatterFields = (document.frontMatter?.fields ?? []).map { ($0.key, $0.value) }
        fragmentContext.documentHasH1 = document.headings.contains { $0.level == 1 }
        // Text changed, so any table geometry cached for a previous revision
        // is stale even when the table's start offset is unchanged (§11.3).
        fragmentContext.invalidateDerivedLayout()
        rebuildParagraphIndex()

        guard let storage = textStorage else { return }
        engine.decorate(storage, document: document, dirty: dirty)
        applySourcePresentation(scopes: isWholesaleUpdate ? nil : dirtyScopes)
        if configuration.showInvisibles || invisiblesApplied {
            applyInvisibles(scopes: isWholesaleUpdate ? nil : dirtyScopes)
        }
        rebuildBaseDisplayMap(document: document)
        refreshElision(rebuildingMap: false)
        // The mirror is repaired over what decoration *rewrote*, not over what
        // the diff reported: decoration grows each dirty range to whole blocks,
        // and a narrower repair leaves the rest of those blocks claiming nothing
        // is hidden in them.  This is the path an external write takes, so it is
        // the one where it mattered most.
        let decoratedScopes = isWholesaleUpdate
            ? []
            : engine.decoratedBounds(for: dirty, in: document, length: storage.length)
        rebuildDisplayMap(
            fullRefresh: isWholesaleUpdate,
            additionalScopes: decoratedScopes
        )
        applyOverlays(scopes: isWholesaleUpdate ? nil : decoratedScopes)
        applyPathExistence(scopes: isWholesaleUpdate ? nil : decoratedScopes)
        if isWholesaleUpdate {
            invalidateAllFragments()
        }
        gutterRail?.reload()
        refreshFragmentAccessibility()
        let resizeRequest: ContentResizeRequest
        if isWholesaleUpdate {
            resizeRequest = .immediate
        } else if paragraphIndex.starts.count != oldParagraphCount {
            resizeRequest = .lineCount
        } else {
            resizeRequest = .semantic
        }
        requestContentResize(
            resizeRequest,
            anchor: resizeRequest == .immediate || followsCaret || lockedViewportY != nil
                ? nil
                : anchor
        )

        // Async parses replace only the tree and decorations. Keep the same
        // source coordinates, scroll anchor, and render mode across commit;
        // TextKit coordinates may have changed with elision.
        if mode != currentMode { mode = currentMode }
        let boundedSelection = selection.map { range -> NSRange in
            let location = min(max(0, range.location), document.length)
            let end = min(max(location, range.upperBound), document.length)
            return NSRange(location: location, length: end - location)
        }
        setSourceSelectedRanges(boundedSelection)
        // A local edit can resolve TextKit's estimated layout above the
        // viewport even when it does not add a line. Keeping the clip's raw
        // y-coordinate then shows an earlier part of the document: the camera
        // appears to jump while the frame merely grew around it. Preserve the
        // source anchor and its exact screen-space gap through both this
        // commit and its deferred height repair. Typewriter scrolling owns the
        // camera when enabled, so it remains the one local-edit exception.
        if let lockedViewportY {
            restoreViewport(y: lockedViewportY)
        } else if !followsCaret {
            restoreViewport(to: anchor)
        }
    }

    /// TextKit exposes this view as one text area. Rendered objects also need
    /// structural children, or VoiceOver reaches only their raw Markdown
    /// source. These virtual nodes name the object while the text area keeps
    /// its normal editable range API.
    private func refreshFragmentAccessibility() {
        guard mode != .source else {
            fragmentAccessibilityElements = []
            setAccessibilityChildren(nil)
            return
        }
        var elements: [NSAccessibilityElement] = []
        parsedDocument.root.walk { block in
            let label: String? = switch block.content {
            case .table: "Markdown table"
            case .mathBlock: "Display math"
            case .mermaid: "Mermaid diagram"
            default: nil
            }
            guard let label else { return }
            let element = FragmentAccessibilityElement(
                textView: self,
                sourceOffset: block.range.location
            )
            element.setAccessibilityRole(.group)
            element.setAccessibilityLabel(label)
            element.setAccessibilityParent(self)
            element.setAccessibilityHelp("Rendered \(label.lowercased())")
            elements.append(element)
        }
        fragmentAccessibilityElements = elements
        setAccessibilityChildren(elements)
    }

    /// Keep the current pixel camera through the next parse/decorate commit.
    /// Used by rendered controls whose mutation must answer in place.
    public func preserveViewportOnNextDocumentUpdate() {
        nextDocumentUpdateViewportY = enclosingScrollView?.contentView.bounds.origin.y
    }

    private func restoreViewport(y: CGFloat) {
        guard let scrollView = enclosingScrollView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, frame.height - clip.bounds.height)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: min(max(0, y), maxY)))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Where the reader is looking, in a form that survives a relayout.
    ///
    /// A source offset alone is not enough.  Restoring one with `.top` parks
    /// its line at the container inset, but the line the reader was actually
    /// looking at was almost never sitting exactly there — so every parse
    /// commit shoved the page by the leftover fraction of a line plus the
    /// inset.  Typing a word into the middle of a document walked the camera
    /// down the page a jolt at a time, which reads as the view teleporting out
    /// from under the caret.
    ///
    /// Keeping the pixel gap between the viewport's top edge and the anchor
    /// line's top edge makes the restore exact: content above the anchor may
    /// change height freely, and the line under the reader's eye does not move
    /// at all.
    struct ViewportAnchor {
        var offset: Int
        /// Signed distance from the anchor line's top edge down to the
        /// viewport's top edge, in document coordinates.
        var gap: CGFloat
    }

    func captureViewportAnchor() -> ViewportAnchor {
        captureViewportAnchor(at: topVisibleOffset)
    }

    private func captureViewportAnchor(at offset: Int) -> ViewportAnchor {
        let visible = enclosingScrollView?.documentVisibleRect ?? visibleRect
        return ViewportAnchor(
            offset: offset,
            gap: rect(forOffset: offset).map { visible.minY - $0.minY } ?? 0
        )
    }

    /// Puts the anchor line back exactly where it was.  A no-op when the
    /// viewport is already there, so a settled document never has its clip
    /// view touched — the cheapest way to guarantee no visible movement.
    func restoreViewport(to anchor: ViewportAnchor) {
        guard let scrollView = enclosingScrollView else { return }
        let offset = min(max(0, anchor.offset), parsedDocument.length)
        guard let rect = rect(forOffset: offset) else { return }
        let clip = scrollView.contentView
        let maxY = max(0, frame.height - clip.bounds.height)
        let y = min(max(0, rect.minY + anchor.gap), maxY)
        guard abs(y - clip.bounds.origin.y) > 0.5 else { return }
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
    }

    /// Size the document view to the height layout actually used.
    ///
    /// TextKit 2 reports an **estimated** container height until layout has run,
    /// and `NSTextView` sizes its frame from that estimate.  For a document
    /// carrying fragments the estimate runs roughly three times high, which
    /// leaves most of the scroll range pointing at space no text will ever
    /// occupy: scroll into it — or restore a reading position that lands in it
    /// (§8.2) — and the window goes blank while the breadcrumb still names a
    /// perfectly sensible heading, because the *offset* is fine and only the
    /// geometry is wrong.  That failure is indistinguishable from "the renderer
    /// is broken", so it is worth resolving layout to be sure of the number.
    ///
    /// Full-document layout is affordable here because §15 Q4 already routes
    /// files past 5MB to windowed rendering; below that the cost is tens of
    /// milliseconds once per structural change, not per keystroke.
    public func resizeToFitContent() {
        resizeToFitContent(layoutScope: .document)
    }

    /// Resolves the restored viewport before the first frame is shown. TextKit
    /// can have a correct document height while still holding the glyphs at a
    /// deep restored offset lazily; the first keyboard scroll would otherwise
    /// be the thing that makes them appear.
    public func prepareForDisplay() {
        guard let layoutManager = textLayoutManager else { return }
        let visible = enclosingScrollView?.documentVisibleRect ?? visibleRect
        let origin = textContainerOrigin
        let viewport = NSRect(
            x: max(0, visible.minX - origin.x),
            y: max(0, visible.minY - origin.y),
            width: max(1, visible.width),
            height: max(1, visible.height)
        )
        layoutManager.ensureLayout(for: viewport)
        // NSTextView's TextKit 2 viewport controller owns the active fragment
        // set. A bounds jump can update the clip view without asking that
        // controller to lay out its new viewport; a native scroll gesture
        // does both. Re-run it explicitly for programmatic restores.
        layoutManager.textViewportLayoutController.layoutViewport()
        setNeedsDisplay(visible)
        // `displayIfNeeded()` may leave a freshly scrolled TextKit 2 surface
        // pending when the view has not painted once at that offset yet.
        // Force this small visible rect so programmatic restores behave like
        // the first native scroll gesture.
        display(visible)
    }

    private enum ContentLayoutScope {
        case viewport
        case document
    }

    /// Paragraphs the eager path may materialise before the estimate takes over.
    ///
    /// `ensureLayout(for: documentRange)` builds — and holds — one
    /// `NSTextLayoutFragment` per paragraph, each carrying its own line
    /// fragments and attribute runs.  Measured on this project's own render
    /// path that costs roughly 25 KB a paragraph, so the ceiling is a memory
    /// budget of about 100 MB rather than a taste judgement.
    ///
    /// 4,000 is far past any document a person wrote: a long specification runs
    /// to a few hundred paragraphs, and this file is under two thousand lines.
    /// It is machine-generated output — an agent's 40,000-block report — that
    /// reaches it, which is exactly the case the estimate exists for.
    private static let eagerLayoutParagraphLimit = 4_000

    /// Whether whole-document layout is still affordable.
    ///
    /// The byte threshold alone was the wrong instrument.  Layout cost tracks
    /// the *number of fragments*, not the number of characters, and the two
    /// diverge by orders of magnitude: a 4 MB document that is one enormous
    /// code fence is a handful of fragments, while 3.7 MB of short blocks is
    /// forty thousand of them — and that second document sat under the 5 MB
    /// default, took the eager path, and settled at over a gigabyte resident.
    ///
    /// Both signals are checked, so a document is estimated when it is heavy by
    /// either measure and laid out exactly when it is light by both.  The
    /// byte threshold stays user-visible in Settings; the fragment ceiling is
    /// an implementation bound and deliberately is not.
    private var exceedsEagerLayoutBudget: Bool {
        if let storage = textStorage,
           storage.length > configuration.largeFileThresholdMegabytes * 1024 * 1024 {
            return true
        }
        return paragraphIndex.starts.count > Self.eagerLayoutParagraphLimit
    }

    private func resizeToFitContent(layoutScope: ContentLayoutScope) {
        guard let layoutManager = textLayoutManager else { return }
        if case .viewport = layoutScope {
            repairContentHeightFromViewport(using: layoutManager)
            return
        }
        if exceedsEagerLayoutBudget {
            let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? 0
            let estimated = max(
                viewportHeight,
                CGFloat(max(1, paragraphIndex.starts.count)) * styleSheet.lineHeight
                    + textContainerInset.height * 2 + viewportHeight * 0.40
            )
            guard abs(frame.height - estimated) > 0.5 else { return }
            if estimated < frame.height, viewportIsPinnedToBottom {
                pendingShrinkRepair = true
                return
            }
            setFrameSize(NSSize(width: frame.width, height: estimated),
                         preservingReadingPosition: estimated < frame.height)
            return
        }
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        let used = layoutManager.usageBoundsForTextContainer
        let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let height = max(used.maxY + textContainerInset.height + viewportHeight * 0.40, viewportHeight)
        guard abs(frame.height - height) > 0.5 else { return }
        // Never shrink the document under the reader's hands.  When the visible
        // region reaches the bottom of the frame, shrinking clamps the clip view
        // and the whole page drops mid-keystroke.  Defer the shrink until the
        // viewport moves away from the bottom edge; the scroll observer then
        // settles the over-tall frame via `pendingShrinkRepair`.
        if height < frame.height, viewportIsPinnedToBottom {
            pendingShrinkRepair = true
            return
        }
        setFrameSize(NSSize(width: frame.width, height: height), preservingReadingPosition: height < frame.height)
    }

    /// The viewport-scope repair inflates the frame by 40% of a viewport, and
    /// the document-scope pass later settles it back to the true height.  The
    /// bottom-pinned guard above covers the last 15% of a viewport; between the
    /// two lies a band where a shrink still clamps the clip view and drops the
    /// page somewhere the reader did not put it.  Pin the anchor line across
    /// the shrink so that band behaves like the rest of the document.
    private func setFrameSize(_ size: NSSize, preservingReadingPosition: Bool) {
        guard preservingReadingPosition else {
            setFrameSize(size)
            return
        }
        let anchor = captureViewportAnchor()
        setFrameSize(size)
        restoreViewport(to: anchor)
    }

    /// Structural zoom (§5.2): the document's extent changes as sections join
    /// or leave the projection.  The new height is resolved synchronously and
    /// then sprung into place on the layer, so the projection does not snap —
    /// it settles, the way a document opening or closing a drawer does.
    private func animateStructuralZoomHeight(from previousHeight: CGFloat) {
        resizeToFitContent(layoutScope: .document)
        let targetHeight = frame.height
        guard abs(targetHeight - previousHeight) > 0.5 else { return }
        // The largest movement in the app: the whole document's height. Reduce
        // Motion has to reach it, and it is the one animation §11.4 names.
        guard !styleSheet.reduceMotion else { return }
        wantsLayer = true
        guard let animationLayer = self.layer else { return }
        animationLayer.removeAnimation(forKey: "downrightStructuralZoom")
        let settle = CABasicAnimation(keyPath: "bounds.size.height")
        settle.fromValue = previousHeight
        settle.toValue = targetHeight
        settle.duration = Motion.deliberate
        settle.timingFunction = Motion.timing(.structural)
        animationLayer.add(settle, forKey: "downrightStructuralZoom")
    }

    /// True while the visible region sits within a hair of the bottom of the
    /// current frame — the one place a frame shrink would clamp the clip view
    /// and drop the whole page.
    private var viewportIsPinnedToBottom: Bool {
        guard let scrollView = enclosingScrollView else { return false }
        let slack = max(24, scrollView.contentView.bounds.height * 0.15)
        return scrollView.documentVisibleRect.maxY >= frame.height - slack
    }

    /// Layout only the visible viewport for semantic updates.  The usage
    /// bounds are incomplete until TextKit has visited the whole document, so
    /// this path may grow the frame but never shrinks it.  A later scroll near
    /// the estimated end upgrades to the document-wide repair path.
    private func repairContentHeightFromViewport(using layoutManager: NSTextLayoutManager) {
        let visible = enclosingScrollView?.documentVisibleRect ?? visibleRect
        let viewportHeight = max(visible.height, enclosingScrollView?.contentView.bounds.height ?? 0)
        guard viewportHeight > 0 else { return }

        let origin = textContainerOrigin
        let viewportBounds = NSRect(
            x: max(0, visible.minX - origin.x),
            y: max(0, visible.minY - origin.y),
            width: max(1, visible.width),
            height: viewportHeight
        )
        layoutManager.ensureLayout(for: viewportBounds)

        let estimated = CGFloat(max(1, paragraphIndex.starts.count)) * styleSheet.lineHeight
            + textContainerInset.height * 2 + viewportHeight * 0.40
        let used = layoutManager.usageBoundsForTextContainer.maxY
            + textContainerInset.height + viewportHeight * 0.40
        // Content-anchored only.  A `visible.maxY`-based term overshoots at the
        // document's end: with the caret pinned to the bottom it grows the frame
        // by another viewport fraction, and the next document-scope repair
        // (scrollRepair / lineCount) shrinks it back — clamping the clip view and
        // dropping the whole page under the user's hands on every keystroke.
        let height = max(frame.height, estimated, used, viewportHeight)
        guard height - frame.height > 0.5 else { return }
        setFrameSize(NSSize(width: frame.width, height: height))
    }

    /// Schedules a height pass. Structural updates run now. Semantic parse
    /// results wait for an idle gap and coalesce, so typing does not force a
    /// document-wide TextKit layout on the main actor for every result.
    private func requestContentResize(_ request: ContentResizeRequest, anchor: ViewportAnchor? = nil) {
        if let anchor { pendingResizeAnchor = anchor }
        // A scroll repair exists *because* the reader moved the camera. Any
        // anchor still queued from an earlier commit describes where they used
        // to be looking, and applying it after the height settles is the exact
        // "the page jumped somewhere else" jolt this path is meant to avoid.
        if request == .scrollRepair { pendingResizeAnchor = nil }
        pendingResizeRequest = ContentResizePolicy.merge(pendingResizeRequest, with: request)
        guard let pending = pendingResizeRequest else { return }

        resizeGeneration &+= 1
        let generation = resizeGeneration
        resizeWorkItem?.cancel()
        resizeWorkItem = nil

        if pending == .immediate {
            pendingResizeRequest = nil
            pendingResizeAnchor = nil
            resizeNeedsRepair = false
            resizeToFitContent()
            return
        }
        resizeNeedsRepair = true

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.resizeGeneration == generation else { return }
            self.resizeWorkItem = nil
            guard self.pendingResizeRequest != nil else { return }
            self.pendingResizeRequest = nil
            let anchor = self.pendingResizeAnchor
            self.pendingResizeAnchor = nil
            self.resizeNeedsRepair = pending == .semantic
            self.resizeToFitContent(
                layoutScope: pending == .semantic ? .viewport : .document)
            if let anchor { self.restoreViewport(to: anchor) }
        }
        resizeWorkItem = workItem
        let delay = ContentResizePolicy.idleDelay(for: pending)
        if delay == 0 {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
        }
    }

    private func rebuildEverything() {
        guard let storage = textStorage else { return }
        // The content storage is reconfigured from the paragraph index below,
        // so it has to describe the text that is in the buffer right now.  A
        // configuration change can arrive before the first `update(document:)`
        // — the buffer already holds the file, the index is still empty.
        rebuildParagraphIndex()
        engine.decorate(storage, document: parsedDocument, dirty: .wholesale)
        applySourcePresentation()
        applyInvisibles()
        rebuildBaseDisplayMap(document: parsedDocument)
        refreshElision(rebuildingMap: false)
        rebuildDisplayMap(fullRefresh: true)
        applyOverlays()
        applyPathExistence()
        invalidateAllFragments()
        gutterRail?.reload()
        refreshFragmentAccessibility()
    }

    /// Theme colour / accent swaps that do not change typography.
    private func restyleAttributesPreservingGeometry() {
        guard let storage = textStorage else { return }
        engine.decorate(storage, document: parsedDocument, dirty: .wholesale)
        applySourcePresentation()
        applyOverlays()
        applyPathExistence()
        refreshBaseLayoutMap()
        invalidateAllFragments()
        if exceedsEagerLayoutBudget {
            markdownLayoutManager.textViewportLayoutController.layoutViewport()
        } else {
            markdownLayoutManager.ensureLayout(for: markdownLayoutManager.documentRange)
        }
        gutterRail?.reload()
        needsDisplay = true
    }

    /// Re-reads the layout replacements after decoration changed attributes
    /// without changing the substitution set.
    ///
    /// `restoreAnchorShift` deliberately does *not* call this: it re-decorates
    /// one paragraph back to exactly the state the cache was built from, and
    /// putting a document-wide pass on the caret path is the cost this cache
    /// exists to remove.
    private func refreshBaseLayoutMap() {
        baseLayoutMap = layoutDisplayMap(from: baseDisplayMap)
    }

    private func rebuildBaseDisplayMap(document: ParsedDocument) {
        var hidden = engine.hiddenRanges(document: document, caret: nil, selections: [])
        if let focus = sourceFocus.range {
            hidden.removeAll { NSIntersectionRange($0, focus).length > 0 }
        }

        let mathRanges = effectivePolicy.rendersFragments
            ? InlineMathDisplay.ranges(in: document).filter { range in
                guard let focus = sourceFocus.range else { return true }
                return NSIntersectionRange(range, focus).length == 0
            }
            : []
        // The math replacement owns its delimiters and content as one visual
        // object. Keeping the marker substitutions too would overlap the
        // object range, causing DisplayMap to reject one of the entries.
        hidden.removeAll { hiddenRange in
            mathRanges.contains { NSIntersectionRange(hiddenRange, $0).length > 0 }
        }
        let mathSubstitutions = effectivePolicy.rendersFragments
            ? InlineMathDisplay.substitutions(
                in: document, styleSheet: styleSheet, excluding: sourceFocus.range)
            : []

        let footnoteReferences = effectivePolicy.hidesInlineMarkers
            ? FootnoteReferenceDisplay.references(in: document).filter { reference in
                guard let focus = sourceFocus.range else { return true }
                return NSIntersectionRange(reference.range, focus).length == 0
            }
            : []
        hidden.removeAll { hiddenRange in
            footnoteReferences.contains {
                NSIntersectionRange(hiddenRange, $0.range).length > 0
            }
        }
        let footnoteSubstitutions = effectivePolicy.hidesInlineMarkers
            ? FootnoteReferenceDisplay.substitutions(
                in: document, styleSheet: styleSheet, excluding: sourceFocus.range
            )
            : []

        baseHiddenRanges = hidden
        let plan = HardWrapReflow.plan(
            document: document,
            text: (textStorage?.string ?? "") as NSString,
            hiddenRanges: hidden,
            enabled: configuration.reflowHardWrappedParagraphs
        )
        hardWrapRanges = plan.ranges
        hardWrapSubstitutions = plan.substitutions.filter(\.isHardWrapReflow)
        baseDisplayMap = DisplayMap(
            paragraphs: paragraphIndex,
            substitutions: hidden.map(DisplaySubstitution.hide)
                + mathSubstitutions
                + footnoteSubstitutions
                + hardWrapSubstitutions
        )
        // Selection / hit-testing speak TextKit coordinates from the layout map
        // (length-preserving joiners). Collapsed logical maps stay on the
        // substitution fallback path only.
        baseLayoutMap = layoutDisplayMap(from: baseDisplayMap)
        displayMap = baseLayoutMap
    }

    /// TextKit 2 elements keep source-length ranges even when Markdown syntax
    /// is visually omitted. Hidden runs become zero-width word joiners here;
    /// the logical map used by marker policy still collapses them for semantic
    /// selection and reveal decisions.
    private func layoutDisplayMap(from logical: DisplayMap) -> DisplayMap {
        let substitutions = logical.substitutions.map(layoutSubstitution)
        return DisplayMap(paragraphs: paragraphIndex, substitutions: substitutions)
    }

    /// One logical substitution in layout space.  Kept separate from the map so
    /// a paragraph-local reveal can transform only its own handful of entries.
    private func layoutSubstitution(_ substitution: DisplaySubstitution) -> DisplaySubstitution {
        guard !substitution.isHidden,
              let replacement = substitution.replacement,
              replacement.length < substitution.sourceRange.length,
              replacement.attribute(.attachment, at: 0, effectiveRange: nil) != nil else {
            guard substitution.isHidden else { return substitution }
            let length = substitution.sourceRange.length
            return DisplaySubstitution(
                sourceRange: substitution.sourceRange,
                displayLength: length,
                replacement: layoutFiller(length: length, styledLike: substitution.sourceRange.location),
                isHidden: true,
                preservesSourceOffsets: true
            )
        }
        let fillerCount = substitution.sourceRange.length - replacement.length
        let layoutReplacement = NSMutableAttributedString(attributedString: replacement)
        layoutReplacement.append(
            layoutFiller(length: fillerCount, styledLike: substitution.sourceRange.location)
        )
        return DisplaySubstitution(
            sourceRange: substitution.sourceRange,
            displayLength: substitution.sourceRange.length,
            replacement: layoutReplacement,
            preservesSourceOffsets: true
        )
    }

    /// A run of `length` word joiners carrying the storage's own attributes at
    /// `offset`.
    ///
    /// Reading those attributes with `storage.attributes(at:)` and handing them
    /// to `NSAttributedString(string:attributes:)` bridges one attribute
    /// dictionary out of Objective-C and straight back into it, per hidden
    /// marker, on every keystroke.  On a 5,000-line document that round trip
    /// measured as most of the keystroke budget, and it buys nothing:
    /// `attributedSubstring` hands back the storage's own dictionary without
    /// bridging, and `replaceCharacters` extends the first replaced character's
    /// attributes over the whole replacement.
    private func layoutFiller(length: Int, styledLike offset: Int) -> NSAttributedString {
        let joiners = wordJoiners(length)
        guard let storage = textStorage, offset >= 0, offset < storage.length else {
            return NSAttributedString(string: joiners)
        }
        let styled = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: NSRange(location: offset, length: 1))
        )
        styled.replaceCharacters(in: NSRange(location: 0, length: 1), with: joiners)
        return styled
    }

    /// Word-joiner runs by length.  A document uses the same handful of marker
    /// lengths over and over — `# `, `- [ ] `, a single `*` — so building the
    /// string once keeps the allocation off the keystroke path.
    private var wordJoinerRuns: [Int: String] = [:]

    private func wordJoiners(_ length: Int) -> String {
        if let cached = wordJoinerRuns[length] { return cached }
        let run = String(repeating: "\u{2060}", count: max(0, length))
        wordJoinerRuns[length] = run
        return run
    }

    /// Source Focus changes typography and local material, never characters.
    /// Decoration runs first so Markdown token colours remain intact; this
    /// pass owns only font, line geometry, and the source-focus marker used by
    /// background/chrome drawing.
    private func applySourcePresentation(scopes: [NSRange]? = nil) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let whole = NSRange(location: 0, length: storage.length)

        let target: NSRange
        let scoped: Bool
        switch sourceFocus {
        case .none:
            guard appliedSourceFocus != .none else { return }
            let previous = sourcePresentationRange(for: appliedSourceFocus, in: whole)
            if let previous { storage.removeAttribute(.drSourceFocus, range: previous) }
            appliedSourceFocus = .none
            return
        case .document:
            target = whole
            scoped = false
        case .scoped(let range):
            let lower = max(0, min(range.location, storage.length))
            let upper = max(lower, min(range.upperBound, storage.length))
            guard upper > lower else { return }
            target = NSRange(location: lower, length: upper - lower)
            scoped = true
        }

        let focusChanged = appliedSourceFocus != sourceFocus
        if focusChanged,
           let previous = sourcePresentationRange(for: appliedSourceFocus, in: whole) {
            storage.removeAttribute(.drSourceFocus, range: previous)
        }
        appliedSourceFocus = sourceFocus

        let applicationRanges: [NSRange]
        if focusChanged || scopes == nil {
            applicationRanges = [target]
        } else {
            applicationRanges = RangeSet.normalized((scopes ?? []).compactMap {
                $0.intersection(target)
            })
        }
        guard !applicationRanges.isEmpty else { return }

        var attributes = styleSheet.monoFontAttributes()
        attributes[.drSourceFocus] = true
        for range in applicationRanges {
            storage.addAttributes(attributes, range: range)
        }

        let source = storage.string as NSString
        let paragraphs = RangeSet.normalized(applicationRanges.compactMap { range in
            let lower = source.paragraphRange(for: NSRange(location: range.location, length: 0))
            let upperOffset = max(range.location, range.upperBound - 1)
            let upper = source.paragraphRange(for: NSRange(location: upperOffset, length: 0))
            return lower.union(upper).intersection(target)
        })
        for paragraphsRange in paragraphs {
            var cursor = paragraphsRange.location
            while cursor < paragraphsRange.upperBound {
                let paragraph = source.paragraphRange(for: NSRange(location: cursor, length: 0))
                    .intersection(target) ?? NSRange(location: cursor, length: 0)
                guard paragraph.length > 0 else { break }
                let style = NSMutableParagraphStyle()
                style.minimumLineHeight = styleSheet.lineHeight
                style.maximumLineHeight = styleSheet.lineHeight
                style.lineBreakMode = .byWordWrapping
                style.paragraphSpacingBefore = scoped && cursor == target.location ? 28 : 0
                style.paragraphSpacing = scoped && paragraph.upperBound >= target.upperBound ? 8 : 0
                style.tabStops = stride(from: 4, through: 80, by: 4).map {
                    NSTextTab(textAlignment: .left,
                              location: CGFloat($0) * styleSheet.averageCharacterWidth,
                              options: [:])
                }
                style.defaultTabInterval = styleSheet.averageCharacterWidth * 4
                storage.addAttribute(.paragraphStyle, value: style, range: paragraph)
                cursor = paragraph.upperBound
            }
        }
    }

    private func sourcePresentationRange(for focus: SourceFocus, in whole: NSRange) -> NSRange? {
        switch focus {
        case .none:
            return nil
        case .document:
            return whole
        case .scoped(let range):
            return range.intersection(whole)
        }
    }

    func rebuildParagraphIndex() {
        guard let storage = textStorage else { return }
        paragraphIndex = ParagraphIndex(text: storage.string as NSString)
        fragmentContext.paragraphIndex = paragraphIndex
    }

    /// The live source ⇄ TextKit map.  Every conversion in the view goes
    /// through this one value; nothing keeps a copy.
    var currentDisplayMap: DisplayMap { displayMap }

    func paragraphRange(containing offset: Int) -> NSRange {
        paragraphIndex.paragraphRange(containing: offset)
    }

    func refreshDisplayMapForComposition() {
        rebuildDisplayMap()
    }

    /// Keeps unaffected paragraphs rendered while an asynchronous parse is in
    /// flight. Only the edited paragraph span falls back to literal source.
    func projectDisplayMapAcrossEdit(
        _ edit: NSRange,
        insertedLength: Int,
        oldParagraphs: ParagraphIndex,
        oldHiddenRanges: [NSRange],
        preservesParagraphStructure: Bool
    ) {
        // Keep rendered objects outside the edited range alive until the async
        // parse lands. Dropping them here made every inline formula and
        // footnote in the document disappear for one frame on each keystroke,
        // then reappear at parse commit — a whole-page flash on documents that
        // use either feature.
        let oldDisplayObjects = baseDisplayMap.substitutions.filter {
            !$0.isHidden && !$0.isHardWrapReflow
        }
        let projection = SourceEditProjection(
            edit: edit,
            insertedLength: insertedLength,
            oldParagraphs: oldParagraphs
        )
        func projectPresentationRange(_ range: NSRange) -> NSRange? {
            preservesParagraphStructure
                ? projection.projectUnchanged(range)
                : projection.project(range)
        }
        let projectedHidden = oldHiddenRanges.compactMap(projectPresentationRange)
        let projectedDisplayObjects = oldDisplayObjects.compactMap {
            substitution -> DisplaySubstitution? in
            guard let range = projectPresentationRange(substitution.sourceRange) else {
                return nil
            }
            var projected = substitution
            projected.sourceRange = range
            return projected
        }
        let projectedHardWrapRanges = RangeSet.normalized(
            hardWrapRanges.compactMap {
                projection.projectContainer(
                    $0,
                    preservingStructure: preservesParagraphStructure
                )
            }
        )
        let projectedHardWrapSubstitutions = hardWrapSubstitutions.compactMap {
            substitution -> DisplaySubstitution? in
            guard let range = projection.projectUnchanged(substitution.sourceRange),
                  RangeSet.covers(projectedHardWrapRanges, range.location) else {
                return nil
            }
            var projected = substitution
            projected.sourceRange = range
            return projected
        }

        baseHiddenRanges = projectedHidden
        hardWrapRanges = projectedHardWrapRanges
        hardWrapSubstitutions = projectedHardWrapSubstitutions
        baseDisplayMap = DisplayMap(
            paragraphs: paragraphIndex,
            substitutions: projectedHidden.map(DisplaySubstitution.hide)
                + projectedDisplayObjects
                + projectedHardWrapSubstitutions
        )
        baseLayoutMap = layoutDisplayMap(from: baseDisplayMap)
        displayMap = baseLayoutMap
        // Physical fallback still collapses markers; layout map keeps TextKit
        // selection arithmetic aligned with content storage.
        substitution.displayMap = baseDisplayMap
        revealParagraph = nil

        guard let storage = textStorage, storage.length > 0 else { return }
        let insertedEnd = min(storage.length, edit.location + insertedLength)
        let first = paragraphIndex.paragraphRange(containing: min(edit.location, storage.length))
        let last = paragraphIndex.paragraphRange(containing: max(edit.location, insertedEnd - 1))
        let affected = first.union(last).intersection(NSRange(location: 0, length: storage.length))
        guard let affected, affected.length > 0 else { return }
        // A length-changing edit moves the NSTextRange of every element after
        // it.  The content-storage cache already drops those shifted elements,
        // but TextKit's layout manager owns a second cache of fragments.  If
        // only `affected` is invalidated, that cache can keep the old suffix
        // while accepting its shifted replacement: both generations then draw
        // at once, producing stacked rows and invalid geometry for viewport
        // restoration.  Preserve the settled prefix, but retire the complete
        // suffix whose source identity changed.  Same-length replacements do
        // not move downstream ranges and remain paragraph-local.
        let layoutAffected = insertedLength == edit.length
            ? affected
            : NSRange(location: affected.location, length: storage.length - affected.location)
        contentStorage.configure(
            paragraphIndex: paragraphIndex,
            reflowRanges: projectedHardWrapRanges,
            displayMap: displayMap,
            invalidating: [layoutAffected]
        )
        storage.beginEditing()
        storage.removeAttribute(.drFragment, range: affected)
        storage.removeAttribute(.drElided, range: affected)
        storage.endEditing()
        applyHiddenAttribute(projectedHidden, scope: affected)
        invalidateFragments(in: layoutAffected)
    }

    func beginSourceEdit() {
        isPerformingSourceEdit = true
        // The map is about to describe a string that no longer exists.  Drop it
        // rather than let the substitution delegate act on it mid-edit.
        substitution.displayMap = .identity
        contentStorage.suspendCustomLayout()
    }

    func endSourceEdit() {
        isPerformingSourceEdit = false
    }

    // MARK: - Hidden ranges and the display map

    private func sameSubstitutions(
        _ lhs: [DisplaySubstitution],
        _ rhs: [DisplaySubstitution]
    ) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            let sameReplacement: Bool
            switch (left.replacement, right.replacement) {
            case (nil, nil): sameReplacement = true
            case let (left?, right?): sameReplacement = left.isEqual(to: right)
            default: sameReplacement = false
            }
            return left.sourceRange == right.sourceRange
                && left.displayLength == right.displayLength
                && left.isHidden == right.isHidden
                && left.isHardWrapReflow == right.isHardWrapReflow
                && left.preservesSourceOffsets == right.preservesSourceOffsets
                && sameReplacement
        }
    }

    /// Rebuilds the substitution set for the current caret.
    ///
    /// Squarely on the keystroke path (§12), so two things it does *not* do:
    /// rewalk the document for the hidden set (it subtracts the revealed spans
    /// from a set cached per document), and touch attributes or layout outside
    /// the paragraphs whose substitutions actually changed — which is only ever
    /// the caret's paragraph and the one it just left.
    private func rebuildDisplayMap(
        fullRefresh: Bool = false,
        additionalScopes: [NSRange] = []
    ) {
        let previousSubstitutions = displayMap.substitutions
        let caret = suppressesCaretReveal ? nil : primarySourceCaret
        var hidden = baseHiddenRanges
        var revealedForAttributes: [NSRange] = []
        var requiresFullHiddenRefresh = false
        /// True once `hidden` has been narrowed to the caret's paragraph and
        /// the one it just left.  What is cleared below then has to be narrowed
        /// to match, or the sweep erases markers it has no data to restore.
        var hiddenIsParagraphScoped = false
        var logicalDisplayMap = baseDisplayMap
        // Both maps are derived from the cached bases by the *same* subsetting.
        // A reveal only ever drops entries, and `baseLayoutMap` already holds
        // every surviving entry in layout form, so nothing here has to rebuild
        // a layout replacement — doing that walked every substitution in the
        // document on every keystroke and was most of the keystroke cost (§12).
        var layoutMap = baseLayoutMap

        if let composing = composingParagraph {
            // Composition suspends hiding in its paragraph so the hybrid and
            // source spaces coincide there and AppKit's marked-text
            // bookkeeping is exactly right.
            hidden = hidden.filter { $0.upperBound <= composing.location || $0.location >= composing.upperBound }
            func stillHiding(in map: DisplayMap) -> [DisplaySubstitution] {
                map.substitutions(inParagraphContaining: composing.location).filter { entry in
                    !baseHiddenRanges.contains { hiddenRange in hiddenRange == entry.sourceRange }
                }
            }
            logicalDisplayMap = baseDisplayMap.replacingParagraph(
                containing: composing.location, with: stillHiding(in: baseDisplayMap))
            layoutMap = baseLayoutMap.replacingParagraph(
                containing: composing.location, with: stillHiding(in: baseLayoutMap))
            requiresFullHiddenRefresh = caret == nil
        } else if effectivePolicy.revealsAtCaret {
            let revealed = MarkerPolicy.revealedMarkerRanges(
                document: parsedDocument, policy: effectivePolicy,
                caret: caret, selections: sourceSelectedRanges)
            let revealedMath = caret.map {
                InlineMathDisplay.ranges(in: parsedDocument, touching: $0)
            } ?? []
            let revealedDisplayObjects = revealed + revealedMath
            let paragraph = caret.map { paragraphIndex.paragraphRange(containing: $0) }
            // The fast path holds when the reveal is confined to the caret's
            // own paragraph, which is every ordinary keystroke.  A span
            // straddling a soft line break, or a multi-paragraph selection,
            // falls back to a full rebuild — rare, and driven by a gesture
            // rather than by typing.
            let singleCaret = paragraph.map { paragraph in
                sourceSelectedRanges.count <= 1 && revealed.allSatisfy {
                    $0.location >= paragraph.location && $0.upperBound <= paragraph.upperBound
                }
            } ?? false
            if let paragraph, singleCaret {
                if !revealedDisplayObjects.isEmpty {
                    logicalDisplayMap = baseDisplayMap.replacingParagraph(containing: paragraph.location,
                                                                           excluding: revealedDisplayObjects)
                    layoutMap = baseLayoutMap.replacingParagraph(containing: paragraph.location,
                                                                 excluding: revealedDisplayObjects)
                    // Keep the cached document-wide set intact.  The display
                    // map and this exclusion list together describe the one
                    // paragraph that is currently revealed; no global filter
                    // is needed on a caret move.
                    revealedForAttributes = revealed
                }
                // Narrowing the set to the caret's own paragraphs is only sound
                // when those are the *only* scopes about to be rewritten.  A
                // caller that passes `additionalScopes` has just re-decorated
                // those blocks — decoration clears `drHidden` — and the sweep
                // below would then run a paragraph-sized set over a block-sized
                // window, removing markers it has no data to restore.  That is
                // how an agent's write left the blocks it touched claiming
                // nothing was hidden in them.
                if !fullRefresh, additionalScopes.isEmpty {
                    let affected = [paragraph, revealParagraph].compactMap { $0 }
                    hidden = RangeSet.normalized(affected.flatMap {
                        baseDisplayMap.hiddenRanges(inParagraphContaining: $0.location)
                    })
                    hiddenIsParagraphScoped = true
                }
            } else if !revealed.isEmpty {
                hidden = subtract(revealed, from: hidden)
                func unrevealed(in map: DisplayMap) -> [DisplaySubstitution] {
                    map.substitutions.filter { entry in
                        !revealedDisplayObjects.contains { $0 == entry.sourceRange }
                    }
                }
                logicalDisplayMap = DisplayMap(
                    paragraphs: paragraphIndex, substitutions: unrevealed(in: baseDisplayMap))
                layoutMap = DisplayMap(
                    paragraphs: paragraphIndex, substitutions: unrevealed(in: baseLayoutMap))
                // A selection can span any number of paragraphs. The map was
                // rebuilt for the whole document, so its mirrored attributes
                // must use the same scope. This path is gesture-driven and is
                // not part of the insertion-caret hot path.
                requiresFullHiddenRefresh = true
            }
        }
        substitution.displayMap = logicalDisplayMap
        displayMap = layoutMap

        let current = caret.map { paragraphIndex.paragraphRange(containing: $0) }
        let isFullRefresh = fullRefresh || (requiresFullHiddenRefresh && additionalScopes.isEmpty)
        // The caret's paragraph and the one it just left are two *discrete*
        // paragraphs.  Covering them with the single range that spans them —
        // and everything in between — is what made clicking feel broken: click
        // far from the last caret and the sweep below cleared `.drHidden`
        // across every paragraph between the two while `hidden` only carried
        // the endpoints' markers to restore, and `invalidateFragments` threw
        // away resolved layout for the whole span.  TextKit then redrew that
        // span from its own line-height estimates, so the page slid out from
        // under the pointer by hundreds of points — the "screen teleports"
        // jolt — and the raw markers in between stopped being marked hidden.
        //
        // Keep them separate.  `normalized` still fuses the two into one range
        // when the caret only moved to a neighbouring paragraph, so the common
        // case costs exactly what it did before.
        let paragraphs = isFullRefresh ? [] : [revealParagraph, current].compactMap { $0 }
        if !isFullRefresh, additionalScopes.isEmpty,
           sameSubstitutions(displayMap.substitutions, previousSubstitutions) {
            // Moving through plain prose changes the caret paragraph but not
            // its presentation. Reconfiguring and invalidating those elements
            // anyway makes TextKit replace settled geometry with estimates;
            // the next rectangle query then corrects a line at a time and the
            // page appears to twitch even though no marker changed visibility.
            revealParagraph = current
            return
        }
        let touched: [NSRange]
        if hiddenIsParagraphScoped || paragraphs.count < 2 {
            touched = paragraphs
        } else {
            // `hidden` is still the document-wide set, so a covering range can
            // be repopulated in full and stays correct.
            touched = [paragraphs[0].union(paragraphs[1])]
        }
        revealParagraph = current
        let invalidatedScopes = RangeSet.normalized(additionalScopes + touched)
        contentStorage.configure(
            paragraphIndex: paragraphIndex,
            reflowRanges: hardWrapRanges,
            displayMap: displayMap,
            invalidating: isFullRefresh ? nil : invalidatedScopes
        )
        if isFullRefresh {
            applyHiddenAttribute(hidden, scope: nil, excluding: revealedForAttributes)
            invalidateFragments(in: nil)
        } else {
            for scope in invalidatedScopes {
                applyHiddenAttribute(hidden, scope: scope, excluding: revealedForAttributes)
                invalidateFragments(in: scope)
            }
        }
    }

    /// `drHidden` mirrors the map so anything reading the storage (rich-text
    /// copy, export, the Quick Look renderer) sees the same decision the layout
    /// did.  `scope == nil` refreshes the document; a range refreshes only that.
    private func applyHiddenAttribute(_ hidden: [NSRange], scope: NSRange?, excluding: [NSRange] = []) {
        guard let storage = textStorage, storage.length > 0 else { return }
        let window = scope.flatMap { clampToStorage($0) } ?? NSRange(location: 0, length: storage.length)
        guard window.length > 0 else { return }
        storage.beginEditing()
        storage.removeAttribute(.drHidden, range: window)
        for range in RangeSet.intersecting(hidden, window) {
            storage.addAttribute(.drHidden, value: true, range: range)
        }
        for range in RangeSet.intersecting(excluding, window) {
            storage.removeAttribute(.drHidden, range: range)
        }
        storage.endEditing()
    }

    private func subtract(_ removed: [NSRange], from ranges: [NSRange]) -> [NSRange] {
        guard !removed.isEmpty else { return ranges }
        var out: [NSRange] = []
        out.reserveCapacity(ranges.count)
        for range in ranges where !removed.contains(where: { $0.location == range.location && $0.length == range.length }) {
            out.append(range)
        }
        return out
    }

    // MARK: - Elision (§5.2, §7.1, §9.4)

    private func refreshElision(rebuildingMap: Bool = true) {
        // Selection is observation, not edit intent (§DESIGN "Surface model"),
        // so it must not force elided content back into view.  It used to be a
        // probe here while nothing refreshed elision on a selection change —
        // so a select-all did nothing until some unrelated reparse fired and
        // then expanded every folded section at once.
        elision = ElisionPlan.make(
            document: parsedDocument, zoom: zoomLevel,
            foldedHeadingSlugs: foldedHeadingSlugs, searchHits: searchHits,
            caret: primarySourceCaret, selections: expandedElisionRanges)
        fragmentContext.cueElision = elision
        let definitionElisions: [NSRange]
        if effectivePolicy.hidesBlockMarkers {
            let source = (textStorage?.string ?? "") as NSString
            definitionElisions = (
                parsedDocument.linkReferences.values.map(\.range)
                    + parsedDocument.footnotes.values.map(\.range)
            ).map { source.paragraphRange(for: $0) }
        } else {
            definitionElisions = []
        }
        fragmentContext.elision = ElisionPlan(
            elidedRanges: RangeSet.normalized(elision.elidedRanges + definitionElisions),
            forcedVisibleRanges: elision.forcedVisibleRanges
        )
        applyElidedAttribute()
        if rebuildingMap {
            rebuildDisplayMap(fullRefresh: true)
            gutterRail?.reload()
        }
    }

    private func applyElidedAttribute() {
        guard let storage = textStorage, storage.length > 0 else { return }
        // The common case by far is no zoom and no folds; sweeping the whole
        // document for that on every keystroke would be pure waste (§12).
        let definitionElisions: [NSRange]
        if effectivePolicy.hidesBlockMarkers {
            let source = storage.string as NSString
            definitionElisions = (
                parsedDocument.linkReferences.values.map(\.range)
                    + parsedDocument.footnotes.values.map(\.range)
            ).map { source.paragraphRange(for: $0) }
        } else {
            definitionElisions = []
        }
        let identity = elision.isIdentity && definitionElisions.isEmpty
        defer { elisionWasIdentity = identity }
        if identity && elisionWasIdentity { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.drElided, range: whole)
        for range in RangeSet.normalized(elision.elidedRanges + definitionElisions) {
            guard range.upperBound <= storage.length, range.length > 0 else { continue }
            storage.addAttribute(.drElided, value: true, range: range)
        }
        storage.endEditing()
    }

    private func unfoldHeadingsContaining(_ hits: [NSRange]) {
        guard !foldedHeadingSlugs.isEmpty, !hits.isEmpty else { return }
        var unfolded = foldedHeadingSlugs
        for heading in parsedDocument.headings where foldedHeadingSlugs.contains(heading.slug) {
            let body = ElisionPlan.bodyRange(of: heading)
            if hits.contains(where: { $0.location < body.upperBound && body.location < $0.upperBound }) {
                unfolded.remove(heading.slug)
            }
        }
        if unfolded != foldedHeadingSlugs { foldedHeadingSlugs = unfolded }
    }

    func expandElision(at offset: Int) {
        guard let range = elision.range(containing: offset) else { return }
        expandedElisionRanges.append(range)
        refreshElision()
    }

    // MARK: - Code block collapse (§5.1)

    public func setCodeBlockCollapsed(_ collapsed: Bool, at offset: Int) {
        codeCollapseOverrides[offset] = collapsed
        fragmentContext.collapseOverrides = codeCollapseOverrides
        invalidateAllFragments()
    }

    /// Collapse state for one block, without walking the document.
    func isCollapsed(_ payload: FragmentPayload) -> Bool {
        codeCollapseOverrides[payload.sourceRange.location] ?? payload.isCollapsed
    }

    // MARK: - Overlays: search, changes, paths

    private func reapplyOverlays(invalidating ranges: [NSRange], invalidateFragments: Bool = true) {
        guard let storage = textStorage, !ranges.isEmpty || !overlayRanges.isEmpty else { return }
        let blocks = RangeSet.normalized(ranges.compactMap { clampToStorage($0) })
        if !blocks.isEmpty {
            let dirty = DirtySet(ranges: blocks, isWholesale: false)
            // Decoration rewrites every attribute of the blocks it touches,
            // `drHidden` among them, and it cannot know what the display map
            // hides — that is the view's decision, taken per caret.  So the
            // mirror has to be laid back over exactly what decoration rewrote,
            // which is *wider* than the ranges asked for: it grows to whole
            // blocks.  Asking the engine keeps the two from disagreeing.
            //
            // Without this, an agent writing to the file wiped the mirror across
            // the blocks it changed: `drHidden` said "nothing hidden here" while
            // the map still hid those markers, so a rich-text copy or an HTML
            // export of a freshly-changed paragraph carried its raw syntax.
            let rewritten = engine.decoratedBounds(
                for: dirty, in: parsedDocument, length: storage.length)
            engine.decorate(storage, document: parsedDocument, dirty: dirty)
            rebuildDisplayMap(additionalScopes: rewritten)
        }
        applyOverlays()
        applyPathExistence()
        refreshBaseLayoutMap()
        if invalidateFragments {
            invalidateAllFragments()
        }
    }

    private func applyOverlays(scopes: [NSRange]? = nil) {
        guard let storage = textStorage, storage.length > 0 else { return }
        guard !searchHits.isEmpty || currentSearchHit != nil || !changeMarks.isEmpty || speechHighlight != nil else {
            overlayRanges = []
            // Cleared here too, or accepting the last change leaves its rule
            // painted beside a table nothing has changed in.
            objectChangeMarks = []
            return
        }
        func needsApplication(_ range: NSRange) -> Bool {
            guard let scopes else { return true }
            return scopes.contains { NSIntersectionRange($0, range).length > 0 }
        }
        storage.beginEditing()
        for hit in searchHits {
            guard let range = clampToStorage(hit), needsApplication(range) else { continue }
            storage.addAttribute(.drSearchHit, value: true, range: range)
            tint(styleSheet.searchHit, over: range, in: storage)
            setReadableForeground(over: range, background: styleSheet.searchHit, in: storage)
        }
        if let current = currentSearchHit, let range = clampToStorage(current),
           needsApplication(range) {
            storage.addAttribute(.drCurrentSearchHit, value: true, range: range)
            tint(styleSheet.searchHitCurrent, over: range, in: storage)
            setReadableForeground(over: range, background: styleSheet.searchHitCurrent, in: storage)
        }
        if let spoken = speechHighlight, let range = clampToStorage(spoken),
           needsApplication(range) {
            storage.addAttribute(.drSpeechHighlight, value: true, range: range)
            tint(styleSheet.searchHitCurrent, over: range, in: storage)
            setReadableForeground(over: range, background: styleSheet.searchHitCurrent, in: storage)
        }
        objectChangeMarks = []
        for mark in changeMarks {
            guard let range = clampToStorage(mark.range) else { continue }
            guard needsApplication(range) else {
                if mark.kind != .deleted,
                   glyphBearingRanges(in: range, storage: storage).isEmpty {
                    objectChangeMarks.append(mark)
                }
                continue
            }
            storage.addAttribute(.drChange, value: mark.kind.rawValue, range: range)
            if mark.kind == .deleted {
                // Removed text is not in the buffer, so there is nothing to
                // tint.  Carry the bytes on the anchor character instead and
                // let the rule in `drawDeletedChangeMarks` stand for them —
                // otherwise the one change the reader most needs to see, an
                // agent dropping a section, is the one the diff cannot show.
                storage.addAttribute(.drChangeGhost, value: mark.deletedText, range: range)
                continue
            }
            // §8.1: changed words are highlighted *in the rendered prose*,
            // never as +/- source lines.  A visited change dims rather than
            // disappearing, so the reader can still see what they reviewed.
            //
            // One encoding per fact.  A changed word used to carry a tint *and*
            // a full-strength underline in the change hue, on top of the margin
            // bar for its block and the pip for its section — four channels
            // saying one thing, and the underline is by far the loudest: a hard
            // rule in a saturated colour beneath every word, cutting through the
            // descenders it runs past.  On a section an agent rewrote whole,
            // that is not a highlight, it is damage.  The tint is the
            // highlighter idiom: it survives being applied to hundreds of words,
            // and it marks text instead of striking it.
            //
            // Colour alone is not an encoding every reader can see, so the
            // underline returns under Increase Contrast — there it *is* the
            // non-colour channel, and there the reader has asked for it.
            // Unread keeps the weight it was tuned at — the underline is what
            // was too loud, and dimming the tint at the same time would cost
            // signal the tint now carries alone.  Visited drops further instead,
            // so reviewing a change visibly costs it ink: the gap between "read
            // this" and "seen it" is the queue's only progress indicator, and at
            // 0.18 against 0.06 the two were nearly the same grey.
            let alpha: CGFloat = mark.visited ? 0.045 : 0.18
            let colour = styleSheet.changeColor(mark.kind).withAlphaComponent(alpha)
            var paintedAnything = false
            for word in mark.words {
                guard let wordRange = clampToStorage(word) else { continue }
                paintedAnything = tint(colour, over: wordRange, in: storage) || paintedAnything
                guard styleSheet.increaseContrast else { continue }
                let underline: NSUnderlineStyle = mark.kind == .inserted
                    ? .single
                    : [.single, .patternDash]
                storage.addAttributes([
                    .underlineStyle: underline.rawValue,
                    .underlineColor: styleSheet.changeColor(mark.kind),
                ], range: wordRange)
            }
            // A change inside a table, a diagram, or a collapsed block has no
            // glyphs to sit behind, so it gets a rule beside the object instead
            // of a tint that would land on the object's empty glyph box.
            if !paintedAnything {
                objectChangeMarks.append(mark)
            }
        }
        storage.endEditing()
        overlayRanges = searchHits + changeMarks.map(\.range) + [speechHighlight].compactMap { $0 }
    }

    /// Paints `colour` behind the parts of `range` that actually have glyphs on
    /// screen, and reports whether any of it did.
    ///
    /// A background colour is a *behind the text* effect, so it is only ever
    /// correct over text TextKit draws.  Applied blindly it also covered the
    /// runs that are hidden syntax and the ones a fragment draws itself, and
    /// there it painted a bare rectangle of colour — the stray shaded squares
    /// that appeared around tables, callout headers and diagrams whenever an
    /// agent wrote to the file.
    @discardableResult
    private func tint(_ colour: NSColor, over range: NSRange, in storage: NSTextStorage) -> Bool {
        var painted = false
        for visible in glyphBearingRanges(in: range, storage: storage) {
            storage.addAttribute(.backgroundColor, value: colour, range: visible)
            painted = true
        }
        return painted
    }

    private func setReadableForeground(
        over range: NSRange,
        background: NSColor,
        in storage: NSTextStorage
    ) {
        guard let rgb = background.usingColorSpace(.sRGB) else { return }
        let luminance = 0.2126 * rgb.redComponent
            + 0.7152 * rgb.greenComponent
            + 0.0722 * rgb.blueComponent
        let foreground = luminance > 0.55 ? NSColor.black : NSColor.white
        for visible in glyphBearingRanges(in: range, storage: storage) {
            storage.addAttribute(.foregroundColor, value: foreground, range: visible)
        }
    }

    /// `range` minus every run that is hidden syntax or drawn by an object
    /// fragment.
    private func glyphBearingRanges(in range: NSRange, storage: NSTextStorage) -> [NSRange] {
        var excluded: [NSRange] = []
        // The map, not only its mirror.  `.drHidden` is refreshed in caret-sized
        // scopes and `ParagraphSubstitution` documents a window where the two are
        // "briefly out of step" after an edit; what is on screen is decided by the
        // map, so a decision about what has glyphs asks the map directly.
        excluded.append(contentsOf: RangeSet.intersecting(baseHiddenRanges, range))
        storage.enumerateAttribute(.drHidden, in: range) { value, subrange, _ in
            if value != nil { excluded.append(subrange) }
        }
        storage.enumerateAttribute(.drFragment, in: range) { value, subrange, _ in
            guard let payload = value as? FragmentPayload, payload.kind.replacesGlyphs else { return }
            excluded.append(subrange)
        }
        guard !excluded.isEmpty else { return [range] }

        var out: [NSRange] = []
        var cursor = range.location
        for gap in RangeSet.normalized(excluded) {
            if gap.location > cursor {
                out.append(NSRange(location: cursor, length: gap.location - cursor))
            }
            cursor = max(cursor, gap.upperBound)
        }
        if cursor < range.upperBound {
            out.append(NSRange(location: cursor, length: range.upperBound - cursor))
        }
        return out
    }

    /// Deleted text has no extent in the buffer, so it gets a mark of its own:
    /// a short wedge in the margin at the join point, standing for the bytes
    /// that used to be there.  Hovering it names how much was removed; the
    /// context menu offers the text itself.
    ///
    /// Without this, an agent replacing a section — the case `SnapshotStore`'s
    /// own header calls the reason the feature exists — was the one change the
    /// document surface drew nothing at all for.
    private func drawDeletedChangeMarks(in dirtyRect: NSRect) {
        let deletions = changeMarks.filter { $0.kind == .deleted }
        guard !deletions.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let colour = styleSheet.changeColor(.deleted)
        let width: CGFloat = 3
        for mark in deletions {
            guard let rect = rect(forOffset: mark.range.location), rect.intersects(dirtyRect) else { continue }
            let wedge = NSRect(
                x: max(0, rect.minX - width - 2),
                y: rect.minY,
                width: width,
                height: max(4, min(rect.height, styleSheet.lineHeight))
            )
            context.setFillColor(colour.withAlphaComponent(mark.visited ? 0.35 : 0.9).cgColor)
            context.fill(wedge)
        }
    }

    /// A change the prose highlight could not express, because every word of it
    /// sits inside something drawn as an object — a table cell, a diagram, a
    /// collapsed block.
    ///
    /// Those get a rule down the left of the object's rows.  Without it the
    /// change is reported in the summary bar and the density rail and then
    /// cannot be found on the page, which is worse than the stray tint this
    /// replaced: at least that was visible.
    private func drawObjectChangeMarks(in dirtyRect: NSRect) {
        guard !objectChangeMarks.isEmpty, let context = NSGraphicsContext.current?.cgContext else { return }
        let width: CGFloat = 2
        for mark in objectChangeMarks {
            guard let start = rect(forOffset: mark.range.location),
                  let end = rect(forOffset: max(mark.range.location, mark.range.upperBound - 1))
            else { continue }
            let band = NSRect(
                x: max(0, start.minX - width - 6),
                y: start.minY,
                width: width,
                height: max(styleSheet.lineHeight, end.maxY - start.minY)
            )
            guard band.intersects(dirtyRect) else { continue }
            let colour = styleSheet.changeColor(mark.kind)
            context.setFillColor(colour.withAlphaComponent(mark.visited ? 0.3 : 0.75).cgColor)
            context.fill(band)
        }
    }

    /// §8.4's trust instrument: a path the agent claims it touched that is not
    /// there gets a dotted red underline.
    private func applyPathExistence(scopes: [NSRange]? = nil) {
        guard let storage = textStorage, !parsedDocument.pathTokens.isEmpty else { return }
        storage.beginEditing()
        for resolvable in parsedDocument.pathTokens {
            guard let range = clampToStorage(resolvable.range) else { continue }
            if let scopes,
               !scopes.contains(where: { NSIntersectionRange($0, range).length > 0 }) {
                continue
            }
            let exists: Bool
            if let cached = pathExistence[resolvable.token] {
                exists = cached
            } else {
                exists = markdownDelegate?.markdownTextView(self, pathExistsFor: resolvable.token) ?? true
                pathExistence[resolvable.token] = exists
            }
            storage.addAttribute(.drPathExists, value: exists, range: range)
            if exists {
                storage.addAttribute(.foregroundColor, value: styleSheet.textSecondary, range: range)
                storage.removeAttribute(.underlineStyle, range: range)
                storage.removeAttribute(.underlineColor, range: range)
            } else {
                storage.addAttributes([
                    .foregroundColor: styleSheet.textSecondary,
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                    .underlineColor: styleSheet.textFaint,
                ], range: range)
            }
        }
        storage.endEditing()
    }

    private func clampToStorage(_ range: NSRange) -> NSRange? {
        guard let storage = textStorage else { return nil }
        let lo = max(0, range.location)
        let hi = min(range.upperBound, storage.length)
        return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
    }

    // MARK: - Selection in source coordinates

    /// Selection converted out of TextKit's hybrid space (see `DisplayMap`).
    public var sourceSelectedRanges: [NSRange] {
        selectedRanges.map { displayMap.sourceRange(forTextKit: $0.rangeValue) }
    }

    public var sourceSelectedRange: NSRange {
        sourceSelectedRanges.first ?? NSRange(location: 0, length: 0)
    }

    /// Primary caret, or `nil` when there is no caret at all (Read mode) or
    /// the selection is not empty.
    public var primarySourceCaret: Int? {
        guard effectivePolicy.showsInsertionPoint else { return nil }
        guard let first = selectedRanges.first?.rangeValue, first.length == 0 else { return nil }
        return displayMap.sourceOffset(forTextKit: first.location)
    }

    public func setSourceSelectedRanges(_ ranges: [NSRange]) {
        let converted = ranges.map { NSValue(range: displayMap.textKitRange(forSource: $0)) }
        guard !converted.isEmpty else { return }
        isApplyingSelection = true
        super.setSelectedRanges(converted, affinity: .downstream, stillSelecting: false)
        isApplyingSelection = false
    }

    public override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelecting)
        guard !isApplyingSelection, !isPerformingSourceEdit,
              !isTrackingMouseSelection, !stillSelecting else { return }
        handleSelectionChanged()
    }

    /// The binding layer gets first crack at a key before the caret does, so a
    /// bound chord (⌥↓/⌥↑ change jumps, ⌘⌥ restructure, and — when the surface
    /// is read-only — the bare 1–5 zoom / `n`/`p` / vim letters) can run.  A
    /// key the host does not claim falls through to normal text editing.
    public override func keyDown(with event: NSEvent) {
        // Arrow and page keys move the viewport too, so they interrupt a
        // running scroll animation for the same reason a gesture does.
        interruptAnimatedScroll()
        if keyEventHandler?(event) == true { return }
        super.keyDown(with: event)
    }

    /// The caret moved, so the reveal set may have.  Order matters: capture the
    /// selection in source terms *before* the map changes under it, rebuild,
    /// then put it back.  Getting this backwards is exactly the caret drift
    /// §6.1 warns about.
    func handleSelectionChanged(allowTypewriterScrolling: Bool = true) {
        // A caret/selection gesture is newer than any queued layout pass. The
        // pass may still repair height, but it must not restore an old viewport.
        pendingResizeAnchor = nil
        // Revealing markers in the new caret paragraph and re-hiding them in
        // the old one can change wrapping above the viewport. Preserve the
        // visible source line through that rebuild; a raw clip y-coordinate
        // points at different content once TextKit resolves the new geometry.
        let sourceSelection = sourceSelectedRanges
        let viewportAnchor = sourceSelection.first.flatMap { selection -> ViewportAnchor? in
            guard selection.length == 0 else { return nil }
            return captureViewportAnchor(at: selection.location)
        } ?? captureViewportAnchor()
        fragmentContext.caret = suppressesCaretReveal ? nil : primarySourceCaret
        let previousAnchor = anchoredParagraph

        rebuildDisplayMap()
        restoreAnchorShift(previous: previousAnchor)
        applyCaretAnchorShift()

        let restored = sourceSelection.map { NSValue(range: displayMap.textKitRange(forSource: $0)) }
        if restored != selectedRanges {
            isApplyingSelection = true
            super.setSelectedRanges(restored, affinity: .downstream, stillSelecting: false)
            isApplyingSelection = false
        }
        restoreViewport(to: viewportAnchor)
        gutterRail?.needsDisplay = true
        markdownDelegate?.markdownTextViewDidChangeSelection(self)
        if allowTypewriterScrolling, !isTrackingMouseSelection,
           configuration.typewriterScrolling, let caret = primarySourceCaret,
           sourceSelectedRange.length == 0 {
            scroll(toOffset: caret, position: .center, animated: true)
        }
    }

    // MARK: - Caret-anchored reveal (§6.1c)

    /// Pins the character under the caret to its screen x-position by shifting
    /// the caret's paragraph left by exactly the width of the markers the
    /// reveal just put in front of it.  Markers then expand *around* the caret
    /// instead of pushing it.
    ///
    /// Exact for the caret's own line: the shift is the measured typographic
    /// width of the revealed marker runs that precede the caret, using the same
    /// attributes those runs will be drawn with.  Approximate in one case,
    /// named honestly: on a paragraph that wraps, the indent applies to every
    /// line of the paragraph, so the caret's line is pinned and the others move
    /// with it.  Vertical position never moves in any case, because block
    /// markers are never revealed inline and line height is fixed per block
    /// kind (§6.1a).
    private func applyCaretAnchorShift() {
        guard !suppressesCaretReveal, effectivePolicy.revealsAtCaret, let caret = primarySourceCaret,
              let storage = textStorage, storage.length > 0 else { return }
        let paragraph = paragraphIndex.paragraphRange(containing: caret)
        let revealed = MarkerPolicy.revealedMarkerRanges(
            document: parsedDocument, policy: effectivePolicy, caret: caret, selections: [])
            .filter { $0.upperBound <= caret && $0.location >= paragraph.location }
        guard !revealed.isEmpty else { return }

        var shift: CGFloat = 0
        for range in revealed {
            guard let clamped = clampToStorage(range) else { continue }
            shift += storage.attributedSubstring(from: clamped).size().width
        }
        guard shift > 0.5 else { return }
        shift = min(shift, RenderMetrics.revealSlack)

        guard let base = storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil)
                as? NSParagraphStyle,
              let adjusted = base.mutableCopy() as? NSMutableParagraphStyle else { return }
        adjusted.firstLineHeadIndent = base.firstLineHeadIndent - shift
        adjusted.headIndent = base.headIndent - shift

        storage.beginEditing()
        storage.addAttribute(.paragraphStyle, value: adjusted, range: paragraph)
        storage.endEditing()
        anchoredParagraph = paragraph
    }

    /// Restores the paragraph the anchor shift was on by re-running the
    /// decorator over it — one code path for "what should this paragraph look
    /// like", never a hand-rolled inverse.
    private func restoreAnchorShift(previous: NSRange?) {
        anchoredParagraph = nil
        guard let previous, let storage = textStorage, let range = clampToStorage(previous) else { return }
        engine.decorate(storage, document: parsedDocument,
                        dirty: DirtySet(ranges: [range], isWholesale: false))
        // The decorator rewrites the paragraph's attributes wholesale, which
        // drops the `.drHidden` mirror `rebuildDisplayMap` re-applied a moment
        // ago — so the paragraph the caret just left kept reporting its markers
        // as revealed for as long as the document stayed open, even though the
        // layout had correctly hidden them again.  Put the mirror back, from
        // the same map the layout used.
        applyHiddenAttribute(displayMap.hiddenRanges(inParagraphContaining: range.location),
                             scope: range)
        applyOverlays()
    }

    // MARK: - Geometry

    public func rect(forOffset offset: Int) -> NSRect? {
        let textKit = displayMap.textKitOffset(forSource: offset)
        guard let location = contentStorage.location(contentStorage.documentRange.location, offsetBy: textKit)
        else { return nil }
        let range = NSTextRange(location: location)
        markdownLayoutManager.ensureLayout(for: range)
        var found: NSRect?
        markdownLayoutManager.enumerateTextSegments(in: range, type: .standard, options: []) { _, frame, _, _ in
            found = frame
            return false
        }
        guard var rect = found else { return nil }
        let origin = textContainerOrigin
        rect.origin.x += origin.x
        rect.origin.y += origin.y
        return rect
    }

    public var topVisibleOffset: Int {
        let visible = enclosingScrollView?.documentVisibleRect ?? visibleRect
        let origin = textContainerOrigin
        // At the top of the document `visible.minY` sits above the text
        // container's vertical inset. Asking AppKit for an insertion index in
        // that empty band can return the current selection instead of the
        // first laid-out glyph, which made the sticky breadcrumb name a far
        // later heading while the title was on screen. Sample inside the
        // visible text container, never inside its padding.
        let sampleY = max(visible.minY, origin.y) + 1
        return sourceOffset(at: NSPoint(x: origin.x + 1, y: sampleY))
    }

    /// One-based source position for status UI. The paragraph index is rebuilt
    /// with each edit, so this stays O(log lines) and allocation-free instead
    /// of copying and splitting the whole prefix on every keystroke.
    public func sourcePosition(at offset: Int) -> (line: Int, column: Int) {
        let clamped = min(max(0, offset), paragraphIndex.length)
        let index = paragraphIndex.index(containing: clamped)
        return (
            line: index + 1,
            column: clamped - paragraphIndex.starts[index] + 1
        )
    }

    /// The programmatic scroll, as one spring on the clip's y.
    ///
    /// This replaces a bezier leg, an interrupt that reconstructed the curve's
    /// slope to recover a velocity, and a hand-rolled inertia coast to spend
    /// it — roughly ninety lines whose whole job was to rebuild the state a
    /// fixed-duration animation throws away.  A spring *is* that state, so:
    ///
    /// * a second jump mid-flight retargets rather than restarting, which is
    ///   what repeated Find-next and outline clicks do constantly;
    /// * the trip is always continuous, because velocity never resets;
    /// * a trackpad flick needs no synthetic handoff at all — the gesture
    ///   carries its own momentum, so the spring simply stands down.
    ///
    /// `perceptualDuration` is retuned per trip from `Motion.scrollDuration`.
    /// A spring's settle time is otherwise a constant, and a three-line hop
    /// and a cross-chapter descent should not cost the same: the distance
    /// scaling that the bezier had is kept, and only the discontinuity is
    /// thrown out.
    private var scrollSpring = Motion.SpringScalar(perceptualDuration: Motion.springDeliberate)
    private var scrollSpringIsActive = false
    private weak var scrollSpringClip: NSClipView?
    /// What the tick resolved, for `apply` to write. The driver keeps the two
    /// phases apart, and the scroll position is drawn state like any other.
    private var pendingScrollY: CGFloat?
    /// Live checkbox pulses from the last `advance` tick, for `apply`'s
    /// invalidation — the driver lift carries `advance`/`apply` phases apart.
    private var pendingMotionInvalidation: NSRect?

    /// DESIGN.md: "User scroll must interrupt animated scrolling." Without
    /// this, flicking the trackpad during the settle after a heading jump made
    /// the animation fight the gesture and yank the page back.
    ///
    /// A gesture supplies its own velocity, so the honest response is for the
    /// spring to stand down where it is rather than hand anything over: two
    /// owners writing the clip's origin in one frame is how a page ends up
    /// outrunning the fingers pushing it.
    func interruptAnimatedScroll() {
        guard scrollSpringIsActive else { return }
        scrollSpringIsActive = false
        scrollSpringClip = nil
        pendingScrollY = nil
        if let clip = enclosingScrollView?.contentView {
            // Re-base the spring on where the page actually is, so the next
            // trip starts from the truth rather than from an abandoned target.
            scrollSpring.snap(to: clip.bounds.origin.y)
        }
    }

    /// Whether this view is somewhere a display link will actually fire.
    /// Having a window is not enough — an unordered or offscreen window has no
    /// screen driving it, so a spring armed there ticks exactly never.
    var canDriveMotion: Bool {
        guard let window else { return false }
        return window.isVisible && window.screen != nil
    }

    /// The one driver for this document surface (§11.4).  Created on first
    /// arm; every closure here is weak-backed so the driver can never outlive
    /// the view it was made for.
    func armMotionDriver() {
        if let motionDriver {
            motionDriver.arm()
            return
        }
        let driver = Motion.SpringDriver(
            view: self,
            advance: { [weak self] dt in self?.documentMotionTick(dt: dt) ?? false },
            apply: { [weak self] in self?.documentMotionApply() }
        )
        motionDriver = driver
        driver.arm()
    }

    func parkMotionDriver() {
        motionDriver?.park()
        scrollSpringIsActive = false
        scrollSpringClip = nil
        pendingScrollY = nil
    }

    /// The display link follows the actual screen refresh rate and only
    /// invalidates the ornaments that are still animating.  Both document
    /// motions — the checkbox confirm pop and the scroll spring — step on the
    /// same clock, so neither can outlive the other or the view.
    func documentMotionTick(dt: CGFloat) -> Bool {
        var moving = false

        let now = CFAbsoluteTimeGetCurrent()
        let live = fragmentContext.checkboxPulses.filter {
            now - $0.started < CheckboxPulse.duration
        }
        if !live.isEmpty {
            pendingMotionInvalidation = pulseInvalidationRect(for: live.map(\.sourceRange))
            moving = true
        }

        if scrollSpringIsActive {
            guard let clip = scrollSpringClip ?? enclosingScrollView?.contentView else {
                scrollSpringIsActive = false
                return moving
            }
            var alive = scrollSpring.advance(dt: dt)
            // The document can grow or shrink under a trip — lazy TextKit
            // layout resolves above the viewport all the time — so the travel
            // is re-clamped every frame rather than only when it is planned.
            let maxY = max(0, (clip.documentView?.frame.height ?? 0) - clip.bounds.height)
            var y = scrollSpring.value
            if y < 0 || y > maxY {
                y = min(maxY, max(0, y))
                // Landing on an edge is an arrival, not a bounce: stop dead
                // rather than let the spring push against the end of the
                // document for the rest of its settle.
                scrollSpring.snap(to: y)
                alive = false
            }
            pendingScrollY = y
            scrollSpringIsActive = alive
            moving = moving || alive
        }
        return moving
    }

    func documentMotionApply() {
        if let y = pendingScrollY {
            pendingScrollY = nil
            // `clip.scroll(to:)` uses the TextKit 2 viewport controller, the
            // same entry point a non-animated jump uses; writing the bounds
            // origin directly would bypass it and leave lazily-rendered
            // fragments unresolved under the travelling viewport.
            if let clip = scrollSpringClip ?? enclosingScrollView?.contentView {
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                enclosingScrollView?.reflectScrolledClipView(clip)
            }
        }
        if let rect = pendingMotionInvalidation {
            pendingMotionInvalidation = nil
            setNeedsDisplay(rect)
        }
    }

    public override func scrollWheel(with event: NSEvent) {
        interruptAnimatedScroll()
        super.scrollWheel(with: event)
    }

    /// A live resize reflows the document under the viewport, so the y a trip
    /// was aiming at stops meaning what it meant when it was chosen.  Ground
    /// the trip rather than fly it to a stale destination.
    public override func viewWillStartLiveResize() {
        super.viewWillStartLiveResize()
        interruptAnimatedScroll()
    }

    public override func magnify(with event: NSEvent) {
        interruptAnimatedScroll()
        if event.phase == .began { textMagnificationAccumulator = 0 }
        textMagnificationAccumulator += event.magnification
        let stepThreshold: CGFloat = 0.075
        let steps = Int(textMagnificationAccumulator / stepThreshold)
        if steps != 0 {
            markdownDelegate?.markdownTextView(self, didRequestTextSizeSteps: steps)
            textMagnificationAccumulator -= CGFloat(steps) * stepThreshold
        }
        if event.phase == .ended || event.phase == .cancelled {
            textMagnificationAccumulator = 0
        }
    }

    public override func smartMagnify(with event: NSEvent) {
        interruptAnimatedScroll()
        markdownDelegate?.markdownTextViewDidRequestSmartTextZoom(self)
    }

    public override func swipe(with event: NSEvent) {
        interruptAnimatedScroll()
        super.swipe(with: event)
    }

    public func scroll(toOffset offset: Int, position: ScrollPosition, animated: Bool) {
        // Navigating into a folded section has to reveal it.  An elided offset
        // resolves to a zero-height fragment, so without this the outline, the
        // command palette and Back/Forward all silently did nothing.  Search
        // already makes exactly this exception.
        if elision.isElided(offset) {
            unfoldHeadingsContaining([NSRange(location: offset, length: 1)])
        }
        guard let rect = rect(forOffset: offset) else { return }
        guard let scrollView = enclosingScrollView else { scrollToVisible(rect); return }
        let clip = scrollView.contentView
        let height = clip.bounds.height

        var y: CGFloat
        switch position {
        case .top: y = rect.minY - RenderMetrics.verticalInset
        case .center: y = rect.midY - height / 2
        case .visible:
            if clip.bounds.intersects(rect) {
                // Already on screen: nothing to ask for.  A trip still in the
                // air is heading somewhere the last caller chose and will
                // glide there on its own — stopping it here would strand the
                // page mid-descent for no reason.
                return
            }
            y = rect.minY - height / 3
        }
        y = max(0, min(y, max(0, frame.height - height)))
        let target = CGPoint(x: clip.bounds.origin.x, y: y)
        let distance = abs(y - clip.bounds.origin.y)

        // §11.4: full respect for Reduce Motion.  `canDriveMotion` is the
        // third condition and not an optimisation: a display link is driven by
        // a screen, so in a window that is not on one the spring would arm and
        // then never tick, and a Find-next or an outline click would silently
        // do nothing.  No display, no journey — just arrive.
        if animated, !styleSheet.reduceMotion, distance > 0.5, canDriveMotion {
            // A trip already in the air keeps its position *and its speed*:
            // this is a change of destination, not a new journey.  Only a
            // standing start re-bases on where the page happens to be.
            if !scrollSpringIsActive {
                scrollSpring.snap(to: clip.bounds.origin.y)
            }
            scrollSpring.retune(perceptualDuration: Motion.scrollDuration(for: distance))
            scrollSpring.target(y)
            scrollSpringClip = clip
            scrollSpringIsActive = true
            armMotionDriver()
        } else {
            interruptAnimatedScroll()
            // Use the clip view's scrolling entry point instead of mutating
            // bounds directly. AppKit forwards this through the TextKit 2
            // viewport controller, which keeps lazily-rendered fragments in
            // sync with a programmatic jump.
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: - Layout plumbing

    public override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawDeletedChangeMarks(in: dirtyRect)
        drawObjectChangeMarks(in: dirtyRect)
        drawHoveredLinkUnderline(in: dirtyRect)
    }

    /// Underlines the link under the pointer.  Drawn after the text so it sits
    /// right on the baseline, with a hair of gap so descenders stay legible —
    /// the classic affordance for "this is interactive" (§7.1).
    private func drawHoveredLinkUnderline(in dirtyRect: NSRect) {
        guard textStorage != nil,
              let range = hoveredLinkRange,
              let clamped = clampToStorage(range), clamped.length > 0 else { return }
        let textKitRange = displayMap.textKitRange(forSource: clamped)
        guard textKitRange.length > 0 else { return }
        let origin = contentStorage.documentRange.location
        guard let start = contentStorage.location(origin, offsetBy: textKitRange.location),
              let end = contentStorage.location(origin, offsetBy: textKitRange.upperBound),
              let textRange = NSTextRange(location: start, end: end) else { return }
        markdownLayoutManager.ensureLayout(for: textRange)

        let path = NSBezierPath()
        path.lineWidth = 1
        markdownLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) {
            _, segmentRect, _, _ in
            let origin = self.textContainerOrigin
            let y = segmentRect.minY + origin.y - 1.5
            path.move(to: NSPoint(x: segmentRect.minX + origin.x, y: y))
            path.line(to: NSPoint(x: segmentRect.maxX + origin.x, y: y))
            return true
        }
        guard path.elementCount > 0 else { return }
        styleSheet.link.setStroke()
        path.stroke()
    }

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, storage.length > 0 else { return }

        discardBandCachesIfLayoutMoved()
        drawScopedSourceBackground(in: rect)
        let whole = NSRange(location: 0, length: storage.length)
        let visibleSourceRange = sourceRangeForDirtyRect(for: rect, storageLength: storage.length)
        let visible = visibleSourceRange ?? whole
        storage.enumerateAttribute(
            .drInlineCode,
            in: visible
        ) { value, range, _ in
            guard value != nil else { return }
            let bands: [CGRect]
            if let cached = self.inlineCodeBandCache[range] {
                bands = cached
            } else {
                bands = self.inlineCodePillBands(forSourceRange: range, in: storage)
                guard !bands.isEmpty else { return }
                self.inlineCodeBandCache[range] = bands
            }
            // Fill plus a hair of edge.  On a dark ground the fill alone is a
            // faint smudge that has to be pushed brighter to read at all, and
            // pushed brighter it turns into a slab; a 1px edge lets the fill stay
            // quiet and still bound the span.
            self.styleSheet.inlineCodeBackground.setFill()
            self.styleSheet.codeRule.withAlphaComponent(0.5).setStroke()
            for band in bands where band.intersects(rect) {
                let path = NSBezierPath(
                    roundedRect: band.insetBy(dx: 0.5, dy: 0.5),
                    xRadius: RenderMetrics.inlineCodeCornerRadius,
                    yRadius: RenderMetrics.inlineCodeCornerRadius
                )
                path.fill()
                path.lineWidth = 1
                path.stroke()
            }
        }
        drawInvisibles(in: visibleSourceRange ?? NSRange(location: 0, length: 0), dirtyRect: rect)
    }

    private func applyInvisibles(scopes: [NSRange]? = nil) {
        guard let storage = textStorage else { return }
        if !configuration.showInvisibles {
            guard invisiblesApplied, storage.length > 0 else { return }
            storage.removeAttribute(.drInvisible, range: NSRange(location: 0, length: storage.length))
            invisiblesApplied = false
            return
        }
        guard storage.length > 0 else { return }
        let ranges: [NSRange]
        if let scopes, !scopes.isEmpty {
            ranges = scopes
        } else {
            ranges = [NSRange(location: 0, length: storage.length)]
        }
        storage.beginEditing()
        for range in ranges {
            storage.removeAttribute(.drInvisible, range: range)
            let text = storage.string as NSString
            let end = min(range.upperBound, text.length)
            var offset = max(0, range.location)
            while offset < end {
                let value = text.character(at: offset)
                if value == 0x20 || value == 0x09 {
                    storage.addAttribute(.drInvisible, value: true, range: NSRange(location: offset, length: 1))
                }
                offset += 1
            }
        }
        storage.endEditing()
        invisiblesApplied = true
    }

    private func drawInvisibles(in sourceRange: NSRange, dirtyRect: NSRect) {
        guard configuration.showInvisibles, let storage = textStorage, sourceRange.length > 0 else { return }
        let textKitRange = displayMap.textKitRange(forSource: sourceRange)
        let origin = contentStorage.documentRange.location
        if let start = contentStorage.location(origin, offsetBy: textKitRange.location),
           let end = contentStorage.location(origin, offsetBy: textKitRange.upperBound),
           let range = NSTextRange(location: start, end: end) {
            markdownLayoutManager.ensureLayout(for: range)
        }
        let text = storage.string as NSString
        storage.enumerateAttribute(.drInvisible, in: sourceRange) { value, range, _ in
            guard value != nil else { return }
            for offset in range.location..<range.upperBound {
                guard offset < text.length,
                      storage.attribute(.drHidden, at: offset, effectiveRange: nil) == nil else { continue }
                let glyph: NSRect
                if let cached = self.invisibleGlyphCache[offset] {
                    glyph = cached
                } else {
                    guard let measured = self.rect(forOffset: offset) else { continue }
                    self.invisibleGlyphCache[offset] = measured
                    glyph = measured
                }
                guard glyph.intersects(dirtyRect) else { continue }
                let point = NSPoint(x: glyph.midX, y: glyph.midY)
                self.styleSheet.textFaint.setStroke()
                if text.character(at: offset) == 0x09 {
                    let arrow = NSBezierPath()
                    arrow.move(to: NSPoint(x: glyph.minX, y: point.y))
                    arrow.line(to: NSPoint(x: glyph.maxX, y: point.y))
                    arrow.line(to: NSPoint(x: glyph.maxX - 3, y: point.y - 2))
                    arrow.move(to: NSPoint(x: glyph.maxX, y: point.y))
                    arrow.line(to: NSPoint(x: glyph.maxX - 3, y: point.y + 2))
                    arrow.lineWidth = 1
                    arrow.stroke()
                } else {
                    self.styleSheet.textFaint.setFill()
                    NSBezierPath(ovalIn: NSRect(x: point.x - 1, y: point.y - 1, width: 2, height: 2)).fill()
                }
            }
        }
    }

    private func sourceRangeForDirtyRect(for rect: NSRect, storageLength: Int) -> NSRange? {
        guard rect.height > 0, storageLength > 0 else { return nil }
        let x = textContainerOrigin.x
        let top = characterIndexForInsertion(at: NSPoint(x: x, y: max(0, rect.minY)))
        let bottom = characterIndexForInsertion(at: NSPoint(x: x, y: max(0, rect.maxY)))
        let lower = min(displayMap.sourceOffset(forTextKit: top), displayMap.sourceOffset(forTextKit: bottom))
        let upper = max(displayMap.sourceOffset(forTextKit: top), displayMap.sourceOffset(forTextKit: bottom))
        guard upper > lower else { return nil }
        let start = max(0, lower - 1)
        let end = min(storageLength, upper + 1)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func drawScopedSourceBackground(in dirtyRect: NSRect) {
        guard case .scoped = sourceFocus, let band = sourceFocusBandRect,
              band.intersects(dirtyRect) else { return }

        styleSheet.surface.setFill()
        NSBezierPath(roundedRect: band, xRadius: 6, yRadius: 6).fill()
        styleSheet.rule.setStroke()
        let rule = NSBezierPath()
        rule.move(to: NSPoint(x: band.minX, y: band.minY + 24))
        rule.line(to: NSPoint(x: band.maxX, y: band.minY + 24))
        rule.lineWidth = 1
        rule.stroke()

        let labelAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: styleSheet.textSecondary,
        ]
        NSAttributedString(string: "Markdown", attributes: labelAttributes)
            .draw(at: NSPoint(x: band.minX + 8, y: band.minY + 5))
        let done = NSAttributedString(string: "Done", attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: styleSheet.accent,
        ])
        let size = done.size()
        done.draw(at: NSPoint(x: band.maxX - size.width - 8, y: band.minY + 5))
    }

    var sourceFocusBandRect: NSRect? {
        guard let range = sourceFocus.range,
              let start = rect(forOffset: range.location),
              let end = rect(forOffset: max(range.location, range.upperBound - 1)) else { return nil }
        let horizontalInset: CGFloat = 8
        let x = max(0, textContainerOrigin.x - horizontalInset)
        return NSRect(
            x: x,
            y: max(0, start.minY - 28),
            width: min(
                max(0, bounds.width - x),
                columnWidth + horizontalInset * 2
            ),
            height: max(styleSheet.lineHeight + 36, end.maxY - start.minY + 40)
        )
    }

    var sourceFocusDoneRect: NSRect? {
        guard let band = sourceFocusBandRect else { return nil }
        return NSRect(x: band.maxX - 56, y: band.minY, width: 56, height: 24)
    }

    /// Throws away cached geometry once the layout it was measured against has
    /// moved.  See `LayoutFingerprint`.
    private func discardBandCachesIfLayoutMoved() {
        let fingerprint = LayoutFingerprint(
            height: markdownLayoutManager.usageBoundsForTextContainer.height.rounded(),
            width: (textContainer?.size.width ?? 0).rounded(),
            generation: fragmentContext.layoutGeneration
        )
        guard fingerprint != bandCacheFingerprint else { return }
        bandCacheFingerprint = fingerprint
        inlineCodeBandCache.removeAll(keepingCapacity: true)
        invisibleGlyphCache.removeAll(keepingCapacity: true)
    }

    /// The pill geometry `drawBackground` paints for one `.drInlineCode` run:
    /// its bands, restricted to the parts of it TextKit actually draws.
    ///
    /// A pill is a *behind the glyphs* effect, so it obeys the same rule `tint`
    /// obeys.  A code span inside a table, a collapsed block, a diagram or an
    /// image has no glyphs on screen — the fragment draws that element itself,
    /// from its own cell layout — so asking TextKit for the span's segments
    /// returns geometry from the hidden linear layout instead, and the pill
    /// lands somewhere the reader can see but the text is not: a rounded
    /// rectangle of tint with nothing in it.  Those are the same stray shaded
    /// squares `glyphBearingRanges` was written for, one draw path further
    /// down, and a table full of `code` in its cells scatters a dozen of them.
    ///
    /// Internal rather than private so that rule is testable without a
    /// screenshot.
    func inlineCodePillBands(forSourceRange range: NSRange, in storage: NSTextStorage) -> [CGRect] {
        glyphBearingRanges(in: range, storage: storage)
            .flatMap { inlineCodeBands(forSourceRange: $0) }
    }

    /// The tinted bands behind an inline code span, one per visual line.
    ///
    /// Asks TextKit for the span's own laid-out segments rather than rebuilding
    /// them from two caret rects.  The old reconstruction could not tell a span
    /// that merely *ended* a line from one that wrapped — the caret after the
    /// last character has already moved to the next line — so a single-line
    /// span ending at a wrap painted a slab across the whole measure.
    private func inlineCodeBands(forSourceRange range: NSRange) -> [CGRect] {
        let startOffset = displayMap.textKitOffset(forSource: range.location)
        let endOffset = displayMap.textKitOffset(forSource: range.upperBound)
        guard endOffset > startOffset,
              let start = contentStorage.location(contentStorage.documentRange.location, offsetBy: startOffset),
              let end = contentStorage.location(contentStorage.documentRange.location, offsetBy: endOffset),
              let textRange = NSTextRange(location: start, end: end) else { return [] }
        markdownLayoutManager.ensureLayout(for: textRange)
        let origin = textContainerOrigin
        let padX: CGFloat = 3
        // No vertical padding: the segment is already a full line fragment tall,
        // and growing it further made the pills on consecutive lines touch, so a
        // paragraph carrying several code spans read as a column of joined tiles.
        let padY: CGFloat = 0
        var bands: [CGRect] = []
        markdownLayoutManager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            guard frame.width > 0.5 else { return true }
            var rect = frame
            rect.origin.x += origin.x
            rect.origin.y += origin.y
            bands.append(rect.insetBy(dx: -padX, dy: -padY))
            return true
        }
        return bands
    }

    /// The container is the reading measure plus a trailing bleed lane
    /// (§11.1).  Prose is held off it by a tail indent, so it still wraps at
    /// 68–72 characters; a fenced block, diagram, table, or display formula
    /// keeps the lane and gets the extra width.
    var columnWidth: CGFloat { styleSheet.measureWidth + RenderMetrics.codeBleed }

    private func applyMeasure() {
        // §11.1: measure capped at 68–72 characters.  The single most common
        // thing markdown viewers get wrong.
        textContainer?.size = CGSize(width: columnWidth, height: CGFloat.greatestFiniteMagnitude)
        fragmentContext.contentWidth = columnWidth
        minSize = NSSize(width: columnWidth, height: 0)
        maxSize = NSSize(width: columnWidth + RenderMetrics.revealSlack * 2,
                         height: CGFloat.greatestFiniteMagnitude)
        backgroundColor = styleSheet.background
        insertionPointColor = mode.policy.showsInsertionPoint ? styleSheet.accent : styleSheet.text
        selectedTextAttributes = [.backgroundColor: styleSheet.selection]
    }

    func applyResponsiveMeasure(_ width: CGFloat) {
        guard width > 100 else { return }
        let previousWidth = textContainer?.size.width ?? 0
        // Capture before the container changes: a width change reflows every
        // wrap below the fold, so the reading position has to be re-derived
        // from the anchor line rather than left at a now-meaningless pixel.
        let anchor = captureViewportAnchor()
        textContainer?.size = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        fragmentContext.contentWidth = width
        minSize = NSSize(width: width, height: 0)
        maxSize = NSSize(width: width + RenderMetrics.revealSlack * 2,
                         height: CGFloat.greatestFiniteMagnitude)
        if abs(previousWidth - width) > 0.5 {
            inlineCodeBandCache.removeAll(keepingCapacity: true)
            invisibleGlyphCache.removeAll(keepingCapacity: true)
            // A responsive measure changes every fragment's wrapping and
            // object frame. Invalidate the old TextKit 2 layout before a
            // saved deep position asks it to paint lazily.
            invalidateAllFragments()
            requestContentResize(.viewport, anchor: anchor)
        }
    }

    private func applyModeChrome() {
        isEditable = mode.policy.showsInsertionPoint
        isSelectable = true
        insertionPointColor = mode.policy.showsInsertionPoint ? styleSheet.accent : styleSheet.text
        typingAttributes = [
            .font: mode == .source ? styleSheet.monoFont() : styleSheet.bodyFont(),
            .foregroundColor: styleSheet.text,
        ]
        refreshSourceAccessibility()
    }

    private func applyTypographicSubstitution() {
        let enabled = configuration.typographicSubstitution
        isAutomaticQuoteSubstitutionEnabled = enabled
        isAutomaticDashSubstitutionEnabled = enabled
    }

    private func refreshSourceAccessibility() {
        if sourceFocus == .none {
            setAccessibilityLabel("Document editor")
            setAccessibilityHelp("Rendered Markdown document. Move the caret to edit in place.")
        } else {
            setAccessibilityLabel("Markdown source editor")
            setAccessibilityHelp("Raw Markdown is visible. Press Escape or choose Done to return to the document.")
        }
    }

    func invalidateAllFragments() {
        inlineCodeBandCache.removeAll(keepingCapacity: true)
        invisibleGlyphCache.removeAll(keepingCapacity: true)
        invalidateFragments(in: nil)
    }

    /// Scoped layout invalidation.  Invalidating the document range on every
    /// caret move would throw away the layout of a 5k-line file to reveal two
    /// asterisks (§12).
    func invalidateFragments(in sourceRange: NSRange?) {
        lastFragmentInvalidationRangeForTesting = sourceRange
        inlineCodeBandCache.removeAll(keepingCapacity: true)
        invisibleGlyphCache.removeAll(keepingCapacity: true)
        guard let sourceRange else {
            markdownLayoutManager.invalidateLayout(for: markdownLayoutManager.documentRange)
            needsDisplay = true
            gutterRail?.needsDisplay = true
            return
        }
        guard sourceRange.length > 0 else { return }
        let textKit = displayMap.textKitRange(forSource: sourceRange)
        let origin = contentStorage.documentRange.location
        guard let start = contentStorage.location(origin, offsetBy: textKit.location),
              let end = contentStorage.location(origin, offsetBy: textKit.upperBound),
              let range = NSTextRange(location: start, end: end) else {
            markdownLayoutManager.invalidateLayout(for: markdownLayoutManager.documentRange)
            needsDisplay = true
            return
        }
        markdownLayoutManager.invalidateLayout(for: range)
        needsDisplay = true
        gutterRail?.needsDisplay = true
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        motionDriver?.viewDidMoveToWindow(window: window)
        installHoverTracking()
        if window == nil {
            // Detached views must not keep driving a clip that may belong to
            // a recycled scroll view — ground the trip with the window.
            interruptAnimatedScroll()
        }
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        if let resignKeyObserver {
            NotificationCenter.default.removeObserver(resignKeyObserver)
            self.resignKeyObserver = nil
        }
        if let window {
            // Hover tracking is `.activeInKeyWindow`, so no `mouseExited`
            // arrives when the window stops being key with the pointer still
            // over a link — the underline, tooltip and copy button would stay
            // drawn on an inactive window.
            resignKeyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didResignKeyNotification,
                object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.clearHoverState() }
            }
        }
        if let scrollView = enclosingScrollView {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    // Coalesce: batch multiple rapid scroll events into one
                    // callback per run-loop iteration.  The gutter needs a
                    // redraw, but the density rail, breadcrumb, and pane sync
                    // can all wait until the next frame.
                    self.scrollCoalesceGeneration &+= 1
                    let generation = self.scrollCoalesceGeneration
                    let existing = self.scrollCoalesceWorkItem
                    self.scrollCoalesceWorkItem = DispatchWorkItem { [weak self] in
                        guard let self, self.scrollCoalesceGeneration == generation else { return }
                        self.scrollCoalesceWorkItem = nil
                        self.markdownDelegate?.markdownTextViewDidScroll(self)
                        self.handleScroll()
                    }
                    // Cancel the previous work item first so only the latest
                    // survives.  Posting async from the main queue means the
                    // block runs *after* the current AppKit event loop turn,
                    // letting all pending scroll events settle.
                    existing?.cancel()
                    if let item = self.scrollCoalesceWorkItem {
                        DispatchQueue.main.async(execute: item)
                    }
                    // Gutter redraw is cheap (just setNeedsDisplay) and
                    // latency-sensitive — run it immediately.
                    self.gutterRail?.needsDisplay = true
                }
            }
        }
    }

    /// Called once per coalesced scroll event.  The gutter rail already
    /// redrew; this handles everything else that can wait a frame.
    private func handleScroll() {
        guard let scrollView = enclosingScrollView else { return }
        let viewportHeight = scrollView.contentView.bounds.height
        let visibleMaxY = scrollView.documentVisibleRect.maxY
        let repairSlack = max(24, viewportHeight * 0.15)
        let pinnedToBottom = visibleMaxY >= frame.height - repairSlack
        if pendingShrinkRepair, !pinnedToBottom {
            // The viewport left the bottom edge — settle an over-tall
            // frame whose shrink was deferred so it never dropped the
            // page under the user's hands.
            pendingShrinkRepair = false
            requestContentResize(.scrollRepair)
            return
        }
        guard resizeNeedsRepair, pinnedToBottom else { return }
        requestContentResize(.scrollRepair)
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverTracking()
    }

    private func installHoverTracking() {
        refreshTrackingArea(
            &hoverTracking,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                      .activeInKeyWindow, .inVisibleRect]
        )
    }
}
