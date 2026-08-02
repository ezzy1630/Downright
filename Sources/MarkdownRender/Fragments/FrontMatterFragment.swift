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
        let showsTitle = context?.documentHasH1 == false && fields.contains { $0.key.lowercased() == "title" }
        let chipFont = style.bodyFont().withSize(style.bodyFont().pointSize * 0.85)
        let available = max(80, contentWidth - 18)
        var used: CGFloat = 0
        var chipLines: CGFloat = 1
        for field in fields where !(showsTitle && field.key.lowercased() == "title") {
            let width = min(available, NSAttributedString(
                string: "\(field.key)  \(field.value)", attributes: [.font: chipFont]
            ).size().width + 22)
            if used > 0, used + width > available { chipLines += 1; used = 0 }
            used += width + 6
        }
        let lines = chipLines + (showsTitle ? 1 : 0)
        return RenderMetrics.snap(lines * style.lineHeight + 18, grid: max(1, style.baselineGrid))
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet, !fields.isEmpty else { return }
        let card = CGRect(x: point.x, y: point.y, width: contentWidth, height: layoutFragmentFrame.height)
        let triangle = NSAttributedString(string: "▸", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: style.textFaint,
        ])
        cg.drawText(triangle, in: CGRect(x: card.minX, y: card.minY + 5, width: 12, height: 16), flipped: true)

        let title = fields.first { $0.key.lowercased() == "title" }
        let showsTitle = context?.documentHasH1 == false && title != nil
        var y = card.minY + 2
        if let title, showsTitle {
            cg.drawText(NSAttributedString(string: title.value, attributes: [
                .font: style.headingFont(level: 1).withSize(style.bodyFont().pointSize * 1.35),
                .foregroundColor: style.text,
            ]), in: CGRect(x: card.minX + 18, y: y, width: card.width - 18, height: style.lineHeight), flipped: true)
            y += style.lineHeight
        }

        let chipFont = style.bodyFont().withSize(style.bodyFont().pointSize * 0.85)
        var x = card.minX + 18
        for field in fields where !(showsTitle && field.key.lowercased() == "title") {
            let label = "\(field.key)  \(field.value)"
            let text = NSAttributedString(string: label, attributes: [
                .font: chipFont, .foregroundColor: style.textSecondary,
            ])
            let width = min(card.width - 18, text.size().width + 16)
            if x + width > card.maxX { x = card.minX + 18; y += style.lineHeight }
            let chip = CGRect(x: x, y: y + 2, width: width, height: style.lineHeight - 4)
            cg.fillRect(chip, color: style.inlineCodeBackground, radius: 6)
            cg.drawText(text, in: chip.insetBy(dx: 8, dy: 1), flipped: true)
            x += width + 6
        }
    }
}
