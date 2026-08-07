import AppKit
import MarkdownCore

/// Quotes and callouts (§11.3): a coloured left rule plus an SF Symbol icon,
/// with a restrained five-percent tint. Agents emit `> [!NOTE]` constantly,
/// so the treatment remains quiet while still separating it from a quote.
///
/// Unlike the object fragments, this one keeps its glyphs: the text is real
/// text with real selection and real find behaviour, and the fragment only
/// adds the rule and the icon underneath it.
///
/// One callout is *several* fragments — TextKit makes one element per physical
/// paragraph plus one grouped element per reflowed prose block — and each of
/// them draws its own slice of the same shape. Three invariants turn those
/// slices back into one block:
///
///   * **The band comes from the block's own head indent**, never from the
///     glyph edge of the current row. An empty header row and a body row
///     report different typographic bounds, and a nested list inside the
///     callout reports a deeper indent, so measuring per row is what made the
///     two ends of the tint disagree.
///
///   * **Only the true top and bottom are rounded or inset.** Interior slices
///     overdraw into their neighbours, so the tint has no seams and the rule
///     runs the full height of the callout instead of restarting per row.
///
///   * **The header belongs to exactly one element**: the one that starts at
///     the block's first character. A reflowed body element begins at the
///     marker line's newline — still inside the marker line's *paragraph* — so
///     paragraph identity alone drew the icon and title twice.
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

    override var verticalPadding: (top: CGFloat, bottom: CGFloat) {
        guard kind != nil else { return (0, 0) }
        // No reserved header row: the `> [!KIND] …` line is hidden syntax, so
        // it is already an empty row of the block's line height, and that row
        // *is* the header. Adding a second one left a blank line under the
        // icon.
        return (
            isHeaderElement ? RenderMetrics.calloutInsetY : 0,
            isFooterElement ? RenderMetrics.calloutInsetY : 0
        )
    }

    // MARK: - Which slice of the block this is

    /// The element carrying the `> [!KIND]` line. Elements tile the document
    /// and the block starts on a paragraph boundary, so exactly one of them
    /// starts at or before the block's first character.
    private var isHeaderElement: Bool {
        elementSourceRange.location <= payload.sourceRange.location
    }

    private var isFooterElement: Bool {
        elementSourceRange.upperBound >= payload.sourceRange.upperBound
    }

    // MARK: - Drawing

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard let style = styleSheet else { return }
        let reservedInset = kind == nil
            ? RenderMetrics.calloutInsetX
            : RenderMetrics.calloutIconInsetX
        let color = kind.map { style.calloutColor($0) } ?? style.quoteRule
        let ruleWidth = kind == nil ? RenderMetrics.quoteRuleWidth : RenderMetrics.calloutRuleWidth
        let band = bandRect(at: point, reservedInset: reservedInset)

        if kind != nil {
            cg.fillRect(continuous(band), color: color.withAlphaComponent(0.055),
                        radius: RenderMetrics.calloutCornerRadius)
        }
        cg.fillRect(ruleRect(band, width: ruleWidth), color: color, radius: ruleWidth / 2)

        guard let kind, isHeaderElement, headerRowIsBlank else { return }
        drawHeader(kind: kind, band: band, reservedInset: reservedInset,
                   ruleWidth: ruleWidth, color: color, at: point, style: style, in: cg)
    }

    /// The tinted band and its rule, anchored on the callout's own indentation.
    ///
    /// Fragment drawing happens in text-container coordinates, so an absolute
    /// x is meaningful and `point.x` is *not* a shared origin: TextKit puts the
    /// paragraph's head indent into the fragment frame, and a grouped
    /// (reflowed) element reports a different one from the marker row's plain
    /// paragraph. Measuring the band from `point.x` is what made the two ends
    /// of the same callout disagree by exactly one icon column.
    private func bandRect(at point: CGPoint, reservedInset: CGFloat) -> CGRect {
        let indent = max(0, (blockHeadIndent ?? reservedInset) - reservedInset)
        return CGRect(
            x: indent,
            y: point.y,
            width: max(1, contentWidth - indent),
            height: layoutFragmentFrame.height
        )
    }

    /// Head indent of the callout's *own* first paragraph. Reading the current
    /// element's indent instead would let a nested list or quote inside the
    /// callout pull that row's band to the right.
    private var blockHeadIndent: CGFloat? {
        guard let storage = context?.storage else { return nil }
        let location = payload.sourceRange.location
        guard location >= 0, location < storage.length else { return nil }
        let style = storage.attribute(.paragraphStyle, at: location, effectiveRange: nil)
        return (style as? NSParagraphStyle)?.headIndent
    }

    /// The band grown into its neighbours wherever the block continues, so the
    /// corner radius appears only at the real top and bottom and the seams
    /// between rows carry no notch.
    private func continuous(_ band: CGRect) -> CGRect {
        let radius = RenderMetrics.calloutCornerRadius
        var rect = band
        if !isHeaderElement {
            rect.origin.y -= radius
            rect.size.height += radius
        }
        if !isFooterElement { rect.size.height += radius }
        return rect
    }

    /// The rule is one stroke down the whole callout: only the first and last
    /// rows round their own end in, and interior rows butt against each other.
    private func ruleRect(_ band: CGRect, width: CGFloat) -> CGRect {
        let end: CGFloat = kind == nil ? 0 : 4
        let top = isHeaderElement ? end : 0
        let bottom = isFooterElement ? end : 0
        return CGRect(x: band.minX, y: band.minY + top,
                      width: width, height: max(1, band.height - top - bottom))
    }

    // MARK: - Header

    /// True while the header row really is the blank remains of hidden marker
    /// syntax. A scoped source lens (§6.2) puts `> [!NOTE] Title` back on that
    /// row as real text, and the header must not be painted over it.
    private var headerRowIsBlank: Bool {
        guard context?.isSourceFocused(payload.sourceRange) != true,
              let line = textLineFragments.first else { return false }
        let text = line.attributedString.string as NSString
        let range = NSIntersectionRange(line.characterRange,
                                        NSRange(location: 0, length: text.length))
        guard range.length > 0 else { return true }
        return text.substring(with: range).unicodeScalars.allSatisfy(Self.isBlank)
    }

    /// Hidden runs survive layout as word joiners and reflowed breaks as spaces
    /// (`DisplayMap`), so "blank" means "no ink", not "no characters".
    private static func isBlank(_ scalar: Unicode.Scalar) -> Bool {
        scalar == "\u{2060}" || scalar == "\u{200B}" || scalar == "\u{FEFF}"
            || CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private func drawHeader(
        kind: CalloutKind,
        band: CGRect,
        reservedInset: CGFloat,
        ruleWidth: CGFloat,
        color: NSColor,
        at point: CGPoint,
        style: StyleSheet,
        in cg: CGContext
    ) {
        let rowY = point.y + RenderMetrics.calloutInsetY
        let rowHeight = textLineFragments.first.map { max(1, $0.typographicBounds.height) }
            ?? style.lineHeight

        if let icon = NSImage(systemSymbolName: style.calloutSymbol(kind), accessibilityDescription: nil) {
            let configured = icon.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: style.bodyFont().pointSize, weight: .medium)) ?? icon
            let tinted = NSImage(size: configured.size, flipped: false) { rect in
                configured.draw(in: rect)
                color.set()
                rect.fill(using: .sourceAtop)
                return true
            }
            draw(
                image: tinted,
                in: CGRect(x: band.minX + ruleWidth + 7,
                           y: rowY + max(0, (rowHeight - configured.size.height) / 2),
                           width: configured.size.width, height: configured.size.height),
                in: cg
            )
        }

        // An untitled callout is still a callout: it gets its kind's name, so
        // `> [!NOTE]` reads as "Note" rather than as an empty tinted row.
        let label = NSAttributedString(string: title.isEmpty ? Self.defaultLabel(kind) : title, attributes: [
            .font: NSFont.systemFont(ofSize: style.bodyFont().pointSize, weight: .semibold),
            .foregroundColor: color,
        ])
        let labelHeight = min(rowHeight, ceil(label.size().height))
        cg.drawText(
            label,
            in: CGRect(x: band.minX + reservedInset,
                       y: rowY + max(0, (rowHeight - labelHeight) / 2),
                       width: max(40, band.width - reservedInset),
                       height: labelHeight),
            flipped: true
        )
    }

    /// The name a callout carries when its author gave it none. Written out
    /// rather than derived from `rawValue` so the wording is a decision, not an
    /// accident of the enum's spelling.
    private static func defaultLabel(_ kind: CalloutKind) -> String {
        switch kind {
        case .note: return "Note"
        case .tip: return "Tip"
        case .important: return "Important"
        case .warning: return "Warning"
        case .caution: return "Caution"
        case .info: return "Info"
        case .success: return "Success"
        case .question: return "Question"
        case .danger: return "Danger"
        case .example: return "Example"
        case .quote: return "Quote"
        case .abstract: return "Abstract"
        case .bug: return "Bug"
        case .todo: return "To do"
        }
    }
}
