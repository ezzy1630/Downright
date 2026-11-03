import Foundation
import MarkdownCore

/// Image-only physical lines use block drawing even when Markdown groups
/// adjacent lines into one paragraph. Prose images and linked badges stay inline.
enum BlockImageLines {
    struct Image {
        let range: NSRange
        let source: String
        let alt: String
    }

    static func images(in block: MDBlock, text: NSString) -> [Image] {
        guard case .paragraph = block.content,
              block.inlines.contains(where: { if case .image = $0.kind { return true }; return false }) else { return [] }
        var images: [Image] = []
        for span in block.inlines {
            switch span.kind {
            case let .image(source, alt):
                images.append(Image(range: span.range, source: source, alt: alt))
            case .softBreak, .lineBreak:
                continue
            case .text:
                guard text.substring(with: span.range).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
            default:
                return []
            }
        }
        guard !images.isEmpty else { return [] }
        // Preserve the existing solitary-image range, including container prefixes.
        if images.count == 1, block.inlines.count == 1 {
            let image = images[0]
            return [Image(range: block.range, source: image.source, alt: image.alt)]
        }
        for image in images {
            guard !text.substring(with: image.range).contains(where: \.isNewline) else { return [] }
            let line = text.paragraphRange(for: image.range)
            let start = max(line.location, block.range.location)
            let prefix = text.substring(with: NSRange(location: start, length: image.range.location - start))
            let suffix = text.substring(with: NSRange(location: image.range.upperBound,
                                                       length: line.upperBound - image.range.upperBound))
            guard prefix.allSatisfy({ $0 == " " || $0 == "\t" || $0 == ">" }),
                  suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        }
        return images
    }
}
