import AppKit
import MarkdownCore

// Object rendering (§11.3) without a WebView anywhere (§3.3).
//
// Every element that draws as something other than glyphs is an
// `NSTextLayoutFragment` subclass returned from
// `NSTextLayoutManagerDelegate.textLayoutManager(_:textLayoutFragmentFor:in:)`.
// Two rules hold across all of them:
//
//   * **The characters stay put** (§3.1).  A fragment changes geometry and
//     drawing, never content.  Selecting a rendered table and pressing ⌘C
//     still yields the pipe syntax, because the pipes are still there.
//
//   * **A multi-paragraph block is many fragments.**  TextKit 2 makes one
//     fragment per paragraph, so the block's *first* paragraph draws the whole
//     object at full height and the rest collapse to `ElidedFragment`.  That
//     one pattern also implements code-block collapse (§5.1), heading folding
//     (§7.1), and structural zoom (§5.2) — no second mechanism.

/// Identity of a resolved `StyleSheet`, for caching rendered output.
///
/// `StyleSheet.revision` follows the theme *store*, so it does not move when
/// the same theme resolves differently — a light/dark switch, a new accent
/// colour, Increase Contrast.  Cached images have to invalidate on those, so
/// the token folds in the values that actually changed the drawing.
public enum StyleToken {
    public static func of(_ styleSheet: StyleSheet) -> Int {
        var hasher = Hasher()
        hasher.combine(styleSheet.revision)
        hasher.combine(styleSheet.theme.name)
        hasher.combine(styleSheet.bodyFont().pointSize)
        hasher.combine(styleSheet.increaseContrast)
        for color in [styleSheet.background, styleSheet.text, styleSheet.accent, styleSheet.codeBackground] {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            hasher.combine(resolved.redComponent)
            hasher.combine(resolved.greenComponent)
            hasher.combine(resolved.blueComponent)
        }
        return hasher.finalize()
    }
}

/// A checkbox toggle that is still confirming itself on screen (§7.1).
public struct CheckboxPulse {
    /// Total animation time, short enough to feel like an answer, not a scene.
    public static let duration: CFTimeInterval = 0.4
    /// The list block that holds the box, stable across a toggle because
    /// `- [ ]` and `- [x]` are the same length.
    public let sourceRange: NSRange
    public let started: CFAbsoluteTime
    /// The state the box just entered.
    public let checked: Bool
}

/// Identity of a table geometry cache entry: which table, at what measure,
/// against which text revision.  Editing a cell must not reuse a layout
/// computed for its old contents, and a resize must not reuse a layout
/// computed for another width.
struct TableLayoutKey: Hashable {
    var location: Int
    var width: Int
    var textRevision: Int
}

/// View-side state the fragments read while drawing.  A class so a fragment
/// can hold it weakly and never keep the view alive.
public final class FragmentContext {
    public weak var textView: MarkdownTextView?
    public var styleSheet: StyleSheet { didSet { styleToken = StyleToken.of(styleSheet) } }
    /// Cache token for rendered images; see `StyleToken`.
    public private(set) var styleToken: Int
    public var mode: RenderMode = .read
    /// Explicit block/selection source lens.  Full-document source continues
    /// to use `mode == .source`; this range lets one object become writable
    /// while surrounding content stays rendered.
    public var sourceFocusRange: NSRange?
    /// Source range of the fragment under the pointer, for hover affordances
    /// (§7.1: copy button, zebra row).
    public var hoveredFragmentRange: NSRange?
    /// Code block that just copied, for short visual confirmation.
    public var copiedCodeRange: NSRange?
    /// Row the pointer is over inside a hovered table.
    public var hoveredTableRow: NSRange?
    /// A checkbox the user just toggled, for the brief confirm pop (§7.1).
    public var checkboxPulses: [CheckboxPulse] = []
    /// Primary caret in source coordinates, or `nil` in Read mode.
    public var caret: Int?
    /// Width of the text column, for objects that fill the measure.
    public var contentWidth: CGFloat = 640
    /// Directory images and diagrams resolve against (§3.4 — unsandboxed, so
    /// this is a plain path, not a security-scoped bookmark).
    public var documentURL: URL?
    /// Paragraph structure of the current text, for line counts and collapse.
    var paragraphIndex: ParagraphIndex = .empty
    /// Zoom + fold + search visibility (§5.2, §7.1, §9.4).
    var elision: ElisionPlan = .none
    var cueElision: ElisionPlan = .none
    /// Explicit per-block code collapse, overriding the Read-mode default
    /// (§5.1).  Keyed by the block's start offset.
    var collapseOverrides: [Int: Bool] = [:]
    /// Front matter fields, so the metadata card does not re-parse YAML.
    var frontMatterFields: [(key: String, value: String)] = []
    var documentHasH1 = false
    /// Column geometry per table, keyed by the table's start offset, the
    /// measure it was laid out for, and the text revision.  The revision
    /// matters because a table keeps its start offset across a cell edit —
    /// only the payload moves.  See `TableLayoutKey`.
    var tableLayouts: [TableLayoutKey: TableLayout] = [:]
    /// Monotonic counter bumped every time the text storage changes, so the
    /// table geometry cache cannot serve a stale layout for the same offset.
    var textRevision: Int = 0

    public init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.styleToken = StyleToken.of(styleSheet)
    }

    func invalidateDerivedLayout() {
        textRevision &+= 1
        tableLayouts.removeAll(keepingCapacity: true)
    }

    /// Register a toggle and drop any pulse that has already finished, so a
    /// quick re-click does not stack stale ghosts.
    func beginCheckboxPulse(_ range: NSRange, checked: Bool) {
        let now = CFAbsoluteTimeGetCurrent()
        checkboxPulses.removeAll { now - $0.started > CheckboxPulse.duration }
        checkboxPulses.append(CheckboxPulse(sourceRange: range, started: now, checked: checked))
    }

    var storage: NSTextStorage? { textView?.textStorage }

    /// Strictly inside, not merely touching.
    ///
    /// `touches` is inclusive of both edges, so clicking just after a table or
    /// arrowing past an image swapped a 400 pt object for three lines of source
    /// and moved the whole page.  §6.2 scopes source to the object the caret is
    /// *in*; landing on its boundary is not being in it.
    func isCaretInside(_ range: NSRange) -> Bool {
        guard let caret, range.length > 0 else { return false }
        return caret > range.location && caret < range.upperBound
    }

    func isSourceFocused(_ range: NSRange) -> Bool {
        guard let sourceFocusRange else { return false }
        return NSIntersectionRange(sourceFocusRange, range).length > 0
            || sourceFocusRange.contains(offset: range.location)
    }
}

/// Base for every drawing fragment: carries the payload and the context, and
/// centralises the geometry overrides so a subclass only says how tall it is
/// and what it draws.
public class DownrightFragment: NSTextLayoutFragment {
    let payload: FragmentPayload
    weak var context: FragmentContext?

    init(textElement: NSTextElement, range: NSTextRange?, payload: FragmentPayload, context: FragmentContext) {
        self.payload = payload
        self.context = context
        super.init(textElement: textElement, range: range)
    }

    /// Downright never archives its text surface; fragments are always built
    /// by the layout manager delegate.
    public required init?(coder: NSCoder) { nil }

    /// `nil` only after the view has gone away mid-relayout, in which case
    /// there is nothing to draw into either.
    var styleSheet: StyleSheet? { context?.styleSheet }

    /// Cache token for anything expensive this fragment renders.
    var styleToken: Int { context?.styleToken ?? 0 }

    /// Extra height this fragment adds above and below its glyph run.
    var verticalPadding: (top: CGFloat, bottom: CGFloat) { (0, 0) }

    /// When true the fragment's own glyphs are not drawn — the object replaces
    /// them.  The characters are still in the storage and still selectable.
    var suppressesText: Bool { false }

    /// Fixed height, overriding the glyph run's own.  `nil` keeps it.
    var overrideHeight: CGFloat? { nil }

    /// Width of the whole text column — the reading measure *plus* the trailing
    /// bleed lane.  Only a full-bleed block (code, diagram, table, display
    /// math) may use all of it.
    var contentWidth: CGFloat {
        if let width = context?.contentWidth, width > 1 { return width }
        return max(1, super.layoutFragmentFrame.width)
    }

    /// Width of the reading column alone.  An object that belongs beside prose
    /// — a callout's band, an image, a rule, the front-matter card — sizes
    /// itself from this, or it ends a bleed lane wider than the paragraph above
    /// it (§11.1).  Both columns start at the same left edge, so this doubles
    /// as the prose column's right edge in container coordinates.
    var proseContentWidth: CGFloat {
        max(1, contentWidth - RenderMetrics.codeBleed)
    }

    public override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        if let height = overrideHeight {
            frame.size.height = height
        } else {
            let padding = verticalPadding
            frame.size.height += padding.top + padding.bottom
        }
        return frame
    }

    public override var renderingSurfaceBounds: CGRect {
        let frame = layoutFragmentFrame
        let natural = super.renderingSurfaceBounds
        let object = CGRect(x: -RenderMetrics.revealSlack, y: 0,
                            width: contentWidth + RenderMetrics.revealSlack * 2, height: frame.height)
        return natural.union(object)
    }

    public override func draw(at point: CGPoint, in context: CGContext) {
        drawObject(at: point, in: context)
        guard !suppressesText else { return }
        let padding = verticalPadding
        if padding.top == 0 {
            super.draw(at: point, in: context)
        } else {
            super.draw(at: CGPoint(x: point.x, y: point.y + padding.top), in: context)
        }
    }

    /// Drawn beneath the glyphs.  Override instead of `draw(at:in:)`.
    func drawObject(at point: CGPoint, in context: CGContext) {}

    // MARK: Helpers

    /// Rect of this fragment in its own drawing space, anchored at `point`.
    func bounds(at point: CGPoint) -> CGRect {
        CGRect(x: point.x, y: point.y, width: contentWidth, height: layoutFragmentFrame.height)
    }

    /// Text of the fragment's source range, straight from the storage.
    func sourceText(_ range: NSRange) -> String {
        guard let storage = context?.storage, range.upperBound <= storage.length, range.length > 0 else { return "" }
        return storage.attributedSubstring(from: range).string
    }

    /// Paragraph style the engine put on this block, the authority on the
    /// block's indentation.
    var paragraphStyle: NSParagraphStyle? {
        let range = elementSourceRange
        guard let storage = context?.storage, range.location < storage.length else { return nil }
        return storage.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle
    }

    /// Source range of the paragraph this fragment covers.
    var elementSourceRange: NSRange {
        guard let element = textElement, let range = element.elementRange,
              let manager = element.textContentManager else { return payload.sourceRange }
        let location = manager.offset(from: manager.documentRange.location, to: range.location)
        let end = manager.offset(from: manager.documentRange.location, to: range.endLocation)
        return NSRange(location: location, length: max(0, end - location))
    }

    /// Compare paragraph identity, not raw starts. Hidden block markers can
    /// move a rendered element's start past the source block's start even
    /// though both still belong to the same first paragraph.
    var isFirstParagraphOfBlock: Bool {
        guard let context else { return elementSourceRange.location <= payload.sourceRange.location }
        return context.paragraphIndex.index(containing: elementSourceRange.location)
            == context.paragraphIndex.index(containing: payload.sourceRange.location)
    }
}

/// Zero height, draws nothing.  The one mechanism behind every collapse in the
/// app: structural zoom (§5.2), heading folding (§7.1), long code blocks
/// (§5.1), and the continuation paragraphs of any multi-paragraph object.
///
/// Note what it deliberately is *not*: the characters remain in the storage
/// and in the display string, so find still matches inside a collapsed region
/// and `ElisionPlan` can force it back into view (§14's four-way interaction).
public final class ElidedFragment: NSTextLayoutFragment {
    public required init?(coder: NSCoder) { nil }

    public override init(textElement: NSTextElement, range: NSTextRange?) {
        super.init(textElement: textElement, range: range)
    }

    public override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = 0
        return frame
    }

    public override var renderingSurfaceBounds: CGRect { .zero }

    public override func draw(at point: CGPoint, in context: CGContext) {}
}

/// First row of a structurally hidden run. Continuation rows remain zero
/// height, while this row makes the omission and expansion path explicit.
public final class ElisionCueFragment: NSTextLayoutFragment {
    private let hiddenRange: NSRange
    private weak var context: FragmentContext?

    init(
        textElement: NSTextElement,
        range: NSTextRange?,
        hiddenRange: NSRange,
        context: FragmentContext
    ) {
        self.hiddenRange = hiddenRange
        self.context = context
        super.init(textElement: textElement, range: range)
    }

    public required init?(coder: NSCoder) { nil }

    public override var layoutFragmentFrame: CGRect {
        var frame = super.layoutFragmentFrame
        frame.size.height = 28
        return frame
    }

    public override var renderingSurfaceBounds: CGRect { layoutFragmentFrame }

    public override func draw(at point: CGPoint, in cg: CGContext) {
        guard let context, let storage = context.storage else { return }
        let source = storage.string as NSString
        let clamped = NSIntersectionRange(hiddenRange, NSRange(location: 0, length: source.length))
        let count = source.substring(with: clamped).components(separatedBy: .newlines).count
        let lines = max(1, count - 1)
        let style = context.styleSheet
        let label = NSAttributedString(string: "⋯  \(lines) line\(lines == 1 ? "" : "s")", attributes: [
            .font: NSFont.systemFont(ofSize: 10.5, weight: .medium),
            .foregroundColor: style.textFaint,
        ])
        let frame = layoutFragmentFrame
        let size = label.size()
        let y = point.y + max(0, (frame.height - size.height) / 2)
        let center = point.x + frame.width / 2
        let gap: CGFloat = 9
        style.rule.setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        path.move(to: NSPoint(x: point.x, y: y + size.height / 2))
        path.line(to: NSPoint(x: center - size.width / 2 - gap, y: y + size.height / 2))
        path.move(to: NSPoint(x: center + size.width / 2 + gap, y: y + size.height / 2))
        path.line(to: NSPoint(x: point.x + frame.width, y: y + size.height / 2))
        path.stroke()
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
        label.draw(at: NSPoint(x: center - size.width / 2, y: y))
        NSGraphicsContext.current = previous
    }
}

// MARK: - Clipping

extension NSAttributedString {
    /// This string, wrapped at `width` and cut to `maxHeight`, ending in an
    /// ellipsis when anything was dropped.
    ///
    /// A truncating line-break mode cannot express this: AppKit lays a
    /// paragraph carrying one out on a *single* line, which flattens wrapped
    /// text instead of clipping it.  So the ellipsis goes on the text.  The
    /// common case costs one measurement — proving the string fits — and only
    /// an overflowing string pays for the search.
    func clipped(toHeight maxHeight: CGFloat, width: CGFloat) -> NSAttributedString {
        guard length > 0, width > 1, maxHeight > 0 else { return self }
        func height(_ string: NSAttributedString) -> CGFloat {
            string.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
        }
        guard height(self) > maxHeight + 0.5 else { return self }

        func candidate(_ prefix: Int) -> NSAttributedString {
            let head = NSMutableAttributedString(
                attributedString: attributedSubstring(from: NSRange(location: 0, length: prefix)))
            while head.length > 0,
                  let last = head.string.unicodeScalars.last,
                  CharacterSet.whitespacesAndNewlines.contains(last) {
                head.deleteCharacters(in: NSRange(location: head.length - 1, length: 1))
            }
            head.append(NSAttributedString(
                string: "…",
                attributes: attributes(at: Swift.max(0, Swift.min(prefix, length - 1)), effectiveRange: nil)))
            return head
        }

        var low = 0
        var high = length
        while low < high {
            let mid = (low + high + 1) / 2
            if height(candidate(mid)) <= maxHeight + 0.5 { low = mid } else { high = mid - 1 }
        }
        return candidate(low)
    }
}

// MARK: - Failed objects

/// The trust treatment for an object that did not render (§8.4).
///
/// A diagram, formula, or image the agent claims it produced and did not is a
/// fact about the document, so it is stated: a bordered block in `pathMissing`
/// with a plain label and, beneath it, the source that failed.  The block is
/// sized to what it needs, which is the difference between "this did not work"
/// and two clipped lines of grey text.
struct FailedObject {
    /// Plain, unalarmed: "Diagram could not be rendered".
    var label: String
    /// The source that failed, shown in mono beneath the label.  Empty when the
    /// failure is the whole story (a missing file names itself in the label).
    var source: String

    static let insetX: CGFloat = 14
    static let insetY: CGFloat = 12
    /// Enough source to identify the block without turning a broken diagram
    /// into the longest thing on the page.
    static let sourceLineLimit = 12
}

extension DownrightFragment {
    private func failedObjectText(_ object: FailedObject, style: StyleSheet)
        -> (label: NSAttributedString, source: NSAttributedString) {
        let size = style.bodyFont().pointSize
        let labelParagraph = NSMutableParagraphStyle()
        labelParagraph.lineBreakMode = .byWordWrapping
        let label = NSAttributedString(string: object.label, attributes: [
            .font: style.emphasisFont(bold: true, italic: false).withSize(size * 0.86),
            .foregroundColor: style.pathMissing,
            .paragraphStyle: labelParagraph,
        ])
        guard !object.source.isEmpty else { return (label, NSAttributedString()) }
        let sourceParagraph = NSMutableParagraphStyle()
        // Same rule as a code block: the column does not scroll, so an
        // unbreakable run wraps by character instead of running off the edge.
        sourceParagraph.lineBreakMode = .byCharWrapping
        let source = NSAttributedString(string: object.source, attributes: [
            .font: style.monoFont(size: size * 0.82),
            .foregroundColor: style.textSecondary,
            .paragraphStyle: sourceParagraph,
        ])
        return (label, source.clipped(
            toHeight: style.lineHeight * CGFloat(FailedObject.sourceLineLimit),
            width: max(80, contentWidth - FailedObject.insetX * 2)))
    }

    private func failedObjectMetrics(_ object: FailedObject, style: StyleSheet)
        -> (label: CGFloat, source: CGFloat, width: CGFloat) {
        let width = max(80, contentWidth - FailedObject.insetX * 2)
        let text = failedObjectText(object, style: style)
        let bounds = { (string: NSAttributedString) -> CGFloat in
            guard string.length > 0 else { return 0 }
            return ceil(string.boundingRect(
                with: CGSize(width: width, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height)
        }
        return (bounds(text.label), bounds(text.source), width)
    }

    /// Height the block needs, before any grid snapping the caller applies.
    func failedObjectHeight(_ object: FailedObject, style: StyleSheet) -> CGFloat {
        let metrics = failedObjectMetrics(object, style: style)
        let gap = metrics.source > 0 ? RenderMetrics.imageCaptionGap : 0
        return metrics.label + gap + metrics.source + FailedObject.insetY * 2
    }

    func drawFailedObject(
        _ object: FailedObject,
        in rect: CGRect,
        style: StyleSheet,
        in cg: CGContext
    ) {
        cg.fillRect(rect, color: style.codeBackground, radius: RenderMetrics.imageCornerRadius)
        cg.saveGState()
        cg.setStrokeColor(style.pathMissing.withAlphaComponent(0.55).cgColor)
        cg.setLineWidth(1)
        cg.addPath(CGPath(
            roundedRect: rect.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: RenderMetrics.imageCornerRadius,
            cornerHeight: RenderMetrics.imageCornerRadius,
            transform: nil))
        cg.strokePath()
        cg.restoreGState()

        let metrics = failedObjectMetrics(object, style: style)
        let text = failedObjectText(object, style: style)
        let x = rect.minX + FailedObject.insetX
        cg.drawText(text.label,
                    in: CGRect(x: x, y: rect.minY + FailedObject.insetY,
                               width: metrics.width, height: metrics.label),
                    flipped: true)
        guard metrics.source > 0 else { return }
        cg.drawText(text.source,
                    in: CGRect(x: x,
                               y: rect.minY + FailedObject.insetY + metrics.label
                                   + RenderMetrics.imageCaptionGap,
                               width: metrics.width, height: metrics.source),
                    flipped: true)
    }
}

// MARK: - Drawing helpers

extension NSColor {
    /// Blend toward the background, for tints that must not compete with text.
    func mixed(with other: NSColor, amount: CGFloat) -> NSColor {
        let a = usingColorSpace(.sRGB) ?? self
        let b = other.usingColorSpace(.sRGB) ?? other
        let t = Swift.max(0, Swift.min(1, amount))
        return NSColor(
            srgbRed: a.redComponent + (b.redComponent - a.redComponent) * t,
            green: a.greenComponent + (b.greenComponent - a.greenComponent) * t,
            blue: a.blueComponent + (b.blueComponent - a.blueComponent) * t,
            alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * t)
    }
}

/// Draws an `NSImage` into a CGContext without going through AppKit's focus
/// stack, which is not valid inside a layout fragment.
///
/// The text view's drawing context is flipped (y=0 at the top).  `CGContext.draw`
/// treats image row 0 as the bottom of the target rect, so the context must be
/// mirrored around the rect's midline before drawing or the bitmap appears
/// upside down.  The flip is isolated with `saveGState`/`restoreGState` and never
/// leaks into the surrounding context.
func drawNSImage(_ image: NSImage, in target: CGRect, in cg: CGContext, cornerRadius: CGFloat = 0) {
    var proposed = target
    // Rasterize at this view's backing scale, not the main screen's — a
    // drawing-handler NSImage has no representation, so `cgImage(forProposedRect:)`
    // would otherwise sample at `NSScreen.main` and render math (and other
    // bitmap fragments) at the wrong density on any other display.
    let drawingContext = NSGraphicsContext(cgContext: cg, flipped: true)
    guard let cgImage = image.cgImage(forProposedRect: &proposed, context: drawingContext, hints: nil) else { return }
    cg.saveGState()
    if cornerRadius > 0 {
        cg.addPath(CGPath(roundedRect: target, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil))
        cg.clip()
    }
    cg.translateBy(x: 0, y: target.midY)
    cg.scaleBy(x: 1, y: -1)
    cg.translateBy(x: 0, y: -target.midY)
    cg.draw(cgImage, in: target)
    cg.restoreGState()
}

/// Which corners of a rect to round.  Local `OptionSet` rather than AppKit's
/// `RectCorner` so the fragment layer doesn't depend on the `NSRectCorner`
/// optionality dance.
struct RectCorners: OptionSet {
    let rawValue: Int
    static let topLeft = RectCorners(rawValue: 1 << 0)
    static let topRight = RectCorners(rawValue: 1 << 1)
    static let bottomLeft = RectCorners(rawValue: 1 << 2)
    static let bottomRight = RectCorners(rawValue: 1 << 3)
    static let all: RectCorners = [.topLeft, .topRight, .bottomLeft, .bottomRight]
}

extension CGContext {
    /// Named to avoid overloading `CGContext.fill(_:)`, whose default-argument
    /// overload resolution would otherwise recurse.
    func fillRect(_ rect: CGRect, color: NSColor, radius: CGFloat = 0) {
        guard rect.width > 0, rect.height > 0 else { return }
        setFillColor(color.cgColor)
        if radius > 0 {
            addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            fillPath()
        } else {
            fill(rect)
        }
    }

    /// Fills with only some corners rounded.  The code band is built from a
    /// header, body lines, and a footer that must butt *flush* against each
    /// other — rounding every corner of each piece and overlapping them left a
    /// double-painted seam.  Rounding only the outer corners (top of the header,
    /// bottom of the footer) and leaving the shared edges square keeps the whole
    /// band a single flat tint with no overlap.
    func fillRect(_ rect: CGRect, color: NSColor, radius: CGFloat, corners: RectCorners) {
        guard rect.width > 0, rect.height > 0 else { return }
        guard radius > 0, !corners.isEmpty else { fillRect(rect, color: color); return }
        setFillColor(color.cgColor)
        let r = min(radius, min(rect.width, rect.height) / 2)
        let path = CGMutablePath()
        // Flipped-friendly: build in the rect's own space corner by corner.
        let tl = corners.contains(.topLeft) ? r : 0
        let tr = corners.contains(.topRight) ? r : 0
        let br = corners.contains(.bottomRight) ? r : 0
        let bl = corners.contains(.bottomLeft) ? r : 0
        let minX = rect.minX, maxX = rect.maxX, minY = rect.minY, maxY = rect.maxY
        // Start just after the top-left corner, walk clockwise.
        path.move(to: CGPoint(x: minX + tl, y: minY))
        path.addLine(to: CGPoint(x: maxX - tr, y: minY))
        if tr > 0 { path.addArc(center: CGPoint(x: maxX - tr, y: minY + tr), radius: tr,
                                startAngle: -.pi / 2, endAngle: 0, clockwise: false) }
        path.addLine(to: CGPoint(x: maxX, y: maxY - br))
        if br > 0 { path.addArc(center: CGPoint(x: maxX - br, y: maxY - br), radius: br,
                                startAngle: 0, endAngle: .pi / 2, clockwise: false) }
        path.addLine(to: CGPoint(x: minX + bl, y: maxY))
        if bl > 0 { path.addArc(center: CGPoint(x: minX + bl, y: maxY - bl), radius: bl,
                                startAngle: .pi / 2, endAngle: .pi, clockwise: false) }
        path.addLine(to: CGPoint(x: minX, y: minY + tl))
        if tl > 0 { path.addArc(center: CGPoint(x: minX + tl, y: minY + tl), radius: tl,
                                startAngle: .pi, endAngle: .pi * 1.5, clockwise: false) }
        path.closeSubpath()
        addPath(path)
        fillPath()
    }

    /// Draws an attributed string with the current context, without disturbing
    /// AppKit's focus stack more than necessary.
    func drawText(_ string: NSAttributedString, in rect: CGRect, flipped: Bool) {
        guard string.length > 0, rect.width > 1 else { return }
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: self, flipped: flipped)
        string.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.current = previous
    }
}
