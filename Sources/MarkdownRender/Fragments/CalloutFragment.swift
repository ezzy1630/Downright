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

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard let style = styleSheet else { return }
        let frame = layoutFragmentFrame
        let indent = max(0, (paragraphStyle?.headIndent ?? RenderMetrics.calloutInsetX) - RenderMetrics.calloutInsetX)
        let color = kind.map { style.calloutColor($0) } ?? style.quoteRule
        let width = kind == nil ? RenderMetrics.quoteRuleWidth : RenderMetrics.calloutRuleWidth

        if kind != nil {
            cg.fillRect(CGRect(x: point.x + indent, y: point.y,
                               width: max(1, contentWidth - indent), height: frame.height),
                        color: color.withAlphaComponent(0.05))
        }

        cg.fillRect(CGRect(x: point.x + indent, y: point.y, width: width, height: frame.height),
                    color: color, radius: width / 2)

        // The icon rides on the callout's first line only.
        guard let kind, isFirstParagraphOfBlock else { return }
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
        let top = point.y + max(0, (style.lineHeight - configured.size.height) / 2)
        draw(image: tinted,
             in: CGRect(x: point.x + indent + width + 5, y: top,
                        width: configured.size.width, height: configured.size.height),
             in: cg)

        if !title.isEmpty {
            let label = NSAttributedString(string: title, attributes: [
                .font: NSFont.systemFont(ofSize: style.bodyFont().pointSize, weight: .semibold),
                .foregroundColor: color,
            ])
            cg.drawText(label,
                        in: CGRect(x: point.x + indent + RenderMetrics.calloutIconInsetX,
                                   y: point.y, width: max(40, contentWidth - indent - RenderMetrics.calloutIconInsetX),
                                   height: style.lineHeight),
                        flipped: true)
        }
    }
}
