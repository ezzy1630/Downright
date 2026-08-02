import AppKit
import MarkdownCore

/// YAML front matter as a compact metadata card, **not a code block** (§5.1).
///
/// Agents put the useful summary of a document in its front matter and every
/// other viewer renders it as an undifferentiated grey slab of YAML.  Reading
/// it as a key/value card is a two-line change in perception.
///
/// In Live mode with the caret inside, the provider hands back a plain
/// fragment instead and the raw YAML shows through, highlighted (§6.2).
final class FrontMatterFragment: DownrightFragment {
    private let fields: [(key: String, value: String)]

    init(
        textElement: NSTextElement,
        range: NSTextRange?,
        payload: FragmentPayload,
        context: FragmentContext,
        fields: [(key: String, value: String)]
    ) {
        self.fields = fields
        super.init(textElement: textElement, range: range, payload: payload, context: context)
    }

    required init?(coder: NSCoder) { nil }

    override var suppressesText: Bool { true }

    override var overrideHeight: CGFloat? {
        guard isFirstParagraphOfBlock else { return 0 }
        guard let style = styleSheet, !fields.isEmpty else { return 0 }
        let rows = CGFloat(fields.count)
        let height = RenderMetrics.frontMatterInsetY * 2
            + rows * style.lineHeight
            + max(0, rows - 1) * RenderMetrics.frontMatterRowGap
        return RenderMetrics.snap(height + style.lineHeight * 0.5, grid: max(1, style.baselineGrid))
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet, !fields.isEmpty else { return }
        let card = CGRect(x: point.x, y: point.y, width: contentWidth,
                          height: layoutFragmentFrame.height - style.lineHeight * 0.5)
        cg.fillRect(card, color: style.codeBackground.withAlphaComponent(0.7), radius: RenderMetrics.codeCornerRadius)
        cg.fillRect(CGRect(x: card.minX, y: card.minY, width: 2, height: card.height),
                    color: style.accent.withAlphaComponent(0.5), radius: 1)

        let keyFont = style.monoFont(size: style.bodyFont().pointSize * 0.82)
        let valueFont = style.bodyFont().withSize(style.bodyFont().pointSize * 0.9)
        let keyWidth = fields
            .map { NSAttributedString(string: $0.key, attributes: [.font: keyFont]).size().width }
            .max() ?? 60

        var y = card.minY + RenderMetrics.frontMatterInsetY
        for field in fields {
            let rowHeight = style.lineHeight
            cg.drawText(NSAttributedString(string: field.key, attributes: [
                .font: keyFont, .foregroundColor: style.textFaint,
            ]), in: CGRect(x: card.minX + RenderMetrics.frontMatterInsetX, y: y,
                           width: keyWidth + 4, height: rowHeight), flipped: true)

            let valueX = card.minX + RenderMetrics.frontMatterInsetX + keyWidth + 14
            cg.drawText(NSAttributedString(string: field.value, attributes: [
                .font: valueFont, .foregroundColor: style.text,
            ]), in: CGRect(x: valueX, y: y,
                           width: max(20, card.maxX - valueX - RenderMetrics.frontMatterInsetX),
                           height: rowHeight), flipped: true)
            y += rowHeight + RenderMetrics.frontMatterRowGap
        }
    }
}
