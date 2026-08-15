import Foundation

// MARK: - Smart paste (§6.4)
//
// "A URL over a selection makes a link; HTML on the clipboard converts to
// markdown; spreadsheet data becomes a markdown table."
//
// The HTML converter is deliberately small and tag-driven rather than a general
// parser.  What actually lands on the clipboard is browser-generated markup for
// a selection: headings, paragraphs, lists, links, emphasis, code and tables.
// Anything it does not recognise degrades to its text content, which is the
// right failure mode for a paste — you get the words, just not the formatting.

public enum SmartPaste {
    public static func markdown(forHTML html: String) -> String {
        var parser = HTMLToMarkdown(html: html)
        return parser.run()
    }

    /// Spreadsheet and terminal-table paste.  Returns nil when the text has no
    /// tab structure, so the caller can fall through to a plain paste.
    public static func markdownTable(forTabSeparated text: String) -> String? {
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .drop { $0.isEmpty }
            .reversed().drop { $0.isEmpty }.reversed()
            .map { $0 }
        guard lines.count >= 2 || (lines.first?.contains("\t") ?? false) else { return nil }
        guard lines.contains(where: { $0.contains("\t") }) else { return nil }

        let rows = lines.map { line in
            line.components(separatedBy: "\t").map {
                $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "|", with: "\\|")
            }
        }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 1 else { return nil }

        let model = TableFormatter.Model(
            rows: rows.map { row in row + [String](repeating: "", count: columns - row.count) },
            alignments: [TableAlignment](repeating: .none, count: columns),
            indent: ""
        )
        return TableFormatter.render(model)
    }

    /// A URL dropped over a selection.  Returns nil when `url` is not
    /// URL-shaped, so pasting arbitrary text over a selection stays a
    /// replacement rather than silently becoming a broken link.
    public static func linkified(selection: String, url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        let lowercased = trimmed.lowercased()
        let normalized = lowercased.hasPrefix("www.") ? "https://\(trimmed)" : trimmed
        guard let components = URLComponents(string: normalized),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "mailto"].contains(scheme) else { return nil }
        if scheme == "http" || scheme == "https" {
            guard let host = components.host, !host.isEmpty else { return nil }
        } else {
            guard !components.path.isEmpty else { return nil }
        }

        let label = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return "<\(normalized)>" }
        let escaped = label
            .replacingOccurrences(of: "[", with: "\\[")
            .replacingOccurrences(of: "]", with: "\\]")
        let destination = normalized.contains(where: { $0 == "(" || $0 == ")" })
            ? "<\(normalized)>" : normalized
        return "[\(escaped)](\(destination))"
    }
}

// MARK: - HTML → markdown

private struct HTMLToMarkdown {
    let html: String
    private var out = ""
    /// Open block context, so `<li>` inside `<ol>` numbers itself.
    private var listStack: [(ordered: Bool, index: Int)] = []
    private var quoteDepth = 0
    private var skipDepth = 0
    private var pendingTableRows: [[String]] = []
    private var tableCell: String?
    private var tableRow: [String] = []
    private var inTable = false
    private var inPre = false

    init(html: String) { self.html = html }

    mutating func run() -> String {
        var index = html.startIndex
        while index < html.endIndex {
            if html[index] == "<" {
                guard let close = html[index...].firstIndex(of: ">") else { break }
                let tag = String(html[html.index(after: index)..<close])
                handle(tag: tag)
                index = html.index(after: close)
            } else {
                let next = html[index...].firstIndex(of: "<") ?? html.endIndex
                emit(text: String(html[index..<next]))
                index = next
            }
        }
        return HTMLToMarkdown.collapseBlankRuns(out)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Block tags each contribute their own `\n\n`, so a `</h2><p>` boundary
    /// produces four newlines.  Collapse any run to a single blank line.
    static func collapseBlankRuns(_ text: String) -> String {
        var out = ""
        var newlines = 0
        for character in text {
            if character == "\n" {
                newlines += 1
                if newlines <= 2 { out.append(character) }
            } else {
                newlines = 0
                out.append(character)
            }
        }
        return out
    }

    private mutating func handle(tag raw: String) {
        let isClosing = raw.hasPrefix("/")
        let body = isClosing ? String(raw.dropFirst()) : raw
        let name = String(body.prefix { $0.isLetter || $0.isNumber }).lowercased()

        if name == "script" || name == "style" || name == "head" {
            skipDepth += isClosing ? -1 : 1
            skipDepth = max(0, skipDepth)
            return
        }
        guard skipDepth == 0 else { return }

        switch name {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(name.dropFirst()) ?? 1
            append(isClosing ? "\n\n" : "\n\n" + String(repeating: "#", count: level) + " ")
        case "p", "div":
            append("\n\n")
        case "br":
            append("  \n")
        case "hr":
            append("\n\n---\n\n")
        case "strong", "b":
            append("**")
        case "em", "i":
            append("*")
        case "del", "s", "strike":
            append("~~")
        case "pre":
            inPre = !isClosing
            append(isClosing ? "\n```\n\n" : "\n\n```\n")
        case "code":
            if !inPre { append("`") }
        case "blockquote":
            quoteDepth += isClosing ? -1 : 1
            quoteDepth = max(0, quoteDepth)
            append("\n\n")
        case "ul", "ol":
            if isClosing {
                if !listStack.isEmpty { listStack.removeLast() }
                append("\n")
            } else {
                listStack.append((ordered: name == "ol", index: 0))
                append("\n")
            }
        case "li":
            guard !isClosing else { return }
            let depth = max(0, listStack.count - 1)
            let indent = String(repeating: "  ", count: depth)
            if listStack.isEmpty {
                append("\n" + indent + "- ")
            } else {
                listStack[listStack.count - 1].index += 1
                let entry = listStack[listStack.count - 1]
                append("\n" + indent + (entry.ordered ? "\(entry.index). " : "- "))
            }
        case "a":
            append(isClosing ? "]" : "[")
            if isClosing, let href = attribute("href", in: lastAnchor) { append("(\(href))") }
            if !isClosing { lastAnchor = body }
        case "img":
            let alt = attribute("alt", in: body) ?? ""
            let src = attribute("src", in: body) ?? ""
            if !src.isEmpty { append("![\(alt)](\(src))") }
        case "table":
            if isClosing {
                inTable = false
                flushTable()
            } else {
                inTable = true
                pendingTableRows = []
            }
        case "tr":
            if isClosing {
                pendingTableRows.append(tableRow)
                tableRow = []
            }
        case "td", "th":
            if isClosing {
                tableRow.append((tableCell ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
                tableCell = nil
            } else {
                tableCell = ""
            }
        default:
            break
        }
    }

    private var lastAnchor = ""

    private mutating func emit(text raw: String) {
        guard skipDepth == 0 else { return }
        let decoded = HTMLToMarkdown.decodeEntities(raw)
        if tableCell != nil {
            tableCell? += decoded.replacingOccurrences(of: "\n", with: " ")
            return
        }
        if inPre { append(decoded); return }
        let collapsed = decoded
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        guard !collapsed.trimmingCharacters(in: .whitespaces).isEmpty || out.hasSuffix(" ") == false
        else { return }
        append(squeeze(collapsed))
    }

    private mutating func append(_ piece: String) {
        guard !inTable || tableCell == nil else { tableCell? += piece; return }
        guard !inTable || piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if piece.hasPrefix("\n"), quoteDepth > 0 {
            out += piece + String(repeating: "> ", count: quoteDepth)
            return
        }
        out += piece
    }

    private mutating func flushTable() {
        let rows = pendingTableRows.filter { !$0.isEmpty }
        pendingTableRows = []
        guard rows.count >= 1 else { return }
        let columns = rows.map(\.count).max() ?? 0
        guard columns > 0 else { return }
        let model = TableFormatter.Model(
            rows: rows.map { $0 + [String](repeating: "", count: columns - $0.count) },
            alignments: [TableAlignment](repeating: .none, count: columns),
            indent: ""
        )
        out += "\n\n" + TableFormatter.render(model) + "\n\n"
    }

    private func squeeze(_ text: String) -> String {
        var out = ""
        var lastWasSpace = false
        for character in text {
            let isSpace = character == " "
            if isSpace && lastWasSpace { continue }
            out.append(character)
            lastWasSpace = isSpace
        }
        return out
    }

    private func attribute(_ name: String, in tag: String) -> String? {
        // `href=` must start at an attribute boundary: matching it as a bare
        // substring would also hit `data-href=` or `xlink-href=` and pull the
        // wrong value out of the tag.
        guard let start = tag.range(of: "\(name)=", options: .caseInsensitive),
              start.lowerBound == tag.startIndex
                  || tag[tag.index(before: start.lowerBound)].isWhitespace
                  || tag[tag.index(before: start.lowerBound)] == "/"
        else { return nil }
        var rest = tag[start.upperBound...]
        guard let quote = rest.first else { return nil }
        if quote == "\"" || quote == "'" {
            rest = rest.dropFirst()
            guard let end = rest.firstIndex(of: quote) else { return nil }
            return HTMLToMarkdown.decodeEntities(String(rest[rest.startIndex..<end]))
        }
        return HTMLToMarkdown.decodeEntities(String(rest.prefix { !$0.isWhitespace && $0 != ">" }))
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = text
        // `&amp;` must be decoded last so an escaped entity such as `&amp;lt;`
        // resolves to the literal text `&lt;` rather than double-decoding to `<`.
        let named = [
            "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'",
            "&apos;": "'", "&nbsp;": " ", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…",
            "&ldquo;": "\u{201C}", "&rdquo;": "\u{201D}", "&lsquo;": "\u{2018}", "&rsquo;": "\u{2019}",
        ]
        for (entity, replacement) in named {
            out = out.replacingOccurrences(of: entity, with: replacement)
        }
        out = out.replacingOccurrences(of: "&amp;", with: "&")
        return out
    }
}
