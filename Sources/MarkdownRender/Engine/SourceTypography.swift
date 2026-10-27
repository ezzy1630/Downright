import AppKit

/// Shared by whole-document Source decoration and scoped source lenses.
/// Seeding the final typography before semantic runs avoids rewriting every
/// attribute dictionary a second time when entering Source.
enum SourceTypography {
    static func paragraphStyle(for sheet: StyleSheet) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = sheet.lineHeight
        style.maximumLineHeight = sheet.lineHeight
        style.lineBreakMode = .byWordWrapping
        let characterWidth = sheet.averageCharacterWidth
        style.tabStops = stride(from: 4, through: 80, by: 4).map {
            NSTextTab(textAlignment: .left, location: CGFloat($0) * characterWidth, options: [:])
        }
        style.defaultTabInterval = characterWidth * 4
        return style.copy() as! NSParagraphStyle
    }

    static func attributes(for sheet: StyleSheet) -> [NSAttributedString.Key: Any] {
        var attributes = sheet.monoFontAttributes()
        attributes[.paragraphStyle] = paragraphStyle(for: sheet)
        attributes[.drSourceFocus] = true
        return attributes
    }
}
