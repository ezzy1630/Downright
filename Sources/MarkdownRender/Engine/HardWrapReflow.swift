import Foundation
import MarkdownCore

/// Plans display-only substitutions for soft Markdown line breaks. The
/// renderer keeps this planner separate from live TextKit integration: a
/// replacement must preserve UTF-16 coordinates before it is safe to publish.
enum HardWrapReflow {
    struct Plan {
        var ranges: [NSRange]
        var substitutions: [DisplaySubstitution]
    }

    static func plan(
        document: ParsedDocument,
        text: NSString,
        hiddenRanges: [NSRange],
        excludedRanges: [NSRange] = [],
        enabled: Bool
    ) -> Plan {
        guard enabled, text.length > 0 else { return Plan(ranges: [], substitutions: []) }

        var ranges: [NSRange] = []
        var substitutions: [DisplaySubstitution] = []
        document.root.walk { block in
            guard case .paragraph = block.content else { return }
            guard !excludedRanges.contains(where: {
                NSIntersectionRange($0, block.range).length > 0
            }) else { return }
            let elementRange = rangeIncludingTrailingSeparator(for: block, text: text)
            guard let softBreaks = softBreakRanges(
                in: block,
                elementRange: elementRange,
                text: text
            ), !softBreaks.isEmpty else {
                return
            }

            ranges.append(elementRange)
            substitutions.append(contentsOf: softBreaks.map {
                .replaceHardWrap($0, with: softBreakReplacement(for: text, range: $0))
            })

            for hidden in hiddenRanges where hidden.location >= elementRange.location
                && hidden.upperBound <= elementRange.upperBound {
                guard !softBreaks.contains(where: { NSIntersectionRange($0, hidden).length > 0 }) else {
                    continue
                }
                substitutions.append(
                    .replaceHidden(hidden, with: zeroWidthReplacement(length: hidden.length))
                )
            }
        }

        return Plan(ranges: ranges.sorted { $0.location < $1.location }, substitutions: substitutions)
    }

    private static func softBreakRanges(
        in block: MDBlock,
        elementRange: NSRange,
        text: NSString
    ) -> [NSRange]? {
        var result: [NSRange] = []
        let upperBound = Swift.min(elementRange.upperBound, text.length)
        var cursor = Swift.max(0, block.range.location)
        while cursor < upperBound {
            let length = lineTerminatorLength(in: text, at: cursor)
            guard length > 0 else {
                cursor += 1
                continue
            }
            let range = NSRange(location: cursor, length: length)
            guard range.upperBound < elementRange.upperBound else { break }
            guard !isProtected(range, in: block.inlines) else { return nil }
            guard !isExplicitBreak(range, in: text) else { return nil }
            result.append(range)
            cursor = range.upperBound
        }
        return result
    }

    private static func rangeIncludingTrailingSeparator(for block: MDBlock, text: NSString) -> NSRange {
        let length = lineTerminatorLength(in: text, at: block.range.upperBound)
        guard length > 0, block.range.upperBound + length <= text.length else { return block.range }
        return NSRange(location: block.range.location, length: block.range.length + length)
    }

    private static func isProtected(_ range: NSRange, in spans: [InlineSpan]) -> Bool {
        var protected = false
        walk(spans) { span in
            guard span.range.location <= range.location,
                  span.range.upperBound >= range.upperBound else { return }
            switch span.kind {
            case .inlineCode, .inlineMath, .inlineHTML, .lineBreak:
                protected = true
            default:
                break
            }
        }
        return protected
    }

    private static func walk(_ spans: [InlineSpan], visit: (InlineSpan) -> Void) {
        for span in spans {
            visit(span)
            walk(span.children, visit: visit)
        }
    }

    private static func lineTerminatorLength(in text: NSString, at offset: Int) -> Int {
        guard offset >= 0, offset < text.length else { return 0 }
        let character = text.character(at: offset)
        guard character == 0x0A || character == 0x0D
                || character == 0x0085 || character == 0x2028 || character == 0x2029
        else { return 0 }
        if character == 0x0D, offset + 1 < text.length, text.character(at: offset + 1) == 0x0A {
            return 2
        }
        return 1
    }

    private static func isExplicitBreak(_ range: NSRange, in text: NSString) -> Bool {
        let before = range.location
        if before >= 1, text.character(at: before - 1) == 0x5C { return true }
        return before >= 2
            && text.character(at: before - 1) == 0x20
            && text.character(at: before - 2) == 0x20
    }

    private static func softBreakReplacement(for text: NSString, range: NSRange) -> NSAttributedString {
        if range.length == 2,
           text.character(at: range.location) == 0x0D,
           text.character(at: range.location + 1) == 0x0A {
            return NSAttributedString(string: " \u{200B}")
        }
        return NSAttributedString(string: String(repeating: " ", count: range.length))
    }

    private static func zeroWidthReplacement(length: Int) -> NSAttributedString {
        NSAttributedString(string: String(repeating: "\u{200B}", count: max(1, length)))
    }
}
