import AppKit
import MarkdownCore

/// Materialises the semantic content of a Markdown table cell.
///
/// Table fragments replace TextKit's glyph drawing, so reading directly from
/// `NSTextStorage` also reads the Markdown delimiters that the normal display
/// map hides.  Keep that projection local and pure: decoration attributes stay
/// intact, only the inline marker characters are removed.
enum TableCellPresentation {
    static func attributedContent(
        for cell: TableCell,
        in storage: NSAttributedString
    ) -> NSAttributedString {
        guard cell.contentRange.length > 0,
              cell.contentRange.upperBound <= storage.length else {
            return NSAttributedString()
        }

        let content = NSMutableAttributedString(
            attributedString: storage.attributedSubstring(from: cell.contentRange)
        )
        let markers = markerRanges(in: cell.inlines)
            .compactMap { marker -> NSRange? in
                let intersection = NSIntersectionRange(marker, cell.contentRange)
                guard intersection.length > 0 else { return nil }
                return NSRange(
                    location: intersection.location - cell.contentRange.location,
                    length: intersection.length
                )
            }
            .sorted { $0.location > $1.location }
        for marker in markers where marker.upperBound <= content.length {
            content.deleteCharacters(in: marker)
        }
        return content
    }

    static func plainText(for cell: TableCell, in storage: NSAttributedString) -> String {
        attributedContent(for: cell, in: storage).string
    }

    private static func markerRanges(in spans: [InlineSpan]) -> [NSRange] {
        var result: [NSRange] = []
        func collect(_ span: InlineSpan) {
            result.append(contentsOf: span.markerRanges)
            for child in span.children { collect(child) }
        }
        for span in spans { collect(span) }
        return RangeSet.normalized(result)
    }
}

/// Column geometry for one table, computed once and shared by its rows.
struct TableLayout {
    var columnX: [CGFloat]
    var columnWidths: [CGFloat]
    var alignments: [NSTextAlignment]
    var rowHeights: [CGFloat]
    var totalWidth: CGFloat

    /// §11.3: numeric columns are right-aligned automatically.  A column
    /// counts as numeric when most of its non-empty body cells parse as a
    /// number — "most", not "all", because agent tables routinely carry an
    /// `n/a` in an otherwise numeric column.
    static func make(data: TableData, storage: NSAttributedString, width: CGFloat, style: StyleSheet) -> TableLayout {
        let columns = max(1, data.columnCount)
        var natural = [CGFloat](repeating: 0, count: columns)
        var minimums = [CGFloat](repeating: 0, count: columns)
        var numeric = [Int](repeating: 0, count: columns)
        var counted = [Int](repeating: 0, count: columns)

        for row in data.rows {
            for (index, cell) in row.cells.enumerated() where index < columns {
                let text = TableCellPresentation.plainText(for: cell, in: storage)
                let measured = NSAttributedString(string: text, attributes: [
                    .font: row.isHeader ? style.emphasisFont(bold: true, italic: false) : style.bodyFont(),
                ]).size().width
                natural[index] = max(natural[index], measured)
                let longestToken = text
                    .split(whereSeparator: \.isWhitespace)
                    .map(String.init)
                    .map {
                        NSAttributedString(string: $0, attributes: [
                            .font: row.isHeader
                                ? style.emphasisFont(bold: true, italic: false)
                                : style.bodyFont(),
                        ]).size().width
                    }
                    .max() ?? 0
                // Short labels should remain labels. Long prose columns may
                // wrap, but never below their longest readable token.
                let readableMinimum = measured <= 180 ? measured : longestToken
                minimums[index] = max(minimums[index], readableMinimum)
                guard !row.isHeader else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                counted[index] += 1
                if isNumeric(trimmed) { numeric[index] += 1 }
            }
        }

        let gaps = RenderMetrics.tableColumnGap * CGFloat(columns - 1)
        // Tables are drawn inside the existing text container. A table may
        // wrap aggressively, but it must never claim a wider layout fragment:
        // doing so invites a second scroll surface inside TextKit.
        let available = max(1, width - gaps)
        let floor = min(28, available / CGFloat(columns))
        var widths = minimums.map { max(floor, $0) }
        let minimumTotal = widths.reduce(0, +)
        if minimumTotal > available {
            let correction = available / minimumTotal
            widths = widths.map { max(1, $0 * correction) }
        } else if natural.reduce(0, +) > 0 {
            // Give remaining space only to columns that can use it. This keeps
            // a compact label column intact beside a long prose column.
            var remaining = available - minimumTotal
            var unmet = natural.indices.map { max(0, natural[$0] - widths[$0]) }
            while remaining > 0.5 {
                let demand = unmet.reduce(0, +)
                guard demand > 0.5 else { break }
                let budget = remaining
                for index in widths.indices where unmet[index] > 0 {
                    let addition = min(unmet[index], budget * (unmet[index] / demand))
                    widths[index] += addition
                    unmet[index] -= addition
                    remaining -= addition
                }
            }
            if remaining > 0.5 {
                let share = remaining / CGFloat(columns)
                widths = widths.map { $0 + share }
            }
        } else {
            widths = [CGFloat](repeating: available / CGFloat(columns), count: columns)
        }

        var xs: [CGFloat] = []
        var cursor: CGFloat = 0
        for width in widths {
            xs.append(cursor)
            cursor += width + RenderMetrics.tableColumnGap
        }

        var alignments: [NSTextAlignment] = []
        for index in 0..<columns {
            let declared = index < data.alignments.count ? data.alignments[index] : .none
            switch declared {
            case .left: alignments.append(.left)
            case .center: alignments.append(.center)
            case .right: alignments.append(.right)
            case .none:
                let isNumericColumn = counted[index] > 0 && numeric[index] * 5 >= counted[index] * 3
                alignments.append(isNumericColumn ? .right : .left)
            }
        }

        var rowHeights: [CGFloat] = []
        rowHeights.reserveCapacity(data.rows.count)
        for row in data.rows {
            var lines: CGFloat = 1
            for (index, cell) in row.cells.enumerated() where index < widths.count {
                let value = TableCellPresentation.plainText(for: cell, in: storage)
                let font = row.isHeader
                    ? style.emphasisFont(bold: true, italic: false).withSize(style.bodyFont().pointSize * 0.85)
                    : style.bodyFont()
                let rect = (value as NSString).boundingRect(
                    with: CGSize(width: widths[index], height: style.lineHeight * 3),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: [.font: font]
                )
                lines = max(lines, min(3, ceil(rect.height / max(1, style.lineHeight))))
            }
            rowHeights.append(RenderMetrics.snap(style.lineHeight * lines + RenderMetrics.tableRowPadding * 2,
                                                  grid: max(1, style.baselineGrid)))
        }
        return TableLayout(columnX: xs, columnWidths: widths, alignments: alignments,
                           rowHeights: rowHeights,
                           totalWidth: min(width, max(0, cursor - RenderMetrics.tableColumnGap)))
    }

    private static func isNumeric(_ text: String) -> Bool {
        var stripped = text
        for token in ["$", "%", ",", "€", "£", "+"] { stripped = stripped.replacingOccurrences(of: token, with: "") }
        stripped = stripped.trimmingCharacters(in: .whitespaces)
        guard !stripped.isEmpty else { return false }
        return Double(stripped) != nil
    }
}

/// One table row (§11.3): **no gridlines**.  A horizontal rule under the
/// header, zebra on hover, numeric columns right-aligned.  The pipe syntax
/// stays in the storage untouched, so ⌘C still copies a markdown table and the
/// table editor (§6.3) has something to rewrite.
final class TableRowFragment: DownrightFragment {
    private let data: TableData
    private let rowIndex: Int

    /// `nil` when the payload carries no table geometry, so the provider can
    /// fall back to a plain fragment.  A factory rather than a failable
    /// initialiser because the base class's is not failable.
    static func make(
        textElement: NSTextElement,
        range: NSTextRange?,
        payload: FragmentPayload,
        context: FragmentContext
    ) -> TableRowFragment? {
        guard payload.tableData != nil else { return nil }
        return TableRowFragment(textElement: textElement, range: range, payload: payload, context: context)
    }

    override init(textElement: NSTextElement, range: NSTextRange?, payload: FragmentPayload, context: FragmentContext) {
        let data = payload.tableData ?? TableData(rows: [], alignments: [], delimiterRange: NSRange(location: 0, length: 0))
        self.data = data
        // Resolved against the element's own range so a row keeps its identity
        // when the table moves.
        let elementStart: Int
        if let elementRange = textElement.elementRange, let manager = textElement.textContentManager {
            elementStart = manager.offset(from: manager.documentRange.location, to: elementRange.location)
        } else {
            elementStart = payload.sourceRange.location
        }
        self.rowIndex = data.rows.firstIndex { $0.range.contains(offset: elementStart) } ?? -1
        super.init(textElement: textElement, range: range, payload: payload, context: context)
    }

    required init?(coder: NSCoder) { nil }

    override var suppressesText: Bool { true }

    override var overrideHeight: CGFloat? {
        guard row != nil, let layout = layout(), rowIndex < layout.rowHeights.count else { return 0 }
        return layout.rowHeights[rowIndex]
    }

    private var row: TableRow? {
        rowIndex >= 0 && rowIndex < data.rows.count ? data.rows[rowIndex] : nil
    }

    private func layout() -> TableLayout? {
        guard let context, let style = styleSheet, let storage = context.storage else { return nil }
        let width = contentWidth - RenderMetrics.tableColumnGap
        let key = TableLayoutKey(
            location: payload.sourceRange.location,
            width: Int((width * 4).rounded()),
            textRevision: context.textRevision
        )
        if let cached = context.tableLayouts[key] { return cached }
        let made = TableLayout.make(data: data, storage: storage,
                                    width: width, style: style)
        context.tableLayouts[key] = made
        return made
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard let style = styleSheet, let layout = layout(), let row else { return }
        let rowHeight = rowIndex < layout.rowHeights.count ? layout.rowHeights[rowIndex] : style.lineHeight
        let frame = CGRect(x: point.x, y: point.y, width: max(contentWidth, layout.totalWidth), height: rowHeight)

        if !row.isHeader, context?.hoveredTableRow == row.range {
            cg.fillRect(frame, color: style.text.withAlphaComponent(0.04))
        }

        for (index, cell) in row.cells.enumerated() where index < layout.columnX.count {
            let source: NSAttributedString
            if let storage = context?.storage {
                source = TableCellPresentation.attributedContent(for: cell, in: storage)
            } else {
                source = NSAttributedString()
            }
            let text = NSMutableAttributedString(attributedString: row.isHeader
                ? NSAttributedString(string: source.string.uppercased(), attributes: source.length > 0 ? source.attributes(at: 0, effectiveRange: nil) : [:])
                : source)
            guard text.length > 0 else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = layout.alignments[index]
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 0
            let whole = NSRange(location: 0, length: text.length)
            text.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            if row.isHeader {
                text.addAttributes([
                    .font: style.emphasisFont(bold: true, italic: false).withSize(style.bodyFont().pointSize * 0.85),
                    .foregroundColor: style.textSecondary,
                    .kern: style.bodyFont().pointSize * 0.06,
                ], range: whole)
            }
            let cellRect = CGRect(x: frame.minX + layout.columnX[index],
                                  y: frame.minY + RenderMetrics.tableRowPadding,
                                  width: layout.columnWidths[index],
                                  height: frame.height - RenderMetrics.tableRowPadding)
            cg.drawText(text, in: cellRect, flipped: true)
        }

        // One rule under the header. An open bottom keeps the table out of box territory.
        if row.isHeader {
            cg.fillRect(CGRect(x: frame.minX, y: frame.maxY - RenderMetrics.tableRuleWidth,
                               width: frame.width, height: RenderMetrics.tableRuleWidth),
                        color: style.rule)
        }
    }
}
