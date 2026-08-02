import Foundation

// These tests use swift-testing (`import Testing`).  XCTest is not installed on
// this machine — there is no Xcode.app and the Command Line Tools ship no
// XCTest.framework, so `import XCTest` fails with "no such module" in any
// package.  swift-testing *is* present, but at a path SwiftPM does not search
// by default, so the suite needs two extra flags:
//
//   swift test --scratch-path .build-core --filter MarkdownCoreTests \
//     -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//     -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
//     -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib
//
// Installing Xcode, or adding those search paths to the test target in
// Package.swift, would let the bare `swift test` command work.

// A small corpus of documents that have historically broken markdown tooling:
// odd spacing, mixed markers, nested structure, tabs, CRLF, no trailing
// newline, a BOM, and the agent-flavoured constructs from §4.1.  Kept inline
// so the tests carry their own fixtures.

enum Corpus {
    static let kitchenSink = """
    ---
    title: Release Plan
    tags: [alpha, beta]
    owner: "Ada Lovelace"
    ---

    # Release Plan

    Intro paragraph with **bold**, *italic*, `code`, ~~strike~~ and a [link](docs/plan.md).
    See src/auth/session.ts:42 for the handler.

    ## Phase one

    > [!NOTE] Read this first
    > The plan changed on Tuesday.

    - [ ] Wire the parser
    - [x] Land the model
        - nested detail
        - more detail

    1. First
    2. Second
    3. Third

    ```swift
    func greet() -> String { "hi" }
    ```

    | Name | Count | Notes |
    |:-----|------:|:-----:|
    | a | 1 | x |
    | bb | 22 | yy |

    ### Phase one details

    Inline math $x^2 + y^2$ and a display block:

    $$
    e^{i\\pi} + 1 = 0
    $$

    See [[Design Notes|the notes]] for more.

    ## Phase two

    Some prose.  A second sentence lives here.

    ---

    Final paragraph.[^1]

    [^1]: A footnote body.
    """

    static let nestedLists = """
    - top
      - second
        - third
          continued line
      - back to second
    - another top

    1. one
       1. one-a
       2. one-b
    2. two
    """

    static let htmlAndCode = """
    <div class="warning">
      <p>Raw HTML block</p>
    </div>

    Text after html.

        indented code block
        second line

    ~~~python
    def main():
        pass
    ~~~
    """

    static let oddSpacing = "para one\n\n\n\n\npara two   \n\nline with break  \nnext line\n\n\n"

    static let tabs = "\t- tab indented item\n\t\t- deeper\n\nnormal\n"

    static let noTrailingNewline = "# Title\n\nBody without a trailing newline."

    static let crlf = "# Title\r\n\r\nA paragraph.\r\n\r\n- item\r\n- item two\r\n"

    static let mixedEndings = "line one\nline two\r\nline three\rline four\n"

    static let unicode = """
    # Überschrift mit Ümlauten

    Ein Absatz mit *Betonung* und `Código` und 日本語のテキスト.

    Emoji 🎉 in a **bold** run, then more text.

    | Spalte | Wert |
    | --- | --- |
    | café | 1 |
    | 日本 | 22 |
    """

    static let shellSnippets = """
    Run `echo $PATH` to see it.

    It costs $5 and $10 respectively, or $100 total.

    ```bash
    echo $HOME
    x=$(pwd)
    ```

    Use $VAR and $(cmd) freely.
    """

    /// Everything above, for sweeps that want maximum surface.
    static let all: [(name: String, text: String)] = [
        ("kitchenSink", kitchenSink),
        ("nestedLists", nestedLists),
        ("htmlAndCode", htmlAndCode),
        ("oddSpacing", oddSpacing),
        ("tabs", tabs),
        ("noTrailingNewline", noTrailingNewline),
        ("crlf", crlf),
        ("mixedEndings", mixedEndings),
        ("unicode", unicode),
        ("shellSnippets", shellSnippets),
    ]

    /// A synthetic 200-block document for the AST-diff locality test.
    static func manyBlocks(count: Int) -> String {
        (0..<count).map { index in
            index % 5 == 0 ? "## Section \(index)" : "Paragraph number \(index) with some words in it."
        }.joined(separator: "\n\n") + "\n"
    }
}
