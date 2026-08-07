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

    /// Where an ornament's optical centre belongs: the middle of the *first*
    /// line's x-height.
    ///
    /// A fraction of the fragment height cannot express that.  A wrapped item
    /// is two lines tall and a task row carries a grid of paragraph spacing, so
    /// the same fraction lands near the ascender on one row and near the
    /// descender on the next — which is exactly what made adjacent bullets
    /// disagree.
    ///
    /// Every block here has a fixed line height (`BlockStyleFactory` pins
    /// minimum and maximum), and TextKit places such a line's baseline so the
    /// descent rests on the box's bottom edge.  That gives the baseline from
    /// the line box alone — no glyph metrics needed — and the x-height centre
    /// follows from the font.
    static func ornamentCentreY(lineTop: CGFloat, lineHeight: CGFloat, font: NSFont) -> CGFloat {
        let baseline = lineTop + lineHeight + font.descender
        return baseline - font.xHeight / 2
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard isFirstParagraphOfBlock, let style = styleSheet else { return }
        // `point.x` is the layout fragment origin; TextKit has already
        // resolved paragraph indents inside the first line fragment. Adding
        // `headIndent` again places the ornament on top of the first word.
        // Read the actual glyph edge instead, so tasks, ordered markers, and
        // bullets all share the same hanging column at every nesting level.
        let firstLine = textLineFragments.first?.typographicBounds
        let textEdge = point.x + (firstLine?.minX ?? 0)
        let centreY = Self.ornamentCentreY(
            lineTop: point.y + (firstLine?.minY ?? 0),
            lineHeight: firstLine.map { max(1, $0.height) } ?? style.lineHeight,
            font: style.bodyFont()
        )

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
        // `drawText` lays out from the line-fragment origin, so the marker's
        // baseline sits `size.height + descender` below the rect's top
        // (`descender` is negative).  Put that baseline half a cap-height under
        // the line's optical centre and the glyph — digit or dot — is centred.
        cg.drawText(attributed,
                    in: CGRect(x: textEdge - size.width - style.bodyFont().pointSize * 0.5,
                               y: centreY + font.capHeight / 2 - (size.height + font.descender),
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
        // when checked with a knocked-out tick, neutral border when open.  Both
        // the radius and the tick come from `RenderMetrics`, which is also what
        // the panel checkbox scales, so the two can no longer drift apart —
        // they used to be the same drawing written out twice.
        let radius = box.width * RenderMetrics.taskBoxCornerRatio
        let path = CGPath(roundedRect: box, cornerWidth: radius, cornerHeight: radius, transform: nil)
        cg.addPath(path)
        if checked {
            cg.setFillColor(style.accent.cgColor)
            cg.fillPath()
            cg.setStrokeColor(style.onAccent.cgColor)
            cg.setLineWidth(box.width * RenderMetrics.taskTickStrokeRatio)
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            // The unit tick is measured from the bottom of the box and this
            // context is flipped, so y counts down from `maxY`.
            for (index, unit) in RenderMetrics.taskTick.enumerated() {
                let point = CGPoint(x: box.minX + unit.x * box.width,
                                    y: box.maxY - unit.y * box.height)
                if index == 0 { cg.move(to: point) } else { cg.addLine(to: point) }
            }
            cg.strokePath()
        } else {
            cg.setStrokeColor(style.textFaint.cgColor)
            cg.setLineWidth(box.width * RenderMetrics.taskBoxStrokeRatio)
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
