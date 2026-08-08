import AppKit
import MarkdownCore

/// Presentation-only sidenotes anchored to their in-flow references. The
/// source definitions remain untouched for Source mode and export.
final class FootnoteMarginView: NSView {
    weak var textView: MarkdownTextView?
    var styleSheet: StyleSheet { textView?.styleSheet ?? .current }

    init(textView: MarkdownTextView) {
        self.textView = textView
        super.init(frame: .zero)
        setAccessibilityElement(false)
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let textView, textView.mode != .source else { return }
        let document = textView.parsedDocument
        let references = FootnoteReferenceDisplay.references(in: document)
        guard !references.isEmpty else { return }

        let font = styleSheet.bodyFont().withSize(styleSheet.bodyFont().pointSize * 0.85)
        let labelFont = NSFont.monospacedDigitSystemFont(ofSize: font.pointSize * 0.78, weight: .semibold)
        let lineHeight = max(font.ascender - font.descender + font.leading, styleSheet.lineHeight * 0.85)
        let clipOrigin = textView.enclosingScrollView?.contentView.bounds.minY ?? 0
        var nextY: CGFloat = 0

        for reference in references {
            guard let definition = document.footnotes[reference.identifier],
                  let anchor = textView.rect(forOffset: reference.range.location)
            else { continue }
            let targetY = anchor.minY - clipOrigin
            let body = document.substring(definition.contentRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            let text = NSAttributedString(string: body, attributes: [
                .font: font,
                .foregroundColor: styleSheet.textSecondary,
            ])
            let textRect = text.boundingRect(
                with: CGSize(width: max(40, bounds.width - 24), height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            let height = max(lineHeight, ceil(textRect.height))
            guard targetY + height >= bounds.minY, targetY <= bounds.maxY else { continue }
            let y = max(targetY, nextY)
            let frame = NSRect(x: 0, y: y, width: bounds.width, height: height)
            guard frame.maxY >= dirtyRect.minY, frame.minY <= dirtyRect.maxY else {
                nextY = frame.maxY + 10
                continue
            }
            NSAttributedString(string: reference.identifier, attributes: [
                .font: labelFont,
                .foregroundColor: styleSheet.accent,
            ]).draw(in: NSRect(x: 0, y: y + 1, width: 18, height: lineHeight))
            text.draw(
                with: NSRect(x: 24, y: y, width: max(40, bounds.width - 24), height: height),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            nextY = frame.maxY + 10
        }
    }
}
