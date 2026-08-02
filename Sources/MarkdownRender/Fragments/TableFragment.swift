import AppKit
import MarkdownCore

/// Column geometry for one table, computed once and shared by its rows.
struct TableLayout {
    var columnX: [CGFloat]
    var columnWidths: [CGFloat]
    var alignments: [NSTextAlignment]
    var rowHeight: CGFloat

    /// §11.3: numeric columns are right-aligned automatically.  A column
    /// counts as numeric when most of its non-empty body cells parse as a
    /// number — "most", not "all", because agent tables routinely carry an
    /// `n/a` in an otherwise numeric column.
    static func make(data: TableData, storage: NSAttributedString, width: CGFloat, style: StyleSheet) -> TableLayout {
        let columns = max(1, data.columnCount)
        var natural = [CGFloat](repeating: 0, count: columns)
        var numeric = [Int](repeating: 0, count: columns)
        var counted = [Int](repeating: 0, count: columns)

        for row in data.rows {
            for (index, cell) in row.cells.enumerated() where index < columns {
                let text = substring(storage, cell.contentRange)
                let measured = NSAttributedString(string: text, attributes: [
                    .font: row.isHeader ? style.emphasisFont(bold: true, italic: false) : style.bodyFont(),
                ]).size().width
                natural[index] = max(natural[index], measured)
                guard !row.isHeader else { continue }
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                counted[index] += 1
                if isNumeric(trimmed) { numeric[index] += 1 }
            }
        }

        let gaps = RenderMetrics.tableColumnGap * CGFloat(columns - 1)
        let available = max(120, width - gaps)
        let total = natural.reduce(0, +)
        let scale = total > available ? available / max(1, total) : 1
        var widths = natural.map { max(28, $0 * scale) }
        // Distribute any slack so the table fills the measure rather than
        // hugging the left edge.
        let used = widths.reduce(0, +)
        if used < available, total > 0 {
            let slack = available - used
            for i in widths.indices { widths[i] += slack * (natural[i] / total) }
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

        let rowHeight = RenderMetrics.snap(style.lineHeight + RenderMetrics.tableRowPadding * 2,
                                           grid: max(1, style.baselineGrid))
        return TableLayout(columnX: xs, columnWidths: widths, alignments: alignments, rowHeight: rowHeight)
    }

    private static func substring(_ storage: NSAttributedString, _ range: NSRange) -> String {
        guard range.length > 0, range.upperBound <= storage.length else { return "" }
        return storage.attributedSubstring(from: range).string
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

    override var overrideHeight: CGFloat? { row == nil ? 0 : layout()?.rowHeight }

    private var row: TableRow? {
        rowIndex >= 0 && rowIndex < data.rows.count ? data.rows[rowIndex] : nil
    }

    private func layout() -> TableLayout? {
        guard let context, let style = styleSheet, let storage = context.storage else { return nil }
        let key = payload.sourceRange.location
        if let cached = context.tableLayouts[key] { return cached }
        let made = TableLayout.make(data: data, storage: storage,
                                    width: contentWidth - RenderMetrics.tableColumnGap, style: style)
        context.tableLayouts[key] = made
        return made
    }

    override func drawObject(at point: CGPoint, in cg: CGContext) {
        guard let style = styleSheet, let layout = layout(), let row else { return }
        let frame = CGRect(x: point.x, y: point.y, width: contentWidth, height: layout.rowHeight)

        if !row.isHeader, context?.hoveredTableRow == row.range {
            cg.fillRect(frame, color: style.codeBackground.withAlphaComponent(0.6))
        }

        for (index, cell) in row.cells.enumerated() where index < layout.columnX.count {
            let text = NSMutableAttributedString(attributedString: attributedSource(cell.contentRange))
            guard text.length > 0 else { continue }
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = layout.alignments[index]
            paragraph.lineBreakMode = .byTruncatingTail
            paragraph.firstLineHeadIndent = 0
            paragraph.headIndent = 0
            let whole = NSRange(location: 0, length: text.length)
            text.addAttribute(.paragraphStyle, value: paragraph, range: whole)
            if row.isHeader {
                text.addAttributes([
                    .font: style.emphasisFont(bold: true, italic: false),
                    .foregroundColor: style.textSecondary,
                ], range: whole)
            }
            let cellRect = CGRect(x: frame.minX + layout.columnX[index],
                                  y: frame.minY + RenderMetrics.tableRowPadding,
                                  width: layout.columnWidths[index],
                                  height: frame.height - RenderMetrics.tableRowPadding)
            cg.drawText(text, in: cellRect, flipped: true)
        }

        // Horizontal rules only — one under the header, one under the last row.
        if row.isHeader || rowIndex == data.rows.count - 1 {
            cg.fillRect(CGRect(x: frame.minX, y: frame.maxY - RenderMetrics.tableRuleWidth,
                               width: frame.width, height: RenderMetrics.tableRuleWidth),
                        color: style.rule)
        }
    }
}
