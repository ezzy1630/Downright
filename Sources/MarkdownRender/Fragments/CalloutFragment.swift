import AppKit
import MarkdownCore

/// Quotes and callouts (§11.3): a coloured left rule plus an SF Symbol icon,
/// with a restrained five-percent tint. Agents emit `> [!NOTE]` constantly,
/// so the treatment remains quiet while still separating it from a quote.
///
/// Unlike the object fragments, this one keeps its glyphs: the text is real
/// text with real selection and real find behaviour, and the fragment only
/// adds the rule and the icon underneath it.
final class CalloutFragment: DownrightFragment {
    private let kind: CalloutKind?
    private let title: String

    override init(textElement: NSTextElement, range: NSTextRange?, payload: FragmentPayload, context: FragmentContext) {
        let parts = payload.detail.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        self.kind = parts.first.flatMap { CalloutKind(token: String($0)) }
        self.title = parts.count > 1 ? String(parts[1]) : ""
        super.init(textElement: textElement, range: range, payload: payload, context: context)
    }

    required init?(coder: NSCoder) { nil }

    override var verticalPadding: (top: CGFloat, bottom: CGFloat) {
        guard kind != nil else { return (0, 0) }
        let headerHeight = title.isEmpty ? 0 : (styleSheet?.lineHeight ?? 24)
        return (
            isFirstParagraphOfBlock ? RenderMetrics.calloutInsetY + headerHeight : 0,
            isLastParagraphOfBlock ? RenderMetrics.calloutInsetY : 0
        )
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard let style = styleSheet else { return }
        let frame = layoutFragmentFrame
        let reservedInset = kind == nil
            ? RenderMetrics.calloutInsetX
            : RenderMetrics.calloutIconInsetX
        let color = kind.map { style.calloutColor($0) } ?? style.quoteRule
        let width = kind == nil ? RenderMetrics.quoteRuleWidth : RenderMetrics.calloutRuleWidth
        let textEdge = point.x + (textLineFragments.first?.typographicBounds.minX ?? 0)

        // TextKit's fragment point is the actual glyph edge after hidden
        // marker substitution. Put semantic chrome in the reserved column to
        // its left; drawing it inside `point.x` covers the first word.
        let band = CGRect(
            x: textEdge - reservedInset,
            y: point.y,
            width: max(1, contentWidth + reservedInset),
            height: frame.height
        )
        if kind != nil {
            cg.fillRect(band, color: color.withAlphaComponent(0.055),
                        radius: RenderMetrics.calloutCornerRadius)
        }

        let ruleInset: CGFloat = kind == nil ? 0 : 4
        cg.fillRect(
            CGRect(
                x: band.minX,
                y: band.minY + ruleInset,
                width: width,
                height: max(1, band.height - ruleInset * 2)
            ),
            color: color,
            radius: width / 2
        )

        // Untitled callouts stay typographic: rule + tint, no floating badge.
        // A symbol only earns space when it is paired with a real title.
        guard let kind, isFirstParagraphOfBlock, !title.isEmpty else { return }
        let symbol = style.calloutSymbol(kind)
        guard let icon = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) else { return }
        let side = style.bodyFont().pointSize
        let configured = icon.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: side, weight: .medium)) ?? icon
        let tinted = NSImage(size: configured.size, flipped: false) { rect in
            configured.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        let top = point.y + RenderMetrics.calloutInsetY
            + max(0, (style.lineHeight - configured.size.height) / 2)
        let iconX = band.minX + width + 7
        draw(
            image: tinted,
            in: CGRect(x: iconX, y: top,
                       width: configured.size.width, height: configured.size.height),
            in: cg
        )

        if !title.isEmpty {
            let label = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: style.bodyFont().pointSize, weight: .semibold),
                .foregroundColor: color,
            ])
            cg.drawText(label,
                        in: CGRect(x: band.minX + RenderMetrics.calloutIconInsetX,
                                   y: point.y + RenderMetrics.calloutInsetY,
                                   width: max(40, contentWidth - RenderMetrics.calloutIconInsetX),
                                   height: style.lineHeight),
                        flipped: true)
        }
    }
}
