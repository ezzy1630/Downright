import Foundation
import SwiftMath

/// Translates the LaTeX people write for KaTeX, MathJax, Typora and Obsidian
/// into the subset SwiftMath 1.7.3 parses.
///
/// Only the string handed to SwiftMath changes; the document's bytes never
/// do. Each rule either spells a construct the way SwiftMath knows it
/// (`\dfrac`, `align*`, `\not=`) or drops presentation SwiftMath cannot draw
/// while keeping every symbol of the formula (`\big` sizes, `\boxed` frames,
/// `\label`). A construct with no faithful spelling is left alone, so the
/// formula still falls back to its source text instead of rendering wrongly.
enum SwiftMathDialect {

    /// Adds the symbols SwiftMath lacks, with their TeX classes so relations
    /// and operators get TeX spacing.
    ///
    /// SwiftMath's symbol table is an unsynchronized static dictionary, so
    /// this must finish before any parse reads it. `MathRenderer` is the only
    /// door into SwiftMath and evaluates this first; `static let` makes the
    /// registration run exactly once.
    static let registerSymbols: Void = {
        func add(_ name: String, _ value: Character, _ type: MTMathAtomType) {
            // Never override a definition SwiftMath already has: an upstream
            // update that adds the symbol should win.
            guard MTMathAtomFactory.atom(forLatexSymbol: name) == nil,
                  let atom = MTMathAtomFactory.atom(forCharacter: value) else { return }
            atom.type = type
            MTMathAtomFactory.add(latexSymbol: name, value: atom)
        }
        for (name, value) in [
            ("leqslant", "\u{2A7D}"), ("geqslant", "\u{2A7E}"), ("lesssim", "\u{2272}"), ("gtrsim", "\u{2273}"),
            ("nleq", "\u{2270}"), ("ngeq", "\u{2271}"), ("nless", "\u{226E}"), ("ngtr", "\u{226F}"),
            ("nequiv", "\u{2262}"), ("nsim", "\u{2241}"), ("napprox", "\u{2249}"), ("ncong", "\u{2247}"),
            ("nmid", "\u{2224}"), ("nparallel", "\u{2226}"), ("notni", "\u{220C}"),
            ("subsetneq", "\u{228A}"), ("supsetneq", "\u{228B}"), ("nsubset", "\u{2284}"), ("nsupset", "\u{2285}"),
            ("nsubseteq", "\u{2288}"), ("nsupseteq", "\u{2289}"),
            ("implies", "\u{27F9}"), ("impliedby", "\u{27F8}"), ("longmapsto", "\u{27FC}"),
            ("hookrightarrow", "\u{21AA}"), ("hookleftarrow", "\u{21A9}"), ("twoheadrightarrow", "\u{21A0}"),
            ("rightleftharpoons", "\u{21CC}"), ("leftrightharpoons", "\u{21CB}"), ("rightharpoonup", "\u{21C0}"),
            ("leadsto", "\u{21DD}"), ("nrightarrow", "\u{219B}"), ("nRightarrow", "\u{21CF}"),
            ("therefore", "\u{2234}"), ("because", "\u{2235}"), ("coloneqq", "\u{2254}"), ("triangleq", "\u{225C}"),
            ("vdash", "\u{22A2}"), ("dashv", "\u{22A3}"),
        ] as [(String, Character)] {
            add(name, value, .relation)
        }
        for (name, value) in [
            ("diamond", "\u{22C4}"), ("dag", "\u{2020}"), ("ddag", "\u{2021}"), ("smallsetminus", "\u{2216}"),
        ] as [(String, Character)] {
            add(name, value, .binaryOperator)
        }
        for (name, value) in [
            ("nexists", "\u{2204}"), ("varnothing", "\u{2205}"), ("complement", "\u{2201}"), ("hslash", "\u{210F}"),
            ("dots", "\u{2026}"), ("dotsc", "\u{2026}"), ("dotso", "\u{2026}"),
            ("dotsb", "\u{22EF}"), ("dotsm", "\u{22EF}"), ("dotsi", "\u{22EF}"),
            ("checkmark", "\u{2713}"), ("Box", "\u{25A1}"), ("blacksquare", "\u{25A0}"), ("lozenge", "\u{25CA}"),
            ("bigstar", "\u{2605}"), ("surd", "\u{221A}"),
            ("clubsuit", "\u{2663}"), ("diamondsuit", "\u{2662}"), ("heartsuit", "\u{2661}"), ("spadesuit", "\u{2660}"),
            // Italic Greek variants, as unicode-math spells them.
            ("varkappa", "\u{1D718}"), ("digamma", "\u{03DD}"),
            ("varGamma", "\u{1D6E4}"), ("varDelta", "\u{1D6E5}"), ("varTheta", "\u{1D6E9}"),
            ("varLambda", "\u{1D6EC}"), ("varXi", "\u{1D6EF}"), ("varPi", "\u{1D6F1}"), ("varSigma", "\u{1D6F4}"),
            ("varUpsilon", "\u{1D6F6}"), ("varPhi", "\u{1D6F7}"), ("varPsi", "\u{1D6F9}"), ("varOmega", "\u{1D6FA}"),
        ] as [(String, Character)] {
            add(name, value, .ordinary)
        }
        for (name, value) in [
            ("iint", "\u{222C}"), ("iiint", "\u{222D}"), ("iiiint", "\u{2A0C}"), ("oiint", "\u{222F}"), ("oiiint", "\u{2230}"),
        ] where MTMathAtomFactory.atom(forLatexSymbol: name) == nil {
            MTMathAtomFactory.add(latexSymbol: name, value: MTMathAtomFactory.operatorWithName(value, limits: false))
        }
        // Deliberate override: SwiftMath's `\square` is its editing
        // placeholder, which it paints blue. In a document it is the
        // end-of-proof box.
        if let square = MTMathAtomFactory.atom(forCharacter: "\u{25A1}") {
            square.type = .ordinary
            MTMathAtomFactory.add(latexSymbol: "square", value: square)
        }
    }()

    /// The SwiftMath spelling of `latex`.
    /// `display` is the formula's own style. A style switch has to be undone
    /// explicitly afterwards, because SwiftMath flattens `{…}` into the
    /// surrounding list and a `\displaystyle` inside braces would leak.
    static func source(from latex: String, display: Bool) -> String {
        var rewriter = Rewriter(latex, display: display)
        return rewriter.run()
    }

    /// Commands SwiftMath knows under another name. Approximations are
    /// marked: they keep the formula's content and lose only a style.
    private static let renamedCommands: [String: String] = [
        "boldsymbol": "bm", "pmb": "bm",
        "mathscr": "mathcal", // approximation: no script alphabet
        "mbox": "text", "hbox": "text", "textnormal": "text", "textup": "text",
        "emph": "textit",
        "lvert": "vert", "rvert": "vert", "lVert": "Vert", "rVert": "Vert",
        "overrightarrow": "vec", // approximation: a fixed-size arrow accent
    ]

    /// Commands with nothing to draw: equation numbering and table rules.
    private static let droppedCommands: Set<String> = ["nonumber", "notag", "hline"]

    /// Manual delimiter sizes. SwiftMath cannot size a delimiter by hand, so
    /// the delimiter is kept at its natural size.
    private static let sizingCommands: Set<String> = {
        var names: Set<String> = ["middle"]
        for size in ["big", "Big", "bigg", "Bigg"] {
            for suffix in ["", "l", "r", "m"] { names.insert(size + suffix) }
        }
        return names
    }()

    /// `\frac`-like commands that force a style: the plain command and
    /// whether the forced style is display (`\dfrac`) or text (`\tfrac`).
    private static let styledFractions: [String: (command: String, display: Bool)] = [
        "dfrac": ("frac", true), "cfrac": ("frac", true), "tfrac": ("frac", false),
        "dbinom": ("binom", true), "tbinom": ("binom", false),
    ]

    /// `\not` followed by a token, spelled as the negated symbol.
    private static let negations: [String: String] = [
        "=": "neq", "<": "nless", ">": "ngtr",
        "in": "notin", "ni": "notni", "exists": "nexists",
        "equiv": "nequiv", "sim": "nsim", "approx": "napprox", "cong": "ncong",
        "mid": "nmid", "parallel": "nparallel",
        "leq": "nleq", "le": "nleq", "geq": "ngeq", "ge": "ngeq",
        "subset": "nsubset", "supset": "nsupset", "subseteq": "nsubseteq", "supseteq": "nsupseteq",
        "rightarrow": "nrightarrow", "to": "nrightarrow", "Rightarrow": "nRightarrow",
    ]

    /// Environments SwiftMath lacks, mapped to the closest one it has. An
    /// empty name unwraps the environment: `equation` is a display formula
    /// with a number, and Downright does not number formulas.
    private static let environments: [String: String] = [
        "equation": "", "equation*": "",
        "align": "aligned", "align*": "aligned", "flalign": "aligned", "flalign*": "aligned",
        "alignat": "aligned", "alignat*": "aligned", "alignedat": "aligned",
        "gather*": "gather", "gathered": "gather", "multline": "gather", "multline*": "gather",
        "eqnarray*": "eqnarray",
        "smallmatrix": "matrix", // approximation: full-size cells
        "array": "matrix", // approximation: centred columns, no rules
        "dcases": "cases",
    ]

    /// Environments whose `\begin` takes a mandatory argument SwiftMath does
    /// not: a column count or a column specification.
    private static let environmentsWithArgument: Set<String> = ["alignat", "alignat*", "alignedat", "array"]

    private struct Rewriter {
        private let chars: [Character]
        private let display: Bool
        private var index = 0
        private var output = ""

        init(_ latex: String, display: Bool) {
            chars = Array(latex)
            self.display = display
        }

        private func source(from latex: String) -> String {
            SwiftMathDialect.source(from: latex, display: display)
        }

        mutating func run() -> String {
            while index < chars.count {
                let char = chars[index]
                switch char {
                case "\\":
                    let name = readControlSequence()
                    rewrite(command: name)
                case "%":
                    // A TeX comment runs to the end of the line.
                    while index < chars.count, !chars[index].isNewline { index += 1 }
                case "~":
                    output += "\\ "
                    index += 1
                default:
                    output.append(char)
                    index += 1
                }
            }
            return output
        }

        private mutating func rewrite(command name: String) {
            if let renamed = SwiftMathDialect.renamedCommands[name] {
                output += "\\" + renamed
                return
            }
            if SwiftMathDialect.droppedCommands.contains(name) { return }
            if SwiftMathDialect.sizingCommands.contains(name) {
                rewriteSizedDelimiter()
                return
            }
            if let fraction = SwiftMathDialect.styledFractions[name] {
                rewriteStyledFraction(name, as: fraction)
                return
            }
            switch name {
            case ":":
                output += "\\>" // medium space
            case "\\":
                output += "\\\\"
                skipRowSpacing()
            case "label":
                let start = index
                if readArgument() == nil { index = start; output += "\\label" }
            case "mathop", "boxed":
                let start = index
                if let content = readArgument() {
                    if name == "mathop", !content.isEmpty, content.allSatisfy(\.isLetter) {
                        // A named operator (`\mathop{lim}`) is exactly what
                        // `\operatorname` builds, and scripts attach to it.
                        output += "\\operatorname{" + content + "}"
                    } else {
                        // Otherwise only the presentation is dropped: the
                        // content stays visible, though a following script
                        // attaches to its last atom rather than the whole.
                        output += "{" + source(from: content) + "}"
                    }
                } else {
                    index = start
                    output += "\\" + name
                }
            case "operatorname":
                let starred = consume("*")
                let start = index
                if let content = readArgument() {
                    output += "\\operatorname{" + source(from: content) + "}"
                    if starred { output += "\\limits" }
                } else {
                    index = start
                    output += "\\operatorname"
                }
            case "tag":
                // Downright does not number formulas, but a written tag is
                // content readers refer to, so it stays visible at the end.
                let starred = consume("*")
                let start = index
                if let content = readArgument() {
                    let text = "\\text{" + source(from: content) + "}"
                    output += starred ? "\\qquad " + text : "\\qquad (" + text + ")"
                } else {
                    index = start
                    output += "\\tag"
                }
            case "not":
                rewriteNegation()
            case "begin", "end":
                rewriteEnvironment(name)
            default:
                output += "\\" + name
            }
        }

        /// `\big(` → `(`; `\big.` draws nothing; `\big<` is an angle bracket.
        private mutating func rewriteSizedDelimiter() {
            skipSpaces()
            guard index < chars.count else { return }
            switch chars[index] {
            case ".": index += 1
            case "<": index += 1; appendControlWord("langle")
            case ">": index += 1; appendControlWord("rangle")
            default: break
            }
        }

        private mutating func rewriteStyledFraction(_ name: String, as fraction: (command: String, display: Bool)) {
            let start = index
            if name == "cfrac" { skipOptionalArgument() }
            guard let numerator = readArgument(), let denominator = readArgument() else {
                index = start
                output += "\\" + name
                return
            }
            let body = "\\\(fraction.command){\(source(from: numerator))}{\(source(from: denominator))}"
            guard fraction.display != display else {
                output += body
                return
            }
            // TeX sets the numerator and denominator one style smaller by
            // itself; only the fraction's own style needs forcing, and the
            // formula's style is restored after it.
            let forced = fraction.display ? "\\displaystyle " : "\\textstyle "
            let restore = display ? "\\displaystyle " : "\\textstyle "
            output += forced + body + restore
        }

        private mutating func rewriteNegation() {
            let start = index
            skipSpaces()
            var operand: String?
            if index < chars.count, chars[index] == "\\" {
                operand = readControlSequence()
            } else if index < chars.count {
                operand = String(chars[index])
                index += 1
            }
            guard let operand, let negated = SwiftMathDialect.negations[operand] else {
                index = start
                output += "\\not"
                return
            }
            appendControlWord(negated)
        }

        private mutating func rewriteEnvironment(_ command: String) {
            let start = index
            skipSpaces()
            guard consume("{") else {
                index = start
                output += "\\" + command
                return
            }
            var name = ""
            while index < chars.count, chars[index] != "}" {
                name.append(chars[index])
                index += 1
            }
            guard consume("}") else {
                index = start
                output += "\\" + command
                return
            }
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard let mapped = SwiftMathDialect.environments[trimmed] else {
                output += "\\\(command){\(name)}"
                return
            }
            if command == "begin" {
                if trimmed == "array" { skipOptionalArgument() }
                if SwiftMathDialect.environmentsWithArgument.contains(trimmed) { _ = readArgument() }
            }
            if !mapped.isEmpty { output += "\\\(command){\(mapped)}" }
        }

        /// `\\[4pt]` adds row spacing SwiftMath cannot express; without this
        /// the bracket would render as text.
        private mutating func skipRowSpacing() {
            let start = index
            skipSpaces()
            guard consume("[") else { index = start; return }
            var length = ""
            while index < chars.count, chars[index] != "]" {
                length.append(chars[index])
                index += 1
            }
            let units = ["pt", "em", "ex", "mm", "cm", "in", "mu", "bp", "pc", "dd", "sp"]
            let value = length.trimmingCharacters(in: .whitespaces)
            let isLength = units.contains { unit in
                value.hasSuffix(unit)
                    && Double(value.dropLast(unit.count).trimmingCharacters(in: .whitespaces)) != nil
            }
            guard isLength, consume("]") else { index = start; return }
        }

        /// Reads the control sequence after a backslash: a run of ASCII
        /// letters (`\alpha`) or exactly one other character (`\\`, `\{`,
        /// `\,`), so an escaped backslash is never mistaken for the start of
        /// a command.
        private mutating func readControlSequence() -> String {
            index += 1
            guard index < chars.count else { return "" }
            guard chars[index].isControlWordLetter else {
                defer { index += 1 }
                return String(chars[index])
            }
            let start = index
            while index < chars.count, chars[index].isControlWordLetter { index += 1 }
            return String(chars[start..<index])
        }

        /// Reads one macro argument: a brace group's contents, a control
        /// sequence, or a single character.
        private mutating func readArgument() -> String? {
            skipSpaces()
            guard index < chars.count else { return nil }
            switch chars[index] {
            case "{":
                guard let closing = matchingBrace(from: index) else { return nil }
                defer { index = closing + 1 }
                return String(chars[(index + 1)..<closing])
            case "}":
                return nil
            case "\\":
                let start = index
                _ = readControlSequence()
                return String(chars[start..<index])
            default:
                defer { index += 1 }
                return String(chars[index])
            }
        }

        private mutating func skipOptionalArgument() {
            let start = index
            skipSpaces()
            guard consume("[") else { index = start; return }
            while index < chars.count, chars[index] != "]" { index += 1 }
            guard consume("]") else { index = start; return }
        }

        private func matchingBrace(from opening: Int) -> Int? {
            var depth = 0
            var cursor = opening
            while cursor < chars.count {
                switch chars[cursor] {
                case "\\": cursor += 1
                case "%":
                    // A comment's braces are not structure.
                    while cursor + 1 < chars.count, !chars[cursor + 1].isNewline { cursor += 1 }
                case "{": depth += 1
                case "}":
                    depth -= 1
                    if depth == 0 { return cursor }
                default: break
                }
                cursor += 1
            }
            return nil
        }

        /// Appends `\name`, separated from a following letter so `\not=b`
        /// becomes `\neq b`, not the unknown command `\neqb`.
        private mutating func appendControlWord(_ name: String) {
            output += "\\" + name
            if index < chars.count, chars[index].isLetter { output += " " }
        }

        private mutating func consume(_ char: Character) -> Bool {
            guard index < chars.count, chars[index] == char else { return false }
            index += 1
            return true
        }

        private mutating func skipSpaces() {
            while index < chars.count, chars[index].isWhitespace { index += 1 }
        }
    }
}

private extension Character {
    var isControlWordLetter: Bool { isASCII && isLetter }
}
