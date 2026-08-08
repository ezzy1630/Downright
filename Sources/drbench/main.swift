import AppKit
import Foundation
import Markdown
import MarkdownCore
import MarkdownRender

// The performance budget from §12, made runnable.
//
// "Wire these into a benchmark suite in P0 and run them in CI. They are the
// product promise."  A budget nobody measures is a wish, and the numbers here
// decide §13's P0 kill criterion — if keystroke→render will not come under 8ms,
// the architecture needs rethinking before six months are built on top of it.
//
//   swift run -c release drbench

// MARK: - Harness

/// Set when a measured p95 misses its budget.  Release runs exit non-zero so a
/// CI gate can treat the budget as a promise, not a wish (§12).
var budgetViolated = false

@discardableResult
func measure(_ label: String, budget: Double? = nil, runs: Int = 25, _ body: () -> Void) -> Double {
    // One warm-up so first-call lazy initialisation isn't charged to the p50.
    body()
    var samples: [Double] = []
    samples.reserveCapacity(runs)
    for _ in 0..<runs {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        samples.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
    }
    samples.sort()
    let p50 = samples[samples.count / 2]
    let p95 = samples[min(samples.count - 1, Int((Double(samples.count) * 0.95).rounded(.down)))]

    var line = String(format: "  %-44@  p50 %8.3f ms   p95 %8.3f ms", label as NSString, p50, p95)
    if let budget {
        line += p95 <= budget
            ? String(format: "   ✓ under %.0f ms", budget)
            : String(format: "   ✗ BUDGET %.0f ms", budget)
        if p95 > budget { budgetViolated = true }
    }
    print(line)
    return p95
}

// MARK: - Render dump
//
// `drbench render <file.md> <out.png> [mode] [width] [height]`
//
// A headless capture of the real container view.  Debugging "the window is
// blank" through the app is a rebuild-relaunch-squint loop; this makes it a
// command that produces a picture and an ink percentage.

func renderToPNG(input: URL, output: URL, mode: RenderMode, size: NSSize) throws {
    let text = try String(contentsOf: input, encoding: .utf8)
    let storage = NSTextStorage()
    storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: text)

    let container = MarkdownContainerView(storage: storage)
    container.frame = NSRect(origin: .zero, size: size)
    container.textView.mode = mode
    container.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
    container.layoutSubtreeIfNeeded()
    if let layout = container.textView.textLayoutManager {
        layout.ensureLayout(for: layout.documentRange)
    }

    print("""
      container   \(container.frame.size)
      scrollView  \(container.scrollView.frame.size)
      textView    frame \(container.textView.frame.size)  \
    minSize \(container.textView.minSize)  \
    maxSize \(container.textView.maxSize)
      container   textContainer size \(container.textView.textContainer?.size ?? .zero)
      insets      \(container.scrollView.contentInsets)
      vResizable  \(container.textView.isVerticallyResizable)  \
    hResizable \(container.textView.isHorizontallyResizable)
      storage     \(storage.length) chars
    """)

    guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
    container.cacheDisplay(in: container.bounds, to: rep)
    guard let png = rep.representation(using: .png, properties: [:]) else { return }
    try png.write(to: output)

    // Ink fraction against the top-left pixel, which is always page background.
    if let bytes = rep.bitmapData {
        let base = (bytes[0], bytes[1], bytes[2])
        var differing = 0, total = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 2) {
                let o = y * rep.bytesPerRow + x * rep.samplesPerPixel
                if abs(Int(bytes[o]) - Int(base.0)) + abs(Int(bytes[o + 1]) - Int(base.1))
                    + abs(Int(bytes[o + 2]) - Int(base.2)) > 24 { differing += 1 }
                total += 1
            }
        }
        print(String(format: "      ink         %.2f%% of pixels", 100 * Double(differing) / Double(max(1, total))))
    }
    print("      wrote       \(output.path)")
}

let arguments = CommandLine.arguments
if arguments.count >= 4, arguments[1] == "render" {
    let mode = arguments.count > 4 ? (RenderMode(rawValue: arguments[4]) ?? .read) : .read
    let width = arguments.count > 5 ? Double(arguments[5]) ?? 1000 : 1000
    let height = arguments.count > 6 ? Double(arguments[6]) ?? 1400 : 1400
    print("\n\(mode.rawValue) mode:")
    try renderToPNG(
        input: URL(fileURLWithPath: arguments[2]),
        output: URL(fileURLWithPath: arguments[3]),
        mode: mode,
        size: NSSize(width: width, height: height)
    )
    exit(0)
}

// MARK: - Corpus

/// A document shaped like agent output: headings every few lines, task lists,
/// fenced code, tables, inline paths.  Benchmarking on prose alone would flatter
/// the parser, since the extension passes are the part that scales badly.
func agentDocument(lines targetLines: Int) -> String {
    var out = ""
    var lineCount = 0
    var index = 0
    while lineCount < targetLines {
        index += 1
        let block = """
        ## Section \(index)

        A paragraph with **bold**, `code`, a [link](https://example.com), and a
        path reference `src/module\(index)/file.ts:\(index)` that resolves.

        - [ ] first task for section \(index)
        - [x] second task
        - a plain item

        """
        out += block
        lineCount += block.count(where: { $0 == "\n" })
        if index % 7 == 0 {
            out += "```swift\nlet value\(index) = \(index)\nfunc compute\(index)() -> Int { value\(index) * 2 }\n```\n\n"
            lineCount += 6
        }
        if index % 11 == 0 {
            out += "| column | value |\n|---|--:|\n| a | \(index) |\n| b | \(index * 2) |\n\n"
            lineCount += 6
        }
        if index % 13 == 0 {
            out += "> [!NOTE]\n> A callout, because agents emit these constantly.\n\n"
            lineCount += 3
        }
    }
    return out
}

// MARK: - Run

let document5k = agentDocument(lines: 5_000)
let document100k = String(agentDocument(lines: 2_000).prefix(100_000))

print("""

Downright performance budget (§12)
  build: \(isDebugBuild ? "DEBUG — numbers are not the product promise, rebuild with -c release" : "release")
  corpus: \(document5k.count) chars, \(document5k.count(where: { $0 == "\n" })) lines

""")

var isDebugBuild: Bool {
    #if DEBUG
    return true
    #else
    return false
    #endif
}

print("Parse (§3.5 — full reparse on every edit)")
measure("cmark alone", runs: 15) {
    _ = Document(parsing: document5k, options: [.disableSmartOpts])
}
measure("MarkdownParser.parse, all passes", runs: 15) {
    _ = MarkdownParser.parse(document5k)
}
measure("  … extension passes off", runs: 15) {
    _ = MarkdownParser.parse(document5k, options: MarkdownCore.ParseOptions(
        detectFrontMatter: false, detectMath: false, detectCallouts: false,
        detectWikilinks: false, detectPathTokens: false, detectMermaid: false
    ))
}
let variants: [(String, (inout MarkdownCore.ParseOptions) -> Void)] = [
    ("  … without path tokens", { (o: inout MarkdownCore.ParseOptions) in o.detectPathTokens = false }),
    ("  … without math", { (o: inout MarkdownCore.ParseOptions) in o.detectMath = false }),
    ("  … without wikilinks", { (o: inout MarkdownCore.ParseOptions) in o.detectWikilinks = false }),
    ("  … without callouts", { (o: inout MarkdownCore.ParseOptions) in o.detectCallouts = false }),
]
for (name, mutate) in variants {
    var options = MarkdownCore.ParseOptions.default
    mutate(&options)
    measure(name, runs: 15) { _ = MarkdownParser.parse(document5k, options: options) }
}

print("\nDiff")
let baseline = MarkdownParser.parse(document5k)
var editedText = document5k
editedText.insert("x", at: editedText.index(editedText.startIndex, offsetBy: editedText.count / 2))
let edited = MarkdownParser.parse(editedText)
measure("ASTDiff.dirtySet, one-character edit") { _ = ASTDiff.dirtySet(old: baseline, new: edited) }
measure("TextDiff.hunks, external rewrite", runs: 10) { _ = TextDiff.hunks(old: document5k, new: editedText) }

print("\nDecorate (§12 — keystroke → updated render, budget 8 ms p95)")
let styleSheet = StyleSheet(theme: Theme.fallback, appearance: NSAppearance.currentDrawing())
let engine = DecorationEngine(styleSheet: styleSheet)
let storage = NSTextStorage()
storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: document5k)
let dirty = ASTDiff.dirtySet(old: baseline, new: edited)
measure("incremental, one dirty block", budget: 8) {
    engine.decorate(storage, document: baseline, dirty: dirty)
}
measure("wholesale (mode switch)", runs: 5) {
    engine.decorate(storage, document: baseline, dirty: .wholesale)
}

print("\nSynchronous typing response (§12 — main-thread budget 8 ms p95)")
let responseStorage = NSTextStorage(string: document5k)
var responseCaret = responseStorage.length / 2
let typingP95 = measure("edit + paragraph map", budget: 8, runs: 100) {
    responseStorage.replaceCharacters(
        in: NSRange(location: responseCaret, length: 0), with: "x"
    )
    let paragraphs = ParagraphIndex(text: responseStorage.string as NSString)
    let map = DisplayMap(paragraphs: paragraphs, hidden: [])
    _ = map.textKitOffset(forSource: responseCaret)
    responseCaret += 1
}

print("\nSemantic convergence (end to end; outside the typing budget)")
let convergenceStorage = NSTextStorage(string: editedText)
let convergenceP95 = measure("worker pipeline", budget: 100, runs: 15) {
    let fresh = MarkdownParser.parse(editedText)
    let set = ASTDiff.dirtySet(old: baseline, new: fresh)
    engine.decorate(convergenceStorage, document: fresh, dirty: set)
}

print("\nCold open (§12 — first rendered pixel under 250 ms for 100 KB)")
measure("parse 100 KB", budget: 250, runs: 10) { _ = MarkdownParser.parse(document100k) }

print("\nOther")
measure("StructuralZoom.plan, skeleton", runs: 10) { _ = StructuralZoom.plan(baseline, level: .skeleton) }
measure("Metrics.metrics", runs: 10) { _ = Metrics.metrics(for: document5k) }
measure("TidyDocument.plan", runs: 10) { _ = TidyDocument.plan(baseline) }
measure("syntax highlight 10 KB Swift", runs: 20) {
    _ = BuiltinSyntaxHighlighter.shared.highlight(
        String(repeating: "func f() -> Int { let x = \"s\" // c\n return 1 }\n", count: 200),
        language: "swift"
    )
}

print("""

Typing response p95: \(String(format: "%.2f", typingP95)) ms against an 8 ms budget.
End-to-end semantic convergence p95: \(String(format: "%.2f", convergenceP95)) ms against a 100 ms budget.
""")

// Debug numbers are not the product promise — the banner above already says so —
// but a release run that misses a budget should fail loudly.
if budgetViolated && !isDebugBuild {
    print("\n❌ One or more budgets were missed. The performance budget is the product promise (§12).")
    exit(1)
}
