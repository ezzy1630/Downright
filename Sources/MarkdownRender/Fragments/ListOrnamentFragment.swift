import AppKit

/// Typographic list markers. Markdown syntax remains hidden while the semantic
/// ornament sits in the hanging indent in Read and Live modes.
final class ListOrnamentFragment: DownrightFragment {
    static let taskBoxSide: CGFloat = RenderMetrics.taskBoxSide
    static let taskHitTargetSide: CGFloat = 28

    static func taskHitRect(textEdge: CGFloat, centreY: CGFloat, bodySize: CGFloat) -> CGRect {
        let box = taskBoxRect(textEdge: textEdge, centreY: centreY, bodySize: bodySize)
        return CGRect(
            x: box.midX - taskHitTargetSide / 2,
            y: box.midY - taskHitTargetSide / 2,
            width: taskHitTargetSide,
            height: taskHitTargetSide
        )
    }

    static func taskBoxRect(textEdge: CGFloat, centreY: CGFloat, bodySize: CGFloat) -> CGRect {
        // The paragraph reserves `taskMarkerColumn` (box + gap + clearance) as
        // its head indent, so the box's right edge meets the label's left edge
        // after exactly one gap and the box itself starts ≥ 4pt inside the
        // fragment — never on or past the fragment origin (P1-6/7).
        CGRect(
            x: textEdge - taskBoxSide - RenderMetrics.taskBoxGap,
            y: centreY - taskBoxSide / 2,
            width: taskBoxSide,
            height: taskBoxSide
        )
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet else { return }
        let lineHeight = max(style.lineHeight, layoutFragmentFrame.height)
        // `point.x` is the layout fragment origin; TextKit has already
        // resolved paragraph indents inside the first line fragment. Adding
        // `headIndent` again places the ornament on top of the first word.
        // Read the actual glyph edge instead, so tasks, ordered markers, and
        // bullets all share the same hanging column at every nesting level.
        let textEdge = point.x + (textLineFragments.first?.typographicBounds.minX ?? 0)
        let centreY = point.y + min(lineHeight, layoutFragmentFrame.height) * 0.44

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
        let side = Self.taskBoxSide
        var box = Self.taskBoxRect(
            textEdge: textEdge,
            centreY: centreY,
            bodySize: style.bodyFont().pointSize
        )

        // Micro-feedback: the box pops and a ring fades out, so a toggle is
        // answered in place even when the new state is a single dark tick (§7.1).
        var ring: (radius: CGFloat, alpha: CGFloat)?
        if let pulse = context?.checkboxPulses.first(where: { $0.sourceRange == payload.sourceRange }) {
            let elapsed = CFAbsoluteTimeGetCurrent() - pulse.started
            if elapsed < CheckboxPulse.duration {
                let t = elapsed / CheckboxPulse.duration
                let scale = 1.0 + 0.18 * sin(min(1, t * 2) * .pi)
                let center = CGPoint(x: box.midX, y: box.midY)
                box = CGRect(x: center.x - box.width * scale / 2,
                             y: center.y - box.height * scale / 2,
                             width: box.width * scale, height: box.height * scale)
                let eased = 1 - pow(1 - t, 2)
                ring = (side * (0.55 + 1.2 * eased), (1 - t) * 0.5)
            }
        }

        // One checkbox look everywhere (§8.5): a rounded square, accent-filled
        // when checked with a tick in the surface colour, neutral border when
        // open — the same stroke weight, radius, and tick geometry the task
        // panel draws.
        let path = CGPath(roundedRect: box, cornerWidth: 5, cornerHeight: 5, transform: nil)
        cg.addPath(path)
        if checked {
            cg.setFillColor(style.accent.cgColor)
            cg.fillPath()
            cg.setStrokeColor(NSColor.white.cgColor)
            cg.setLineWidth(1.8)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            cg.move(to: CGPoint(x: box.minX + 2.6, y: box.midY))
            cg.addLine(to: CGPoint(x: box.minX + 5.2, y: box.maxY - 2.6))
            cg.addLine(to: CGPoint(x: box.maxX - 2.2, y: box.minY + 2.6))
            cg.strokePath()
        } else {
            cg.setStrokeColor(style.textFaint.cgColor)
            cg.setLineWidth(1.4)
            cg.strokePath()
        }

        if let ring {
            let rect = CGRect(x: box.midX - ring.radius, y: box.midY - ring.radius,
                              width: ring.radius * 2, height: ring.radius * 2)
            cg.setStrokeColor(style.accent.withAlphaComponent(ring.alpha).cgColor)
            cg.setLineWidth(1.5)
            cg.strokeEllipse(in: rect)
        }
    }
}
