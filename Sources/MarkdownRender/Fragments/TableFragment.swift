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
        // A cell with no inlines has no span to bound its content, so the
        // parser falls back to the cell's whole source range — which for an
        // empty cell reaches over the row's `|`.  Left in, README's empty
        // header row rendered as a line of pipes, and every "is this header
        // empty?" question upstream answered no.
        if cell.inlines.isEmpty {
            let husk = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "|"))
            while content.length > 0,
                  let last = content.string.unicodeScalars.last, husk.contains(last) {
                content.deleteCharacters(in: NSRange(location: content.length - 1, length: 1))
            }
            while content.length > 0,
                  let first = content.string.unicodeScalars.first, husk.contains(first) {
                content.deleteCharacters(in: NSRange(location: 0, length: 1))
            }
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
    /// Cell font size as a fraction of the body font.  Below 1 only when the
    /// columns would not otherwise fit: cells set at the header's own label
    /// size still read as a table, and one row per cell does not.
    var bodyFontScale: CGFloat = 1

    /// Floor for `bodyFontScale`.  `applyHeaderTreatment` already sets header
    /// labels at 0.85 of body, so a cell may follow the labels down to about
    /// that size and no further: past it the table stops being read and starts
    /// being decoded.
    static let minimumCellScale: CGFloat = 0.8

    /// §11.3: numeric columns are right-aligned automatically.  A column
    /// counts as numeric when most of its non-empty body cells parse as a
    /// number — "most", not "all", because agent tables routinely carry an
    /// `n/a` in an otherwise numeric column.
    ///
    /// Width is spent in a fixed order, because the columns *are* the table:
    /// the whole measure at body size, then the same columns with the cells
    /// shrunk toward label size, then — and only for a table whose header can
    /// actually label the fields — one field per line.
    static func make(data: TableData, storage: NSAttributedString, width: CGFloat, style: StyleSheet) -> TableLayout {
        let columns = max(1, data.columnCount)
        // Cell text is projected out of the storage once and reused by every
        // pass below.  The ladder can measure the same cells at a second font
        // size and the row heights need them again; re-projecting per pass is
        // what would put a wide table on the keystroke path (§12).
        let cellText: [[String]] = data.rows.map { row in
            row.cells.prefix(columns).map { TableCellPresentation.plainText(for: $0, in: storage) }
        }

        let gaps = RenderMetrics.tableColumnGap * CGFloat(columns - 1)
        // Tables are drawn inside the existing text container. A table may
        // wrap aggressively, but it must never claim a wider layout fragment:
        // doing so invites a second scroll surface inside TextKit.
        let available = max(1, width - gaps)
        let floor = min(28, available / CGFloat(columns))

        var scale: CGFloat = 1
        var demand = columnDemand(rows: data.rows, cellText: cellText, columns: columns,
                                  style: style, scale: scale)
        var widths = demand.minimums.map { max(floor, $0) }
        // Label or prose is a property of the cell, not of the size it is being
        // tried at, so every rung of the ladder re-measures against the verdicts
        // taken here at body size.
        let prose = demand.prose
        // Fields can only be stacked under labels that exist.  README's
        // four-column keyboard table has a completely empty header row, so
        // stacking it produced four unlabelled lines per binding: the data,
        // minus the table that made it legible.
        let labels = stackedLabels(
            header: data.rows.firstIndex(where: \.isHeader).map { cellText[$0] },
            columns: columns
        )
        let canStack = labels.contains { $0 != nil }

        if widths.reduce(0, +) > available {
            let body = style.bodyFont().pointSize
            // Glyph widths scale with point size, so the shortfall predicts the
            // gentlest size worth trying.  The floor is tried after it rather
            // than instead of it because the prediction is optimistic: a column
            // pinned at `floor` does not shrink with the type and neither do the
            // gaps, so the predicted size can still miss the measure by a point.
            // Two extra passes at worst, and only for a table that would
            // otherwise have been stacked.
            let wanted = available / max(1, widths.reduce(0, +))
            // Half-point steps: a size taken straight from the ratio would
            // creep on every window drag and re-render the table for nothing.
            let estimate = (body * wanted * 2).rounded(.down) / 2
            let smallest = (body * minimumCellScale).rounded()
            var sizes = [max(estimate, smallest), smallest].filter { $0 < body }
            if sizes.count == 2, sizes[0] == sizes[1] { sizes.removeLast() }
            for size in sizes {
                let tighter = columnDemand(rows: data.rows, cellText: cellText, columns: columns,
                                           style: style, scale: size / body, prose: prose)
                let tighterWidths = tighter.minimums.map { max(floor, $0) }
                // Smaller type earns its place by saving the columns.  Failing
                // that it is still taken when there is nothing to stack under:
                // the columns are staying either way, and smaller cells clip
                // less of the text inside them.
                guard tighterWidths.reduce(0, +) <= available || (!canStack && size == sizes.last) else {
                    continue
                }
                scale = size / body
                demand = tighter
                widths = tighterWidths
                break
            }
        }

        let minimumTotal = widths.reduce(0, +)
        var isStacked = minimumTotal > available && canStack
        let degraded = scale < 1 || minimumTotal > available
        if isStacked {
            // Never squeeze a word below its readable width. On a narrow
            // measure, transpose rows into labeled fields instead of turning
            // `Source` into `Sourc/e` or introducing a nested scroll view.
            widths = [CGFloat](repeating: available / CGFloat(columns), count: columns)
        } else if minimumTotal > available {
            // Nothing to stack under, so the columns stay and the cells take
            // the loss: wrapped tighter than their longest token, and clipped
            // with an ellipsis past three lines.  A clipped cell still says
            // which column and which row it belongs to, which is exactly what
            // an unlabelled stack throws away.
            widths = squeezed(widths, into: available, floor: floor)
        } else if demand.natural.reduce(0, +) > 0 {
            // Give remaining space only to columns that can use it. This keeps
            // a compact label column intact beside a long prose column.
            var remaining = available - minimumTotal
            var unmet = demand.natural.indices.map { max(0, demand.natural[$0] - widths[$0]) }
            while remaining > 0.5 {
                let wanted = unmet.reduce(0, +)
                guard wanted > 0.5 else { break }
                let budget = remaining
                for index in widths.indices where unmet[index] > 0 {
                    let addition = min(unmet[index], budget * (unmet[index] / wanted))
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

        // A rung of the ladder is chosen on width alone, and a layout that fits
        // the measure can still ellipsise a cell past the three-line cap — which
        // a stack would have shown in full.  A column's shape is worth less than
        // the words in it, so a degraded layout that clips gives way to the stack
        // whenever there are labels to stack under.  Checked only when the table
        // was degraded, so a table that simply fits pays nothing for it.
        if degraded, !isStacked, canStack,
           !fitsWithoutClipping(rows: data.rows, cellText: cellText, widths: widths,
                                style: style, scale: scale) {
            isStacked = true
            widths = [CGFloat](repeating: available / CGFloat(columns), count: columns)
        }

        var xs: [CGFloat] = []
        var cursor: CGFloat = 0
        for width in widths {
            xs.append(cursor)
            cursor += width + RenderMetrics.tableColumnGap
        }

        let alignments = self.alignments(for: data, cellText: cellText, columns: columns)

        let stackedLabelWidth = min(150, max(72, width * 0.30))
        let cellAttributes: [NSAttributedString.Key: Any] = [.font: bodyFont(style: style, scale: scale)]
        let headerAttributes = self.headerAttributes(style: style, scale: scale)
        var rowHeights: [CGFloat] = []
        rowHeights.reserveCapacity(data.rows.count)
        for (rowIndex, row) in data.rows.enumerated() {
            if isStacked {
                guard !row.isHeader else {
                    rowHeights.append(0)
                    continue
                }
                let cellsHeight = cellText[rowIndex].enumerated()
                    .reduce(CGFloat.zero) { partial, entry in
                        let hasLabel = entry.offset < labels.count && labels[entry.offset] != nil
                        return partial + stackedCellHeight(
                            value: entry.element,
                            width: stackedField(hasLabel: hasLabel,
                                                labelWidth: stackedLabelWidth,
                                                in: width).valueWidth,
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
            for (index, value) in cellText[rowIndex].enumerated() where index < widths.count {
                let rect = (value as NSString).boundingRect(
                    with: CGSize(width: widths[index], height: style.lineHeight * 3),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: row.isHeader ? headerAttributes : cellAttributes
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
                           stackedLabelWidth: stackedLabelWidth,
                           bodyFontScale: scale)
    }

    /// What each column asks for at one cell font size: the width its widest
    /// cell wants, the width below which that cell stops being readable, and the
    /// label-or-prose verdict per cell so a re-measure does not take it again.
    struct ColumnDemand {
        var natural: [CGFloat]
        var minimums: [CGFloat]
        var prose: [[Bool]]
    }

    /// Where a cell stops being a label and becomes prose.  A label keeps its
    /// whole width so it never wraps; prose may wrap, but never below its
    /// longest word.  Counted in average characters because the same point value
    /// buys a different number of words at every body size — 25 average
    /// characters is 180.1pt at the default 16pt body, which is the width this
    /// rule was calibrated at.
    private static let proseCharacters: CGFloat = 25

    private static func bodyFont(style: StyleSheet, scale: CGFloat) -> NSFont {
        let body = style.bodyFont()
        guard scale < 1 else { return body }
        return body.withSize(body.pointSize * scale)
    }

    /// The face and tracking a header cell is actually *drawn* at, so the pass
    /// that measures a column and the pass that draws it agree.  Measuring
    /// headers at the full emphasis font claimed about 15% more width than the
    /// glyphs occupy, which sent header-dominated tables down the degradation
    /// ladder — and, on a narrow measure, into stacking — for width nobody used.
    /// Tracking is part of that width: 0.06 em is about a point per character at
    /// a 16pt body — two average characters across a sixteen-letter label — and a
    /// column measured without it wraps its own header.
    ///
    /// The label follows the cell scale so a rung of the ladder shrinks the
    /// labels with the fields they label.  Left at body size the header
    /// minimums would be the one demand the ladder cannot reduce, so a table
    /// whose headers are its widest cells would stack however small the cells go.
    static func headerLabel(style: StyleSheet, scale: CGFloat) -> (font: NSFont, kern: CGFloat) {
        let body = style.bodyFont().pointSize
        return (style.emphasisFont(bold: true, italic: false).withSize(body * 0.85 * scale),
                body * 0.06 * scale)
    }

    static func headerAttributes(style: StyleSheet, scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let label = headerLabel(style: style, scale: scale)
        return [.font: label.font, .kern: label.kern]
    }

    /// `prose` is the verdict taken by the body-size pass; passing it back in is
    /// what keeps the ladder monotonic.  Deciding per trial size instead let a
    /// cell that had just dropped under the threshold stop counting its longest
    /// token and start counting its whole width, so the same four columns
    /// measured 541pt at body size, 598pt at 0.94 of it, and 522pt at 0.81 — and
    /// the ladder skipped the gentle rung that would have saved the columns.
    static func columnDemand(
        rows: [TableRow],
        cellText: [[String]],
        columns: Int,
        style: StyleSheet,
        scale: CGFloat,
        prose: [[Bool]]? = nil
    ) -> ColumnDemand {
        var natural = [CGFloat](repeating: 0, count: columns)
        var minimums = [CGFloat](repeating: 0, count: columns)
        // Verdicts are shaped like `cellText`, and the ladder hands back the ones
        // the body-size pass took, so both passes index them the same way.
        var verdicts = prose ?? cellText.map { [Bool](repeating: false, count: $0.count) }
        let decide = prose == nil
        let proseWidth = style.averageCharacterWidth * proseCharacters
        let cellAttributes: [NSAttributedString.Key: Any] = [.font: bodyFont(style: style, scale: scale)]
        let headerAttributes = self.headerAttributes(style: style, scale: scale)
        for (rowIndex, row) in rows.enumerated() where rowIndex < cellText.count {
            let attributes = row.isHeader ? headerAttributes : cellAttributes
            for (index, text) in cellText[rowIndex].enumerated() where index < columns {
                let measured = NSAttributedString(string: text, attributes: attributes).size().width
                natural[index] = max(natural[index], measured)
                let hasVerdict = rowIndex < verdicts.count && index < verdicts[rowIndex].count
                if decide, hasVerdict { verdicts[rowIndex][index] = measured > proseWidth }
                guard hasVerdict, verdicts[rowIndex][index] else {
                    minimums[index] = max(minimums[index], measured)
                    continue
                }
                // Only prose pays for the token scan: a table of labels is the
                // common case and it is on the keystroke path (§12).
                let longestToken = text
                    .split(whereSeparator: \.isWhitespace)
                    .map { NSAttributedString(string: String($0), attributes: attributes).size().width }
                    .max() ?? 0
                minimums[index] = max(minimums[index], longestToken)
            }
        }
        return ColumnDemand(natural: natural, minimums: minimums, prose: verdicts)
    }

    /// Shrinks columns to a width they did not ask for, in proportion to what
    /// each asked for, so a keystroke column stays narrow beside a prose one.
    /// Columns that would fall under the floor are pinned there and the rest
    /// cover their share, which is why this iterates.
    /// True when every cell fits inside the three-line cap at these widths, so
    /// keeping the columns costs no text.
    ///
    /// Measured against an unbounded height on purpose: the row-height pass caps
    /// its measurement at three lines, which cannot tell a cell that fills them
    /// from one that wanted five.
    /// Internal rather than private so the invariant it enforces is measurable
    /// from a test; nothing outside this file calls it.
    static func fitsWithoutClipping(
        rows: [TableRow],
        cellText: [[String]],
        widths: [CGFloat],
        style: StyleSheet,
        scale: CGFloat
    ) -> Bool {
        let cap = style.lineHeight * 3 + 0.5
        let cellAttributes: [NSAttributedString.Key: Any] = [.font: bodyFont(style: style, scale: scale)]
        let headerAttributes = self.headerAttributes(style: style, scale: scale)
        for (rowIndex, row) in rows.enumerated() where rowIndex < cellText.count {
            for (index, value) in cellText[rowIndex].enumerated()
            where index < widths.count && !value.isEmpty {
                let rect = (value as NSString).boundingRect(
                    with: CGSize(width: widths[index], height: .greatestFiniteMagnitude),
                    options: [.usesLineFragmentOrigin, .usesFontLeading],
                    attributes: row.isHeader ? headerAttributes : cellAttributes
                )
                if rect.height > cap { return false }
            }
        }
        return true
    }

    private static func squeezed(_ widths: [CGFloat], into available: CGFloat, floor: CGFloat) -> [CGFloat] {
        var pinned = Set<Int>()
        var result = widths
        for _ in widths.indices {
            let budget = available - floor * CGFloat(pinned.count)
            let flexible = widths.indices
                .filter { !pinned.contains($0) }
                .reduce(CGFloat.zero) { $0 + widths[$1] }
            guard flexible > 0.5, budget > 0 else { break }
            let factor = budget / flexible
            result = widths.indices.map { pinned.contains($0) ? floor : widths[$0] * factor }
            let starved = result.indices.filter { !pinned.contains($0) && result[$0] < floor }
            guard !starved.isEmpty else { break }
            pinned.formUnion(starved)
        }
        return result
    }

    /// Header text per column, `nil` where there is no header row or the author
    /// left that cell empty.  Both the height pass and the drawing read this: a
    /// field with no label gets the whole measure instead of an invented one.
    static func stackedLabels(header: [String]?, columns: Int) -> [String?] {
        (0..<max(1, columns)).map { index in
            guard let header, index < header.count else { return nil }
            let trimmed = header[index].trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? nil : trimmed
        }
    }

    /// Where one stacked field's value starts and how wide it is.  An
    /// unlabelled field has nothing to put in the label lane, so it takes the
    /// lane rather than leaving a blank column and wrapping the value early.
    static func stackedField(
        hasLabel: Bool,
        labelWidth: CGFloat,
        in width: CGFloat
    ) -> (valueOffset: CGFloat, valueWidth: CGFloat) {
        guard hasLabel else { return (0, max(40, width)) }
        let offset = labelWidth + RenderMetrics.tableColumnGap
        return (offset, max(40, width - offset))
    }

    private static func alignments(
        for data: TableData,
        cellText: [[String]],
        columns: Int
    ) -> [NSTextAlignment] {
        var numeric = [Int](repeating: 0, count: columns)
        var counted = [Int](repeating: 0, count: columns)
        for (rowIndex, row) in data.rows.enumerated() where !row.isHeader && rowIndex < cellText.count {
            for (index, text) in cellText[rowIndex].enumerated() where index < columns {
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                counted[index] += 1
                if isNumeric(trimmed) { numeric[index] += 1 }
            }
        }
        return (0..<columns).map { index in
            let declared = index < data.alignments.count ? data.alignments[index] : .none
            switch declared {
            case .left: return .left
            case .center: return .center
            case .right: return .right
            case .none:
                let isNumericColumn = counted[index] > 0 && numeric[index] * 5 >= counted[index] * 3
                return isNumericColumn ? .right : .left
            }
        }
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
        // A table is a full-bleed block, so `contentWidth` — the reading measure
        // plus the trailing bleed lane — is already the table's to use, exactly
        // as a code block uses it, and the container's line fragment padding is
        // zero.  Holding a column gap back off the trailing edge bought nothing
        // (no column starts there) and cost the README's four-column keyboard
        // table the point of width it needed to keep its columns.
        let width = contentWidth
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
                Self.applyHeaderTreatment(to: text, style: style, scale: layout.bodyFontScale)
            } else if layout.bodyFontScale < 1 {
                Self.applyCellScale(layout.bodyFontScale, to: text, style: style)
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
    /// inside the header survives instead of being overwritten wholesale.  Size
    /// and tracking come from `TableLayout.headerLabel`, which is also what the
    /// column-measuring pass measures with, so a header cannot be drawn wider
    /// than the column it was given.
    private static func applyHeaderTreatment(
        to text: NSMutableAttributedString,
        style: StyleSheet,
        scale: CGFloat
    ) {
        let whole = NSRange(location: 0, length: text.length)
        let label = TableLayout.headerLabel(style: style, scale: scale)
        let size = label.font.pointSize
        text.addAttributes([
            .foregroundColor: style.textSecondary,
            .kern: label.kern,
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

    /// Brings a body cell down to the size its column was measured at — per
    /// font run, so an inline `code` or emphasis span inside the cell keeps its
    /// family and traits instead of being flattened to the body face.
    private static func applyCellScale(
        _ scale: CGFloat,
        to text: NSMutableAttributedString,
        style: StyleSheet
    ) {
        let whole = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(.font, in: whole) { value, range, _ in
            let font = value as? NSFont ?? style.bodyFont()
            text.addAttribute(.font, value: font.withSize(font.pointSize * scale), range: range)
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
        let labels = TableLayout.stackedLabels(
            header: data.rows.first(where: \.isHeader).map { header in
                header.cells.map { TableCellPresentation.plainText(for: $0, in: storage) }
            },
            columns: data.columnCount
        )
        var y = frame.minY + RenderMetrics.tableRowPadding

        for (index, cell) in row.cells.enumerated() {
            let label = index < labels.count ? labels[index] : nil
            let field = TableLayout.stackedField(
                hasLabel: label != nil,
                labelWidth: layout.stackedLabelWidth,
                in: frame.width
            )
            let valueX = frame.minX + field.valueOffset
            let valueWidth = field.valueWidth
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
            // A missing one is left out rather than filled in with `Column 3`,
            // which named nothing and stole the width the value needed.
            if let label {
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
            }

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
