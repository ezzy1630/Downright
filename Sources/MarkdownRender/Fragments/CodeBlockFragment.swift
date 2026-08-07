import AppKit
import MarkdownCore

/// Fenced code (§11.3): a subtle tint plus a left rule, **never** a heavy
/// bordered card.  Language chip top-right, copy button on hover (§7.1),
/// ```diff fences coloured by the engine's diff tokens.
///
/// The fence lines are not hidden — they become the band's chrome.  That keeps
/// the display string closer to the storage, keeps ⌘C yielding a complete
/// fenced block, and means the top and bottom padding is a real paragraph with
/// real geometry rather than an offset applied to somebody's glyph run.
final class CodeBlockFragment: DownrightFragment {

    enum Role {
        /// Opening fence line: top padding, language chip, copy button.
        case openChrome
        /// A line of code.
        case body
        /// Closing fence line: bottom padding.
        case closeChrome
        /// Read-mode one-line chip for a block over 20 lines (§5.1).
        case collapsedChip
    }

    let role: Role
    let language: String
    let lineCount: Int

    init(
        textElement: NSTextElement,
        range: NSTextRange?,
        payload: FragmentPayload,
        context: FragmentContext,
        role: Role,
        lineCount: Int
    ) {
        self.role = role
        self.language = payload.detail
        self.lineCount = lineCount
        super.init(textElement: textElement, range: range, payload: payload, context: context)
    }

    required init?(coder: NSCoder) { nil }

    override var suppressesText: Bool {
        switch role {
        case .openChrome, .closeChrome, .collapsedChip: return true
        case .body: return false
        }
    }

    override var overrideHeight: CGFloat? {
        switch role {
        case .openChrome: return RenderMetrics.codeHeaderHeight
        case .closeChrome: return RenderMetrics.codeInsetY
        case .collapsedChip: return RenderMetrics.chipHeight
        case .body: return nil
        }
    }

    /// The closing chrome's copy control is taller than the band it sits in, so
    /// the fragment has to claim the surface it draws into or TextKit clips it.
    public override var renderingSurfaceBounds: CGRect {
        let base = super.renderingSurfaceBounds
        guard role == .closeChrome else { return base }
        let overhang = Self.copyControlOverhang
        return base.union(CGRect(x: base.minX, y: -overhang,
                                 width: base.width,
                                 height: layoutFragmentFrame.height + overhang * 2))
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard let style = styleSheet else { return }
        let band = bandRect(at: point)

        switch role {
        case .collapsedChip:
            drawCollapsedChip(band, style: style, in: cg)
        case .openChrome:
            // Overdraws downward by the corner radius so the seam with the
            // first code line has no notch; the body fills the same colour.
            var extended = band
            extended.size.height += RenderMetrics.codeCornerRadius
            cg.fillRect(extended, color: style.codeBackground, radius: RenderMetrics.codeCornerRadius)
            drawRule(band, style: style, in: cg)
            drawChip(band, style: style, in: cg)
        case .closeChrome:
            var extended = band
            extended.origin.y -= RenderMetrics.codeCornerRadius
            extended.size.height += RenderMetrics.codeCornerRadius
            cg.fillRect(extended, color: style.codeBackground, radius: RenderMetrics.codeCornerRadius)
            drawRule(band, style: style, in: cg)
            // A long block scrolls its opening chrome off the top, taking the
            // only copy control with it.  The closing fence carries a second
            // one so the block always has a reachable copy (§7.1).
            drawCopyControl(in: band, style: style, language: "", in: cg)
        case .body:
            cg.fillRect(band, color: style.codeBackground)
            drawRule(band, style: style, in: cg)
        }
    }

    private func drawRule(_ band: CGRect, style: StyleSheet, in cg: CGContext) {
        let topInset: CGFloat = role == .openChrome ? 4 : 0
        let bottomInset: CGFloat = role == .closeChrome ? 4 : 0
        cg.fillRect(
            CGRect(
                x: band.minX,
                y: band.minY + topInset,
                width: RenderMetrics.codeRuleWidth,
                height: max(1, band.height - topInset - bottomInset)
            ),
            color: style.codeRule,
            radius: RenderMetrics.codeRuleWidth / 2
        )
    }

    private func drawChip(_ band: CGRect, style: StyleSheet, in cg: CGContext) {
        if !language.isEmpty {
            let chip = Self.chipRect(in: band, style: style, language: language)
            cg.fillRect(chip, color: style.codeRule.withAlphaComponent(0.22), radius: 4)
            cg.drawText(Self.chipText(language, style: style), in: chip.insetBy(dx: 6, dy: 2), flipped: true)
        }
        drawCopyControl(in: band, style: style, language: language, in: cg)
    }

    private func drawCopyControl(in band: CGRect, style: StyleSheet, language: String, in cg: CGContext) {
        guard context?.hoveredFragmentRange == payload.sourceRange else { return }
        let copy = Self.copyButtonRect(in: band, style: style, language: language)
        cg.fillRect(copy, color: style.codeRule.withAlphaComponent(0.22), radius: 6)
        let copied = context?.copiedCodeRange == payload.sourceRange
        let symbol = copied ? "checkmark" : "doc.on.doc"
        let description = copied ? "Copied" : "Copy code"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)) {
            let tinted = image.tinted(style.textSecondary)
            draw(image: tinted, in: copy.insetBy(dx: 8, dy: 8), in: cg)
        }
    }

    private func drawCollapsedChip(_ band: CGRect, style: StyleSheet, in cg: CGContext) {
        let chip = CGRect(x: band.minX, y: band.minY + 2, width: band.width, height: band.height - 4)
        cg.fillRect(chip, color: style.codeBackground, radius: RenderMetrics.codeCornerRadius)
        cg.fillRect(CGRect(x: chip.minX, y: chip.minY, width: RenderMetrics.codeRuleWidth, height: chip.height),
                    color: style.codeRule)

        let label = language.isEmpty ? "code" : language
        let text = "\(label) · \(lineCount) lines"
        let attributed = NSAttributedString(string: text, attributes: [
            .font: style.monoFont(size: 11),
            .foregroundColor: style.textSecondary,
        ])
        cg.drawText(attributed, in: chip.insetBy(dx: RenderMetrics.codeInsetX, dy: 6), flipped: true)
        if let triangle = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Expand code")?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold)) {
            draw(image: triangle.tinted(style.textSecondary),
                 in: CGRect(x: chip.minX + 7, y: chip.midY - 5, width: 10, height: 10), in: cg)
        }
    }

    /// The tinted band, inset to the block's own indentation so a code block
    /// inside a list stays inside the list.
    func bandRect(at point: CGPoint) -> CGRect {
        let indent = max(0, (paragraphStyle?.headIndent ?? 0) - RenderMetrics.codeInsetX)
        let frame = layoutFragmentFrame
        // TextKit bakes the paragraph head indent into the fragment origin, so
        // `point.x` already sits `codeInsetX` right of the column edge — adding
        // `indent` again shifted the whole band (and its chip) 22pt right of
        // the text.  Start the band at the glyph edge minus the inset, flush
        // with the column; the `contentWidth - indent` width keeps the right
        // edge on the measure.
        let textEdge = point.x + (textLineFragments.first?.typographicBounds.minX ?? 0)
        return CGRect(x: textEdge - RenderMetrics.codeInsetX, y: point.y,
                      width: max(1, contentWidth - indent), height: frame.height)
    }

    // MARK: Hit-test geometry, shared with the view (§7.1)

    static func chipText(_ string: String, style: StyleSheet) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [
            .font: style.monoFont(size: 10),
            .foregroundColor: style.textSecondary,
        ])
    }

    static func chipRect(in band: CGRect, style: StyleSheet, language: String) -> CGRect {
        let width = chipText(language, style: style).size().width + 12
        // Vertically centred in the header row so the badge never touches the
        // band's top edge (§11.3).
        let y = band.minY + max(0, (band.height - 17) / 2)
        return CGRect(x: band.maxX - width - RenderMetrics.codeInsetX, y: y, width: width, height: 17)
    }

    /// A 28pt square: the smallest pointer target that does not need aiming.
    /// The old 24x17 was a decoration you had to hunt for.
    static let copyControlSide: CGFloat = 28

    /// How far the closing chrome's control overhangs its own 14pt band.  The
    /// band is padding, not a header row, so the control is centred on it and
    /// claims the surface above and below rather than shrinking to fit.
    static var copyControlOverhang: CGFloat {
        max(0, (copyControlSide - RenderMetrics.codeInsetY) / 2).rounded(.up)
    }

    static func copyButtonRect(in band: CGRect, style: StyleSheet, language: String) -> CGRect {
        let side = copyControlSide
        let chip = language.isEmpty
            ? band.maxX - RenderMetrics.codeInsetX
            : chipRect(in: band, style: style, language: language).minX
        return CGRect(x: chip - side - 6, y: band.midY - side / 2, width: side, height: side)
    }
}

private extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
    }
}
