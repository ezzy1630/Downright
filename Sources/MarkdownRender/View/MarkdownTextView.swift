import AppKit
import MarkdownCore

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

    public private(set) var parsedDocument: ParsedDocument = .empty

    /// Instant, and preserves scroll position and selection (§3.2).
    public var mode: RenderMode = .live {
        didSet {
            guard mode != oldValue else { return }
            let anchor = topVisibleOffset
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
            scroll(toOffset: anchor, position: .top, animated: false)
            markdownDelegate?.markdownTextView(self, didChangeSourceFocus: sourceFocus)
        }
    }

    public var configuration = MarkdownRenderConfiguration() {
        didSet {
            guard configuration != oldValue else { return }
            let anchor = topVisibleOffset
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
            scroll(toOffset: anchor, position: .top, animated: false)
        }
    }

    /// Transient raw-Markdown visibility.  Never persisted by the render
    /// layer; hosts decide how its toolbar/menu affordance is presented.
    public internal(set) var sourceFocus: SourceFocus = .none

    public var styleSheet: StyleSheet {
        didSet {
            let anchor = topVisibleOffset
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

    /// Change marks from §8.1.
    public var changeMarks: [(kind: ChangeKind, range: NSRange, words: [NSRange])] = [] {
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
        let anchor = topVisibleOffset
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
            let anchor = topVisibleOffset
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
    var paragraphIndex: ParagraphIndex = .empty
    private var displayMap: DisplayMap = .identity
    private var hardWrapRanges: [NSRange] = []
    private var hardWrapSubstitutions: [DisplaySubstitution] = []
    private var elision: ElisionPlan = .none

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
    private var pathExistence: [PathToken: Bool] = [:]
    private var codeCollapseOverrides: [Int: Bool] = [:]
    /// Inline-code backgrounds are geometry, not text attributes. Cache their
    /// bands between background passes and discard them whenever layout can
    /// move. The draw path only populates entries intersecting the dirty
    /// viewport, so a long document does not measure every code span on every
    /// repaint.
    private var inlineCodeBandCache: [NSRange: [CGRect]] = [:]
    private var invisibleGlyphCache: [Int: NSRect] = [:]
    private var invisiblesApplied = false
    private var hoverTracking: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?
    private var pendingResizeRequest: ContentResizeRequest?
    private var resizeWorkItem: DispatchWorkItem?
    var copiedCodeFeedbackWorkItem: DispatchWorkItem?
    /// Drives the short checkbox confirm pop (§7.1) at a fixed cadence until
    /// every pulse has finished.
    var checkboxPulseTimer: Timer?
    private var resizeGeneration: UInt = 0
    private var pendingResizeAnchor: Int?
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

    private var effectivePolicy: DecorationPolicy {
        var policy = mode.policy
        policy.revealsAtCaret = configuration.revealPolicy != .never
        policy.revealsAtAllCursors = configuration.revealPolicy == .allCursors
        return policy
    }

    // Test seam for the scheduler. It does not expose the view's layout
    // internals to the app target.
    var pendingResizeRequestForTesting: ContentResizeRequest? { pendingResizeRequest }
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
        resizeWorkItem?.cancel()
        copiedCodeFeedbackWorkItem?.cancel()
        // A repeating 60fps timer on the main run loop would otherwise keep
        // firing forever after the view is gone: its block only ever
        // invalidates itself while `self` is still alive.
        checkboxPulseTimer?.invalidate()
        checkboxPulseTimer = nil
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
        let anchor = topVisibleOffset
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
        pathExistence.removeAll(keepingCapacity: true)
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
        rebuildDisplayMap(fullRefresh: isWholesaleUpdate, additionalScopes: dirtyScopes)
        applyOverlays()
        applyPathExistence()
        if isWholesaleUpdate {
            invalidateAllFragments()
        }
        gutterRail?.reload()
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
            anchor: resizeRequest == .immediate || followsLocalEdit ? nil : anchor
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
        // AppKit already owns the clip view during typing. Re-scrolling to a
        // source-derived top offset after every local parse re-resolves lazy
        // TextKit geometry and makes the whole page shudder. Vertical metrics
        // are fixed for inline edits, so leave the pixel viewport untouched;
        // real line growth still flows through the coalesced resize path.
        if !followsCaret, !followsLocalEdit {
            scroll(toOffset: min(max(0, anchor), document.length), position: .top, animated: false)
        }
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

    private func resizeToFitContent(layoutScope: ContentLayoutScope) {
        guard let layoutManager = textLayoutManager else { return }
        if case .viewport = layoutScope {
            repairContentHeightFromViewport(using: layoutManager)
            return
        }
        if let storage = textStorage,
           storage.length > configuration.largeFileThresholdMegabytes * 1024 * 1024 {
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
            setFrameSize(NSSize(width: frame.width, height: estimated))
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
        setFrameSize(NSSize(width: frame.width, height: height))
    }

    /// Structural zoom (§5.2): the document's extent changes as sections join
    /// or leave the projection.  The new height is resolved synchronously and
    /// then sprung into place on the layer, so the projection does not snap —
    /// it settles, the way a document opening or closing a drawer does.
    private func animateStructuralZoomHeight(from previousHeight: CGFloat) {
        resizeToFitContent(layoutScope: .document)
        let targetHeight = frame.height
        guard abs(targetHeight - previousHeight) > 0.5 else { return }
        wantsLayer = true
        guard let animationLayer = self.layer else { return }
        animationLayer.removeAnimation(forKey: "downrightStructuralZoom")
        let spring = CASpringAnimation(keyPath: "bounds.size.height")
        spring.fromValue = previousHeight
        spring.toValue = targetHeight
        spring.mass = 1
        spring.stiffness = 190
        spring.damping = 18
        spring.initialVelocity = 0
        spring.duration = spring.settlingDuration
        animationLayer.add(spring, forKey: "downrightStructuralZoom")
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
    private func requestContentResize(_ request: ContentResizeRequest, anchor: Int? = nil) {
        if let anchor { pendingResizeAnchor = anchor }
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
            if let anchor {
                self.scroll(toOffset: min(max(0, anchor), self.parsedDocument.length),
                            position: .top, animated: false)
            }
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
    }

    /// Theme colour / accent swaps that do not change typography.
    private func restyleAttributesPreservingGeometry() {
        guard let storage = textStorage else { return }
        engine.decorate(storage, document: parsedDocument, dirty: .wholesale)
        applySourcePresentation()
        applyOverlays()
        applyPathExistence()
        invalidateAllFragments()
        gutterRail?.reload()
        needsDisplay = true
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
                + hardWrapSubstitutions
        )
        // Selection / hit-testing speak TextKit coordinates from the layout map
        // (length-preserving joiners). Collapsed logical maps stay on the
        // substitution fallback path only.
        displayMap = layoutDisplayMap(from: baseDisplayMap)
        contentStorage.configure(
            paragraphIndex: paragraphIndex,
            reflowRanges: hardWrapRanges,
            displayMap: displayMap
        )
    }

    /// TextKit 2 elements keep source-length ranges even when Markdown syntax
    /// is visually omitted. Hidden runs become zero-width word joiners here;
    /// the logical map used by marker policy still collapses them for semantic
    /// selection and reveal decisions.
    private func layoutDisplayMap(from logical: DisplayMap) -> DisplayMap {
        let substitutions = logical.substitutions.map { substitution in
            guard !substitution.isHidden,
                  let replacement = substitution.replacement,
                  replacement.length < substitution.sourceRange.length,
                  replacement.attribute(.attachment, at: 0, effectiveRange: nil) != nil else {
                guard substitution.isHidden else { return substitution }
                let length = substitution.sourceRange.length
                let replacement = NSAttributedString(
                    string: String(repeating: "\u{2060}", count: length),
                    attributes: textStorage?.attributes(
                        at: substitution.sourceRange.location,
                        effectiveRange: nil
                    ) ?? [:]
                )
                return DisplaySubstitution(
                    sourceRange: substitution.sourceRange,
                    displayLength: length,
                    replacement: replacement,
                    isHidden: true,
                    preservesSourceOffsets: true
                )
            }
            let fillerCount = substitution.sourceRange.length - replacement.length
            let layoutReplacement = NSMutableAttributedString(attributedString: replacement)
            layoutReplacement.append(NSAttributedString(
                string: String(repeating: "\u{2060}", count: fillerCount),
                attributes: textStorage?.attributes(
                    at: substitution.sourceRange.location,
                    effectiveRange: nil
                ) ?? [:]
            ))
            return DisplaySubstitution(
                sourceRange: substitution.sourceRange,
                displayLength: substitution.sourceRange.length,
                replacement: layoutReplacement,
                preservesSourceOffsets: true
            )
        }
        return DisplayMap(paragraphs: paragraphIndex, substitutions: substitutions)
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
        let projection = SourceEditProjection(
            edit: edit,
            insertedLength: insertedLength,
            oldParagraphs: oldParagraphs
        )
        let projectedHidden = oldHiddenRanges.compactMap(projection.projectUnchanged)
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
                + projectedHardWrapSubstitutions
        )
        displayMap = layoutDisplayMap(from: baseDisplayMap)
        contentStorage.configure(
            paragraphIndex: paragraphIndex,
            reflowRanges: projectedHardWrapRanges,
            displayMap: displayMap
        )
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
        storage.beginEditing()
        storage.removeAttribute(.drFragment, range: affected)
        storage.removeAttribute(.drElided, range: affected)
        storage.endEditing()
        applyHiddenAttribute(projectedHidden, scope: affected)
        invalidateFragments(in: affected)
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
        let caret = suppressesCaretReveal ? nil : primarySourceCaret
        var hidden = baseHiddenRanges
        var revealedForAttributes: [NSRange] = []
        var requiresFullHiddenRefresh = false
        var logicalDisplayMap = baseDisplayMap

        if let composing = composingParagraph {
            // Composition suspends hiding in its paragraph so the hybrid and
            // source spaces coincide there and AppKit's marked-text
            // bookkeeping is exactly right.
            hidden = hidden.filter { $0.upperBound <= composing.location || $0.location >= composing.upperBound }
            let entries = baseDisplayMap.substitutions(inParagraphContaining: composing.location).filter { entry in
                !baseHiddenRanges.contains { hiddenRange in hiddenRange == entry.sourceRange }
            }
            logicalDisplayMap = baseDisplayMap.replacingParagraph(containing: composing.location, with: entries)
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
                    // Keep the cached document-wide set intact.  The display
                    // map and this exclusion list together describe the one
                    // paragraph that is currently revealed; no global filter
                    // is needed on a caret move.
                    revealedForAttributes = revealed
                }
                if !fullRefresh {
                    let affected = [paragraph, revealParagraph].compactMap { $0 }
                    hidden = RangeSet.normalized(affected.flatMap {
                        baseDisplayMap.hiddenRanges(inParagraphContaining: $0.location)
                    })
                }
            } else if !revealed.isEmpty {
                hidden = subtract(revealed, from: hidden)
                let revealedMapEntries = baseDisplayMap.substitutions.filter { entry in
                    !revealedDisplayObjects.contains { $0 == entry.sourceRange }
                }
                logicalDisplayMap = DisplayMap(paragraphs: paragraphIndex, substitutions: revealedMapEntries)
                // A selection can span any number of paragraphs. The map was
                // rebuilt for the whole document, so its mirrored attributes
                // must use the same scope. This path is gesture-driven and is
                // not part of the insertion-caret hot path.
                requiresFullHiddenRefresh = true
            }
        }
        substitution.displayMap = logicalDisplayMap
        displayMap = layoutDisplayMap(from: logicalDisplayMap)
        contentStorage.configure(
            paragraphIndex: paragraphIndex,
            reflowRanges: hardWrapRanges,
            displayMap: displayMap
        )

        let current = caret.map { paragraphIndex.paragraphRange(containing: $0) }
        let scope: NSRange?
        if fullRefresh || (requiresFullHiddenRefresh && additionalScopes.isEmpty) {
            scope = nil
        } else {
            switch (revealParagraph, current) {
            case (nil, nil): scope = NSRange(location: 0, length: 0)
            case (let a?, nil): scope = a
            case (nil, let b?): scope = b
            case (let a?, let b?): scope = a.union(b)
            }
        }
        revealParagraph = current
        if fullRefresh || (requiresFullHiddenRefresh && additionalScopes.isEmpty) {
            applyHiddenAttribute(hidden, scope: nil, excluding: revealedForAttributes)
            invalidateFragments(in: nil)
        } else {
            let scopes = RangeSet.normalized(additionalScopes + [scope].compactMap { $0 })
            for scope in scopes {
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
        elision = ElisionPlan.make(
            document: parsedDocument, zoom: zoomLevel,
            foldedHeadingSlugs: foldedHeadingSlugs, searchHits: searchHits,
            caret: primarySourceCaret, selections: sourceSelectedRanges)
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

    public func toggleFold(headingSlug: String) {
        if foldedHeadingSlugs.contains(headingSlug) { foldedHeadingSlugs.remove(headingSlug) }
        else { foldedHeadingSlugs.insert(headingSlug) }
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

    public func collapsedCodeBlockOffsets() -> Set<Int> {
        var out: Set<Int> = []
        guard let storage = textStorage else { return out }
        storage.enumerateAttribute(.drFragment, in: NSRange(location: 0, length: storage.length)) { value, range, _ in
            guard let payload = value as? FragmentPayload,
                  payload.kind == .codeBlock || payload.kind == .collapsedCodeBlock,
                  range.location == payload.sourceRange.location else { return }
            let collapsed = codeCollapseOverrides[payload.sourceRange.location] ?? payload.isCollapsed
            if collapsed { out.insert(payload.sourceRange.location) }
        }
        return out
    }

    // MARK: - Overlays: search, changes, paths

    private func reapplyOverlays(invalidating ranges: [NSRange], invalidateFragments: Bool = true) {
        guard let storage = textStorage, !ranges.isEmpty || !overlayRanges.isEmpty else { return }
        let blocks = RangeSet.normalized(ranges.compactMap { clampToStorage($0) })
        if !blocks.isEmpty {
            engine.decorate(storage, document: parsedDocument, dirty: DirtySet(ranges: blocks, isWholesale: false))
        }
        applyOverlays()
        applyPathExistence()
        if invalidateFragments {
            invalidateAllFragments()
        }
    }

    private func applyOverlays() {
        guard let storage = textStorage, storage.length > 0 else { return }
        guard !searchHits.isEmpty || currentSearchHit != nil || !changeMarks.isEmpty || speechHighlight != nil else {
            overlayRanges = []
            return
        }
        storage.beginEditing()
        for hit in searchHits {
            guard let range = clampToStorage(hit) else { continue }
            storage.addAttributes([
                .drSearchHit: true,
                .backgroundColor: styleSheet.searchHit,
            ], range: range)
        }
        if let current = currentSearchHit, let range = clampToStorage(current) {
            storage.addAttributes([
                .drCurrentSearchHit: true,
                .backgroundColor: styleSheet.searchHitCurrent,
            ], range: range)
        }
        if let spoken = speechHighlight, let range = clampToStorage(spoken) {
            storage.addAttributes([
                .drSpeechHighlight: true,
                .backgroundColor: styleSheet.searchHitCurrent,
            ], range: range)
        }
        for mark in changeMarks {
            guard let range = clampToStorage(mark.range) else { continue }
            storage.addAttribute(.drChange, value: mark.kind.rawValue, range: range)
            // §8.1: changed words are highlighted *in the rendered prose*,
            // never as +/- source lines.
            for word in mark.words {
                guard let wordRange = clampToStorage(word) else { continue }
                storage.addAttribute(.backgroundColor,
                                     value: styleSheet.changeColor(mark.kind).withAlphaComponent(0.18),
                                     range: wordRange)
            }
        }
        storage.endEditing()
        overlayRanges = searchHits + changeMarks.map(\.range) + [speechHighlight].compactMap { $0 }
    }

    /// §8.4's trust instrument: a path the agent claims it touched that is not
    /// there gets a dotted red underline.
    private func applyPathExistence() {
        guard let storage = textStorage, !parsedDocument.pathTokens.isEmpty else { return }
        storage.beginEditing()
        for resolvable in parsedDocument.pathTokens {
            guard let range = clampToStorage(resolvable.range) else { continue }
            let exists: Bool
            if let cached = pathExistence[resolvable.token] {
                exists = cached
            } else {
                exists = markdownDelegate?.markdownTextView(self, pathExistsFor: resolvable.token) ?? true
                pathExistence[resolvable.token] = exists
            }
            storage.addAttribute(.drPathExists, value: exists, range: range)
            if exists {
                storage.addAttribute(.foregroundColor, value: styleSheet.accent, range: range)
            } else {
                storage.addAttributes([
                    .foregroundColor: styleSheet.pathMissing,
                    .underlineStyle: NSUnderlineStyle.patternDot.rawValue | NSUnderlineStyle.single.rawValue,
                    .underlineColor: styleSheet.pathMissing,
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

    /// The caret moved, so the reveal set may have.  Order matters: capture the
    /// selection in source terms *before* the map changes under it, rebuild,
    /// then put it back.  Getting this backwards is exactly the caret drift
    /// §6.1 warns about.
    func handleSelectionChanged(allowTypewriterScrolling: Bool = true) {
        // A caret/selection gesture is newer than any queued layout pass. The
        // pass may still repair height, but it must not restore an old viewport.
        pendingResizeAnchor = nil
        let sourceSelection = sourceSelectedRanges
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

    public func scroll(toOffset offset: Int, position: ScrollPosition, animated: Bool) {
        guard let rect = rect(forOffset: offset) else { return }
        guard let scrollView = enclosingScrollView else { scrollToVisible(rect); return }
        let clip = scrollView.contentView
        let height = clip.bounds.height

        var y: CGFloat
        switch position {
        case .top: y = rect.minY - RenderMetrics.verticalInset
        case .center: y = rect.midY - height / 2
        case .visible:
            if clip.bounds.intersects(rect) { return }
            y = rect.minY - height / 3
        }
        y = max(0, min(y, max(0, frame.height - height)))
        let target = CGPoint(x: clip.bounds.origin.x, y: y)

        // §11.4: full respect for Reduce Motion.
        if animated && !styleSheet.reduceMotion {
            Motion.run(
                reduceMotion: false,
                duration: Motion.deliberate,
                curve: .spring,
                changes: { _ in clip.animator().setBoundsOrigin(target) },
                completion: { scrollView.reflectScrolledClipView(clip) }
            )
        } else {
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
                guard let start = self.rect(forOffset: range.location),
                      let end = self.rect(forOffset: range.upperBound) else { return }
                bands = self.inlineCodeBands(start: start, end: end)
                self.inlineCodeBandCache[range] = bands
            }
            self.styleSheet.inlineCodeBackground.setFill()
            for band in bands where band.intersects(rect) {
                NSBezierPath(roundedRect: band, xRadius: 4, yRadius: 4).fill()
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
                styleSheet.measureWidth + horizontalInset * 2
            ),
            height: max(styleSheet.lineHeight + 36, end.maxY - start.minY + 40)
        )
    }

    var sourceFocusDoneRect: NSRect? {
        guard let band = sourceFocusBandRect else { return nil }
        return NSRect(x: band.maxX - 56, y: band.minY, width: 56, height: 24)
    }

    private func inlineCodeBands(start: CGRect, end: CGRect) -> [CGRect] {
        let padX: CGFloat = 3
        let padY: CGFloat = 1
        if abs(start.minY - end.minY) < 1 {
            return [CGRect(
                x: start.minX - padX,
                y: start.minY - padY,
                width: max(1, end.minX - start.minX + padX * 2),
                height: max(start.height, end.height) + padY * 2
            )]
        }

        var bands: [CGRect] = []
        let lineHeight = max(1, styleSheet.lineHeight)
        bands.append(CGRect(
            x: start.minX - padX,
            y: start.minY - padY,
            width: max(1, bounds.maxX - start.minX),
            height: start.height + padY * 2
        ))
        var y = start.minY + lineHeight
        while y + lineHeight / 2 < end.minY {
            bands.append(CGRect(x: 0, y: y - padY, width: bounds.width, height: lineHeight + padY * 2))
            y += lineHeight
        }
        bands.append(CGRect(
            x: 0,
            y: end.minY - padY,
            width: max(1, end.minX + padX),
            height: end.height + padY * 2
        ))
        return bands
    }

    private func applyMeasure() {
        // §11.1: measure capped at 68–72 characters.  The single most common
        // thing markdown viewers get wrong.
        textContainer?.size = CGSize(width: styleSheet.measureWidth, height: CGFloat.greatestFiniteMagnitude)
        fragmentContext.contentWidth = styleSheet.measureWidth
        minSize = NSSize(width: styleSheet.measureWidth, height: 0)
        maxSize = NSSize(width: styleSheet.measureWidth + RenderMetrics.revealSlack * 2,
                         height: CGFloat.greatestFiniteMagnitude)
        backgroundColor = styleSheet.background
        insertionPointColor = mode.policy.showsInsertionPoint ? styleSheet.accent : styleSheet.text
        selectedTextAttributes = [.backgroundColor: styleSheet.selection]
    }

    func applyResponsiveMeasure(_ width: CGFloat) {
        guard width > 100 else { return }
        let previousWidth = textContainer?.size.width ?? 0
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
            requestContentResize(.viewport)
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
        installHoverTracking()
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        if let scrollView = enclosingScrollView {
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.gutterRail?.needsDisplay = true
                    self.markdownDelegate?.markdownTextViewDidScroll(self)
                    guard let scrollView = self.enclosingScrollView else { return }
                    let viewportHeight = scrollView.contentView.bounds.height
                    let visibleMaxY = scrollView.documentVisibleRect.maxY
                    let repairSlack = max(24, viewportHeight * 0.15)
                    let pinnedToBottom = visibleMaxY >= self.frame.height - repairSlack
                    if self.pendingShrinkRepair, !pinnedToBottom {
                        // The viewport left the bottom edge — settle an over-tall
                        // frame whose shrink was deferred so it never dropped the
                        // page under the user's hands.
                        self.pendingShrinkRepair = false
                        self.requestContentResize(.scrollRepair)
                        return
                    }
                    guard self.resizeNeedsRepair, pinnedToBottom else { return }
                    self.requestContentResize(.scrollRepair)
                }
            }
        }
    }

    public override func updateTrackingAreas() {
        super.updateTrackingAreas()
        installHoverTracking()
    }

    private func installHoverTracking() {
        if let hoverTracking { removeTrackingArea(hoverTracking) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate,
                      .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }
}
