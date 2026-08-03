import AppKit
import MarkdownCore

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
        // Tables are drawn inside the existing text container. A table may
        // wrap aggressively, but it must never claim a wider layout fragment:
        // doing so invites a second scroll surface inside TextKit.
        let available = max(1, width - gaps)
        let total = natural.reduce(0, +)
        let scale = total > available ? available / max(1, total) : 1
        let minimum = min(28, available / CGFloat(columns))
        var widths = natural.map { max(minimum, $0 * scale) }
        let usedBeforeSlack = widths.reduce(0, +)
        if usedBeforeSlack > available {
            let correction = available / usedBeforeSlack
            widths = widths.map { $0 * correction }
        }
        // Distribute any slack so the table fills the measure rather than
        // hugging the left edge.
        let used = widths.reduce(0, +)
        if used < available, total > 0 {
            let slack = available - used
            for i in widths.indices { widths[i] += slack * (natural[i] / total) }
        } else if total == 0 {
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
                let value = substring(storage, cell.contentRange)
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
            let source = attributedSource(cell.contentRange)
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
