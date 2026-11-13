import AppKit
import Testing
@testable import MarkdownRender

/// Issue #55: LaTeX written for KaTeX, MathJax, Typora or Obsidian must render
/// rather than fall back to its source text. SwiftMath 1.7.3 lacks these
/// spellings; `SwiftMathDialect` and the vendored patches supply them.
@Suite("Math dialect")
struct MathDialectTests {

    @Test(arguments: [
        #"\dfrac{a}{b} + \tfrac{1}{2} + \cfrac{1}{1+x} + \dbinom{n}{k}"#,
        #"\operatorname{tr}(A) + \operatorname*{argmax}_x f(x)"#,
        #"\boldsymbol{\alpha} + \mathscr{F} + \textbf{two words} + \mbox{box}"#,
        #"a \not= b,\ a \not\in B,\ a \not\equiv b"#,
        #"\leqslant \subsetneq \implies \therefore \nexists \varnothing \dots \checkmark \hookrightarrow"#,
        #"\iint_D f \, dA + \iiint_V g \, dV"#,
        #"\big( x \Big] \quad \left( a \middle| b \right) \quad \lvert x \rvert + \lVert v \rVert"#,
        #"\boxed{E = mc^2} \quad \overrightarrow{AB} \quad a \: b \quad A \& B"#,
        #"E = mc^2 \tag{1} \label{eq:energy} \nonumber"#,
        #"\begin{equation} E = mc^2 \end{equation}"#,
        #"\begin{align*} f(x) &= x^2 \\[4pt] &= x \cdot x \end{align*}"#,
        #"\begin{gather*} a = b \\ c = d \end{gather*}"#,
        #"\begin{gathered} a = b \\ c = d \end{gathered}"#,
        #"\left( \begin{array}{c|c} a & b \\ \hline c & d \end{array} \right)"#,
        #"\begin{smallmatrix} a & b \\ c & d \end{smallmatrix}"#,
        "x = 1 % a TeX comment\n+ 2",
        #"\text{速度} = \frac{\text{距离}}{\text{时间}}"#,
    ])
    @MainActor func commonLatexRenders(_ latex: String) {
        for display in [true, false] {
            let image = MathRenderer.image(latex: latex, display: display, pointSize: 16, color: .labelColor)
            #expect(image != nil, "\(display ? "display" : "inline"): \(latex)")
        }
    }

    /// SwiftMath used to delete every non-ASCII character without an error,
    /// so `\text{中文}` and a typed `α` rendered as nothing at all.
    @Test @MainActor func nonASCIICharactersAreDrawnNotDropped() throws {
        func width(_ latex: String) throws -> CGFloat {
            try #require(MathRenderer.image(latex: latex, display: false, pointSize: 16, color: .labelColor)).size.width
        }
        #expect(try width("α ≤ β") == width(#"\alpha \leq \beta"#), "a typed symbol renders as its command")
        #expect(try width(#"x\text{中文}"#) > width("x") + 16, "CJK text draws with a fallback font")
    }

    /// `\\` is a row break, never the start of a command: `\\label` is a break
    /// followed by the letters "label", which must survive the rewrite.
    @Test func escapedBackslashIsNotACommand() {
        #expect(SwiftMathDialect.source(from: #"a \\label{x}"#, display: false) == #"a \\label{x}"#)
        #expect(SwiftMathDialect.source(from: #"a \label{x} b"#, display: false) == #"a  b"#)
    }

    /// `\dfrac` forces display size inline and `\tfrac` text size in a display
    /// formula; the formula's own style resumes after the fraction, because
    /// SwiftMath's braces do not scope a style switch.
    @Test @MainActor func styledFractionsForceTheirSizeAndRestoreTheFormulas() throws {
        func height(_ latex: String, display: Bool) throws -> CGFloat {
            try #require(MathRenderer.image(latex: latex, display: display, pointSize: 16, color: .labelColor)).size.height
        }
        #expect(try height(#"\dfrac{a}{b}"#, display: false) > height(#"\frac{a}{b}"#, display: false))
        #expect(try height(#"\tfrac{a}{b}"#, display: true) < height(#"\frac{a}{b}"#, display: true))
        #expect(SwiftMathDialect.source(from: #"\dfrac{a}{b} x"#, display: false)
            == #"\displaystyle \frac{a}{b}\textstyle  x"#)
        #expect(SwiftMathDialect.source(from: #"\dfrac{a}{b}"#, display: true) == #"\frac{a}{b}"#)
    }

    @Test func namedMathopBecomesAnOperatorThatTakesScripts() {
        #expect(SwiftMathDialect.source(from: #"\mathop{lim}_{x}"#, display: true) == #"\operatorname{lim}_{x}"#)
    }

    @Test func commentBracesDoNotCloseAnArgument() {
        #expect(SwiftMathDialect.source(from: "\\boxed{x % }\n+ 1} y", display: true) == "{x \n+ 1} y")
    }
}
