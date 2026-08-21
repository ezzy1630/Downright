import AppKit
import MarkdownCore

/// What one `decorate` call did.  Counts rather than ranges: the engine is on
/// the keystroke path (§12) and building a report object per edit would be the
/// kind of cost that makes the budget by accident and misses it later.
public struct DecorationResult: Sendable {
    /// Number of attribute applications performed.
    public var attributeRanges: Int
    public var fragmentCount: Int
    public var elapsed: TimeInterval

    public init(attributeRanges: Int = 0, fragmentCount: Int = 0, elapsed: TimeInterval = 0) {
        self.attributeRanges = attributeRanges
        self.fragmentCount = fragmentCount
        self.elapsed = elapsed
    }
}

/// Turns a `ParsedDocument` into attributes on an `NSTextStorage`.
///
/// **The invariant this whole file exists to hold: it never mutates a single
/// character** (§3.1).  `decorate` calls `setAttributes` and `addAttributes`
/// and nothing else, so a file that passes through Downright is byte-identical
/// on the way out, including its odd spacing and its trailing newline.  Marker
/// *hiding* is not this type's job — it is a display-string substitution
/// driven by `hiddenRanges` and `DisplayMap`, which is why it cannot leak into
/// the storage.
///
/// §14's warning is taken literally as well: nothing dynamic goes through
/// `NSTextLayoutManager.addRenderingAttribute`.  Everything is on the storage.
public final class DecorationEngine {

    // MARK: Configuration

    /// Assigning always rebuilds the derived styles and drops the cache.
    /// `StyleSheet.revision` tracks the *theme store*, not the resolved sheet,
    /// so it cannot distinguish a light/dark switch from no change at all —
    /// and a stale cached font is worse than a rebuild that costs microseconds
    /// on a path that runs when the user changes theme, not when they type.
    public var styleSheet: StyleSheet {
        didSet {
            styles = BlockStyleFactory(styleSheet: styleSheet)
            cachedSeparatorStyle = nil
            programCache.removeAll(keepingCapacity: true)
            programSeen.removeAll(keepingCapacity: true)
            syntaxCache.removeAll()
        }
    }

    public var policy: DecorationPolicy {
        didSet {
            guard policy != oldValue else { return }
            programCache.removeAll(keepingCapacity: true)
            programSeen.removeAll(keepingCapacity: true)
        }
    }

    public var codeCollapseLineCount: Int {
        get { collapseLineCount }
        set { collapseLineCount = min(10_000, max(1, newValue)) }
    }

    private let highlighter: SyntaxHighlighter
    private var collapseLineCount = RenderMetrics.codeCollapseLineCount
    private var styles: BlockStyleFactory
    private let syntaxCache = SyntaxRunCache()

    // MARK: Source-mode typography (§3.2)

    /// Set for the duration of one `decorate` call whose `.font`, `.ligature`
    /// and `.paragraphStyle` output is guaranteed to be thrown away before
    /// anything can read it.
    ///
    /// Switching the one text surface into Source is a wholesale pass under the
    /// Source policy followed — in the same turn, before any layout — by the
    /// view's whole-document source presentation, which rewrites the font and
    /// one uniform paragraph style over *every* character.  So the heading
    /// faces, the list indents, the code row hangs and the per-paragraph styles
    /// this file computes on that path exist for microseconds and are then
    /// overwritten.  They are not free to compute: each one is a paragraph walk
    /// and an attribute run split that the source pass then has to walk back
    /// over, which is why the switch cost grew with the document rather than
    /// with what changed.
    ///
    /// Everything that is *not* typography still has to be produced here —
    /// foreground colours, marker highlighting, code syntax runs, links,
    /// fragments, block identity — because nothing downstream re-establishes
    /// any of it.  `apply` enforces that split in one place rather than trusting
    /// each call site to remember it.
    private var discardsTypography = false

    /// The policy shape Source mode uses: markers styled in place rather than
    /// hidden, and nothing rendered as an object.  Live and Read both hide
    /// markers and both render fragments, so this cannot be true for either.
    private var policyIsSourceShaped: Bool {
        !policy.rendersFragments && !policy.hidesBlockMarkers && !policy.hidesInlineMarkers
    }

    public init(styleSheet: StyleSheet, highlighter: SyntaxHighlighter = BuiltinSyntaxHighlighter.shared) {
        self.styleSheet = styleSheet
        self.highlighter = highlighter
        self.styles = BlockStyleFactory(styleSheet: styleSheet)
        self.policy = RenderMode.read.policy
    }

    // MARK: Per-block program cache (§12)

    /// One attribute application, with `range` relative to the block's start so
    /// a cached program survives the block moving because text above it
    /// changed.
    private struct AttributeOp {
        var range: NSRange
        var attributes: [NSAttributedString.Key: Any]
    }

    private struct ProgramKey: Hashable {
        var hash: UInt64
        var kind: Int
        var listDepth: Int
        var quoteDepth: Int
        var length: Int
        /// A task label reserves the checkbox column, a bullet does not
        /// (§11.3).  Two paragraphs with identical text at the same depth hash
        /// identically (the subtree hash covers the label, not the marker), so
        /// the key must carry the task bit or the cache records the wrong
        /// marker column for one of them.
        var task: Bool
        /// A program recorded during a wholesale Source pass carries no font
        /// and no paragraph style, because the source presentation was about
        /// to overwrite both.  Replaying that program anywhere else leaves the
        /// paragraph with no typography at all, so the two shapes must never
        /// share an entry — the policy change that ends Source mode already
        /// drops the cache, but an incremental commit *inside* Source mode does
        /// not, and that is the one that would have hit a stale entry.
        var plainTypography: Bool
    }

    private var programCache: [ProgramKey: [AttributeOp]] = [:]
    /// Keys seen exactly once.  Recording a program costs a scratch pass, so a
    /// block is only worth caching the *second* time it appears — in a
    /// document of all-unique paragraphs the recorder would otherwise double
    /// the work of every wholesale pass and never pay it back.
    private var programSeen: Set<ProgramKey> = []
    private let programCacheCapacity = 4096

    // MARK: - Decorate

    /// The ranges `decorate` will actually rewrite, which are wider than the
    /// dirty set: each range grows to whole blocks.
    ///
    /// Published because decoration *wipes* the attributes it is about to
    /// rewrite, and one of them — `drHidden` — is not the engine's to know: what
    /// is hidden is the view's decision, taken per caret.  The view therefore has
    /// to lay its mirror back over exactly this much, and computing the bounds a
    /// second time from the same rule is how the two come to disagree.
    public func decoratedBounds(for dirty: DirtySet, in document: ParsedDocument, length: Int) -> [NSRange] {
        let full = NSRange(location: 0, length: length)
        guard full.length > 0 else { return [] }
        guard !dirty.isWholesale else { return [full] }
        return RangeSet.normalized(dirty.ranges.compactMap { clip(blockBounds(of: $0, in: document), to: full) })
    }

    /// Applies attributes for the given source ranges.  `dirty.isWholesale`
    /// means redecorate everything.
    @discardableResult
    public func decorate(_ storage: NSTextStorage, document: ParsedDocument, dirty: DirtySet) -> DecorationResult {
        let started = CFAbsoluteTimeGetCurrent()
        let full = NSRange(location: 0, length: storage.length)
        guard full.length > 0 else { return DecorationResult(elapsed: CFAbsoluteTimeGetCurrent() - started) }

        // Settle the document's direction before any paragraph style is built.
        // The factory drops its cache only when the answer actually changes, so
        // for the overwhelmingly common case — an edit that leaves the opening
        // sentence alone — this costs one bounded scan and nothing else.
        styles.baseWritingDirection = WritingDirection.of(document.text)

        let targets: [NSRange]
        if dirty.isWholesale {
            targets = [full]
        } else if dirty.ranges.isEmpty {
            return DecorationResult(elapsed: CFAbsoluteTimeGetCurrent() - started)
        } else {
            // Grow each dirty range to whole blocks: a paragraph's style is a
            // property of the paragraph, not of the characters that changed.
            targets = RangeSet.normalized(dirty.ranges.compactMap { clip(blockBounds(of: $0, in: document), to: full) })
        }
        guard !targets.isEmpty else { return DecorationResult(elapsed: CFAbsoluteTimeGetCurrent() - started) }

        // Only a *wholesale* Source pass earns the shortcut.  An incremental
        // commit in Source mode re-decorates whole blocks while the source
        // presentation is re-applied over the narrower ranges the diff
        // reported, so typography dropped here would not be put back over the
        // rest of those blocks.
        discardsTypography = dirty.isWholesale && policyIsSourceShaped
        defer { discardsTypography = false }

        var state = DecorateState(document: document, storage: storage)
        state.documentBase = documentBaseAttributes()

        storage.beginEditing()
        for target in targets {
            // Wipe first so no attribute from a previous parse survives; the
            // walk below re-establishes everything inside `target`.  Text that
            // belongs to no block at all (the blank lines between them) keeps
            // the document base and therefore the body metrics.
            storage.setAttributes(state.documentBase, range: target)
            state.attributeRanges += 1
            state.target = target
            for childIndex in Self.intersectingChildIndices(document.root.children, target: state.target) {
                walk(document.root.children[childIndex], context: .root, state: &state)
            }
            collapseSeparators(state: &state)
        }
        storage.endEditing()

        if programCache.count > programCacheCapacity {
            programCache.removeAll(keepingCapacity: true)
            programSeen.removeAll(keepingCapacity: true)
        }

        return DecorationResult(
            attributeRanges: state.attributeRanges,
            fragmentCount: state.fragmentCount,
            elapsed: CFAbsoluteTimeGetCurrent() - started
        )
    }

    // MARK: - Block separators

    /// Blank lines *between* blocks are separators, not content.
    ///
    /// Markdown puts a blank line between every pair of blocks, and those lines
    /// belong to no block — so left alone they keep the document's body metrics
    /// and each costs a full line box.  On a 35KB document that is around a
    /// thousand empty lines, roughly two thirds of the laid-out height.  The
    /// visible result is a page spaced out like a collection of essays, and a
    /// scroll range mostly pointing at nothing: scroll into it, or restore a
    /// reading position that lands in it (§8.2), and the viewport can contain
    /// no text at all while the breadcrumb still names a sensible heading.
    ///
    /// Inter-block air is `paragraphSpacing`'s job (see `BlockStyleFactory`),
    /// so these collapse to a hairline.  Not to zero: TextKit reads a zero
    /// `minimumLineHeight` as "use the font's natural height", and a caret has
    /// to have somewhere to sit on an empty line in Live mode.
    ///
    /// Source mode is exempt — the whole point of that mode is seeing the
    /// markdown exactly as it is written (§3.2).
    private func collapseSeparators(state: inout DecorateState) {
        guard policy.hidesBlockMarkers else { return }
        let separator = separatorParagraphStyle()
        let document = state.document
        let text = document.text as NSString
        let length = text.length

        // Work line by line rather than by the gaps between block ranges.  A
        // gap spans the newline that *terminates* the preceding block as well
        // as the blank line itself, and collapsing that terminator would
        // squash the block's own last line.  Whole blank lines are unambiguous.
        for index in Self.lineIndices(intersecting: state.target, lineStarts: document.lineStarts) {
            let lineStart = document.lineStarts[index]
            let nextStart = index + 1 < document.lineStarts.count ? document.lineStarts[index + 1] : length
            guard nextStart > lineStart else { continue }

            // Content of the line, terminator excluded.
            var contentEnd = nextStart
            while contentEnd > lineStart {
                let ch = text.character(at: contentEnd - 1)
                guard ch == 0x0A || ch == 0x0D else { break }
                contentEnd -= 1
            }
            guard contentEnd > lineStart ? false : true else { continue }

            // Blank lines inside a fence, a math block, front matter or a table
            // are content: they hold the shape of the thing they are inside.
            if let block = document.root.block(at: lineStart) {
                switch block.content {
                case .codeBlock, .mermaid, .mathBlock, .frontMatter, .table, .htmlBlock:
                    continue
                default:
                    break
                }
            }

            let lineRange = NSRange(location: lineStart, length: nextStart - lineStart)
            guard let clipped = clip(lineRange, to: state.target), clipped.length > 0 else { continue }
            state.storage.addAttribute(.paragraphStyle, value: separator, range: clipped)
            state.attributeRanges += 1
        }
    }

    /// Returns the line indices whose full source ranges intersect `target`.
    /// `lineStarts` is sorted, so two binary searches avoid scanning unrelated
    /// lines on a local edit.
    private static func lineIndices(intersecting target: NSRange, lineStarts: [Int]) -> Range<Int> {
        guard target.length > 0, !lineStarts.isEmpty else { return 0..<0 }

        var lower = 0
        var upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] <= target.location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let first = max(0, lower - 1)

        lower = 0
        upper = lineStarts.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if lineStarts[middle] < target.upperBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return first..<max(first, lower)
    }

    /// Child blocks are sorted and non-overlapping, so only the contiguous
    /// slice that intersects `target` needs to enter the recursive walk.
    private static func intersectingChildIndices(_ children: [MDBlock], target: NSRange) -> Range<Int> {
        guard target.length > 0, !children.isEmpty else { return 0..<0 }

        var lower = 0
        var upper = children.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if children[middle].range.upperBound <= target.location {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        let first = lower

        upper = children.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if children[middle].range.location < target.upperBound {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return first..<max(first, lower)
    }

    private var cachedSeparatorStyle: NSParagraphStyle?

    private func separatorParagraphStyle() -> NSParagraphStyle {
        if let cachedSeparatorStyle { return cachedSeparatorStyle }
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = 1
        style.maximumLineHeight = 1
        style.lineSpacing = 0
        style.paragraphSpacing = 0
        style.paragraphSpacingBefore = 0
        let frozen = style.copy() as? NSParagraphStyle ?? NSParagraphStyle.default
        cachedSeparatorStyle = frozen
        return frozen
    }

    private struct DecorateState {
        let document: ParsedDocument
        let storage: NSTextStorage
        var target = NSRange(location: 0, length: 0)
        var attributeRanges = 0
        var fragmentCount = 0
        var documentBase: [NSAttributedString.Key: Any] = [:]

        init(document: ParsedDocument, storage: NSTextStorage) {
            self.document = document
            self.storage = storage
        }
    }

    /// Base attributes for text that belongs to no block.
    private func documentBaseAttributes() -> [NSAttributedString.Key: Any] {
        let zero = NSRange(location: 0, length: 0)
        return styles.baseAttributes(
            for: MDBlock(content: .paragraph, range: zero, contentRange: zero), context: .root)
    }

    /// Smallest range covering every leaf block that intersects `range`.  A
    /// paragraph's style is a property of the paragraph, not of the characters
    /// that changed, so a one-character edit still redecorates its whole block
    /// — and only its block.
    private func blockBounds(of range: NSRange, in document: ParsedDocument) -> NSRange {
        var bounds = range
        document.root.walkPruning { block in
            guard block.range.location < range.upperBound, range.location < block.range.upperBound else {
                return false
            }
            if block.children.isEmpty { bounds = bounds.union(block.range) }
            return true
        }
        return bounds
    }

    private func clip(_ range: NSRange, to bounds: NSRange) -> NSRange? {
        let lo = max(range.location, bounds.location)
        let hi = min(range.upperBound, bounds.upperBound)
        return hi > lo ? NSRange(location: lo, length: hi - lo) : nil
    }

    // MARK: - Walk

    private func walk(_ block: MDBlock, context: BlockContext, state: inout DecorateState) {
        guard block.range.location < state.target.upperBound,
              state.target.location < block.range.upperBound else { return }

        var childContext = context
        switch block.content {
        case .document:
            for childIndex in Self.intersectingChildIndices(block.children, target: state.target) {
                walk(block.children[childIndex], context: context, state: &state)
            }
            return

        case .list:
            childContext.listDepth += 1
            for childIndex in Self.intersectingChildIndices(block.children, target: state.target) {
                walk(block.children[childIndex], context: childContext, state: &state)
            }
            applyTrailingListSpacing(block, state: &state)
            return

        case .blockQuote:
            emitFragment(.callout, block: block, detail: "", state: &state)
            childContext.quoteDepth += 1
            childContext.calloutKind = nil
            applyBase(block, context: context, state: &state)
            for childIndex in Self.intersectingChildIndices(block.children, target: state.target) {
                walk(block.children[childIndex], context: childContext, state: &state)
            }
            return

        case .callout(let kind, let title):
            emitFragment(.callout, block: block,
                         detail: kind.rawValue + "|" + (title ?? ""), state: &state)
            childContext.quoteDepth += 1
            childContext.calloutKind = kind
            applyBase(block, context: context, state: &state)
            for childIndex in Self.intersectingChildIndices(block.children, target: state.target) {
                walk(block.children[childIndex], context: childContext, state: &state)
            }
            if let title, !title.isEmpty {
                let source = state.document.substring(block.range) as NSString
                let bracket = source.range(of: "]")
                let searchStart = bracket.location != NSNotFound ? bracket.location + 1 : 0
                let searchRange = NSRange(location: searchStart, length: source.length - searchStart)
                let found = source.range(of: title, options: [], range: searchRange)
                if found.location != NSNotFound {
                    apply([
                        .font: NSFont.systemFont(ofSize: styleSheet.bodyFont().pointSize, weight: .semibold),
                        .foregroundColor: styleSheet.calloutColor(kind),
                    ], to: NSRange(location: block.range.location + found.location, length: found.length), state: &state)
                }
            }
            return

        case .listItem(let ordinal, let checkbox):
            childContext.ordinal = ordinal
            // A task's own text is a child paragraph block; it needs the task
            // marker column (not the bullet column) so the checkbox the list
            // ornament draws has room (§11.3).
            childContext.task = checkbox != nil
            applyBase(block, context: childContext, state: &state)
            applyBlockMarker(block, context: childContext, state: &state)
            let ornament: String
            if let checkbox { ornament = checkbox.isChecked ? "task:checked" : "task:unchecked" }
            else if let ordinal { ornament = "ordered:\(ordinal)" }
            else { ornament = "unordered:\(max(1, context.listDepth))" }
            emitFragment(.listOrnament, block: block, detail: ornament, state: &state)
            if let checkbox {
                apply([.drCheckbox: checkbox.isChecked], to: checkbox.markRange, state: &state)
            }
            applyInlinesIfLeaf(block, context: context, state: &state)
            for childIndex in Self.intersectingChildIndices(block.children, target: state.target) {
                walk(block.children[childIndex], context: childContext, state: &state)
            }
            if checkbox?.isChecked == true {
                let completed: [NSAttributedString.Key: Any] = [
                    .foregroundColor: styleSheet.text.withAlphaComponent(0.55),
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: styleSheet.text.withAlphaComponent(0.40),
                ]
                // A completed task strikes out *its own* text and stops.
                // `contentRange` spans the item's whole subtree, so styling it
                // wholesale also crossed out every nested item — including ones
                // still open, which states the opposite of their real state.
                // Sub-items own their completion, so they are left to style
                // themselves; the item's other blocks (a second paragraph, a
                // code sample it owns) are struck with it.
                if block.children.isEmpty {
                    apply(completed, to: block.contentRange, state: &state)
                } else {
                    for child in block.children where !child.content.isList {
                        apply(completed, to: child.range, state: &state)
                    }
                }
            }
            return

        case .codeBlock(let language, _, let contentRange):
            decorateCodeBlock(block, language: language, contentRange: contentRange, context: context, state: &state)
            return

        case .mermaid(let sourceRange):
            applyBase(block, context: context, state: &state)
            emitFragment(.mermaid, block: block, detail: state.document.substring(sourceRange), state: &state)
            return

        case .mathBlock(let latexRange):
            applyBase(block, context: context, state: &state)
            emitFragment(.blockMath, block: block, detail: state.document.substring(latexRange), state: &state)
            return

        case .table(let data):
            applyBase(block, context: context, state: &state)
            let payload = emitFragment(.table, block: block, detail: "", state: &state)
            payload?.tableData = data
            for row in data.rows {
                for cell in row.cells {
                    applyInlines(cell.inlines, context: context, blockFont: styles.font(for: block.content),
                                 bold: false, italic: false, state: &state)
                }
            }
            return

        case .thematicBreak:
            applyBase(block, context: context, state: &state)
            emitFragment(.thematicBreak, block: block, detail: "", state: &state)
            return

        case .frontMatter(let matter):
            applyBase(block, context: context, state: &state)
            emitFragment(.frontMatter, block: block, detail: matter.fields.first?.key ?? "", state: &state)
            for field in matter.fields {
                apply([.foregroundColor: styleSheet.accent], to: field.keyRange, state: &state)
                apply([.foregroundColor: styleSheet.text], to: field.valueRange, state: &state)
            }
            return

        case .heading, .paragraph, .htmlBlock, .footnoteDefinition:
            if let html = block.safeHTML, html.isSafe {
                applyBase(block, context: context, state: &state)
                applySafeHTML(html, block: block, state: &state)
            } else if let program = cachedProgram(for: block, context: context) {
                applyProgram(program, at: block.range.location, state: &state)
                let attributes = styles.baseAttributes(for: block, context: context)
                applyFirstHeadingSpacing(block, attributes: attributes, state: &state)
                applyHardWrapContinuationSpacing(block, attributes: attributes, state: &state)
            } else {
                applyBase(block, context: context, state: &state)
                applyBlockMarker(block, context: context, state: &state)
                applyInlinesIfLeaf(block, context: context, state: &state)
            }
            apply([.drBlock: block.identity], to: block.range, state: &state)
            emitInlineImageFragmentIfSolitary(block, state: &state)
            for childIndex in Self.intersectingChildIndices(block.children, target: state.target) {
                walk(block.children[childIndex], context: context, state: &state)
            }
            return
        }
    }

    // MARK: - Attribute application

    private func applyTrailingListSpacing(_ list: MDBlock, state: inout DecorateState) {
        guard !discardsTypography else { return }
        guard let last = list.children.last, last.range.length > 0 else { return }
        let source = state.storage.string as NSString
        let offset = min(source.length - 1, max(last.range.location, last.range.upperBound - 1))
        guard offset >= 0 else { return }
        let paragraph = source.paragraphRange(for: NSRange(location: offset, length: 0))
        guard paragraph.location < state.target.upperBound,
              state.target.location < paragraph.upperBound,
              let existing = state.storage.attribute(
                .paragraphStyle, at: offset, effectiveRange: nil
              ) as? NSParagraphStyle,
              let spaced = existing.mutableCopy() as? NSMutableParagraphStyle
        else { return }
        spaced.paragraphSpacing = RenderMetrics.snap(
            styleSheet.lineHeight * 0.45,
            grid: max(1, styleSheet.baselineGrid)
        )
        apply([.paragraphStyle: spaced.copy() as Any], to: paragraph, state: &state)
    }

    private func apply(
        _ attributes: [NSAttributedString.Key: Any],
        to range: NSRange,
        state: inout DecorateState
    ) {
        guard let clipped = clip(range, to: state.target), clipped.length > 0 else { return }
        guard clipped.upperBound <= state.storage.length else { return }
        guard !discardsTypography else {
            // The one place the Source shortcut is enforced, so a call site
            // that forgets it still cannot write typography that the source
            // presentation is about to overwrite.  An operation that carried
            // nothing but a font or a paragraph style disappears entirely
            // rather than splitting an attribute run for nothing.
            var surviving = attributes
            surviving.removeValue(forKey: .font)
            surviving.removeValue(forKey: .paragraphStyle)
            guard !surviving.isEmpty else { return }
            state.storage.addAttributes(surviving, range: clipped)
            state.attributeRanges += 1
            return
        }
        state.storage.addAttributes(attributes, range: clipped)
        state.attributeRanges += 1
    }

    private func applyBase(_ block: MDBlock, context: BlockContext, state: inout DecorateState) {
        var attributes = styles.baseAttributes(for: block, context: context)
        if !discardsTypography,
           styleSheet.theme.typography.opticalMargins,
           context.listDepth == 0,
           case .paragraph = block.content,
           let first = state.document.substring(block.contentRange).first,
           "\"'“‘".contains(first),
           let original = attributes[.paragraphStyle] as? NSParagraphStyle,
           let paragraph = original.mutableCopy() as? NSMutableParagraphStyle {
            paragraph.firstLineHeadIndent -= styles.font(for: block.content).pointSize * 0.34
            attributes[.paragraphStyle] = paragraph.copy() as? NSParagraphStyle ?? original
        }

        // A paragraph style must reach only paragraphs that *begin* inside this
        // block's own content.  Applying it over `block.range` would cross into
        // nested children's paragraphs, and NSTextStorage's paragraph fixup
        // then flattens a child item's deeper indent back to the parent's —
        // the nested-task indentation bug.  The split also keeps the base
        // font/colour over the whole block, which the fixup does not touch.
        if let paragraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle {
            var withoutParagraph = attributes
            withoutParagraph.removeValue(forKey: .paragraphStyle)
            apply(withoutParagraph, to: block.range, state: &state)
            applyOwnParagraphStyle(paragraphStyle, over: block, state: &state)
        } else {
            apply(attributes, to: block.range, state: &state)
        }
        apply([.drBlock: block.identity], to: block.range, state: &state)

        applyFirstHeadingSpacing(block, attributes: attributes, state: &state)
        applyHardWrapContinuationSpacing(block, attributes: attributes, state: &state)
    }

    /// Applies `style` paragraph by paragraph across the block, skipping any
    /// paragraph that *begins* inside a child block.  Applying the style over
    /// `block.range` wholesale would cross into nested children's paragraphs,
    /// and NSTextStorage's paragraph fixup then flattens a child item's deeper
    /// indent back to the parent's — the nested-task indentation bug.  Leaf
    /// blocks (a fenced code block, say) have no children, so every paragraph
    /// — fences included — keeps the block's own style.
    private func applyOwnParagraphStyle(
        _ style: NSParagraphStyle,
        over block: MDBlock,
        state: inout DecorateState
    ) {
        guard !discardsTypography else { return }
        let text = state.storage.string as NSString
        let children = block.children
        var cursor = block.range.location
        let end = block.range.upperBound
        while cursor < end && cursor < text.length {
            let paragraph = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            guard paragraph.length > 0 else { break }
            let ownedByChild = children.contains { child in
                child.range.length > 0 && child.range.contains(offset: paragraph.location)
            }
            if !ownedByChild, let clipped = clip(paragraph, to: state.target), clipped.length > 0 {
                apply([.paragraphStyle: style], to: paragraph, state: &state)
            }
            guard paragraph.upperBound > cursor else { break }
            cursor = paragraph.upperBound
        }
    }

    private func applyFirstHeadingSpacing(
        _ block: MDBlock,
        attributes: [NSAttributedString.Key: Any],
        state: inout DecorateState
    ) {
        guard !discardsTypography else { return }
        guard case .heading = block.content,
              let original = attributes[.paragraphStyle] as? NSParagraphStyle else { return }
        let isFirst = state.document.headings.first?.range.location == block.range.location
        // Space before a heading exists to separate it from the prose it follows.
        // A heading that follows another heading has no prose to be separated
        // from, and the full gap there reads as a missing section rather than as
        // hierarchy — an H2 immediately followed by its H3 looked exactly as far
        // apart as an H2 and the paragraph above it.
        let follows = followsAnotherHeading(block, in: state)
        guard isFirst || follows,
              let paragraph = original.mutableCopy() as? NSMutableParagraphStyle else { return }
        paragraph.paragraphSpacingBefore = isFirst
            ? 0
            : (original.paragraphSpacingBefore * 0.4).rounded()
        apply([.paragraphStyle: paragraph.copy() as? NSParagraphStyle ?? original],
              to: block.range, state: &state)
    }

    /// True when the nearest block above this heading is itself a heading.
    private func followsAnotherHeading(_ block: MDBlock, in state: DecorateState) -> Bool {
        let headings = state.document.headings
        guard let index = headings.firstIndex(where: { $0.range.location == block.range.location }),
              index > 0 else { return false }
        let previous = headings[index - 1]
        // Nothing but whitespace between the two means they are adjacent even
        // though the parser reports them as separate blocks.
        let between = NSRange(
            location: previous.range.upperBound,
            length: max(0, block.range.location - previous.range.upperBound)
        )
        guard between.length > 0, between.upperBound <= state.document.length else { return true }
        return state.document.substring(between).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Air belongs to the *logical* paragraph, not to the source lines it
    /// happens to be typed across: its opening keeps the space before it, its
    /// close keeps the space after it, and the joins in between get neither.
    ///
    /// This used to end by zeroing both on the whole block, which deleted the
    /// space *after* every hard-wrapped paragraph in the document.  Since blank
    /// source lines collapse to a hairline (`collapseSeparators`) on the
    /// understanding that `paragraphSpacing` supplies the air, two consecutive
    /// hard-wrapped paragraphs then met with one point between them and read as
    /// a single block of text.
    private func applyHardWrapContinuationSpacing(
        _ block: MDBlock,
        attributes: [NSAttributedString.Key: Any],
        state: inout DecorateState
    ) {
        guard !discardsTypography else { return }
        guard case .paragraph = block.content,
              state.document.substring(block.contentRange).contains("\n"),
              let original = attributes[.paragraphStyle] as? NSParagraphStyle
        else { return }
        let lines = physicalParagraphs(of: block, in: state)
        guard lines.count > 1 else { return }
        for (index, line) in lines.enumerated() {
            guard let paragraph = original.mutableCopy() as? NSMutableParagraphStyle else { continue }
            if index > 0 { paragraph.paragraphSpacingBefore = 0 }
            if index < lines.count - 1 { paragraph.paragraphSpacing = 0 }
            apply([.paragraphStyle: paragraph.copy() as? NSParagraphStyle ?? original],
                  to: line, state: &state)
        }
    }

    /// Hangs every code row's wraps off that row's own indentation.
    ///
    /// The column never scrolls horizontally, so a long statement has to wrap
    /// somewhere; where it resumes is what decides whether the result still
    /// reads as code.  One `headIndent` for the whole block resumed a wrapped
    /// row at the block's left edge — to the *left* of the statement it belongs
    /// to, so a continuation impersonated a new line of source.
    private func applyCodeRowIndents(
        _ block: MDBlock, context: BlockContext, state: inout DecorateState
    ) {
        guard !discardsTypography else { return }
        let base = styles.paragraphStyle(for: block, context: context)
        let text = state.storage.string as NSString
        for line in physicalParagraphs(of: block, in: state) {
            let columns = BlockStyleFactory.indentColumns(of: text.substring(with: line) as NSString)
            guard columns > 0 else { continue }
            apply([.paragraphStyle: styles.codeRowStyle(base: base, indentColumns: columns)],
                  to: line, state: &state)
        }
    }

    /// The physical paragraphs a block is typed across, terminators included —
    /// the last one's terminator is the paragraph's own, and it is what carries
    /// the trailing air.
    private func physicalParagraphs(of block: MDBlock, in state: DecorateState) -> [NSRange] {
        let text = state.storage.string as NSString
        guard block.range.length > 0, block.range.upperBound <= text.length else { return [] }
        var lines: [NSRange] = []
        var cursor = block.range.location
        while cursor < block.range.upperBound {
            let line = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            guard line.length > 0 else { break }
            lines.append(line)
            cursor = max(line.upperBound, cursor + 1)
        }
        return lines
    }

    /// Block markers are attributed but never revealed inline (§6.1a); the
    /// gutter rail draws their text and `drGutterMarker` is what it reads.
    private func applyBlockMarker(_ block: MDBlock, context: BlockContext, state: inout DecorateState) {
        guard let marker = block.markerRange, marker.length > 0 else { return }
        var attrs = styles.markerAttributes(dimmed: !policy.highlightsMarkers)
        if let text = Self.gutterText(for: block, context: context) { attrs[.drGutterMarker] = text }
        apply(attrs, to: marker, state: &state)
        if let trailing = block.trailingMarkerRange, trailing.length > 0 {
            apply(styles.markerAttributes(dimmed: !policy.highlightsMarkers), to: trailing, state: &state)
        }
    }

    private func applyInlinesIfLeaf(_ block: MDBlock, context: BlockContext, state: inout DecorateState) {
        guard !block.inlines.isEmpty else { return }
        applyInlines(block.inlines, context: context, blockFont: styles.font(for: block.content),
                     bold: false, italic: false, state: &state)
    }

    private func applyInlines(
        _ spans: [InlineSpan],
        context: BlockContext,
        blockFont: NSFont,
        bold: Bool,
        italic: Bool,
        state: inout DecorateState
    ) {
        for span in spans {
            guard span.range.location < state.target.upperBound, state.target.location < span.range.upperBound else { continue }
            var bold = bold
            var italic = italic

            switch span.kind {
            case .strong:
                // The trait still has to propagate into the children even when
                // the face itself is about to be overwritten: a `**bold _and_
                // italic**` span resolves its emphasis from both flags.
                bold = true
                if !discardsTypography {
                    apply([.font: emphasized(blockFont, bold: true, italic: italic)], to: span.contentRange, state: &state)
                }
            case .emphasis:
                italic = true
                if !discardsTypography {
                    apply([.font: emphasized(blockFont, bold: bold, italic: true)], to: span.contentRange, state: &state)
                }
            case .strikethrough:
                apply([
                    .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                    .strikethroughColor: styleSheet.textFaint,
                    .foregroundColor: styleSheet.textFaint,
                ], to: span.contentRange, state: &state)
            case .inlineCode:
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: styleSheet.text,
                    .drInlineCode: true,
                ]
                // Resolving a resized mono face goes through the font
                // descriptor, so it is worth not asking for one that is about
                // to be replaced by the source presentation's own mono.
                if !discardsTypography {
                    attributes[.font] = styleSheet.monoFont(size: blockFont.pointSize * 0.94)
                }
                apply(attributes, to: span.contentRange, state: &state)
            case .link(let destination, _):
                applyLink(destination, span: span, state: &state)
            case .autolink(let destination):
                applyLink(destination, span: span, state: &state)
            case .wikilink(let target, _):
                applyLink(target, span: span, state: &state)
            case .image(let source, _):
                apply([
                    .drLink: source,
                    .foregroundColor: styleSheet.textSecondary,
                ], to: span.contentRange, state: &state)
            case .inlineMath(let latexRange):
                let payload = FragmentPayload(
                    kind: .inlineMath, sourceRange: span.range,
                    blockIdentity: BlockIdentity(kind: 9, ordinal: span.range.location),
                    detail: state.document.substring(latexRange))
                apply([.drFragment: payload], to: span.range, state: &state)
                state.fragmentCount += 1
            case .pathToken(let token):
                // §8.4: the engine marks it; only the app knows whether the
                // file is there, so `drPathExists` starts optimistic and the
                // view refines it through the delegate.
                var attributes: [NSAttributedString.Key: Any] = [
                    .drPathToken: token,
                    .drPathExists: true,
                    .drInlineCode: true,
                    .foregroundColor: styleSheet.textSecondary,
                ]
                if !discardsTypography {
                    attributes[.font] = styleSheet.monoFont(size: blockFont.pointSize * 0.94)
                }
                apply(attributes, to: span.range, state: &state)
            case .footnoteReference(let identifier):
                // The raised baseline survives into Source — only the smaller
                // face is overwritten — so the offset is still measured from
                // the block's own font here.
                var attributes: [NSAttributedString.Key: Any] = [
                    .drReference: identifier,
                    .foregroundColor: styleSheet.accent,
                    .baselineOffset: blockFont.xHeight * 0.42,
                ]
                if !discardsTypography {
                    attributes[.font] = blockFont.withSize(blockFont.pointSize * 0.62)
                }
                apply(attributes, to: span.range, state: &state)
            case .inlineHTML:
                apply([.foregroundColor: styleSheet.textFaint], to: span.range, state: &state)
            case .text, .softBreak, .lineBreak:
                break
            }

            for marker in span.markerRanges where marker.length > 0 {
                apply(styles.markerAttributes(dimmed: !policy.highlightsMarkers), to: marker, state: &state)
            }
            if !span.children.isEmpty {
                applyInlines(span.children, context: context, blockFont: blockFont,
                             bold: bold, italic: italic, state: &state)
            }
        }
    }

    private func applyLink(_ destination: String, span: InlineSpan, state: inout DecorateState) {
        // A link has to be findable without colour: WCAG 1.4.1, and readers who
        // cannot separate the link hue from body text otherwise have no way to
        // see one at all.  The rest at low contrast, so the page stays calm;
        // hover still strengthens it (§7.1).
        apply([
            .drLink: destination,
            .link: destination,
            .foregroundColor: styleSheet.link,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .underlineColor: styleSheet.link.withAlphaComponent(
                styleSheet.increaseContrast ? 0.75 : 0.35
            ),
        ], to: span.contentRange.length > 0 ? span.contentRange : span.range, state: &state)
    }

    /// Applies a conservative native presentation to README-style HTML while
    /// leaving every source character in storage. MarkerPolicy controls when
    /// the original tags are shown for editing.
    private func applySafeHTML(
        _ html: SafeHTMLDocument,
        block: MDBlock,
        state: inout DecorateState
    ) {
        let bodyFont = styleSheet.bodyFont()
        for annotation in html.annotations {
            for tagRange in annotation.tagRanges {
                apply(styles.markerAttributes(dimmed: true), to: tagRange, state: &state)
            }
            switch annotation.kind {
            case .paragraph(let alignment):
                guard !discardsTypography,
                      let alignment, annotation.contentRange.length > 0 else { continue }
                let current = state.storage.attribute(
                        .paragraphStyle,
                        at: annotation.contentRange.location,
                        effectiveRange: nil
                      ) as? NSParagraphStyle
                let paragraph = current?.mutableCopy() as? NSMutableParagraphStyle
                    ?? NSMutableParagraphStyle()
                switch alignment {
                case .left: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .right: paragraph.alignment = .right
                case .justify: paragraph.alignment = .justified
                }
                let physicalParagraph = (state.storage.string as NSString)
                    .paragraphRange(for: annotation.range)
                apply([.paragraphStyle: paragraph.copy() as Any], to: physicalParagraph, state: &state)

            case .heading(let level):
                apply([
                    .font: styleSheet.headingFont(level: level),
                    .foregroundColor: styleSheet.headingColor(level: level),
                    .drHeading: level,
                ], to: annotation.contentRange, state: &state)

            case .strong:
                apply([.font: emphasized(bodyFont, bold: true, italic: false)],
                      to: annotation.contentRange, state: &state)

            case .emphasis:
                apply([.font: emphasized(bodyFont, bold: false, italic: true)],
                      to: annotation.contentRange, state: &state)

            case .link(let destination, _):
                apply([
                    .drLink: destination,
                    .link: destination,
                    .foregroundColor: styleSheet.link,
                    .underlineStyle: NSUnderlineStyle.single.rawValue,
                ], to: annotation.contentRange, state: &state)

            case .image(let source, let alt):
                let payload = FragmentPayload(
                    kind: .image,
                    sourceRange: annotation.range,
                    blockIdentity: block.identity,
                    detail: source
                )
                apply([
                    .drFragment: payload,
                    .drLink: source,
                    .drReference: alt,
                ], to: annotation.range, state: &state)
                state.fragmentCount += 1

            case .summary:
                // Keep the summary visually distinct even though the source
                // tags are hidden in Read/Live. The disclosure glyph is a
                // source-preserving display-map substitution; this treatment
                // gives VoiceOver/text selection and a narrow window a stable
                // semantic anchor without inserting a character into source.
                apply([
                    .font: emphasized(bodyFont, bold: true, italic: false),
                    .backgroundColor: styleSheet.surface.withAlphaComponent(0.34),
                ], to: annotation.contentRange, state: &state)

            case .tableCell(let header, let alignment):
                if header {
                    apply([.font: emphasized(bodyFont, bold: true, italic: false)],
                          to: annotation.contentRange, state: &state)
                }
                if !discardsTypography, let alignment, annotation.contentRange.length > 0 {
                    let current = state.storage.attribute(
                        .paragraphStyle,
                        at: annotation.contentRange.location,
                        effectiveRange: nil
                    ) as? NSParagraphStyle
                    let paragraph = current?.mutableCopy() as? NSMutableParagraphStyle
                        ?? NSMutableParagraphStyle()
                    switch alignment {
                    case .left: paragraph.alignment = .left
                    case .center: paragraph.alignment = .center
                    case .right: paragraph.alignment = .right
                    case .justify: paragraph.alignment = .justified
                    }
                    apply([.paragraphStyle: paragraph], to: annotation.contentRange, state: &state)
                }
                // HTML tables commonly omit whitespace between cells. A small
                // trailing kern is a visual column gutter that does not alter
                // the source string or its source/display coordinate mapping.
                if annotation.contentRange.length > 0 {
                    let trailing = NSRange(
                        location: annotation.contentRange.upperBound - 1,
                        length: 1
                    )
                    apply([
                        .kern: RenderMetrics.tableColumnGap * 0.5,
                        .backgroundColor: styleSheet.surface.withAlphaComponent(header ? 0.26 : 0.12),
                    ], to: trailing, state: &state)
                    apply([
                        .backgroundColor: styleSheet.surface.withAlphaComponent(header ? 0.26 : 0.12),
                    ], to: annotation.contentRange, state: &state)
                }

            case .inert:
                apply([.foregroundColor: styleSheet.textFaint],
                      to: annotation.range, state: &state)

            case .lineBreak, .details, .detailsClosing, .table, .tableRow:
                break
            }
        }
    }

    /// Bold and italic inside a heading must stay at the heading's size, so
    /// traits are derived from the block's own font unless the block is at body
    /// size — where the theme's `emphasisFont` gets to make the call (§11.1).
    private func emphasized(_ base: NSFont, bold: Bool, italic: Bool) -> NSFont {
        guard bold || italic else { return base }
        if abs(base.pointSize - styleSheet.bodyFont().pointSize) < 0.5 {
            return styleSheet.emphasisFont(bold: bold, italic: italic)
        }
        var traits = base.fontDescriptor.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        let descriptor = base.fontDescriptor.withSymbolicTraits(traits)
        return NSFont(descriptor: descriptor, size: base.pointSize) ?? base
    }

    // MARK: - Code blocks (§11.3)

    private func decorateCodeBlock(
        _ block: MDBlock,
        language: String?,
        contentRange: NSRange,
        context: BlockContext,
        state: inout DecorateState
    ) {
        applyBase(block, context: context, state: &state)

        let lineCount = Self.lineCount(of: contentRange, in: state.document)
        let collapses = policy.collapsesLongCodeBlocks && lineCount > collapseLineCount
        let payload = emitFragment(collapses ? .collapsedCodeBlock : .codeBlock,
                                   block: block, detail: language ?? "", state: &state)
        payload?.isCollapsed = collapses

        // Fences stay in the text (see `MarkerPolicy.blockMarkersAreHidden`);
        // the fragment absorbs them as the band's chrome, so they are styled
        // as markers rather than as code.
        if let marker = block.markerRange {
            apply(styles.markerAttributes(dimmed: true), to: marker, state: &state)
        }
        if let trailing = block.trailingMarkerRange {
            apply(styles.markerAttributes(dimmed: true), to: trailing, state: &state)
        }
        applyCodeRowIndents(block, context: context, state: &state)
        guard contentRange.length > 0, contentRange.upperBound <= state.storage.length else { return }

        let code = state.document.substring(contentRange)
        let runs = syntaxCache.runs(for: code, language: language, highlighter: highlighter)
        let isDiff = (language?.lowercased() == "diff")
        if isDiff {
            let ns = code as NSString
            var cursor = 0
            while cursor < ns.length {
                let line = ns.lineRange(for: NSRange(location: cursor, length: 0))
                if line.length > 0 {
                    let first = ns.character(at: line.location)
                    if first == 0x2B || first == 0x2D {
                        let token: SyntaxToken = first == 0x2B ? .diffAdded : .diffRemoved
                        apply([.backgroundColor: styleSheet.codeColor(token).withAlphaComponent(0.12)],
                              to: NSRange(location: contentRange.location + line.location, length: line.length),
                              state: &state)
                    }
                }
                cursor = max(cursor + 1, line.upperBound)
            }
        }
        for run in runs {
            let absolute = NSRange(location: contentRange.location + run.range.location, length: run.range.length)
            let attrs: [NSAttributedString.Key: Any] = [.foregroundColor: styleSheet.codeColor(run.token)]
            // §11.3: ```diff fences get real diff colouring, which means a
            // tinted line, not just a coloured `+`.
            apply(attrs, to: absolute, state: &state)
        }
    }

    private static func lineCount(of range: NSRange, in document: ParsedDocument) -> Int {
        guard range.length > 0 else { return 0 }
        return document.line(at: range.upperBound - 1) - document.line(at: range.location) + 1
    }

    // MARK: - Fragments

    @discardableResult
    private func emitFragment(
        _ kind: FragmentKind,
        block: MDBlock,
        detail: String,
        state: inout DecorateState
    ) -> FragmentPayload? {
        guard block.range.length > 0 else { return nil }
        let payload = FragmentPayload(kind: kind, sourceRange: block.range,
                                      blockIdentity: block.identity, detail: detail)
        apply([.drFragment: payload], to: block.range, state: &state)
        state.fragmentCount += 1
        return payload
    }

    /// A paragraph that is nothing but an image renders as an object with a
    /// caption (§11.3); an image sitting inside a sentence stays inline.
    private func emitInlineImageFragmentIfSolitary(_ block: MDBlock, state: inout DecorateState) {
        guard case .paragraph = block.content, block.inlines.count == 1,
              case .image(let source, let alt) = block.inlines[0].kind else { return }
        let payload = FragmentPayload(kind: .image, sourceRange: block.range,
                                      blockIdentity: block.identity, detail: source)
        payload.tableData = nil
        apply([.drFragment: payload, .drLink: source, .drReference: alt], to: block.range, state: &state)
        state.fragmentCount += 1
    }

    // MARK: - Program cache

    private func cachedProgram(for block: MDBlock, context: BlockContext) -> [AttributeOp]? {
        guard block.safeHTML == nil else { return nil }
        guard block.subtreeHash != 0, block.children.isEmpty, block.content.isLeafText else { return nil }
        // Inline math carries its LaTeX as a payload read out of the document,
        // which the range-shifted recorder cannot resolve.  Rare enough that
        // skipping the cache for those paragraphs costs nothing measurable.
        guard !Self.containsInlineMath(block.inlines) else { return nil }
        let key = ProgramKey(hash: block.subtreeHash, kind: BlockStyleFactory.kindCode(block.content),
                             listDepth: context.listDepth, quoteDepth: context.quoteDepth,
                             length: block.range.length, task: context.task,
                             plainTypography: discardsTypography)
        if let hit = programCache[key] { return hit }
        guard programSeen.contains(key) else {
            programSeen.insert(key)
            return nil
        }
        let program = recordProgram(for: block, context: context)
        programCache[key] = program
        return program
    }

    /// Runs the same code paths as the live decorator against a scratch state,
    /// capturing the operations instead of applying them.  One implementation,
    /// so a cached block and a freshly decorated one cannot diverge.
    private func recordProgram(for block: MDBlock, context: BlockContext) -> [AttributeOp] {
        let recorder = NSTextStorage(string: String(repeating: " ", count: block.range.length))
        let shifted = MDBlock(
            content: block.content,
            range: NSRange(location: 0, length: block.range.length),
            contentRange: shift(block.contentRange, by: -block.range.location),
            markerRange: block.markerRange.map { shift($0, by: -block.range.location) },
            trailingMarkerRange: block.trailingMarkerRange.map { shift($0, by: -block.range.location) },
            children: [],
            inlines: block.inlines.map { shift($0, by: -block.range.location) },
            depth: block.depth, quoteDepth: block.quoteDepth,
            subtreeHash: block.subtreeHash, identity: block.identity)

        var scratch = DecorateState(document: .empty, storage: recorder)
        scratch.target = NSRange(location: 0, length: block.range.length)
        recorder.beginEditing()
        applyBase(shifted, context: context, state: &scratch)
        applyBlockMarker(shifted, context: context, state: &scratch)
        applyInlinesIfLeaf(shifted, context: context, state: &scratch)
        recorder.endEditing()

        var ops: [AttributeOp] = []
        recorder.enumerateAttributes(in: NSRange(location: 0, length: recorder.length)) { attrs, range, _ in
            ops.append(AttributeOp(range: range, attributes: attrs))
        }
        return ops
    }

    private static func containsInlineMath(_ spans: [InlineSpan]) -> Bool {
        for span in spans {
            if case .inlineMath = span.kind { return true }
            if containsInlineMath(span.children) { return true }
        }
        return false
    }

    private func applyProgram(_ program: [AttributeOp], at origin: Int, state: inout DecorateState) {
        for op in program {
            apply(op.attributes, to: shift(op.range, by: origin), state: &state)
        }
    }

    private func shift(_ range: NSRange, by delta: Int) -> NSRange {
        NSRange(location: range.location + delta, length: range.length)
    }

    private func shift(_ span: InlineSpan, by delta: Int) -> InlineSpan {
        InlineSpan(
            kind: shift(span.kind, by: delta),
            range: shift(span.range, by: delta),
            contentRange: shift(span.contentRange, by: delta),
            leadingMarkerRange: span.leadingMarkerRange.map { shift($0, by: delta) },
            trailingMarkerRange: span.trailingMarkerRange.map { shift($0, by: delta) },
            children: span.children.map { shift($0, by: delta) })
    }

    private func shift(_ kind: InlineKind, by delta: Int) -> InlineKind {
        if case .inlineMath(let latexRange) = kind { return .inlineMath(latexRange: shift(latexRange, by: delta)) }
        return kind
    }

    // MARK: - Hidden ranges (§6.1)

    /// Ranges of syntax markers that must be omitted from the display string,
    /// given the current policy and caret.  Ascending, non-overlapping.
    public func hiddenRanges(document: ParsedDocument, caret: Int?, selections: [NSRange]) -> [NSRange] {
        MarkerPolicy.hiddenRanges(document: document, policy: policy, caret: caret, selections: selections)
    }

    // MARK: - Gutter markers (§6.1a)

    /// Gutter marker text per block, keyed by the block's start offset.
    ///
    /// Derived from the block's *kind*, not from the source substring: a
    /// marker that has scrolled out of alignment with its text (`*` where the
    /// document elsewhere uses `-`) still reads as one rail rather than as
    /// noise, and a block whose `markerRange` the parser left `nil` still gets
    /// a rail entry.
    public func gutterMarkers(document: ParsedDocument) -> [(offset: Int, text: String, level: Int)] {
        var out: [(offset: Int, text: String, level: Int)] = []
        collectGutterMarkers(document.root, context: .root, into: &out)
        out.sort { $0.offset < $1.offset }
        return out
    }

    private func collectGutterMarkers(
        _ block: MDBlock,
        context: BlockContext,
        into out: inout [(offset: Int, text: String, level: Int)]
    ) {
        var childContext = context
        switch block.content {
        case .list: childContext.listDepth += 1
        case .blockQuote, .callout: childContext.quoteDepth += 1
        case .listItem(let ordinal, _): childContext.ordinal = ordinal
        default: break
        }
        if let text = Self.gutterText(for: block, context: context) {
            out.append((offset: block.range.location, text: text, level: Self.gutterLevel(for: block, context: context)))
        }
        for child in block.children { collectGutterMarkers(child, context: childContext, into: &out) }
    }

    /// What a block writes into the left rail — and, just as important, what it
    /// does *not*.
    ///
    /// The rail exists so block syntax never sits inline (§6.1a).  It is not a
    /// second rendering of syntax the page already shows: a list item draws a
    /// real bullet, ordinal, or checkbox in its hanging column, so repeating
    /// `-`, `1.`, `- [ ]` in the rail put the same marker on screen twice.  A
    /// heading keeps its `##` because nothing else states the level as a
    /// number, and a quote keeps its `>` because the rule alone is very quiet.
    ///
    /// Whatever is returned has to *fit* `RenderMetrics.gutterWidth`.  The
    /// spelled-out `> [!WARNING]` did not: at the rail's font it measured half
    /// again as wide as the rail and the view clipped it mid-token, so callouts
    /// read `> [!WAR` down the margin.  A callout's kind is already carried by
    /// its icon and its title, so the rail only has to say "quote".
    static func gutterText(for block: MDBlock, context: BlockContext) -> String? {
        switch block.content {
        case .heading(let level):
            return "H\(max(1, min(level, 6)))"
        default:
            return nil
        }
    }

    private static func gutterLevel(for block: MDBlock, context: BlockContext) -> Int {
        switch block.content {
        case .heading(let level): return level
        case .listItem: return context.listDepth
        case .blockQuote, .callout: return context.quoteDepth
        default: return 0
        }
    }
}
