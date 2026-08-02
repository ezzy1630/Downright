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
            engine.policy = mode.policy
            fragmentContext.mode = mode
            applyModeChrome()
            rebuildEverything()
            requestContentResize(.viewport, anchor: anchor)
            setSourceSelectedRanges(selection)
            scroll(toOffset: anchor, position: .top, animated: false)
        }
    }

    public var styleSheet: StyleSheet {
        didSet {
            let anchor = topVisibleOffset
            engine.styleSheet = styleSheet
            fragmentContext.styleSheet = styleSheet
            fragmentContext.invalidateDerivedLayout()
            applyMeasure()
            applyModeChrome()
            rebuildEverything()
            requestContentResize(.viewport, anchor: anchor)
        }
    }

    /// §5.2.  A level change is an elision change, nothing more.
    public var zoomLevel: ZoomLevel = .everything {
        didSet {
            guard zoomLevel != oldValue else { return }
            refreshElision()
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
            reapplyOverlays(invalidating: previous + searchHits)
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

    // MARK: - Internals

    let engine: DecorationEngine
    let fragmentContext: FragmentContext
    private let substitution = ParagraphSubstitution()
    private var fragmentProvider: FragmentProvider!
    private let contentStorage: NSTextContentStorage
    private let markdownLayoutManager: NSTextLayoutManager

    /// Fully collapsed hidden set for the current document and policy, from
    /// which the caret-aware set is derived by subtraction (§12).
    private var baseHiddenRanges: [NSRange] = []
    /// The fully collapsed map for the document, rebuilt only when the text,
    /// the policy, or the parse changes.  Every caret move is an override on
    /// top of this rather than a rebuild of it (§12).
    private var baseDisplayMap: DisplayMap = .identity
    private var paragraphIndex: ParagraphIndex = .empty
    private var displayMap: DisplayMap = .identity
    private var elision: ElisionPlan = .none

    private var isApplyingSelection = false
    private var isPerformingSourceEdit = false
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
    private var hoverTracking: NSTrackingArea?
    private var scrollObserver: NSObjectProtocol?
    private var pendingResizeRequest: ContentResizeRequest?
    private var resizeWorkItem: DispatchWorkItem?
    var copiedCodeFeedbackWorkItem: DispatchWorkItem?
    private var resizeGeneration: UInt = 0
    private var pendingResizeAnchor: Int?
    private var resizeNeedsRepair = false

    // Test seam for the scheduler. It does not expose the view's layout
    // internals to the app target.
    var pendingResizeRequestForTesting: ContentResizeRequest? { pendingResizeRequest }
    /// Heading under the pointer, for the gutter's anchor glyph (§7.1).
    var hoveredHeadingIndex: Int?
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

        contentStorage = NSTextContentStorage()
        markdownLayoutManager = NSTextLayoutManager()
        let container = NSTextContainer(size: CGSize(width: styleSheet.measureWidth,
                                                     height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        markdownLayoutManager.textContainer = container
        contentStorage.addTextLayoutManager(markdownLayoutManager)
        contentStorage.textStorage = storage

        super.init(frame: frame, textContainer: container)

        contentStorage.delegate = substitution
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

        engine.policy = mode.policy
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
    }

    /// Used only by the convenience initialiser, so a text view can always be
    /// constructed — in tests, and in the Quick Look extension before the
    /// theme store has resolved anything (§10).
    public static func fallbackStyleSheet() -> StyleSheet {
        StyleSheet(theme: .fallback, appearance: NSAppearance.currentDrawing())
    }

    // MARK: - Document updates

    /// Re-decorates only what the AST diff says changed (§3.5).
    public func update(document: ParsedDocument, dirty: DirtySet) {
        let selection = sourceSelectedRanges
        let anchor = topVisibleOffset
        let currentMode = mode
        let isInitialUpdate = updateGeneration == 0
        let oldParagraphCount = paragraphIndex.starts.count
        parsedDocument = document
        updateGeneration &+= 1
        pathExistence.removeAll(keepingCapacity: true)
        fragmentContext.frontMatterFields = (document.frontMatter?.fields ?? []).map { ($0.key, $0.value) }
        fragmentContext.documentHasH1 = document.headings.contains { $0.level == 1 }
        rebuildParagraphIndex()

        guard let storage = textStorage else { return }
        engine.decorate(storage, document: document, dirty: dirty)
        baseHiddenRanges = engine.hiddenRanges(document: document, caret: nil, selections: [])
        baseDisplayMap = DisplayMap(paragraphs: paragraphIndex, hidden: baseHiddenRanges)
        refreshElision(rebuildingMap: false)
        rebuildDisplayMap(fullRefresh: true)
        applyOverlays()
        applyPathExistence()
        invalidateAllFragments()
        gutterRail?.reload()
        let resizeRequest: ContentResizeRequest
        if isInitialUpdate || dirty.isWholesale {
            resizeRequest = .immediate
        } else if paragraphIndex.starts.count != oldParagraphCount {
            resizeRequest = .lineCount
        } else {
            resizeRequest = .semantic
        }
        requestContentResize(resizeRequest, anchor: resizeRequest == .immediate ? nil : anchor)

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
        scroll(toOffset: min(max(0, anchor), document.length), position: .top, animated: false)
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
        guard let layoutManager = textLayoutManager else { return }
        layoutManager.ensureLayout(for: layoutManager.documentRange)

        let used = layoutManager.usageBoundsForTextContainer
        let viewportHeight = enclosingScrollView?.contentView.bounds.height ?? 0
        let height = max(used.maxY + textContainerInset.height + viewportHeight * 0.40, viewportHeight)
        guard abs(frame.height - height) > 0.5 else { return }
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
            self.resizeNeedsRepair = false
            self.resizeToFitContent()
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
        baseHiddenRanges = engine.hiddenRanges(document: parsedDocument, caret: nil, selections: [])
        baseDisplayMap = DisplayMap(paragraphs: paragraphIndex, hidden: baseHiddenRanges)
        refreshElision(rebuildingMap: false)
        rebuildDisplayMap(fullRefresh: true)
        applyOverlays()
        applyPathExistence()
        invalidateAllFragments()
        gutterRail?.reload()
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

    /// Used for the window between a text edit and the host's reparse.
    func resetDisplayMapToIdentity() {
        displayMap = DisplayMap(paragraphs: paragraphIndex, substitutions: [])
        baseDisplayMap = displayMap
        baseHiddenRanges = []
        substitution.displayMap = displayMap
        revealParagraph = nil
        invalidateAllFragments()
    }

    func beginSourceEdit() {
        isPerformingSourceEdit = true
        // The map is about to describe a string that no longer exists.  Drop it
        // rather than let the substitution delegate act on it mid-edit.
        substitution.displayMap = .identity
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
    private func rebuildDisplayMap(fullRefresh: Bool = false) {
        let caret = primarySourceCaret
        var hidden = baseHiddenRanges
        var revealedForAttributes: [NSRange] = []
        var requiresFullHiddenRefresh = false
        displayMap = baseDisplayMap

        if let composing = composingParagraph {
            // Composition suspends hiding in its paragraph so the hybrid and
            // source spaces coincide there and AppKit's marked-text
            // bookkeeping is exactly right.
            hidden = hidden.filter { $0.upperBound <= composing.location || $0.location >= composing.upperBound }
            displayMap = baseDisplayMap.replacingParagraph(containing: composing.location, with: [])
            requiresFullHiddenRefresh = caret == nil
        } else if mode.policy.revealsAtCaret {
            let revealed = MarkerPolicy.revealedMarkerRanges(
                document: parsedDocument, policy: mode.policy,
                caret: caret, selections: sourceSelectedRanges)
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
                if !revealed.isEmpty {
                    displayMap = baseDisplayMap.replacingParagraph(containing: paragraph.location,
                                                                    excluding: revealed)
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
                displayMap = DisplayMap(paragraphs: paragraphIndex, hidden: hidden)
                // A selection can span any number of paragraphs. The map was
                // rebuilt for the whole document, so its mirrored attributes
                // must use the same scope. This path is gesture-driven and is
                // not part of the insertion-caret hot path.
                requiresFullHiddenRefresh = true
            }
        }
        substitution.displayMap = displayMap

        let current = caret.map { paragraphIndex.paragraphRange(containing: $0) }
        let scope: NSRange?
        if fullRefresh || requiresFullHiddenRefresh {
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
        applyHiddenAttribute(hidden, scope: scope, excluding: revealedForAttributes)
        invalidateFragments(in: scope)
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
        fragmentContext.elision = elision
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
        let identity = elision.isIdentity
        defer { elisionWasIdentity = identity }
        if identity && elisionWasIdentity { return }
        let whole = NSRange(location: 0, length: storage.length)
        storage.beginEditing()
        storage.removeAttribute(.drElided, range: whole)
        for range in elision.elidedRanges {
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

    private func reapplyOverlays(invalidating ranges: [NSRange]) {
        guard let storage = textStorage, !ranges.isEmpty || !overlayRanges.isEmpty else { return }
        let blocks = RangeSet.normalized(ranges.compactMap { clampToStorage($0) })
        if !blocks.isEmpty {
            engine.decorate(storage, document: parsedDocument, dirty: DirtySet(ranges: blocks, isWholesale: false))
        }
        applyOverlays()
        applyPathExistence()
        invalidateAllFragments()
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
        guard mode.policy.showsInsertionPoint else { return nil }
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
        guard !isApplyingSelection, !isPerformingSourceEdit else { return }
        handleSelectionChanged()
    }

    /// The caret moved, so the reveal set may have.  Order matters: capture the
    /// selection in source terms *before* the map changes under it, rebuild,
    /// then put it back.  Getting this backwards is exactly the caret drift
    /// §6.1 warns about.
    private func handleSelectionChanged() {
        let sourceSelection = sourceSelectedRanges
        fragmentContext.caret = primarySourceCaret
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
        guard mode.policy.revealsAtCaret, let caret = primarySourceCaret,
              let storage = textStorage, storage.length > 0 else { return }
        let paragraph = paragraphIndex.paragraphRange(containing: caret)
        let revealed = MarkerPolicy.revealedMarkerRanges(
            document: parsedDocument, policy: mode.policy, caret: caret, selections: [])
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
        let point = CGPoint(x: 0, y: max(0, visible.minY - origin.y))
        guard let fragment = markdownLayoutManager.textLayoutFragment(for: point) else { return 0 }
        let textKit = contentStorage.offset(from: contentStorage.documentRange.location,
                                            to: fragment.rangeInElement.location)
        return displayMap.sourceOffset(forTextKit: textKit)
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
            clip.setBoundsOrigin(target)
            scrollView.reflectScrolledClipView(clip)
        }
    }

    // MARK: - Layout plumbing

    public override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, storage.length > 0 else { return }
        storage.enumerateAttribute(
            .drInlineCode,
            in: NSRange(location: 0, length: storage.length)
        ) { value, range, _ in
            guard value != nil,
                  let start = self.rect(forOffset: range.location),
                  let end = self.rect(forOffset: range.upperBound) else { return }
            let bands = self.inlineCodeBands(start: start, end: end)
            self.styleSheet.inlineCodeBackground.setFill()
            for band in bands where band.intersects(rect) {
                NSBezierPath(roundedRect: band, xRadius: 4, yRadius: 4).fill()
            }
        }
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
        insertionPointColor = styleSheet.accent
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
            requestContentResize(.viewport)
        }
    }

    private func applyModeChrome() {
        isEditable = mode.policy.showsInsertionPoint
        isSelectable = true
        insertionPointColor = styleSheet.accent
        typingAttributes = [
            .font: styleSheet.bodyFont(),
            .foregroundColor: styleSheet.text,
        ]
    }

    func invalidateAllFragments() {
        invalidateFragments(in: nil)
    }

    /// Scoped layout invalidation.  Invalidating the document range on every
    /// caret move would throw away the layout of a 5k-line file to reveal two
    /// asterisks (§12).
    func invalidateFragments(in sourceRange: NSRange?) {
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
                    guard self.resizeNeedsRepair,
                          let scrollView = self.enclosingScrollView else { return }
                    let viewportHeight = scrollView.contentView.bounds.height
                    let visibleMaxY = scrollView.documentVisibleRect.maxY
                    let repairSlack = max(24, viewportHeight * 0.15)
                    guard visibleMaxY >= self.frame.height - repairSlack else { return }
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
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverTracking = area
    }
}
