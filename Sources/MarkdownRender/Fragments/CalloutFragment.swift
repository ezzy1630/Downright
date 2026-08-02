import AppKit
import MarkdownCore

/// Quotes and callouts (§11.3): a coloured left rule plus an SF Symbol icon,
/// **never a filled box**.  Agents emit `> [!NOTE]` constantly (§4.1), so this
/// is a high-traffic element and a filled panel every third paragraph would
/// wreck the page.
///
/// Unlike the object fragments, this one keeps its glyphs: the text is real
/// text with real selection and real find behaviour, and the fragment only
/// adds the rule and the icon underneath it.
final class CalloutFragment: DownrightFragment {
    private let kind: CalloutKind?

    override init(textElement: NSTextElement, range: NSTextRange?, payload: FragmentPayload, context: FragmentContext) {
        self.kind = CalloutKind(token: payload.detail)
        super.init(textElement: textElement, range: range, payload: payload, context: context)
    }

    required init?(coder: NSCoder) { nil }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard let style = styleSheet else { return }
        let frame = layoutFragmentFrame
        let indent = max(0, (paragraphStyle?.headIndent ?? RenderMetrics.calloutInsetX) - RenderMetrics.calloutInsetX)
        let color = kind.map { style.calloutColor($0) } ?? style.quoteRule
        let width = kind == nil ? RenderMetrics.quoteRuleWidth : RenderMetrics.calloutRuleWidth

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
    }
}
