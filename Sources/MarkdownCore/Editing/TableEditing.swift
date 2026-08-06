import Foundation

public enum TableEditOperation: Sendable {
    case setCell(row: Int, column: Int, text: String)
    case setAlignment(column: Int, alignment: TableAlignment)
    case insertRow(index: Int, cells: [String])
    case deleteRow(index: Int)
    case moveRow(from: Int, to: Int)
    case insertColumn(index: Int, header: String, cells: [String])
    case deleteColumn(index: Int)
    case moveColumn(from: Int, to: Int)

    public static func editCell(row: Int, column: Int, text: String) -> Self {
        .setCell(row: row, column: column, text: text)
    }

    public static func align(column: Int, to alignment: TableAlignment) -> Self {
        .setAlignment(column: column, alignment: alignment)
    }
}

public enum TableSourceFallback: String, Error, Equatable, Sendable {
    case tableNotFound
    case invalidSourceRange
    case sourceChanged
    case invalidRow
    case invalidColumn
    case cannotDeleteHeader
    case malformedTable
    case unsupportedOperation
    case cannotDeleteLastColumn
}

public struct TableEditProposal: Sendable {
    public let range: NSRange
    public let replacement: String
    public let summary: String
    public let expected: String

    public init(range: NSRange, replacement: String, summary: String, expected: String) {
        self.range = range
        self.replacement = replacement
        self.summary = summary
        self.expected = expected
    }

    public var edit: TextEdit { TextEdit(range: range, replacement: replacement, summary: summary) }

    public func applying(to source: String) -> String? {
        let ns = source as NSString
        guard range.location >= 0, range.upperBound <= ns.length,
              ns.substring(with: range) == expected else { return nil }
        let output = NSMutableString(string: source)
        output.replaceCharacters(in: range, with: replacement)
        return output as String
    }
}

public struct TableEditResult: Sendable {
    public let proposal: TableEditProposal?
    public let fallback: TableSourceFallback?

    public init(proposal: TableEditProposal?, fallback: TableSourceFallback? = nil) {
        self.proposal = proposal
        self.fallback = fallback
    }
}

public enum TableEditing {
    public static func propose(
        _ document: ParsedDocument,
        tableIndex: Int = 0,
        operation: TableEditOperation
    ) -> TableEditResult {
        let tables = tableBlocks(in: document)
        guard tableIndex >= 0, tableIndex < tables.count else {
            return TableEditResult(proposal: nil, fallback: .tableNotFound)
        }
        return propose(document, block: tables[tableIndex].block, data: tables[tableIndex].data, operation: operation)
    }

    public static func propose(
        _ document: ParsedDocument,
        table: TableData,
        operation: TableEditOperation
    ) -> TableEditResult {
        guard let found = tableBlocks(in: document).first(where: { sameTable($0.data, table) }) else {
            return TableEditResult(proposal: nil, fallback: .tableNotFound)
        }
        return propose(document, block: found.block, data: found.data, operation: operation)
    }

    public static func proposal(
        _ document: ParsedDocument,
        tableIndex: Int = 0,
        operation: TableEditOperation
    ) -> TableEditProposal? {
        propose(document, tableIndex: tableIndex, operation: operation).proposal
    }

    private static func propose(
        _ document: ParsedDocument,
        block: MDBlock,
        data: TableData,
        operation: TableEditOperation
    ) -> TableEditResult {
        guard case .table = block.content, !data.rows.isEmpty else {
            return TableEditResult(proposal: nil, fallback: .malformedTable)
        }
        let source = document.text as NSString
        let firstRow = data.rows[0]
        let lastRow = data.rows[data.rows.count - 1]
        let start = min(source.lineStart(before: firstRow.range.location), source.lineStart(before: data.delimiterRange.location))
        let end = max(source.lineEnd(after: lastRow.range.upperBound), source.lineEnd(after: data.delimiterRange.upperBound))
        guard start >= 0, end <= source.length, start < end else {
            return TableEditResult(proposal: nil, fallback: .invalidSourceRange)
        }
        let tableRange = NSRange(location: start, length: end - start)
        let expected = source.substring(with: tableRange)
        let records = lineRecords(source: source, range: tableRange)
        guard let delimiter = records.firstIndex(where: { NSIntersectionRange($0.contentRange, data.delimiterRange).length > 0 }) else {
            return TableEditResult(proposal: nil, fallback: .malformedTable)
        }
        let rowIndices = data.rows.compactMap { row in records.firstIndex { NSIntersectionRange($0.contentRange, row.range).length > 0 } }
        guard rowIndices.count == data.rows.count else {
            return TableEditResult(proposal: nil, fallback: .sourceChanged)
        }

        switch operation {
        case let .setCell(row, column, text):
            guard row >= 0, row < rowIndices.count else { return fail(.invalidRow) }
            let line = records[rowIndices[row]]
            guard let segment = cellSegments(line.text).element(at: column) else {
                return fail(.invalidColumn)
            }
            guard let replacement = replaceSegment(line.text, segment: segment, content: text) else {
                return fail(.malformedTable)
            }
            let range = line.contentRange
            return make(document, range: range, replacement: replacement, summary: "Edit table cell", expected: source.substring(with: range))
        case let .setAlignment(column, alignment):
            let line = records[delimiter]
            let segments = cellSegments(line.text)
            guard let segment = segments.element(at: column) else { return fail(.invalidColumn) }
            let lineSource = line.text as NSString
            guard let replacement = replaceSegment(line.text, segment: segment, content: delimiterToken(for: alignment, old: lineSource.substring(with: segment))) else {
                return fail(.malformedTable)
            }
            return make(document, range: line.contentRange, replacement: replacement, summary: "Set table alignment", expected: source.substring(with: line.contentRange))
        case let .insertRow(index, cells):
            guard index >= 1, index <= data.rows.count else { return fail(.invalidRow) }
            guard cells.count <= data.columnCount else { return fail(.unsupportedOperation) }
            let insertionOffset: Int
            if index < rowIndices.count {
                insertionOffset = max(delimiter + 1, rowIndices[index])
            } else {
                insertionOffset = records.count
            }
            let indent = indentation(records[rowIndices[0]].text)
            let paddedCells = cells + [String](
                repeating: "", count: data.columnCount - cells.count
            )
            let line = renderRow(cells: paddedCells, indent: indent)
            return makeWhole(document, range: tableRange, records: records, replacementAt: insertionOffset, inserted: [line], summary: "Insert table row", expected: expected)
        case let .deleteRow(index):
            guard index > 0, index < rowIndices.count else { return fail(index == 0 ? .cannotDeleteHeader : .invalidRow) }
            return makeWhole(document, range: records[rowIndices[index]].fullRange, directReplacement: "", summary: "Delete table row", expected: source.substring(with: records[rowIndices[index]].fullRange))
        case let .moveRow(from, to):
            guard from > 0, to > 0, from < rowIndices.count, to < rowIndices.count else { return fail(.invalidRow) }
            let ending = records.first?.terminator ?? "\n"
            // `rawWithTerminator` has no trailing terminator for the last record
            // of a file that does not end in a newline.  A move can place that
            // record in the middle, which would glue it onto its new neighbour
            // — normalise every record to a terminator first (§3.6 editor; a
            // missing final newline is `DocumentIO`'s fidelity concern at save
            // time).
            var output = records.map { hasTerminator($0.rawWithTerminator) ? $0.rawWithTerminator : $0.rawWithTerminator + ending }
            let moved = output.remove(at: rowIndices[from])
            output.insert(moved, at: rowIndices[to])
            return make(document, range: tableRange, replacement: output.joined(), summary: "Move table row", expected: expected)
        case let .insertColumn(index, header, cells):
            let count = data.columnCount
            guard index >= 0, index <= count else { return fail(.invalidColumn) }
            guard cells.count <= max(0, data.rows.count - 1) else {
                return fail(.unsupportedOperation)
            }
            return columnMutation(document, tableRange: tableRange, records: records, delimiter: delimiter, rowIndices: rowIndices, column: index, mode: .insert(header: header, cells: cells), summary: "Insert table column", expected: expected)
        case let .deleteColumn(index):
            guard index >= 0, index < data.columnCount else { return fail(.invalidColumn) }
            guard data.columnCount > 1 else { return fail(.cannotDeleteLastColumn) }
            return columnMutation(document, tableRange: tableRange, records: records, delimiter: delimiter, rowIndices: rowIndices, column: index, mode: .delete, summary: "Delete table column", expected: expected)
        case let .moveColumn(from, to):
            guard from >= 0, to >= 0, from < data.columnCount, to < data.columnCount else { return fail(.invalidColumn) }
            return columnMutation(document, tableRange: tableRange, records: records, delimiter: delimiter, rowIndices: rowIndices, column: from, mode: .move(to: to), summary: "Move table column", expected: expected)
        }

        func fail(_ reason: TableSourceFallback) -> TableEditResult {
            TableEditResult(proposal: nil, fallback: reason)
        }
    }

    private enum ColumnMode {
        case insert(header: String, cells: [String])
        case delete
        case move(to: Int)
    }

    private static func columnMutation(
        _ document: ParsedDocument, tableRange: NSRange, records: [LineRecord], delimiter: Int,
        rowIndices: [Int], column: Int, mode: ColumnMode, summary: String, expected: String
    ) -> TableEditResult {
        var output = records.map(\.rawWithTerminator)
        for (row, recordIndex) in rowIndices.enumerated() {
            let record = records[recordIndex]
            let recordSource = record.text as NSString
            var parts = cellSegments(record.text).map { recordSource.substring(with: $0) }
            switch mode {
            case let .insert(header, cells):
                let value = row == 0 ? header : (row - 1 < cells.count ? cells[row - 1] : "")
                parts.insert(preservedCell(value, like: parts.first ?? ""), at: min(column, parts.count))
            case .delete:
                guard column < parts.count else { return TableEditResult(proposal: nil, fallback: .invalidColumn) }
                parts.remove(at: column)
            case let .move(to):
                guard column < parts.count, to < parts.count else { return TableEditResult(proposal: nil, fallback: .invalidColumn) }
                let moved = parts.remove(at: column)
                parts.insert(moved, at: to)
            }
            output[recordIndex] = renderRawRow(parts: parts, template: record.text) + record.terminator
        }
        let delimiterSource = records[delimiter].text as NSString
        let delimiterParts = cellSegments(records[delimiter].text).map { delimiterSource.substring(with: $0) }
        var delimiterValues = delimiterParts
        switch mode {
        case .insert:
            delimiterValues.insert("---", at: min(column, delimiterValues.count))
        case .delete:
            guard column < delimiterValues.count else { return TableEditResult(proposal: nil, fallback: .invalidColumn) }
            delimiterValues.remove(at: column)
        case let .move(to):
            guard column < delimiterValues.count, to < delimiterValues.count else { return TableEditResult(proposal: nil, fallback: .invalidColumn) }
            let moved = delimiterValues.remove(at: column)
            delimiterValues.insert(moved, at: to)
        }
        let delimiterRecord = records[delimiter]
        output[delimiter] = renderRawRow(parts: delimiterValues, template: delimiterRecord.text) + delimiterRecord.terminator
        return make(document, range: tableRange, replacement: output.joined(), summary: summary, expected: expected)
    }

    private static func makeWhole(
        _ document: ParsedDocument, range: NSRange, records: [LineRecord], replacementAt: Int,
        inserted: [String], summary: String, expected: String
    ) -> TableEditResult {
        let ending = records.first?.terminator ?? "\n"
        var output = records.map(\.rawWithTerminator)
        // The last record of a file that does not end in a newline has an empty
        // terminator.  Inserting after it would glue the new line straight onto
        // its content (`| one | two || x | y |`), so give the record preceding
        // the insertion a terminator first.  A missing final newline is a
        // byte-fidelity concern handled by `DocumentIO` at save time, not here.
        if replacementAt > 0, replacementAt <= output.count, !hasTerminator(output[replacementAt - 1]) {
            output[replacementAt - 1] += ending
        }
        output.insert(contentsOf: inserted.map { $0 + ending }, at: replacementAt)
        return make(document, range: range, replacement: output.joined(), summary: summary, expected: expected)
    }

    /// True when the last *code unit* of the line is a line terminator.
    /// `String.hasSuffix` cannot be used here: UAX #29 treats CRLF as a single
    /// grapheme cluster, so `"…\r\n".hasSuffix("\n")` is false — a CRLF row
    /// move would silently double every terminator.  Scalar comparison sees the
    /// real last unit.
    private static func hasTerminator(_ line: String) -> Bool {
        guard let last = line.unicodeScalars.last else { return false }
        return last == "\n" || last == "\r"
    }

    private static func makeWhole(
        _ document: ParsedDocument, range: NSRange, directReplacement: String,
        summary: String, expected: String
    ) -> TableEditResult {
        make(document, range: range, replacement: directReplacement, summary: summary, expected: expected)
    }

    private static func make(
        _ document: ParsedDocument, range: NSRange, replacement: String,
        summary: String, expected: String
    ) -> TableEditResult {
        guard range.location >= 0, range.upperBound <= (document.text as NSString).length,
              (document.text as NSString).substring(with: range) == expected else {
            return TableEditResult(proposal: nil, fallback: .sourceChanged)
        }
        return TableEditResult(proposal: TableEditProposal(range: range, replacement: replacement, summary: summary, expected: expected))
    }

    private struct LineRecord {
        let contentRange: NSRange
        let fullRange: NSRange
        let text: String
        let terminator: String
        var rawWithTerminator: String { text + terminator }
    }

    private static func lineRecords(source: NSString, range: NSRange) -> [LineRecord] {
        var records: [LineRecord] = []
        var offset = range.location
        while offset < range.upperBound {
            let fullEnd = min(source.length, source.lineEnd(after: offset))
            var contentEnd = fullEnd
            if contentEnd > offset, source.character(at: contentEnd - 1) == 0x0A { contentEnd -= 1 }
            if contentEnd > offset, source.character(at: contentEnd - 1) == 0x0D { contentEnd -= 1 }
            let boundedContentEnd = min(contentEnd, range.upperBound)
            let full = NSRange(location: offset, length: min(fullEnd, range.upperBound) - offset)
            let content = NSRange(location: offset, length: max(0, boundedContentEnd - offset))
            let text = source.substring(with: content)
            let terminator = source.substring(with: NSRange(location: content.upperBound, length: max(0, full.upperBound - content.upperBound)))
            records.append(LineRecord(contentRange: content, fullRange: full, text: text, terminator: terminator))
            offset = full.upperBound
        }
        return records
    }

    private static func tableBlocks(in document: ParsedDocument) -> [(block: MDBlock, data: TableData)] {
        var found: [(MDBlock, TableData)] = []
        document.root.walk { block in
            if case let .table(data) = block.content { found.append((block, data)) }
        }
        return found
    }

    private static func sameTable(_ lhs: TableData, _ rhs: TableData) -> Bool {
        lhs.delimiterRange == rhs.delimiterRange && lhs.rows.map(\.range) == rhs.rows.map(\.range)
    }

    private static func cellSegments(_ line: String) -> [NSRange] {
        let ns = line as NSString
        var pipes: [Int] = []
        for index in 0..<ns.length where ns.character(at: index) == 124 {
            var slashes = 0
            var prior = index - 1
            while prior >= 0, ns.character(at: prior) == 92 { slashes += 1; prior -= 1 }
            if slashes.isMultiple(of: 2) { pipes.append(index) }
        }
        guard !pipes.isEmpty else { return [] }
        var segments: [NSRange] = []
        if pipes[0] > 0 {
            let prefix = ns.substring(with: NSRange(location: 0, length: pipes[0]))
            if !prefix.allSatisfy({ $0 == " " || $0 == "\t" || $0 == ">" }) {
                segments.append(NSRange(location: 0, length: pipes[0]))
            }
        }
        for (left, right) in zip(pipes, pipes.dropFirst()) {
            segments.append(NSRange(location: left + 1, length: max(0, right - left - 1)))
        }
        if pipes.last! < ns.length - 1 {
            segments.append(NSRange(location: pipes.last! + 1, length: ns.length - pipes.last! - 1))
        }
        return segments
    }

    private static func replaceSegment(_ line: String, segment: NSRange, content: String) -> String? {
        let raw = line as NSString
        let old = raw.substring(with: segment)
        let left = old.prefix { $0.isWhitespace }
        let right = old.reversed().prefix { $0.isWhitespace }.reversed()
        let replacement = String(left) + escapeCell(content) + String(right)
        let output = NSMutableString(string: line)
        output.replaceCharacters(in: segment, with: replacement)
        return output as String
    }

    private static func preservedCell(_ value: String, like old: String) -> String {
        let left = old.prefix { $0.isWhitespace }
        let right = old.reversed().prefix { $0.isWhitespace }.reversed()
        return String(left) + escapeCell(value) + String(right)
    }

    private static func escapeCell(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "|", with: "\\|")
    }

    private static func renderRawRow(parts: [String], template: String) -> String {
        let source = template as NSString
        guard let firstPipe = (0..<source.length).first(where: { source.character(at: $0) == 124 }) else {
            return template
        }
        let prefix = source.substring(with: NSRange(location: 0, length: firstPipe))
        let hasLeadingPipe = prefix.allSatisfy { $0 == " " || $0 == "\t" || $0 == ">" }
        let lastNonWhitespace = template.lastIndex { !$0.isWhitespace }
        let hasTrailingPipe = lastNonWhitespace.map { template[$0] == "|" } ?? false
        return (hasLeadingPipe ? prefix + "|" : "")
            + parts.joined(separator: "|") + (hasTrailingPipe ? "|" : "")
    }

    /// A single inserted row has no column-width context, so alignment is not
    /// padded here — the exit-time §6.3 realign applies it to the whole table.
    /// Emits a structurally valid row.
    private static func renderRow(cells: [String], indent: String) -> String {
        indent + "|" + cells.map { " " + escapeCell($0) + " |" }.joined()
    }

    private static func delimiterToken(for alignment: TableAlignment, old: String) -> String {
        let trimmed = old.trimmingCharacters(in: .whitespaces)
        let width = max(3, trimmed.filter { $0 == "-" }.count)
        let core = String(repeating: "-", count: width)
        let token: String
        switch alignment {
        case .none: token = core
        case .left: token = ":" + String(core.dropFirst())
        case .right: token = String(core.dropLast()) + ":"
        case .center: token = ":" + String(core.dropFirst(2)) + ":"
        }
        return token
    }

    private static func indentation(_ line: String) -> String {
        String(line.prefix { $0 == " " || $0 == "\t" || $0 == ">" })
    }
}

private extension Array {
    func element(at index: Int) -> Element? {
        guard index >= 0, index < count else { return nil }
        return self[index]
    }
}

public typealias TableEditor = TableEditing
