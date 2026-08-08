import AppKit
import MarkdownCore

/// Turns `[^12]` into one semantic superscript without touching source bytes.
/// The replacement keeps the reference identifier as an attribute, so the
/// existing navigation and tooltip path gets the larger semantic hit range.
enum FootnoteReferenceDisplay {
    struct Reference {
        var range: NSRange
        var identifier: String
    }

    static func references(in document: ParsedDocument) -> [Reference] {
        var result: [Reference] = []
        document.root.walk { block in
            for span in block.inlines {
                span.walk { inline in
                    if case .footnoteReference(let identifier) = inline.kind {
                        result.append(Reference(range: inline.range, identifier: identifier))
                    }
                }
            }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    static func substitutions(
        in document: ParsedDocument,
        styleSheet: StyleSheet,
        excluding excludedRange: NSRange?
    ) -> [DisplaySubstitution] {
        references(in: document).compactMap { reference in
            if let excludedRange,
               NSIntersectionRange(reference.range, excludedRange).length > 0 {
                return nil
            }
            let value = superscript(reference.identifier)
            let font = styleSheet.bodyFont().withSize(styleSheet.bodyFont().pointSize * 0.62)
            let string = NSAttributedString(string: value, attributes: [
                .font: font,
                .foregroundColor: styleSheet.accent,
                .baselineOffset: styleSheet.bodyFont().xHeight * 0.42,
                .drReference: reference.identifier,
            ])
            return .replace(reference.range, with: string)
        }
    }

    private static func superscript(_ identifier: String) -> String {
        let map: [Character: Character] = [
            "0": "⁰", "1": "¹", "2": "²", "3": "³", "4": "⁴",
            "5": "⁵", "6": "⁶", "7": "⁷", "8": "⁸", "9": "⁹",
            "+": "⁺", "-": "⁻",
        ]
        let converted = identifier.map { map[$0] ?? $0 }
        return converted.isEmpty ? "•" : String(converted)
    }
}
