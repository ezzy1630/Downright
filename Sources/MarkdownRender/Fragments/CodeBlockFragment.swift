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

    /// The chrome rows claim their band *plus* `codeBlockGap` of page
    /// background on the block's outer edge, which `bandRect` then leaves
    /// unpainted.  Two adjacent fences therefore have real page between them
    /// instead of butting tint against tint.
    override var overrideHeight: CGFloat? {
        switch role {
        case .openChrome: return RenderMetrics.codeHeaderHeight + RenderMetrics.codeBlockGap
        case .closeChrome: return RenderMetrics.codeInsetY + RenderMetrics.codeBlockGap
        case .collapsedChip: return RenderMetrics.chipHeight
        case .body: return nil
        }
    }

    /// Untinted page background this fragment reserves, and where it sits.
    private var outerGap: (top: CGFloat, bottom: CGFloat) {
        switch role {
        case .openChrome: return (RenderMetrics.codeBlockGap, 0)
        case .closeChrome: return (0, RenderMetrics.codeBlockGap)
        case .body, .collapsedChip: return (0, 0)
        }
    }

    /// The band paints exactly its own frame.  TextKit 2 composites each layout
    /// fragment as an independent, lazily-rendered surface, so a fragment that
    /// paints *outside* its frame (a taller claimed surface) leaves a tinted
    /// rectangle behind when the neighbour it overlaps does not redraw in the
    /// same pass — the stray shading blocks that appear beside and below code.
    /// Keeping every fill inside the frame is what makes the band seam-tight.
    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard let style = styleSheet else { return }
        let band = bandRect(at: point)

        switch role {
        case .collapsedChip:
            drawCollapsedChip(band, style: style, in: cg)
        case .openChrome:
            // The top edge carries the rounded corners; the bottom is square so
            // it butts flush against the first code line with no overlap.
            cg.fillRect(band, color: style.codeBackground,
                        radius: RenderMetrics.codeCornerRadius,
                        corners: [.topLeft, .topRight])
            drawHorizontalEdge(band, atTop: true, style: style, in: cg)
            drawRule(band, style: style, in: cg)
            drawChip(band, style: style, in: cg)
        case .closeChrome:
            // Mirror image: square top against the last code line, rounded
            // bottom edge.  The copy control is allowed to be taller than this
            // thin band, but the *fill* never leaves the frame.
            cg.fillRect(band, color: style.codeBackground,
                        radius: RenderMetrics.codeCornerRadius,
                        corners: [.bottomLeft, .bottomRight])
            drawHorizontalEdge(band, atTop: false, style: style, in: cg)
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

    /// A one-pixel optical edge gives the tinted band depth against both paper
    /// and dark canvas. Only the outer fragments draw it, so lazy TextKit
    /// surfaces never produce seams between code rows.
    private func drawHorizontalEdge(
        _ band: CGRect,
        atTop: Bool,
        style: StyleSheet,
        in cg: CGContext
    ) {
        let y = atTop ? band.minY + 0.5 : band.maxY - 1
        let edge = atTop
            ? style.surface.withAlphaComponent(0.72)
            : style.text.withAlphaComponent(0.10)
        cg.fillRect(
            CGRect(x: band.minX + RenderMetrics.codeCornerRadius,
                   y: y,
                   width: max(0, band.width - RenderMetrics.codeCornerRadius * 2),
                   height: 1),
            color: edge
        )
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
        let isHovered = context?.hoveredFragmentRange == payload.sourceRange
        if !language.isEmpty, !isHovered {
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
        // `firstLineHeadIndent`, not `headIndent`: wrapped code rows hang by a
        // continuation indent, and measuring the band from that would pull its
        // right edge in by two columns on any block containing a long line.
        let indent = max(0, (paragraphStyle?.firstLineHeadIndent ?? 0) - RenderMetrics.codeInsetX)
        let gap = outerGap
        let frame = layoutFragmentFrame
        // TextKit draws into a rendering surface widened by `revealSlack`.
        // That local draw point already includes one code inset, while the
        // paragraph fragment carries the other. Back both out, then restore
        // only the block's structural indent. Otherwise top-level bands land
        // 22pt right of prose and nested bands lose their list edge.
        return CGRect(x: point.x + indent - RenderMetrics.codeInsetX * 2,
                      y: point.y + gap.top,
                      width: max(1, contentWidth - indent),
                      height: max(1, frame.height - gap.top - gap.bottom))
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

    static func copyButtonRect(in band: CGRect, style: StyleSheet, language: String) -> CGRect {
        // Clamp to the band: the header's 36pt row keeps the full 28pt target,
        // but the 14pt closing fence collapses the button to fit so the control
        // (like the fill around it) never paints outside the fragment's frame.
        let side = min(copyControlSide, max(0, band.height))
        let trailing = band.maxX - RenderMetrics.codeInsetX
        return CGRect(x: trailing - side, y: band.midY - side / 2, width: side, height: side)
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
