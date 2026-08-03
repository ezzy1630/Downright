import AppKit
import MarkdownCore

/// Builds inline math substitutions without changing the source text.
///
/// Inline math is part of a prose paragraph, so it cannot use the block
/// fragment path.  The logical display map replaces the source span with one
/// attachment character; the TextKit layout map expands that replacement back
/// to the source span's length with zero-width joiners, keeping element ranges
/// source-aligned while still drawing the formula inline.
enum InlineMathDisplay {

    static func ranges(in document: ParsedDocument) -> [NSRange] {
        var result: [NSRange] = []
        document.root.walk { block in
            for span in block.inlines {
                span.walk { inline in
                    if case .inlineMath = inline.kind, inline.range.length > 0 {
                        result.append(inline.range)
                    }
                }
            }
        }
        return result.sorted { $0.location < $1.location }
    }

    static func ranges(in document: ParsedDocument, touching offset: Int) -> [NSRange] {
        ranges(in: document).filter { $0.touches(offset: offset) }
    }

    static func substitutions(
        in document: ParsedDocument,
        styleSheet: StyleSheet,
        excluding excludedRange: NSRange?
    ) -> [DisplaySubstitution] {
        ranges(in: document).compactMap { range in
            if let excludedRange, NSIntersectionRange(range, excludedRange).length > 0 {
                return nil
            }
            let latex = document.substring(
                range.intersection(NSRange(location: 0, length: document.length)) ?? range)
            guard let replacement = MathRenderer.inlineAttachment(
                latex: latex,
                pointSize: styleSheet.mathPointSize,
                color: styleSheet.text,
                font: styleSheet.bodyFont()) else {
                return nil
            }
            return .replace(range, with: replacement)
        }
    }
}

extension MathRenderer {

    static func inlineAttachment(
        latex: String,
        pointSize: CGFloat,
        color: NSColor,
        font: NSFont
    ) -> NSAttributedString? {
        guard let image = image(latex: latex, display: false, pointSize: pointSize, color: color),
              image.size.width > 0, image.size.height > 0 else {
            return nil
        }

        let attachment = NSTextAttachment()
        attachment.image = image
        let baselineOffset = (font.xHeight - image.size.height) / 2
        attachment.bounds = CGRect(
            x: 0,
            y: baselineOffset,
            width: image.size.width,
            height: image.size.height)
        return NSAttributedString(attachment: attachment)
    }
}
