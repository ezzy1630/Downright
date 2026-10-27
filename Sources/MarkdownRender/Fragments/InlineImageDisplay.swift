// Authored by Claude Code as directed by Brad Nicholas <70774+bradn@users.noreply.github.com>
import AppKit
import MarkdownCore

/// What inline images need from the view that presents them.
///
/// The host controls remote-image consent; source spans remain authoritative.
final class InlineImageContext {
    var documentURL: URL?
    var localAssetAuthorizer: ((URL) -> Bool)?
    /// `nil` leaves `https:` images as alt text, and HTML ones inert.
    var remoteImageLoader: RemoteImageLoading?
    var allowsPlayback = true
    var items: [InlineImageDisplay.Item] = []
    /// Pictures are scaled down to fit inside this, in points.
    var maximumSize = CGSize(width: 640, height: 480)
    var displayScale: CGFloat = 2
    /// Called on the main queue when a picture lands, so the host can rebuild
    /// its presentation.  Hosts should coalesce: a badge row lands in a burst.
    var imageDidArrive: (@MainActor @Sendable () -> Void)?
    /// Animated pictures in the last build, for the reader to overlay.
    struct AnimatedItem {
        let sourceLocation: Int
        let image: NSImage
    }
    var animatedItems: [AnimatedItem] = []

    var maximumPixelDimension: Int {
        min(2048, max(1, Int(ceil(max(maximumSize.width, maximumSize.height) * displayScale))))
    }
}

/// Images inside a line of text: README badges, a logo in a centred
/// `<p>`, `[![badge](…)](…)`.
///
/// Block images (a paragraph that is only an image, an `<img>` that starts
/// its line) are fragments with captions.  An image sharing its line cannot
/// be a fragment: `FragmentProvider` looks for a fragment payload only at the
/// start of a paragraph (after indentation and `>`), so upstream never drew
/// an image inside a sentence, a link or a `<p>` — on the Mac either.  An
/// HTML `<img>` there got a payload that layout never picked up; a Markdown
/// inline image only ever got link styling, so its alt text showed.  So
/// inline images use inline math's path: the logical display map
/// replaces its source span with one attachment, and the source text is never
/// touched.  Until the picture is loaded, and if it never is, the alt text
/// stands in for it.
enum InlineImageDisplay {

    struct Item: Equatable {
        /// The whole image syntax: `![alt](src)` or the `<img …>` tag.
        let range: NSRange
        let source: String
        let alt: String
        /// The enclosing link, so a badge stays tappable.
        let link: String?
        /// `<img width height>`, in points; `nil` uses the picture's own size.
        var width: CGFloat? = nil
        var height: CGFloat? = nil
    }

    /// `joinsHTMLParagraphs` matches `PresentationMaps`: inside a joined HTML
    /// paragraph no image starts its display line, so every one is inline.
    static func items(
        in document: ParsedDocument, includesRemoteHTML: Bool, joinsHTMLParagraphs: Bool = false
    ) -> [Item] {
        let text = document.text as NSString
        var result: [Item] = []
        document.root.walk { block in
            if let html = block.safeHTML {
                guard html.isSafe else { return }
                let links: [(NSRange, String)] = html.annotations.compactMap {
                    if case .link(let destination, _) = $0.kind { return ($0.contentRange, destination) }
                    return nil
                }
                for annotation in html.annotations {
                    let source: String, alt: String
                    switch annotation.kind {
                    case .image(let s, let a): (source, alt) = (s, a)
                    case .remoteImage(let s, let a) where includesRemoteHTML: (source, alt) = (s, a)
                    default: continue
                    }
                    // First on its line: the block fragment path draws it,
                    // unless the line is joined into its paragraph.
                    if startsItsLine(annotation.range, in: text),
                       !(joinsHTMLParagraphs && HardWrapReflow.isParagraphLike(block, html: html, text: text)) {
                        continue
                    }
                    let link = links.last { NSIntersectionRange($0.0, annotation.range) == annotation.range }?.1
                    let tag = text.substring(with: annotation.range)
                    result.append(Item(range: annotation.range, source: source, alt: alt, link: link,
                                       width: dimension("width", in: tag), height: dimension("height", in: tag)))
                }
                return
            }
            // A paragraph that is only an image is the engine's block fragment.
            if case .paragraph = block.content, block.inlines.count == 1,
               case .image = block.inlines[0].kind { return }
            for span in block.inlines { collect(span, link: nil, into: &result) }
        }
        return result.sorted { $0.range.location < $1.range.location }
    }

    private static func collect(_ span: InlineSpan, link: String?, into result: inout [Item]) {
        switch span.kind {
        case .image(let source, let alt):
            guard span.range.length > 0 else { return }
            result.append(Item(range: span.range, source: source, alt: alt, link: link))
        case .link(let destination, _):
            for child in span.children { collect(child, link: destination, into: &result) }
        default:
            for child in span.children { collect(child, link: link, into: &result) }
        }
    }

    /// A `width`/`height` attribute in pixels (`128`, `"128"`, `128px`).
    /// Percentages and anything else are ignored.  The sanitizer drops these
    /// attributes, so they are read from the tag's own source text.
    private static let attributePattern = try? NSRegularExpression(
        pattern: #"([a-z][a-z0-9:._-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#,
        options: [.caseInsensitive])

    static func dimension(_ name: String, in tag: String) -> CGFloat? {
        guard let pattern = attributePattern else { return nil }
        let text = tag as NSString
        for match in pattern.matches(in: tag, range: NSRange(location: 0, length: text.length)) {
            guard text.substring(with: match.range(at: 1)).lowercased() == name else { continue }
            guard let range = (2...4).map({ match.range(at: $0) }).first(where: { $0.location != NSNotFound }) else { return nil }
            var raw = text.substring(with: range).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if raw.hasSuffix("px") { raw.removeLast(2) }
            guard let value = Double(raw), value.isFinite, value > 0 else { return nil }
            return CGFloat(value)
        }
        return nil
    }

    /// Whether only indentation and `>` markers precede `range` on its line,
    /// the same prefix `FragmentProvider` steps over to find a block fragment.
    private static func startsItsLine(_ range: NSRange, in text: NSString) -> Bool {
        var index = range.location
        while index > 0 {
            let character = text.character(at: index - 1)
            if character == 0x0A || character == 0x0D { return true }
            guard character == 0x20 || character == 0x09 || character == 0x3E else { return false }
            index -= 1
        }
        return true
    }

    static func substitutions(
        for items: [Item], context: InlineImageContext, styleSheet: StyleSheet
    ) -> [DisplaySubstitution] {
        items.map { item in .replace(item.range, with: replacement(for: item, context: context, styleSheet: styleSheet)) }
    }

    private static func replacement(
        for item: Item, context: InlineImageContext, styleSheet: StyleSheet
    ) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.drReference: item.alt]
        if let link = item.link {
            attributes[.drLink] = link
            attributes[.link] = link
        }
        guard let image = image(for: item, context: context), image.size.width > 0, image.size.height > 0 else {
            // Alt text stands in, styled as a link when it is one.
            attributes[.font] = styleSheet.bodyFont()
            attributes[.foregroundColor] = item.link == nil ? styleSheet.textSecondary : styleSheet.link
            let alt = item.alt.trimmingCharacters(in: .whitespacesAndNewlines)
            return NSAttributedString(string: alt.isEmpty ? "[image]" : alt, attributes: attributes)
        }
        let attachment = NSTextAttachment()
        attachment.image = image
        let size = fitted(requested(image.size, width: item.width, height: item.height), in: context.maximumSize)
        if context.allowsPlayback, image.animatedSource != nil {
            attachment.image = NSImage(size: size)
            context.animatedItems.append(.init(sourceLocation: item.range.location, image: image))
        }
        let font = styleSheet.bodyFont()
        // Pictures that fit the line (badges, icons) centre on the text;
        // taller ones sit on the descender, and the paragraph's lines grow to
        // hold them (`MarkdownContentStorage.fittingInlineImages`).
        let y = size.height <= styleSheet.lineHeight
            ? (font.capHeight - size.height) / 2
            : font.descender
        attachment.bounds = CGRect(x: 0, y: y, width: size.width, height: size.height)
        let string = NSMutableAttributedString(attachment: attachment)
        attributes[.drInlineImageHeight] = size.height
        string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
        return string
    }

    /// The author's `width`/`height`, keeping the picture's aspect ratio
    /// when only one is given.
    static func requested(_ natural: CGSize, width: CGFloat?, height: CGFloat?) -> CGSize {
        switch (width, height) {
        case let (w?, h?): return CGSize(width: w, height: h)
        case let (w?, nil): return CGSize(width: w, height: natural.height * w / natural.width)
        case let (nil, h?): return CGSize(width: natural.width * h / natural.height, height: h)
        case (nil, nil): return natural
        }
    }

    private static func fitted(_ natural: CGSize, in bounds: CGSize) -> CGSize {
        let scale = min(1, bounds.width / natural.width, bounds.height / natural.height)
        return CGSize(width: (natural.width * scale).rounded(), height: (natural.height * scale).rounded())
    }

    /// A cached picture, or `nil` after starting its load.
    private static func image(for item: Item, context: InlineImageContext) -> NSImage? {
        let dimension = context.maximumPixelDimension
        let raw = item.source.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased().hasPrefix("https://") {
            guard let loader = context.remoteImageLoader,
                  let url = URL(string: raw), url.host?.isEmpty == false else { return nil }
            if let image = loader.cachedImage(for: url, maxPixelDimension: dimension) { return image }
            guard !loader.hasFailed(url) else { return nil }
            let arrived = context.imageDidArrive
            loader.loadImage(for: url, maxPixelDimension: dimension) { image in
                if image != nil { arrived?() }
            }
            return nil
        }
        guard let request = LocalAssetPolicy.request(raw: raw, documentURL: context.documentURL),
              LocalAssetPolicy.allows(request, authorizer: context.localAssetAuthorizer) else { return nil }
        if let image = MarkdownFragmentImageCaches.images.cachedImage(for: request.url, maxPixelDimension: dimension) {
            return image
        }
        let arrived = context.imageDidArrive
        MarkdownFragmentImageCaches.images.loadImageAsync(for: request.url, maxPixelDimension: dimension) { image in
            if image != nil { arrived?() }
        }
        return nil
    }
}
