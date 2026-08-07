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
    var isStacked: Bool
    var stackedLabelWidth: CGFloat

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
        let isStacked = minimumTotal > available
        if isStacked {
            // Never squeeze a word below its readable width. On a narrow
            // measure, transpose rows into labeled fields instead of turning
            // `Source` into `Sourc/e` or introducing a nested scroll view.
            widths = [CGFloat](repeating: available / CGFloat(columns), count: columns)
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

        let stackedLabelWidth = min(150, max(72, width * 0.30))
        let stackedValueWidth = max(40, width - stackedLabelWidth - RenderMetrics.tableColumnGap)
        var rowHeights: [CGFloat] = []
        rowHeights.reserveCapacity(data.rows.count)
        for row in data.rows {
            if isStacked {
                guard !row.isHeader else {
                    rowHeights.append(0)
                    continue
                }
                let cellsHeight = row.cells.reduce(CGFloat.zero) { partial, cell in
                    let value = TableCellPresentation.plainText(for: cell, in: storage)
                    return partial + stackedCellHeight(
                        value: value,
                        width: stackedValueWidth,
                        font: style.bodyFont(),
                        style: style
                    )
                }
                rowHeights.append(RenderMetrics.snap(
                    cellsHeight + RenderMetrics.tableRowPadding * 2,
                    grid: max(1, style.baselineGrid)
                ))
                continue
            }
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
                           totalWidth: min(width, max(0, cursor - RenderMetrics.tableColumnGap)),
                           isStacked: isStacked,
                           stackedLabelWidth: stackedLabelWidth)
    }

    static func stackedCellHeight(
        value: String,
        width: CGFloat,
        font: NSFont,
        style: StyleSheet
    ) -> CGFloat {
        let rect = (value as NSString).boundingRect(
            with: CGSize(width: width, height: style.lineHeight * 4),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font]
        )
        let lines = min(CGFloat(4), max(1, ceil(rect.height / max(1, style.lineHeight))))
        return lines * style.lineHeight + style.baselineGrid
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

        if layout.isStacked {
            drawStackedRow(row, frame: frame, layout: layout, style: style, in: cg)
            return
        }

        for (index, cell) in row.cells.enumerated() where index < layout.columnX.count {
            let source: NSAttributedString
            if let storage = context?.storage {
                source = TableCellPresentation.attributedContent(for: cell, in: storage)
            } else {
                source = NSAttributedString()
            }
            // Header cells keep their author's casing.  Upper-casing turned
            // `pH` into `PH` and `macOS` into `MACOS`, and rebuilding the string
            // from the attributes at index 0 flattened every inline span in the
            // cell.  Kern + secondary + semibold already separate the row.
            let text = NSMutableAttributedString(attributedString: source)
            guard text.length > 0 else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = layout.alignments[index]
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 0
            let whole = NSRange(location: 0, length: text.length)
            text.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            if row.isHeader {
                Self.applyHeaderTreatment(to: text, style: style)
            }
            let cellRect = CGRect(x: frame.minX + layout.columnX[index],
                                  y: frame.minY + RenderMetrics.tableRowPadding,
                                  width: layout.columnWidths[index],
                                  height: frame.height - RenderMetrics.tableRowPadding)
            // The row reserved at most three lines (§11.3).  Anything longer
            // ends in an ellipsis, so a clipped cell reads as "there is more"
            // rather than as a sentence that stops mid-word.
            let visible = text.clipped(
                toHeight: rowHeight - RenderMetrics.tableRowPadding * 2,
                width: layout.columnWidths[index])
            cg.drawText(visible, in: cellRect, flipped: true)
        }

        // One rule under the header. An open bottom keeps the table out of box territory.
        if row.isHeader {
            cg.fillRect(CGRect(x: frame.minX, y: frame.maxY - RenderMetrics.tableRuleWidth,
                               width: frame.width, height: RenderMetrics.tableRuleWidth),
                        color: style.rule)
        }
    }

    /// Label treatment for a header cell: smaller, tracked, secondary, and
    /// semibold — applied *per font run* so an inline `code` or emphasis span
    /// inside the header survives instead of being overwritten wholesale.
    private static func applyHeaderTreatment(to text: NSMutableAttributedString, style: StyleSheet) {
        let whole = NSRange(location: 0, length: text.length)
        let size = style.bodyFont().pointSize * 0.85
        text.addAttributes([
            .foregroundColor: style.textSecondary,
            .kern: style.bodyFont().pointSize * 0.06,
        ], range: whole)
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            let font = value as? NSFont ?? style.bodyFont()
            let label = font.isFixedPitch
                ? style.monoFont(size: size)
                : style.emphasisFont(
                    bold: true,
                    italic: font.fontDescriptor.symbolicTraits.contains(.italic)
                ).withSize(size)
            text.addAttribute(.font, value: label, range: range)
        }
    }

    private func drawStackedRow(
        _ row: TableRow,
        frame: CGRect,
        layout: TableLayout,
        style: StyleSheet,
        in cg: CGContext
    ) {
        guard !row.isHeader, let storage = context?.storage else { return }
        let header = data.rows.first(where: \.isHeader)
        let valueX = frame.minX + layout.stackedLabelWidth + RenderMetrics.tableColumnGap
        let valueWidth = max(40, frame.maxX - valueX)
        var y = frame.minY + RenderMetrics.tableRowPadding

        for (index, cell) in row.cells.enumerated() {
            let label = header.flatMap { index < $0.cells.count ? $0.cells[index] : nil }
                .map { TableCellPresentation.plainText(for: $0, in: storage) }
                .flatMap { $0.isEmpty ? nil : $0 }
                ?? "Column \(index + 1)"
            let value = NSMutableAttributedString(
                attributedString: TableCellPresentation.attributedContent(for: cell, in: storage)
            )
            let valueString = value.string
            let cellHeight = TableLayout.stackedCellHeight(
                value: valueString,
                width: valueWidth,
                font: style.bodyFont(),
                style: style
            )

            // Same rule as the wide layout: the author's casing is the label.
            let labelParagraph = NSMutableParagraphStyle()
            labelParagraph.lineBreakMode = .byTruncatingTail
            let labelText = NSAttributedString(string: label, attributes: [
                .font: NSFont.systemFont(ofSize: max(10, style.bodyFont().pointSize * 0.72), weight: .semibold),
                .foregroundColor: style.textSecondary,
                .kern: style.bodyFont().pointSize * 0.045,
                .paragraphStyle: labelParagraph,
            ])
            cg.drawText(
                labelText,
                in: CGRect(x: frame.minX, y: y + 1,
                           width: layout.stackedLabelWidth, height: style.lineHeight),
                flipped: true
            )

            if value.length > 0 {
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                value.addAttribute(.paragraphStyle, value: paragraph,
                                   range: NSRange(location: 0, length: value.length))
                // Stacked cells cap at four lines; anything longer ends in an
                // ellipsis rather than being cut mid-word.
                let visible = value.clipped(
                    toHeight: cellHeight - style.baselineGrid, width: valueWidth)
                cg.drawText(
                    visible,
                    in: CGRect(x: valueX, y: y, width: valueWidth, height: cellHeight),
                    flipped: true
                )
            }
            y += cellHeight
        }

        cg.fillRect(
            CGRect(x: frame.minX, y: frame.maxY - RenderMetrics.tableRuleWidth,
                   width: frame.width, height: RenderMetrics.tableRuleWidth),
            color: style.rule.withAlphaComponent(0.65)
        )
    }
}
