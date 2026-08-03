# Status

An honest accounting of what this build does, what is approximate, and where it
departs from `markdown-app-spec.md`. Read this before filing a bug.

## Environment constraints this build was made under

The whole project builds with the **Command Line Tools only** — no Xcode. That
shaped three things:

### Tests use swift-testing, and must be run through `Scripts/check.sh`

XCTest ships with Xcode; the Command Line Tools do not include
`XCTest.framework` at all, so `import XCTest` cannot compile here. swift-testing
*does* ship with the CLT, but outside SwiftPM's default framework search path.

This produces a genuinely dangerous failure mode worth stating plainly: SwiftPM
wraps its generated test runner's swift-testing entry point in
`#if canImport(Testing)`. Without the search path that condition is false, the
branch compiles out, and **bare `swift test` exits 0 having run nothing** — a
green result that tested zero code. `Scripts/check.sh` passes the flag and then
asserts a non-zero test count, so the silent no-op fails loudly instead.

```bash
Scripts/check.sh
```

### Quick Look needs the Xcode release path

`Scripts/bundle-xcode-app.sh` builds and embeds the preview and thumbnail
`.appex` bundles. The simpler `Scripts/bundle-app.sh` SwiftPM path does not.
`Sources/DownrightQL/` and `Sources/DownrightThumb/` also compile as libraries
in CI and carry the full memory discipline §10 demands.

To make this real rather than aspirational, `DensityGutterView` was moved out of
the app and into `MarkdownRender`, so the extension draws **the same rail** the
app draws rather than a second implementation that could drift.

### Sparkle is not embedded

It ships as a framework with XPC helpers needing a Copy Files phase and
per-bundle signing. `AppDelegate` performs no update checks of its own, so
adding it is purely additive. [RELEASE.md](RELEASE.md) has the steps.

## Deliberate deviations from the spec

### Callout tint

The UI plan's recommended 5% semantic-colour tint is adopted for callouts.
This intentionally departs from the original "never filled boxes" rule: the
tint is low enough to remain document typography, while making callouts
distinct from plain blockquotes in both signature themes.

### Syntax highlighting is a native lexer, not tree-sitter

§12 names **SwiftTreeSitter + Neon**. Those need a separate SPM package per
language — eight-plus additional dependencies, each a large C target, each an
independent source of version drift.

So `MarkdownRender/Syntax/` implements a single-pass scanner over `[UInt16]`
(so `NSRange` offsets come free and no per-token `String` is allocated),
parameterised by per-language *data*: keyword tables, comment and string forms,
raw-string shapes, sigils. It sits behind the `SyntaxHighlighter` protocol
precisely so a tree-sitter backend can replace it later without the decoration
engine noticing.

Throughput: **≈250 MB/s** (1.7 ms for a 218 KB Swift block).

24 canonical languages: `bash, c, cpp, css, diff, go, html, java, javascript,
json, jsx, markdown, objc, plaintext, python, ruby, rust, sql, swift, toml, tsx,
typescript, xml, yaml`, plus the usual aliases (`ts`, `sh`, `py`, `rs`, `yml`,
`c++`, `objective-c`, …).

Known lexer simplifications: JSX/TSX markup lexes as expressions rather than
tags (`<Foo` still colours as a type); Ruby and shell heredocs are not tracked.

### Main dependency choices from §12

`swift-markdown` (cmark-gfm) for parsing, `SwiftMath` for math,
`beautiful-mermaid-swift` for diagrams, `NLTokenizer` for sentence segmentation,
and FSEvents (directory-level) for watching. No WebView is used. The Xcode
release path includes Quick Look. It does not include a metadata importer, a
Share extension, or Sparkle.

## Open questions from §15, decided

| Question | Decision |
|---|---|
| **1. Name** | Downright. Bundle ID `com.ezzyrappeport.downright`, CLI verb `down` (with `md` as an alias, per §3.4). |
| **2. Licence** | MIT. `MarkdownRender`'s value compounds through adoption; a fork has to keep pace with the original, and a licence that discourages contribution costs more than the fork it prevents. |
| **3. `.mdx` / `.qmd`** | Open them. Render the markdown, grey out the JSX and executable chunks, never evaluate them (§2). Refusing a file is worse than rendering the 90% of it that is plain markdown. |
| **4. Very large files** | 5MB by default, configurable in Settings → Editor; files above it use a line-count height estimate instead of eager whole-document layout. |
| **5. Editor integration** | One direction for 1.0: `file.ts:42` opens in your editor. The reverse is not implemented — per-editor protocol work for a use case nobody has asked for yet. |
| **6. Version timeline placement** | Separate window. Scrubbing a month of rewrites is a comparison activity, and the document you are comparing against has to stay visible. |
| **7. Theme format** | Hand-rolled JSON plus a **VS Code / Shiki importer**. Adopting a foreign schema would force the semantic palette into an editor's vocabulary; importing means people reuse existing work without the app inheriting someone else's model. |

## §6.1 — the hard part, precisely

The three-part solution lands as follows.

**(a) Block markers in the gutter — exact.** `#`, `>`, `-`, `1.`, `- [ ]` never
appear inline under any policy. `BlockStyleFactory.lineHeight` is a grid-snapped
function of block kind and nesting *only* — never of caret state. A reveal
therefore **structurally cannot** change line height. The vertical axis is
exact, unconditionally, and that is the part that actually hurts.

**(b) Per-span inline reveal — exact.** Entering `**bold**` reveals only that
span's markers. Multiple cursors reveal at the primary caret only, following
§14's recommendation.

**(c) Caret-anchored x-position pinning — partly exact, and here is the line.**

Exact: horizontal pinning on the caret's own line. The shift is the measured
typographic width of exactly the revealed marker runs preceding the caret,
drawn with the same attributes, applied as a negative head indent against 44pt
of reserved lead-in.

Approximate:

1. The shift is a paragraph-level indent, so on a **wrapped** paragraph the
   non-caret lines shift with it — the caret is pinned, its neighbours on other
   lines move.
2. Markers are measured in isolation, so kerning at the seam can put the pin off
   by a fraction of a point.
3. If a reveal pushes a word across a wrap boundary, the caret's line changes
   and its vertical position moves. No compensating re-wrap is attempted.
4. The shift is clamped to 44pt.
5. It is applied on caret changes, not continuously during a drag.

### Other render-layer deviations

- **Elision (zoom and folding) uses zero-height fragments, not display-string
  substitution.** A substitution cannot remove a paragraph terminator without
  desynchronising the text element from its content — the one failure that
  silently corrupts every later coordinate conversion. Favourable consequence:
  find still matches inside elided text, which keeps §14's four-way interaction
  (zoom × folding × find × hidden markers) simple rather than special-cased.
- **Fences, front-matter delimiters, table rows and `$$` lines are not hidden**
  — the fragments absorb them as chrome. Code-block copy and export actions
  use the parsed content range, so they return the body without fence lines.
- **Inline math uses a positive-length substitution** (one attachment
  character), generalising the index map beyond pure hiding.
- **Secondary-caret reveal** is opt-in in Settings → Editor. The default stays
  primary-only to avoid N reflows, while the all-cursors policy uses the same
  source/display map and remains byte-safe.
- **IME suspends hiding in the composing paragraph** so AppKit's marked-text
  bookkeeping stays exact.
- **Hard-wrapped markdown paragraphs are visually reflowed.**
  `MarkdownContentStorage` vends source-length grouped `NSTextParagraph`
  elements, while `HardWrapReflow` swaps soft source breaks for display-only
  spaces. Marker hiding uses same-length invisible replacements, so selection,
  editing, and byte identity stay safe. The physical delegate path remains the
  fallback during edits and stale-map windows; the feature is user-toggleable
  in Settings → Editor and defaults on.

## Core-layer semantics worth knowing

- **Line endings are normalised only when the file is *consistently* CRLF or
  CR.** Mixed-ending files are returned verbatim, so the round trip stays
  byte-identical and there is no `.mixed` case to get wrong.
- **`.disableSmartOpts` is passed to cmark unconditionally** — its smart
  punctuation rewrites quotes and dashes in the AST, which §3.1 forbids.
- **`ListEditing.indent` returns indentation edits only.** Correct ordered-list
  renumbering after a nesting change can only be computed from the reparsed
  result, so callers apply → reparse → `TidyDocument.plan(rules:
  [.orderedListNumbers])` inside one undo group.
- **`moveSection` treats blank lines as a property of the join**, not of either
  section — the §14 warning about this being harder than it looks.
- **Path token ranges include the `:42` suffix** (while `token.rawPath` excludes
  it) so the underline and the click target cover the whole reference.
- **Footnotes and link reference definitions are recovered by a source line
  scan** — cmark has no footnote extension and eats reference definitions.
- **Setext headings get no gutter marker** (there is nothing to put there), and
  tidy and promote/demote skip them, since a setext heading cannot express a
  level jump.
- **Heading scale exponents are `[3, 2, 1.25, 0.5, 0, 0]`**, not a pure power
  law. H5 and H6 remain body-sized and are distinguished by weight and tracking,
  while H1–H4 carry the size hierarchy.
- **`mathPointSize` is clamped to 0.90–1.10× body.** Matching Latin Modern
  Math's x-height against SF Pro would give 1.19× — the same number that makes
  KaTeX look too big everywhere else (§11.3).

## Known gaps

- **Sparkle updates** and **notarised distribution** — see above.
- **Spotlight coverage for files that have not been opened.** Downright adds
  each opened document to Core Spotlight. The metadata extractor for a full
  importer exists, but the signed importer bundle does not.
- **A dedicated Share extension.** The app provides a macOS Service and an App
  Intent. Finder's Share menu does not yet contain a Downright extension.
- **System document versions.** Downright has undo, atomic saves, external
  change detection, and local snapshots. It does not yet use `NSDocument` or
  show the standard macOS Versions interface.
- **Rich link previews.** Links and footnotes have local tooltips, and a
  footnote reference can jump to its definition. Remote link previews are not
  fetched in the background.
- **Reverse editor integration** (§15 Q5) — deliberately deferred.
- **A plugin system** — explicitly out of scope for 1.0 (§2).
- **`LightboxWindow` uses literal black and white** for its scrim and caption
  rather than theme colours: a tinted scrim discolours the image you opened it
  to look at. It goes opaque under Reduce Transparency.

## Performance

The budget in §12 is the product promise, so it is measured rather than
asserted. `Sources/drbench/` is that measurement, runnable:

```bash
swift run -c release drbench
```

It prints p50/p95 for parse, AST diff, text diff, synchronous typing response,
incremental decoration, end-to-end semantic convergence, and cold open. Parse
and diff run outside the synchronous typing path.

Latest release run: typing response p95 **0.149 ms**, semantic convergence p95
**46.726 ms**, and cold parse p95 **16.413 ms**. All are inside the product
budget.

See [PERFORMANCE.md](PERFORMANCE.md) for the measured numbers on this build and
what they mean for §13's P0 kill criterion.

## Test suites

The full check currently runs **436 tests in 53 suites**.

| Suite | Covers |
|---|---|
| `MarkdownCoreTests` | Byte-identical round trips over a tricky corpus, source-range invariants, every extension pass including the negative math cases (`echo $PATH` must not be math), AST diff locality, text diff, tidy idempotence, restructuring, and zoom plans. |
| `MarkdownRenderTests` | Theme decoding and colour resolution, type scale and measure cap, VS Code theme import, the lexer per language, decoration byte-identity across all three modes, the source↔display index map round-tripping every offset, and the keystroke benchmark. |
| `DownrightAppTests` | Scroll anchoring, change-mark shifting and navigation, snapshot restore, selection and split-view restore, find/regex/replace, path resolution, key bindings, jump history, export, sibling scanning, native integrations, local AI, speech, and offscreen rendering in all three modes. |
| `MarkdownCLITests` | Command parsing, health checks, render-target checks, outline output, JSON output, and error policy. |
