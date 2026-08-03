import AppKit

/// Typographic list markers. Markdown syntax remains hidden while the semantic
/// ornament sits in the hanging indent in Read and Live modes.
final class ListOrnamentFragment: DownrightFragment {
    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet else { return }
        let lineHeight = max(style.lineHeight, layoutFragmentFrame.height)
        // `point.x` is the layout fragment origin; TextKit has already
        // resolved paragraph indents inside the first line fragment. Adding
        // `headIndent` again places the ornament on top of the first word.
        // Read the actual glyph edge instead, so tasks, ordered markers, and
        // bullets all share the same hanging column at every nesting level.
        let textEdge = point.x + (textLineFragments.first?.typographicBounds.minX ?? 0)
        let centreY = point.y + min(lineHeight, layoutFragmentFrame.height) * 0.48

        if payload.detail.hasPrefix("task:") {
            drawTask(checked: payload.detail == "task:checked", textEdge: textEdge,
                     centreY: centreY, style: style, in: cg)
            return
        }

        let marker: String
        let color: NSColor
        let font: NSFont
        if payload.detail.hasPrefix("ordered:") {
            marker = String(payload.detail.dropFirst("ordered:".count)) + "."
            color = style.textSecondary
            font = NSFont.monospacedDigitSystemFont(ofSize: style.bodyFont().pointSize * 0.92,
                                                    weight: .regular)
        } else {
            let level = Int(payload.detail.dropFirst("unordered:".count)) ?? 1
            marker = level % 3 == 1 ? "●" : (level % 3 == 2 ? "○" : "▪")
            color = style.textFaint
            font = NSFont.systemFont(ofSize: style.bodyFont().pointSize * 0.30, weight: .regular)
        }
        let attributed = NSAttributedString(string: marker, attributes: [.font: font, .foregroundColor: color])
        let size = attributed.size()
        cg.drawText(attributed,
                    in: CGRect(x: textEdge - size.width - style.bodyFont().pointSize * 0.5,
                               y: centreY - size.height * 0.48,
                               width: size.width, height: size.height),
                    flipped: true)
    }

    private func drawTask(
        checked: Bool,
        textEdge: CGFloat,
        centreY: CGFloat,
        style: StyleSheet,
        in cg: CGContext
    ) {
        let side: CGFloat = 10
        let box = CGRect(x: textEdge - side - style.bodyFont().pointSize * 0.5,
                         y: centreY - side / 2, width: side, height: side)
        let path = CGPath(roundedRect: box, cornerWidth: 3, cornerHeight: 3, transform: nil)
        cg.addPath(path)
        if checked {
            cg.setFillColor(style.accent.cgColor)
            cg.fillPath()
            cg.setStrokeColor(NSColor.white.cgColor)
            cg.setLineWidth(1.5)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.move(to: CGPoint(x: box.minX + 2.1, y: box.midY))
            cg.addLine(to: CGPoint(x: box.minX + 4.2, y: box.maxY - 2.2))
            cg.addLine(to: CGPoint(x: box.maxX - 1.8, y: box.minY + 2.2))
            cg.strokePath()
        } else {
            cg.setStrokeColor(style.textFaint.cgColor)
            cg.setLineWidth(1.5)
            cg.strokePath()
        }
    }
}
