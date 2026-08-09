import AppKit

/// The tinted band behind an inline code span (§11.3).
///
/// A pill is a *behind the glyphs* effect, so the only geometry that can be
/// right for it is the geometry TextKit used to place those glyphs.  This is
/// therefore measured from the fragment's own line fragments, at draw time, in
/// the fragment's own drawing space — never from an absolute rectangle looked
/// up by source range and remembered.
///
/// Two whole classes of defect fall out of that choice rather than being
/// defended against:
///
///   * **Stale geometry.**  An absolute rectangle is only valid against the
///     layout it was measured in, and TextKit 2 relays out constantly — lazily
///     resolving estimates, reflowing an edited paragraph, re-measuring an
///     object.  The pill then stayed painted where the text used to be while
///     the span on screen had none.  A line fragment cannot be stale: it is
///     handed to `draw(at:in:)` by the pass that is drawing it.
///
///   * **Pills with no text under them.**  The runs a fragment draws itself —
///     a table's cells, a diagram, a collapsed block — never reach this code,
///     because those fragments suppress their glyphs and never ask for pills.
///     Hidden syntax is likewise absent from the element's display string, so
///     there is nothing to enumerate over it.
extension NSTextLayoutFragment {

    /// Horizontal air on each side of the code run.  No vertical padding: the
    /// line fragment is already a full line tall, and growing it further made
    /// the pills on consecutive lines touch, so a paragraph carrying several
    /// code spans read as a column of joined tiles.
    static let inlineCodePillPadX: CGFloat = 3

    /// Bands for every `.drInlineCode` run this fragment lays out, one per
    /// visual line, in the fragment's own drawing space anchored at `point`.
    ///
    /// `textOffset` is the vertical offset the fragment draws its glyphs at —
    /// `DownrightFragment` shifts them down by its top padding — so the band
    /// travels with the text rather than with the fragment box.
    func inlineCodePillBands(at point: CGPoint, textOffset: CGFloat = 0) -> [CGRect] {
        var bands: [CGRect] = []
        for line in textLineFragments {
            let string = line.attributedString
            let lineRange = NSIntersectionRange(
                line.characterRange,
                NSRange(location: 0, length: string.length)
            )
            guard lineRange.length > 0 else { continue }
            let bounds = line.typographicBounds
            string.enumerateAttribute(.drInlineCode, in: lineRange) { value, range, _ in
                guard value != nil else { return }
                let leading = line.locationForCharacter(at: range.location).x
                let trailing = line.trailingEdge(
                    after: range.upperBound, past: leading, in: lineRange, bounds: bounds
                )
                guard trailing > leading else { return }
                bands.append(CGRect(
                    x: point.x + leading - Self.inlineCodePillPadX,
                    y: point.y + bounds.minY + textOffset,
                    width: trailing - leading + Self.inlineCodePillPadX * 2,
                    height: bounds.height
                ))
            }
        }
        return bands
    }

    /// One box per invisible character this fragment lays out, in the same
    /// drawing space as the pills and for the same reason: measured from the
    /// line that is being drawn, a mark cannot land on a line that has moved.
    ///
    /// The `.drInvisible` attribute is only on the text while the setting is
    /// on, so its presence is the whole gate.
    func invisibleMarkBoxes(at point: CGPoint, textOffset: CGFloat = 0) -> [(box: CGRect, isTab: Bool)] {
        var boxes: [(CGRect, Bool)] = []
        for line in textLineFragments {
            let string = line.attributedString
            let lineRange = NSIntersectionRange(
                line.characterRange,
                NSRange(location: 0, length: string.length)
            )
            guard lineRange.length > 0 else { continue }
            let text = string.string as NSString
            let bounds = line.typographicBounds
            string.enumerateAttribute(.drInvisible, in: lineRange) { value, range, _ in
                guard value != nil else { return }
                for index in range.location..<range.upperBound {
                    let leading = line.locationForCharacter(at: index).x
                    let trailing = line.trailingEdge(
                        after: index + 1, past: leading, in: lineRange, bounds: bounds
                    )
                    guard trailing > leading else { continue }
                    boxes.append((
                        CGRect(
                            x: point.x + leading,
                            y: point.y + bounds.minY + textOffset,
                            width: trailing - leading,
                            height: bounds.height
                        ),
                        text.character(at: index) == 0x09
                    ))
                }
            }
        }
        return boxes
    }

    /// A dot for a space, a small arrow for a tab.
    func drawInvisibleMarks(
        at point: CGPoint,
        textOffset: CGFloat = 0,
        styleSheet: StyleSheet,
        in cg: CGContext
    ) {
        let boxes = invisibleMarkBoxes(at: point, textOffset: textOffset)
        guard !boxes.isEmpty else { return }
        cg.saveGState()
        cg.setStrokeColor(styleSheet.textFaint.cgColor)
        cg.setFillColor(styleSheet.textFaint.cgColor)
        cg.setLineWidth(1)
        for (box, isTab) in boxes {
            let middle = CGPoint(x: box.midX, y: box.midY)
            if isTab {
                cg.move(to: CGPoint(x: box.minX, y: middle.y))
                cg.addLine(to: CGPoint(x: box.maxX, y: middle.y))
                cg.addLine(to: CGPoint(x: box.maxX - 3, y: middle.y - 2))
                cg.move(to: CGPoint(x: box.maxX, y: middle.y))
                cg.addLine(to: CGPoint(x: box.maxX - 3, y: middle.y + 2))
                cg.strokePath()
            } else {
                cg.fillEllipse(in: CGRect(x: middle.x - 1, y: middle.y - 1, width: 2, height: 2))
            }
        }
        cg.restoreGState()
    }

    /// Paints those bands.  Called from the fragment's own `draw(at:in:)`
    /// before the glyphs, so the tint sits behind the code and moves with it.
    func drawInlineCodePills(
        at point: CGPoint,
        textOffset: CGFloat = 0,
        styleSheet: StyleSheet,
        in cg: CGContext
    ) {
        let bands = inlineCodePillBands(at: point, textOffset: textOffset)
        guard !bands.isEmpty else { return }
        cg.saveGState()
        // Fill plus a hair of edge.  On a dark ground the fill alone is a faint
        // smudge that has to be pushed brighter to read at all, and pushed
        // brighter it turns into a slab; a 1px edge lets the fill stay quiet
        // and still bound the span.
        cg.setFillColor(styleSheet.inlineCodeBackground.cgColor)
        cg.setStrokeColor(styleSheet.codeRule.withAlphaComponent(0.5).cgColor)
        cg.setLineWidth(1)
        for band in bands {
            let path = CGPath(
                roundedRect: band.insetBy(dx: 0.5, dy: 0.5),
                cornerWidth: RenderMetrics.inlineCodeCornerRadius,
                cornerHeight: RenderMetrics.inlineCodeCornerRadius,
                transform: nil
            )
            cg.addPath(path)
            cg.fillPath()
            cg.addPath(path)
            cg.strokePath()
        }
        cg.restoreGState()
    }
}

extension NSTextLineFragment {
    /// Where the run ending at `index` stops, in the line's own x.
    ///
    /// The obvious answer — the location of the character after the run — is
    /// wrong at the end of a line.  Hidden Markdown syntax is present in the
    /// display string as zero-width joiners, and the *last* one on a line
    /// reports x = 0 rather than the line's right edge.  A closing backtick is
    /// exactly that character, so every code span that ended its line measured
    /// as zero width and its pill silently vanished — `Scripts/bundle-app.sh`
    /// on a list line of its own, or a span that ends a sentence.
    ///
    /// So step past any such character to the first one that really is to the
    /// right, and fall back to the line's own right edge, which is where a run
    /// that reaches the end of the line ends anyway.
    func trailingEdge(
        after index: Int, past leading: CGFloat, in lineRange: NSRange, bounds: CGRect
    ) -> CGFloat {
        var probe = index
        while probe <= lineRange.upperBound {
            let x = locationForCharacter(at: probe).x
            if x > leading { return min(x, bounds.maxX) }
            probe += 1
        }
        return bounds.maxX
    }
}
