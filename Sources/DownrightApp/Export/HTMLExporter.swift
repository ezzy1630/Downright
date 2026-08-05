import AppKit
import MarkdownCore
import MarkdownRender

/// Self-contained HTML export (§9.5).
///
/// "Self-contained" is the whole requirement: styles inlined, images embedded
/// as data URIs, and — because the app has no WebView and therefore no KaTeX or
/// Mermaid.js to lean on (§3.3) — math and diagrams embedded as rendered PNGs
/// produced by the same native renderers the app draws with.  The exported file
/// looks like the app because it *is* the app's output, and it opens anywhere
/// with nothing to fetch.
/// Supplies rendered bitmaps for fragments a browser can't draw itself.
/// Injected rather than imported so the exporter stays testable and still works
/// (minus pictures) with no renderer attached.
protocol FragmentImageProvider {
    func image(forMath latex: String, display: Bool, pointSize: CGFloat, color: NSColor) -> NSImage?
    func image(forMermaid source: String, theme: Theme) -> NSImage?
}

struct HTMLExporter {
    var document: ParsedDocument
    var theme: Theme
    var title: String
    var baseDirectory: URL?
    var imageProvider: FragmentImageProvider?
    /// Print-oriented stylesheet: a document set for paper, not a screenshot of
    /// the screen theme (§9.5).
    var forPrint: Bool = false

    func html() -> String {
        var body = ""
        for child in document.root.children {
            body += render(block: child)
        }
        return """
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escape(title))</title>
        <style>
        \(stylesheet())
        </style>
        </head>
        <body>
        <article class="downright">
        \(body)
        </article>
        </body>
        </html>
        """
    }

    // MARK: - Blocks

    private func render(block: MDBlock) -> String {
        switch block.content {
        case .document:
            return block.children.map(render(block:)).joined()

        case .heading(let level):
            let text = renderInlines(block.inlines, in: block.contentRange)
            let slug = document.headings.first { $0.range == block.range }?.slug ?? Slugs.make(text)
            return "<h\(level) id=\"\(escape(slug))\">\(text)</h\(level)>\n"

        case .paragraph:
            return "<p>\(renderInlines(block.inlines, in: block.contentRange))</p>\n"

        case .blockQuote:
            return "<blockquote>\n\(block.children.map(render(block:)).joined())</blockquote>\n"

        case .callout(let kind, let calloutTitle):
            let heading = calloutTitle ?? kind.rawValue.capitalized
            return """
            <div class="callout callout-\(kind.rawValue)">
            <div class="callout-title">\(escape(heading))</div>
            \(block.children.map(render(block:)).joined())</div>

            """

        case .list(let ordered, let start, _, _):
            let tag = ordered ? "ol" : "ul"
            let startAttribute = ordered && start != 1 ? " start=\"\(start)\"" : ""
            return "<\(tag)\(startAttribute)>\n\(block.children.map(render(block:)).joined())</\(tag)>\n"

        case .listItem(_, let checkbox):
            let inner = block.children.map(render(block:)).joined()
            guard let checkbox else { return "<li>\(unwrapTightParagraph(inner))</li>\n" }
            let checked = checkbox.isChecked ? " checked" : ""
            return """
            <li class="task"><input type="checkbox" disabled\(checked)> \
            \(unwrapTightParagraph(inner))</li>

            """

        case .codeBlock(let language, _, let contentRange):
            let code = document.substring(contentRange)
            let languageClass = language.map { " class=\"language-\(escape($0))\"" } ?? ""
            let chip = language.map { "<div class=\"code-lang\">\(escape($0))</div>" } ?? ""
            return "<div class=\"code\">\(chip)<pre><code\(languageClass)>\(escape(code))</code></pre></div>\n"

        case .mermaid(let sourceRange):
            let source = document.substring(sourceRange)
            if let image = imageProvider?.image(forMermaid: source, theme: theme),
               let uri = dataURI(for: image) {
                return "<figure class=\"diagram\"><img src=\"\(uri)\" alt=\"Diagram\"></figure>\n"
            }
            return "<div class=\"code\"><pre><code>\(escape(source))</code></pre></div>\n"

        case .mathBlock(let latexRange):
            let latex = document.substring(latexRange)
            if let image = imageProvider?.image(
                forMath: latex, display: true,
                pointSize: theme.typography.bodySize * 1.1,
                color: theme.palette.text.resolved()
            ), let uri = dataURI(for: image) {
                return "<figure class=\"math\"><img src=\"\(uri)\" alt=\"\(escape(latex))\"></figure>\n"
            }
            return "<figure class=\"math\"><code>\(escape(latex))</code></figure>\n"

        case .table(let data):
            return render(table: data)

        case .thematicBreak:
            return "<hr>\n"

        case .htmlBlock:
            // Exported documents are standalone files opened outside the app,
            // and the whole point of the product is reviewing untrusted agent
            // output.  Inline HTML is escaped for the same reason (see
            // `.inlineHTML`), so a raw block that ships verbatim would let a
            // `<script>` in the source execute on open — a stored XSS hole.
            // Render the block as escaped source text, not as live markup.
            let html = document.substring(block.range)
            return "<div class=\"code\"><pre><code>\(escape(html))</code></pre></div>\n"

        case .frontMatter(let matter):
            guard !matter.fields.isEmpty else { return "" }
            let rows = matter.fields.map {
                "<div class=\"fm-row\"><span class=\"fm-key\">\(escape($0.key))</span>"
                    + "<span class=\"fm-value\">\(escape($0.value))</span></div>"
            }.joined()
            return "<div class=\"frontmatter\">\(rows)</div>\n"

        case .footnoteDefinition(let identifier):
            let inner = block.children.map(render(block:)).joined()
            return "<div class=\"footnote\" id=\"fn-\(escape(identifier))\">"
                + "<sup>\(escape(identifier))</sup>\(inner)</div>\n"
        }
    }

    /// A tight list item wraps its text in `<p>`, which browsers render with
    /// list-item margins the source never asked for.
    private func unwrapTightParagraph(_ html: String) -> String {
        let trimmed = html.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("<p>"), trimmed.hasSuffix("</p>"),
              !trimmed.dropFirst(3).dropLast(4).contains("<p>")
        else { return html }
        return String(trimmed.dropFirst(3).dropLast(4))
    }

    private func render(table: TableData) -> String {
        var out = "<table>\n"
        if let header = table.headerRow {
            out += "<thead><tr>"
            for (index, cell) in header.cells.enumerated() {
                out += "<th\(alignmentAttribute(table, index))>\(renderInlines(cell.inlines, in: cell.contentRange))</th>"
            }
            out += "</tr></thead>\n"
        }
        out += "<tbody>\n"
        for row in table.bodyRows {
            out += "<tr>"
            for (index, cell) in row.cells.enumerated() {
                out += "<td\(alignmentAttribute(table, index))>\(renderInlines(cell.inlines, in: cell.contentRange))</td>"
            }
            out += "</tr>\n"
        }
        return out + "</tbody>\n</table>\n"
    }

    private func alignmentAttribute(_ table: TableData, _ column: Int) -> String {
        guard column < table.alignments.count else { return "" }
        switch table.alignments[column] {
        case .none: return ""
        case .left: return " style=\"text-align:left\""
        case .center: return " style=\"text-align:center\""
        case .right: return " style=\"text-align:right\""
        }
    }

    // MARK: - Inlines

    private func renderInlines(_ spans: [InlineSpan], in range: NSRange) -> String {
        guard !spans.isEmpty else { return escape(document.substring(range)) }
        var out = ""
        var cursor = range.location
        for span in spans.sorted(by: { $0.range.location < $1.range.location }) {
            if span.range.location > cursor {
                out += escape(document.substring(NSRange(location: cursor, length: span.range.location - cursor)))
            }
            out += render(inline: span)
            cursor = max(cursor, span.range.upperBound)
        }
        if cursor < range.upperBound {
            out += escape(document.substring(NSRange(location: cursor, length: range.upperBound - cursor)))
        }
        return out
    }

    private func render(inline span: InlineSpan) -> String {
        let inner = { renderInlines(span.children, in: span.contentRange) }
        switch span.kind {
        case .text:
            return escape(document.substring(span.range))
        case .emphasis:
            return "<em>\(inner())</em>"
        case .strong:
            return "<strong>\(inner())</strong>"
        case .strikethrough:
            return "<del>\(inner())</del>"
        case .inlineCode:
            return "<code>\(escape(document.substring(span.contentRange)))</code>"
        case .link(let destination, let linkTitle):
            let titleAttribute = linkTitle.map { " title=\"\(escape($0))\"" } ?? ""
            return "<a href=\"\(escape(resolveHref(destination)))\"\(titleAttribute)>\(inner())</a>"
        case .autolink(let destination):
            return "<a href=\"\(escape(destination))\">\(escape(destination))</a>"
        case .wikilink(let target, let label):
            return "<a class=\"wikilink\" href=\"\(escape(target)).html\">\(escape(label ?? target))</a>"
        case .image(let source, let alt):
            return renderImage(source: source, alt: alt)
        case .inlineMath(let latexRange):
            let latex = document.substring(latexRange)
            if let image = imageProvider?.image(
                forMath: latex, display: false,
                pointSize: theme.typography.bodySize,
                color: theme.palette.text.resolved()
            ), let uri = dataURI(for: image) {
                return "<img class=\"inline-math\" src=\"\(uri)\" alt=\"\(escape(latex))\">"
            }
            return "<code class=\"inline-math\">\(escape(latex))</code>"
        case .pathToken(let token):
            return "<code class=\"path\">\(escape(token.rawPath))</code>"
        case .footnoteReference(let identifier):
            return "<sup><a href=\"#fn-\(escape(identifier))\">\(escape(identifier))</a></sup>"
        case .softBreak:
            return "\n"
        case .lineBreak:
            return "<br>\n"
        case .inlineHTML:
            // Exported documents are standalone files opened outside the app.
            // Treat inline HTML as source text so a heading like `<Tag>` keeps
            // its content and an untrusted markdown file cannot inject script.
            return escape(document.substring(span.range))
        }
    }

    private func resolveHref(_ destination: String) -> String {
        // A relative link to another markdown file points at that file's
        // exported sibling, so a folder of exports stays navigable.
        guard !destination.contains("://"), destination.hasSuffix(".md") else { return destination }
        return String(destination.dropLast(3)) + ".html"
    }

    private func renderImage(source: String, alt: String) -> String {
        let caption = alt.isEmpty ? "" : "<figcaption>\(escape(alt))</figcaption>"
        guard !source.contains("://") else {
            return "<figure><img src=\"\(escape(source))\" alt=\"\(escape(alt))\">\(caption)</figure>"
        }
        guard let base = baseDirectory else {
            return "<figure><img src=\"\(escape(source))\" alt=\"\(escape(alt))\">\(caption)</figure>"
        }
        let url = base.appendingPathComponent(source).standardizedFileURL
        guard let data = try? Data(contentsOf: url) else {
            return "<figure class=\"missing\"><span>\(escape(source))</span>\(caption)</figure>"
        }
        let mime = HTMLExporter.mimeType(forExtension: url.pathExtension)
        let uri = "data:\(mime);base64,\(data.base64EncodedString())"
        return "<figure><img src=\"\(uri)\" alt=\"\(escape(alt))\">\(caption)</figure>"
    }

    private func dataURI(for image: NSImage) -> String? {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return "data:image/png;base64,\(png.base64EncodedString())"
    }

    static func mimeType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "pdf": return "application/pdf"
        default: return "application/octet-stream"
        }
    }

    private func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for character in text {
            switch character {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            default: out.append(character)
            }
        }
        return out
    }

    // MARK: - Stylesheet

    private func stylesheet() -> String {
        let palette = theme.palette
        let typography = theme.typography
        let bodyFamily = typography.preset == .reading
            ? "'New York', 'Iowan Old Style', Georgia, serif"
            : "-apple-system, 'SF Pro Text', system-ui, sans-serif"
        let scale = typography.scaleRatio

        func hex(_ color: ThemeColor) -> String {
            let resolved = color.resolved().usingColorSpace(.sRGB) ?? .labelColor
            let r = Int((resolved.redComponent * 255).rounded())
            let g = Int((resolved.greenComponent * 255).rounded())
            let b = Int((resolved.blueComponent * 255).rounded())
            return String(format: "#%02x%02x%02x", r, g, b)
        }

        func hex(_ color: NSColor) -> String {
            let resolved = color.usingColorSpace(.sRGB) ?? color
            let r = Int((resolved.redComponent * 255).rounded())
            let g = Int((resolved.greenComponent * 255).rounded())
            let b = Int((resolved.blueComponent * 255).rounded())
            return String(format: "#%02x%02x%02x", r, g, b)
        }

        func size(_ steps: Int) -> String {
            String(format: "%.3frem", pow(scale, CGFloat(steps)))
        }

        func size(exponent: CGFloat) -> String {
            String(format: "%.3frem", pow(scale, exponent))
        }

        func blend(_ first: NSColor, _ second: NSColor, amount: CGFloat) -> NSColor {
            guard let lhs = first.usingColorSpace(.sRGB),
                  let rhs = second.usingColorSpace(.sRGB) else { return first }
            let t = min(max(amount, 0), 1)
            return NSColor(
                srgbRed: lhs.redComponent + (rhs.redComponent - lhs.redComponent) * t,
                green: lhs.greenComponent + (rhs.greenComponent - lhs.greenComponent) * t,
                blue: lhs.blueComponent + (rhs.blueComponent - lhs.blueComponent) * t,
                alpha: lhs.alphaComponent + (rhs.alphaComponent - lhs.alphaComponent) * t
            )
        }

        let headingColor = hex(palette.heading)
        let headingSecondary = palette.textSecondary.resolved()
        let heading4Color = hex(blend(palette.heading.resolved(), headingSecondary, amount: 0.25))
        let heading5Color = hex(blend(palette.heading.resolved(), headingSecondary, amount: 0.5))
        let heading6Color = hex(blend(palette.heading.resolved(), headingSecondary, amount: 0.75))

        let pageRule = forPrint ? """
        @page { margin: 20mm 18mm; }
        body { background: #fff; }
        .downright { max-width: none; }
        pre, blockquote, table, figure { break-inside: avoid; }
        h1, h2, h3 { break-after: avoid; }
        a { color: inherit; text-decoration: none; }
        a[href^="http"]::after { content: " (" attr(href) ")"; font-size: 0.8em; color: #666; }
        """ : ""

        return """
        :root { color-scheme: \(theme.appearance == .dark ? "dark" : "light"); }
        * { box-sizing: border-box; }
        body {
          margin: 0;
          background: \(hex(palette.background));
          color: \(hex(palette.text));
          font-family: \(bodyFamily);
          font-size: \(typography.bodySize)px;
          line-height: \(typography.lineHeightMultiple);
          -webkit-font-smoothing: antialiased;
        }
        .downright {
          /* Measure capped in ch so it tracks the font, not the window (§11.1). */
          max-width: \(Int(typography.measureCharacters))ch;
          margin: 4rem auto;
          padding: 0 1.5rem;
          hanging-punctuation: first last;
        }
        h1, h2, h3, h4, h5, h6 {
          line-height: 1.2;
          margin: 1.8em 0 0.6em;
        }
        h1 { color: \(headingColor); font-size: \(size(3)); margin-top: 0; font-weight: 700; letter-spacing: -0.022em; }
        h2 { color: \(headingColor); font-size: \(size(2)); font-weight: 700; letter-spacing: -0.014em; }
        h3 { color: \(headingColor); font-size: \(size(exponent: 1.25)); font-weight: 700; letter-spacing: -0.014em; }
        h4 { color: \(heading4Color); font-size: \(size(exponent: 0.5)); font-weight: 600; letter-spacing: normal; }
        h5 {
          color: \(heading5Color); font-size: \(size(exponent: -0.5));
          font-weight: 600; letter-spacing: 0.04em;
        }
        h6 {
          color: \(heading6Color); font-size: \(size(exponent: -0.75));
          font-weight: 500; font-style: italic; letter-spacing: 0.06em;
        }
        p { margin: 0 0 1.1em; }
        a { color: \(hex(palette.link)); text-decoration-thickness: 1px; text-underline-offset: 2px; }
        strong { font-weight: 640; }
        /* Left rule, never a filled box (§11.3). */
        blockquote {
          margin: 1.4em 0; padding: 0.1em 0 0.1em 1.1em;
          border-left: 2px solid \(hex(palette.quoteRule));
          color: \(hex(palette.textSecondary));
        }
        .callout {
          margin: 1.4em 0; padding: 0.2em 0 0.2em 1.1em;
          border-left: 3px solid \(hex(palette.calloutNote));
        }
        .callout-title { font-weight: 640; margin-bottom: 0.3em; letter-spacing: 0.01em; }
        .callout-warning { border-left-color: \(hex(palette.calloutWarning)); }
        .callout-warning .callout-title { color: \(hex(palette.calloutWarning)); }
        .callout-caution, .callout-danger, .callout-bug { border-left-color: \(hex(palette.calloutDanger)); }
        .callout-caution .callout-title, .callout-danger .callout-title { color: \(hex(palette.calloutDanger)); }
        .callout-tip, .callout-success { border-left-color: \(hex(palette.calloutSuccess)); }
        .callout-note .callout-title, .callout-info .callout-title { color: \(hex(palette.calloutNote)); }
        /* Subtle tint plus a left rule, never a heavy bordered card (§11.3). */
        .code {
          position: relative; margin: 1.4em 0;
          background: \(hex(palette.codeBackground));
          border-left: 2px solid \(hex(palette.codeRule));
          border-radius: 0 4px 4px 0;
        }
        .code-lang {
          position: absolute; top: 0.5em; right: 0.8em;
          font-size: 0.7rem; letter-spacing: 0.04em; text-transform: uppercase;
          color: \(hex(palette.textFaint));
        }
        pre { margin: 0; padding: 0.9em 1.1em; overflow-x: auto; }
        code {
          font-family: 'SF Mono', ui-monospace, Menlo, monospace;
          font-size: \(typography.monoSizeAdjust)em;
        }
        p code, li code, td code {
          background: \(hex(palette.codeBackground));
          padding: 0.12em 0.35em; border-radius: 3px;
        }
        code.path { color: \(hex(palette.accent)); }
        /* Horizontal rules only, zebra on hover, no gridlines (§11.3). */
        table { width: 100%; border-collapse: collapse; margin: 1.5em 0; font-size: 0.95em; }
        th, td { padding: 0.5em 0.7em; text-align: left; }
        th {
          border-bottom: 1.5px solid \(hex(palette.rule));
          font-weight: 620; color: \(hex(palette.textSecondary));
          font-size: 0.82em; letter-spacing: 0.03em; text-transform: uppercase;
        }
        td { border-bottom: 1px solid \(hex(palette.rule))33; }
        tbody tr:hover { background: \(hex(palette.codeBackground)); }
        /* Hairline with generous space, not a thick divider (§11.3). */
        hr { border: none; border-top: 1px solid \(hex(palette.rule)); margin: 3em 0; }
        ul, ol { padding-left: 1.3em; margin: 0 0 1.1em; }
        li { margin: 0.25em 0; }
        li.task { list-style: none; margin-left: -1.1em; }
        li.task input { margin-right: 0.45em; }
        figure { margin: 1.6em 0; text-align: center; }
        figure img { max-width: 100%; border-radius: 6px; box-shadow: 0 1px 6px rgba(0,0,0,0.10); }
        figcaption { margin-top: 0.6em; font-size: 0.85em; color: \(hex(palette.textSecondary)); }
        figure.missing span { color: \(hex(palette.pathMissing)); font-family: 'SF Mono', monospace; font-size: 0.85em; }
        .inline-math { vertical-align: -0.18em; height: 1.05em; box-shadow: none; border-radius: 0; }
        figure.math img { box-shadow: none; }
        .frontmatter {
          margin: 0 0 2.4em; padding: 0.9em 1.1em;
          background: \(hex(palette.codeBackground)); border-radius: 6px;
          font-size: 0.88em;
        }
        .fm-row { display: flex; gap: 0.8em; padding: 0.15em 0; }
        .fm-key { color: \(hex(palette.textSecondary)); min-width: 7em; }
        .footnote { font-size: 0.88em; color: \(hex(palette.textSecondary)); }
        .footnote sup { margin-right: 0.4em; color: \(hex(palette.accent)); }
        \(pageRule)
        """
    }
}

/// GitHub-compatible heading slugs, shared by export and by
/// "copy link to section" (§7.1).
enum Slugs {
    static func make(_ title: String) -> String {
        var out = ""
        for scalar in title.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
            } else if scalar == " " || scalar == "-" || scalar == "_" {
                out.append("-")
            }
        }
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        return out.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
