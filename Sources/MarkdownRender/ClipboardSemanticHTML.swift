import Foundation

/// A deliberately small, safe Markdown-to-HTML projection for the system
/// clipboard. It is an interchange representation, not Downright's renderer:
/// unsupported Markdown and raw HTML remain escaped text, while common prose,
/// headings, lists, tables, links, emphasis, and code retain their meaning in
/// rich-text applications.
enum ClipboardSemanticHTML {
    private struct ListEntry {
        let indent: Int
        let kind: String
        let text: String
    }

    static func render(markdown: String) -> String {
        let lines = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
        var output: [String] = []
        var index = 0
        var inFence = false
        var fenceLanguage = ""
        var fenceLines: [String] = []
        var paragraph: [String] = []
        var listEntries: [ListEntry] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            let text = paragraph.joined(separator: "\n")
            output.append("<p>\(inline(text))</p>")
            paragraph.removeAll(keepingCapacity: true)
        }
        func flushList() {
            guard !listEntries.isEmpty else { return }
            output.append(listHTML(listEntries))
            listEntries.removeAll(keepingCapacity: true)
        }

        while index < lines.count {
            let line = lines[index]
            if inFence {
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") ||
                    line.trimmingCharacters(in: .whitespaces).hasPrefix("~~~") {
                    let language = fenceLanguage.isEmpty ? "" : " class=\"language-\(escapeAttribute(fenceLanguage))\""
                    output.append("<pre><code\(language)>\(escape(fenceLines.joined(separator: "\n")))</code></pre>")
                    inFence = false
                    fenceLanguage = ""
                    fenceLines.removeAll(keepingCapacity: true)
                } else {
                    fenceLines.append(line)
                }
                index += 1
                continue
            }

            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flushParagraph()
                flushList()
                inFence = true
                fenceLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                index += 1
                continue
            }
            if trimmed.isEmpty {
                flushParagraph()
                flushList()
                index += 1
                continue
            }

            if let heading = headingParts(trimmed) {
                flushParagraph()
                flushList()
                output.append("<h\(heading.level)>\(inline(heading.text))</h\(heading.level)>")
                index += 1
                continue
            }

            if index + 1 < lines.count, isTableDelimiter(lines[index + 1]),
               let header = tableCells(line) {
                flushParagraph()
                flushList()
                var rows: [[String]] = [header]
                index += 2
                while index < lines.count, let row = tableCells(lines[index]) {
                    rows.append(row)
                    index += 1
                }
                output.append(tableHTML(rows))
                continue
            }

            if let item = listPart(line) {
                flushParagraph()
                listEntries.append(item)
                index += 1
                continue
            }

            flushList()
            paragraph.append(line)
            index += 1
        }
        if inFence {
            let language = fenceLanguage.isEmpty ? "" : " class=\"language-\(escapeAttribute(fenceLanguage))\""
            output.append("<pre><code\(language)>\(escape(fenceLines.joined(separator: "\n")))</code></pre>")
        }
        flushParagraph()
        flushList()
        return output.joined(separator: "\n")
    }

    private static func headingParts(_ line: String) -> (level: Int, text: String)? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return (hashes, String(line.dropFirst(hashes)).trimmingCharacters(in: .whitespaces))
    }

    private static func listPart(_ line: String) -> ListEntry? {
        let indent = line.prefix { $0 == " " || $0 == "\t" }.reduce(into: 0) {
            $0 += $1 == "\t" ? 4 : 1
        }
        let content = line.drop { $0 == " " || $0 == "\t" }
        if ["- ", "* ", "+ "].contains(where: { content.hasPrefix($0) }) {
            return ListEntry(indent: indent, kind: "ul", text: String(content.dropFirst(2)))
        }
        var digits = ""
        for character in content {
            guard character.isNumber else { break }
            digits.append(character)
        }
        guard !digits.isEmpty, content.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return ListEntry(
            indent: indent,
            kind: "ol",
            text: String(content.dropFirst(digits.count + 2))
        )
    }

    private static func listHTML(_ entries: [ListEntry]) -> String {
        var index = 0
        func renderLevel(_ indent: Int) -> String {
            var html = ""
            while index < entries.count, entries[index].indent == indent {
                let kind = entries[index].kind
                html += "<\(kind)>"
                while index < entries.count,
                      entries[index].indent == indent,
                      entries[index].kind == kind {
                    let entry = entries[index]
                    index += 1
                    html += "<li>\(inline(entry.text))"
                    if index < entries.count, entries[index].indent > indent {
                        html += renderLevel(entries[index].indent)
                    }
                    html += "</li>"
                }
                html += "</\(kind)>"
            }
            return html
        }
        return renderLevel(entries.first?.indent ?? 0)
    }

    private static func tableCells(_ line: String) -> [String]? {
        guard line.contains("|") else { return nil }
        var cells = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("|"), !cells.isEmpty { cells.removeFirst() }
        if line.trimmingCharacters(in: .whitespaces).hasSuffix("|"), !cells.isEmpty { cells.removeLast() }
        return cells.count > 1 ? cells : nil
    }

    private static func isTableDelimiter(_ line: String) -> Bool {
        guard let cells = tableCells(line), !cells.isEmpty else { return false }
        return cells.allSatisfy { cell in
            let value = cell.trimmingCharacters(in: .whitespaces)
            return value.count >= 3 && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func tableHTML(_ rows: [[String]]) -> String {
        guard let header = rows.first else { return "" }
        let head = header.map { "<th>\(inline($0))</th>" }.joined()
        let body = rows.dropFirst().map { row in
            let cells = row + Array(repeating: "", count: max(0, header.count - row.count))
            return "<tr>\(cells.prefix(header.count).map { "<td>\(inline($0))</td>" }.joined())</tr>"
        }.joined()
        return "<table><thead><tr>\(head)</tr></thead>\(body.isEmpty ? "" : "<tbody>\(body)</tbody>")</table>"
    }

    private static func inline(_ input: String) -> String {
        var output = ""
        var index = input.startIndex
        while index < input.endIndex {
            if input[index] == "<" {
                // Raw HTML is source text from the document, not trusted markup
                // supplied to the destination application.
                output += "&lt;"
                index = input.index(after: index)
                continue
            }
            if input[index] == "\\" {
                let next = input.index(after: index)
                if next < input.endIndex {
                    output += escape(String(input[next]))
                    index = input.index(after: next)
                    continue
                }
            }
            if input[index...].hasPrefix("**") || input[index...].hasPrefix("__") {
                let marker = String(input[index...].prefix(2))
                if let end = input[input.index(index, offsetBy: 2)..<input.endIndex].range(of: marker) {
                    let start = input.index(index, offsetBy: 2)
                    output += "<strong>\(inline(String(input[start..<end.lowerBound])))</strong>"
                    index = end.upperBound
                    continue
                }
            }
            if input[index...].hasPrefix("~~"),
               let end = input[input.index(index, offsetBy: 2)..<input.endIndex].range(of: "~~") {
                let start = input.index(index, offsetBy: 2)
                output += "<del>\(inline(String(input[start..<end.lowerBound])))</del>"
                index = end.upperBound
                continue
            }
            if input[index] == "`", let end = input[input.index(after: index)..<input.endIndex].firstIndex(of: "`") {
                let start = input.index(after: index)
                output += "<code>\(escape(String(input[start..<end])))</code>"
                index = input.index(after: end)
                continue
            }
            if input[index...].hasPrefix("!["),
               let close = input[input.index(index, offsetBy: 2)..<input.endIndex].firstIndex(of: "]"),
               input[input.index(after: close)...].hasPrefix("(") {
                let destinationStart = input.index(after: close)
                if let destinationEnd = input[destinationStart...].firstIndex(of: ")") {
                    let altStart = input.index(index, offsetBy: 2)
                    let alt = String(input[altStart..<close])
                    let destination = String(input[input.index(destinationStart, offsetBy: 1)..<destinationEnd])
                    let source = escapeAttribute(destination)
                    if !source.isEmpty {
                        output += "<img src=\"\(source)\" alt=\"\(escapeAttribute(alt))\">"
                    } else {
                        output += escape("![\(alt)](\(destination))")
                    }
                    index = input.index(after: destinationEnd)
                    continue
                }
            }
            if input[index] == "[", let close = input[input.index(after: index)..<input.endIndex].firstIndex(of: "]"),
               input[input.index(after: close)...].hasPrefix("(") {
                let destinationStart = input.index(after: close)
                if let destinationEnd = input[destinationStart...].firstIndex(of: ")") {
                    let label = String(input[input.index(after: index)..<close])
                    let destination = String(input[input.index(destinationStart, offsetBy: 1)..<destinationEnd])
                    output += "<a href=\"\(escapeAttribute(destination))\">\(inline(label))</a>"
                    index = input.index(after: destinationEnd)
                    continue
                }
            }
            let character = String(input[index])
            output += escape(character)
            index = input.index(after: index)
        }
        return output.replacingOccurrences(of: "  \n", with: "<br>\n")
    }

    private static func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private static func escapeAttribute(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.scheme == nil || ["http", "https", "mailto", "file"].contains(url.scheme?.lowercased() ?? "")
        else { return "" }
        return escape(trimmed)
    }
}
