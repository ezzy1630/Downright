import Foundation

// MARK: - Table source formatting
//
// Shared by §9.1's `tablePipes` tidy rule and §6.3's "on exit, the whole
// table's pipes are re-aligned in the source".  One formatter so the two can
// never disagree — which matters because the editor calls one on every table
// exit and the tidy command calls the other over the whole document, and a
// disagreement would show up as an edit that flip-flops forever.

enum TableFormatter {
    /// Cell contents of a table, header row first.  Reads the *source* rather
    /// than the AST so that a table being edited mid-keystroke still formats.
    struct Model {
        var rows: [[String]]
        var alignments: [TableAlignment]
        var indent: String
        /// The line terminator that followed each source line, in render order
        /// (header, delimiter, body…).  A mixed-ending file keeps the bytes it
        /// had instead of being rebuilt as LF; empty where unknown.
        var lineTerminators: [String] = []
        var columnCount: Int { Swift.max(alignments.count, rows.map(\.count).max() ?? 0) }
    }

    static func model(of table: TableData, in text: NSString) -> Model {
        // A table inside a blockquote carries its `>` markers before the row
        // range; they must survive a realign or the table silently leaves the
        // quote.  Mirrors `TableEditing.indentation`.
        let indent = table.rows.first.map { row -> String in
            String(text.substring(with: NSRange(
                location: text.lineStart(before: row.range.location),
                length: row.range.location - text.lineStart(before: row.range.location)
            )).prefix { $0 == " " || $0 == "\t" || $0 == ">" })
        } ?? ""
        let rows = table.rows.map { row in
            row.cells.map { text.substring(with: $0.range).trimmingCharacters(in: .whitespaces) }
        }
        return Model(
            rows: rows, alignments: table.alignments, indent: indent,
            lineTerminators: lineTerminators(of: table, in: text)
        )
    }

    /// One terminator per source line of the table, in order.  A line without
    /// a terminator (the last one, in a file with no final newline) yields "".
    private static func lineTerminators(of table: TableData, in text: NSString) -> [String] {
        let range = sourceRange(of: table, fallback: NSRange(location: 0, length: 0))
        var terminators: [String] = []
        var offset = range.location
        while offset < range.upperBound {
            let lineEnd = min(text.length, text.lineEnd(after: offset))
            var contentEnd = lineEnd
            if contentEnd > offset, text.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
            if contentEnd > offset, text.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }
            terminators.append(text.substring(with: NSRange(
                location: contentEnd, length: max(0, lineEnd - contentEnd)
            )))
            offset = lineEnd
        }
        return terminators
    }

    /// Renders a table back to aligned pipe syntax.
    static func render(_ model: Model) -> String {
        let columns = model.columnCount
        guard columns > 0, !model.rows.isEmpty else { return "" }

        var widths = [Int](repeating: 3, count: columns)  // `---` is the minimum
        for row in model.rows {
            for (index, cell) in row.enumerated() where index < columns {
                widths[index] = Swift.max(widths[index], displayWidth(cell))
            }
        }

        var lines: [String] = []
        lines.append(renderRow(model.rows[0], widths: widths, alignments: model.alignments, indent: model.indent))
        lines.append(renderDelimiter(widths: widths, alignments: model.alignments, indent: model.indent))
        for row in model.rows.dropFirst() {
            lines.append(renderRow(row, widths: widths, alignments: model.alignments, indent: model.indent))
        }
        var out = ""
        for (index, line) in lines.enumerated() {
            out += line
            if index < lines.count - 1 {
                let captured = model.lineTerminators.indices.contains(index)
                    ? model.lineTerminators[index]
                    : ""
                out += captured.isEmpty ? "\n" : captured
            }
        }
        return out
    }

    private static func renderRow(
        _ cells: [String], widths: [Int], alignments: [TableAlignment], indent: String
    ) -> String {
        var out = indent + "|"
        for index in widths.indices {
            let cell = index < cells.count ? cells[index] : ""
            let alignment = index < alignments.count ? alignments[index] : .none
            out += " " + pad(cell, to: widths[index], alignment: alignment) + " |"
        }
        return out
    }

    private static func renderDelimiter(
        widths: [Int], alignments: [TableAlignment], indent: String
    ) -> String {
        var out = indent + "|"
        for index in widths.indices {
            let width = widths[index]
            let alignment = index < alignments.count ? alignments[index] : .none
            switch alignment {
            case .none: out += " " + String(repeating: "-", count: width) + " |"
            case .left: out += " :" + String(repeating: "-", count: width - 1) + " |"
            case .right: out += " " + String(repeating: "-", count: width - 1) + ": |"
            case .center: out += " :" + String(repeating: "-", count: width - 2) + ": |"
            }
        }
        return out
    }

    private static func pad(_ cell: String, to width: Int, alignment: TableAlignment) -> String {
        let slack = width - displayWidth(cell)
        guard slack > 0 else { return cell }
        switch alignment {
        case .right:
            return String(repeating: " ", count: slack) + cell
        case .center:
            let left = slack / 2
            return String(repeating: " ", count: left) + cell + String(repeating: " ", count: slack - left)
        case .none, .left:
            return cell + String(repeating: " ", count: slack)
        }
    }

    /// Character count, not UTF-16 length: a table aligned by code units looks
    /// wrong the moment a cell contains an emoji or an accented letter.
    private static func displayWidth(_ cell: String) -> Int { cell.count }

    /// Source range covering the whole table including its delimiter row.
    static func sourceRange(of table: TableData, fallback: NSRange) -> NSRange {
        guard let first = table.rows.first?.range else {
            return table.delimiterRange.length > 0 ? table.delimiterRange : fallback
        }
        var range = first
        for row in table.rows.dropFirst() { range = range.union(row.range) }
        if table.delimiterRange.length > 0 { range = range.union(table.delimiterRange) }
        return range
    }
}
