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

    /// Interior YAML newlines become prose spaces in the presentation layer.
    private func singleLine(_ value: String) -> String {
        let collapsed = value.replacingOccurrences(of: "\n", with: " ")
        let squashed = collapsed.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return squashed.isEmpty ? value.trimmingCharacters(in: .whitespaces) : squashed
    }

    override var suppressesText: Bool { true }

    override var overrideHeight: CGFloat? {
        guard isFirstParagraphOfBlock else { return 0 }
        guard let style = styleSheet, !fields.isEmpty else { return 0 }
        let keyWidth = min(112, max(64, proseContentWidth * 0.20))
        let valueWidth = max(80, proseContentWidth - keyWidth - 18)
        let font = style.bodyFont().withSize(style.bodyFont().pointSize * 0.86)
        let height = fields.reduce(CGFloat.zero) { partial, field in
            let rect = (singleLine(field.value) as NSString).boundingRect(
                with: CGSize(width: valueWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font]
            )
            return partial + max(style.lineHeight, ceil(rect.height) + 6)
        }
        return RenderMetrics.snap(height + 14, grid: max(1, style.baselineGrid))
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet, !fields.isEmpty else { return }
        let card = CGRect(x: point.x, y: point.y,
                          width: proseContentWidth, height: layoutFragmentFrame.height)
        let keyWidth = min(112, max(64, card.width * 0.20))
        let valueX = card.minX + keyWidth + 18
        let valueWidth = max(80, card.maxX - valueX)
        let font = style.bodyFont().withSize(style.bodyFont().pointSize * 0.86)
        let keyFont = NSFont.systemFont(ofSize: font.pointSize * 0.90, weight: .medium)
        var y = card.minY + 2
        for field in fields {
            let value = NSAttributedString(string: singleLine(field.value), attributes: [
                .font: font, .foregroundColor: style.textSecondary,
            ])
            let valueHeight = max(style.lineHeight, ceil(value.boundingRect(
                with: CGSize(width: valueWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height) + 6)
            let key = NSAttributedString(string: field.key, attributes: [
                .font: keyFont, .foregroundColor: style.textFaint,
            ])
            cg.drawText(
                key,
                in: CGRect(
                    x: card.minX + max(0, keyWidth - key.size().width),
                    y: y,
                    width: min(keyWidth, key.size().width),
                    height: style.lineHeight
                ),
                flipped: true
            )
            cg.drawText(
                value,
                in: CGRect(x: valueX, y: y, width: valueWidth, height: valueHeight),
                flipped: true
            )
            y += valueHeight
        }
        cg.fillRect(
            CGRect(x: card.minX, y: card.maxY - 1, width: card.width, height: 1),
            color: style.rule
        )
    }
}
