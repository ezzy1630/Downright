# UI & UX Plan

How Downright gets from *renders markdown correctly* to *looks and feels like a
first-party macOS document app*.

Written against the build at `8d2855b`, from reading the source and from
offscreen captures of `Docs/sample.md` and a synthetic element-coverage
document rendered by the actual binary.

**Direction:** Apple-native. Standard toolbar with a real title, a real
`NSSplitViewController` sidebar, system materials and selection, SF Symbols at
consistent weights. Distinctiveness comes from the *document*, not from
reinventing chrome.

**Chrome technology (recommended):** AppKit on standard containers.
Reasoning is in §2.0.

**Governing rule for this plan:** every item below is marked **Keep**,
**Modify**, or **Replace**. Nothing gets torn out and rebuilt identical. Where
existing code is right, it is named and left alone.

---

## 0. What is already right — do not rewrite

These are load-bearing and correct. Changes elsewhere must route around them,
not through them.

| Component | Why it stays |
|---|---|
| All of `MarkdownCore` | Parse, extension passes, AST diff, tidy, restructure, byte-identical round trips. No UI in it. Untouched by this plan except one wikilink fix (§1.7). |
| `DisplayMap` + `ParagraphSubstitution` mechanism | The source↔display index map is the hard part of Live mode and it is correct. §1.2 *extends* it; it does not replace it. |
| `MarkerPolicy`'s inline per-span reveal | §6.1b is genuinely solved. Only the *block*-marker branch changes (§1.1). |
| `DownrightFragment` / `ElidedFragment` architecture | One mechanism behind collapse, folding, and zoom. Every new visual below is a fragment on this base. |
| `MarkdownRender/Syntax/*` | 250 MB/s lexer behind a protocol. Only its *colour mapping* is retuned (§4.4). |
| `Theme` JSON schema, `ColorResolver`, hot reload, VS Code import | The schema gains fields (§4.4); the loading and resolution machinery is fine. |
| `StyleSheet` font resolution, measure cap, `mathPointSize` | The optical math sizing and the 68–72ch cap are two things almost nobody gets right. Keep the code; retune the *numbers* (§4). |
| `DensityGutterView.bands(for:changes:searchHits:)` | The band-building logic is good data. §2.3 replaces the *drawing*, keeps the data. |
| `Sources/drbench` | The performance budget is the product promise. Every phase below re-runs it. |

---

## 1. The document surface

This is where "basic and plain" actually lives. Ordered by visual impact.

### 1.1 List ornaments — **Replace** (highest impact)

**Implemented:** `MarkerPolicy.hiddenRanges` still hides Markdown source
markers in Read and Live, but `ListOrnamentFragment` now supplies the visible
bullet, ordinal, and checkbox treatment in the hanging indent. Live mode keeps
the source affordance in `GutterRailView` as well.

`RenderContracts.swift` keeps Read's `hidesBlockMarkers: true` and
`showsGutterMarkers: false`; the list remains legible without exposing syntax.

**The distinction the current design missed:** a `-` is *markdown syntax*; a
bullet is *typography*. Read mode should hide the syntax and draw the
typography. They are not the same object and hiding one should not remove the
other.

**Change:**

1. New `ListOrnamentFragment` (on `DownrightFragment`) drawn for every list
   item's first paragraph, in Read **and** Live. It draws into the hanging
   indent, not the far-left rail — a bullet belongs optically beside its text.
2. Ornament specs:
   - **Unordered:** `●` at 0.30 em (level 1), `○` (level 2), `▪` (level 3+),
     colour `textFaint`, optically centred on the first line's *x-height*, not
     on the line box. Nested levels cycle.
   - **Ordered:** tabular figures (`.fontFeatureSettings` monospaced-numbers) so
     `9.` and `10.` align, right-aligned against the text edge, `textSecondary`,
     at 0.92 × body size. Respect the source's start number.
   - **Task:** a drawn rounded square (10pt, 1.5pt stroke, 3pt radius),
     `accent`-filled with a white check when checked. Full click target of
     20 × 20. Checked item's text drops to `textSecondary`; strikethrough is a
     preference, default off.
3. **Hanging indent (real defect).** `BlockStyleFactory.paragraphStyle` sets
   `firstLineHeadIndent == headIndent` for every block. Wrapped list lines
   therefore align under the *bullet*, not under the *text*. Fix: for list
   items, `firstLineHeadIndent = indent`, `headIndent = indent + markerColumn`,
   where `markerColumn` is the measured ornament width plus a 0.5 em gap.
4. **Tight vs loose lists.** cmark reports it; the renderer ignores it.
   Tight: 0 spacing between items. Loose: 0.5 grid unit. A whole list block gets
   1 grid unit above and below.
5. `GutterRailView` keeps its Live-mode job — showing the *source* markers
   (`#`, `>`, `- [ ]`) as an editing affordance — but it is no longer the only
   place a list is legible.

**Risk:** low. Additive fragment plus a paragraph-style change, both covered by
`DecorationTests` byte-identity assertions.

### 1.2 Hard-wrapped paragraph reflow — **Implemented**

`MarkdownContentStorage` now groups the physical paragraphs belonging to a
Markdown paragraph into one source-length `NSTextParagraph`. Soft source
newlines become display-only spaces through `HardWrapReflow`; the backing
`NSTextStorage` and all source offsets remain unchanged.

- The custom content storage overrides `enumerateTextElements` and caches
  source-length paragraph elements. Its `NSTextParagraph` subclass supplies
  valid content and separator ranges to TextKit.
- Marker hiding remains source-coordinate safe by carrying invisible,
  same-length word joiners inside grouped elements. `ParagraphSubstitution`
  remains the physical fallback while edits or stale ranges suspend custom
  layout.
- Explicit Markdown breaks, inline-protected spans, code, tables, and other
  non-prose blocks retain their source line behavior.
- `Settings → Editor → Reflow wrapped paragraphs` defaults on and provides the
  escape hatch for documents that rely on physical line boundaries.
- Byte identity and runtime layout are covered by `DecorationTests`, including
  grouped paragraphs, source-preserving edits, marker hiding, and selections.

### 1.3 Code blocks — **Modify**

Verified defects:

- **Code text collides with the left rule.** The band is drawn at the
  paragraph's head indent and the rule at `band.minX`, with no interior padding
  left of the glyphs. `struct StyleSheet {` sits on top of the 2pt rule.
- **The band overhangs the measure** on the right by ~15pt.
- **The language chip costs a whole 24pt line.** `overrideHeight` for
  `.openChrome` returns 24 when a language is present, so every fenced block has
  a blank line above its first line of code.
- Band tint is within a few percent of the page background in the dark theme —
  the block barely reads as a block.

Changes:

1. Geometry: band spans exactly the measure. Rule at `band.minX`, 2pt.
   Code text starts at `band.minX + 2 + 14`. Bottom/top padding 10pt.
2. Chip floats in the band's top-right *inside the padding* — no dedicated
   line. Blocks without a language lose the chrome line entirely.
3. Mono line height computed from the mono font, not from body `lineHeight`:
   `snap(monoSize * 1.45)`. Code currently gets 24pt leading at 14.7pt type,
   which reads as a listing, not as code.
4. Tint: `codeBackground` moves to a deliberate 4–6% delta from `background`
   in both themes, plus a 0.5pt `codeRule` hairline on the remaining three
   edges in Increase Contrast only.
5. Copy button: SF Symbol `doc.on.doc`, fades in on hover over the block (not
   only over the chip), swaps to `checkmark` for 1.2s on click.
6. `diff` fences: full row-width tint for `+`/`-` lines, currently only the
   glyph colour changes (`DecorationEngine.swift:546`).
7. Collapsed chip (`.collapsedChip`): real disclosure triangle, hover
   background, whole-chip click target, and the line count in tabular figures.
8. Optional line numbers for blocks > 12 lines, off by default, in the band's
   left padding.

### 1.4 Tables — **Modify**

`TableLayout.make` is good work (auto numeric right-alignment, proportional
slack distribution). Three changes:

1. **Wrapping.** Cells are `.byTruncatingTail` at a fixed `rowHeight`. A table
   with a sentence in a cell loses the sentence. Allow up to 3 wrapped lines and
   let the row height grow; `rowHeight` becomes per-row rather than per-table.
2. **Full-bleed break-out.** When a table's natural width exceeds the measure,
   let it expand up to the window's content width (minus a 48pt margin) instead
   of scaling columns down to a 28pt minimum. Only if it still does not fit does
   it scroll horizontally within its own clip — with edge fade masks.
3. **Header treatment.** Uppercase, +0.06 em tracking, `textSecondary`, 0.85 ×
   body size. Header rule at 1pt `rule`; last-row rule removed (a table should
   not look closed at the bottom — that reads as a box).
4. Hover zebra already exists; move it from `codeBackground @ 0.6` to
   `text @ 0.04` so it does not read as a code block.

### 1.5 Blockquotes and callouts — **Modify**

- **Callout icon overlaps its text (real defect).** `CalloutFragment` draws the
  icon at `indent + ruleWidth + 5` at `bodySize` wide (≈16pt), so it spans
  8→24pt, while the text starts at `calloutInsetX = 16`. Fix: reserve the icon
  column in the paragraph indent — `calloutInsetX` becomes `rule + gap + icon +
  gap` ≈ 34pt for callouts, and stays 16pt for plain quotes.
- **Callout title line.** `> [!WARNING]` should render a semibold "Warning" in
  the callout colour on the first line, icon inline, body beneath. Today the
  token is hidden and the callout is indistinguishable from a quote except for
  rule colour.
- **Tint.** §11.3 says "never filled boxes". Recommend a 5% tint of the callout
  colour plus the rule — Xcode and Apple's own documentation do exactly this,
  and at 5% it is a whisper, not a box. *This is a deliberate deviation from the
  spec; flag it in `STATUS.md` if adopted.*
- **Quote text colour.** `BlockStyleFactory.color` returns `textSecondary` for
  the entire quote body. Long quotes become unreadably dim. Use full `text`;
  the rule and indent already say "quote".

### 1.6 Headings — **Modify**

- **Scale.** H1–H4 retain the existing hierarchy. H5 is a compact semibold
  label with positive tracking; H6 is smaller, medium, secondary, italic, and
  more widely tracked. Native and exported HTML use the same treatment.
- **Tracking.** Large serif headings need negative tracking. Add `.kern` per
  size band: −0.022 em above 28pt, −0.014 em 20–28pt, 0 below.
- **First-block suppression.** A document's first heading gets no
  `paragraphSpacingBefore`. Combined with the front-matter fix (§1.8) this
  removes the ~75pt void at the top of every document with front matter.
- **Section separation.** H2's 3-unit space-before (18pt) is less than the
  body's own paragraph rhythm at large measures. Go to 5 units before / 2 after
  for H2, 4/2 for H3. The rule: a heading must always be closer to its own body
  than to the section above it.

### 1.7 Inline elements — **Modify**

- **Inline code** uses `.backgroundColor` (`DecorationEngine.swift:433`), which
  paints a hard rectangle flush against the neighbouring words. Verified in the
  capture: `inline code` visibly butts into "and a". Replace with a drawn
  rounded background: collect code-span rects per line fragment in an
  `InlineDecorationPass` and fill them in `drawObject` with 3pt horizontal
  padding and a 4pt radius. Same pass handles `mark`/highlight later.
- **Wikilink labels (real defect).** `[[sample|with a label]]` renders as
  `sample|with a label`. `WikilinkScanner` parses the label correctly, but
  `Inlines.swift:279` sets the leading marker to just `[[`, so `target|` stays
  visible. Fix: when a label exists, the leading marker range extends through
  the `|`.
- **Links.** No underline today. Add a 1pt underline at 40% link colour on
  hover only, plus a 500ms hover popover with the resolved URL (§6.2 specifies
  the popover for Live; it is just as useful in Read).
- **Footnotes** render as literal `^1`. Make them true superscripts at 0.7 × in
  `accent`, with the existing hover popover.
- **Strikethrough** should dim the text to `textFaint`, not only draw a line.

### 1.8 Front matter — **Modify**

The current card is a tall slab with a left accent rule, ~60pt of internal
padding, and a background barely distinct from the page — and it is followed by
a huge gap before H1.

Make it a compact document header: `title` promoted to a document-title
treatment when the document has no H1; remaining fields as small key/value
chips on one wrapped row at 0.85 × body in `textSecondary`; a disclosure
triangle to reveal raw YAML with syntax highlighting. Total height ≈ 2 lines
instead of 5.

### 1.9 Images, math, rules — **Modify**

- **Images:** shadows are invisible on dark backgrounds. Use a 1pt inner
  hairline at 8% `text` in dark, keep the shadow in light. Cap height at 70% of
  viewport. Caption at 0.86 × body centred — already correct.
- **Inline math:** verify the SwiftMath attachment's baseline offset against the
  surrounding line; the point-size work is right but a wrong `attachmentBounds`
  descent makes it sit high.
- **Thematic break:** a 96%-width hairline reads as a UI divider inside prose.
  Replace with three centred 3pt dots at `textFaint`, 32pt apart, with the same
  generous vertical space.

### 1.10 The page — **Modify**

- **Background mismatch (real defect).** `MarkdownContainerView` sets
  `scrollView.backgroundColor` once at init from the *fallback* stylesheet
  (line 66) and only refreshes it in `viewDidChangeEffectiveAppearance` — never
  on a theme change. Confirmed at runtime: the scroll view drew `#1e1e1e` while
  the text column drew `#1c1a18`. Set it in the `styleSheet` didSet.
- **Top inset.** `verticalInset = 28` is the whole top margin of a document.
  Go to 56pt at the top, 40% of viewport height at the bottom so the last
  paragraph can scroll to the middle of the screen.
- **Dead space.** At 1020pt wide the 504pt measure leaves ~250pt of flat void
  per side. Two mitigations: raise the measure cap to 74ch at large window
  widths, and let §2.3's rail and §1.4's full-bleed tables use the margin so it
  reads as *margin* rather than *emptiness*.

---

## 2. Window chrome

### 2.0 Chrome technology — the recommendation you asked for

**AppKit, on standard containers.** Specifically: `NSSplitViewController` with
`NSSplitViewItem(sidebarWithViewController:)`, `NSToolbar` with
`.sidebarTrackingSeparator`, `NSTableView.Style.sourceList`.

Why not fully custom AppKit (the current approach): every macOS behaviour has to
be re-implemented, and the code already shows the cost — the sidebar is a raw
`NSLayoutConstraint.animator()` on a width constant, which means no drag to
resize, no remembered width, no correct full-screen behaviour, no toolbar
divider alignment, and no Reduce Motion honouring. `NSSplitViewController` gives
all of that for free and *correctly*, which is exactly what "Apple-native"
means.

Why not SwiftUI chrome (what the spec said): the text surface must stay AppKit,
so SwiftUI means two layout systems and two theming paths — the entire
`StyleSheet` is `NSColor`/`NSFont`-based and would need a parallel SwiftUI
representation. For a sidebar, a toolbar, and a few overlays that is a poor
trade.

**One exception:** build **Preferences** in SwiftUI (`Form` + `Settings` scene
hosted in an `NSHostingController`). It is a pure form, SwiftUI is
unambiguously better at forms, and the current hand-built 481-line window is the
weakest surface in the app. This is the one place the spec's SwiftUI call was
right.

### 2.1 Toolbar and title — **Replace**

Today: `titleVisibility = .hidden`, icon-only items, a stock
`NSSegmentedControl` built from `RenderMode.allCases`, a progress ring that is
present even at zero tasks, and a separate 26pt breadcrumb strip below — two
stacked bars and no window identity.

- `titleVisibility = .visible`, `toolbarStyle = .unified`. Title = document
  name; **subtitle** = containing folder. This is the native pattern and it
  makes ⌘-click on the title (path popup) work, which it does not today.
- Item order: `[toggleSidebar] [sidebarTrackingSeparator] … [mode] …
  [search] [tasks] [history] [overflow]`.
- Mode control: keep `NSSegmentedControl` (it is the native idiom, cf. Xcode's
  editor mode switch) but give it SF Symbols + labels, `⌘1/⌘2/⌘3` shown in the
  View menu, and correct `validateToolbarItem` so it greys out with no document.
- Progress ring: hidden when `total == 0`.
- Overflow `…` menu: zoom level, split view, export, tidy — the items that were
  toolbar-customisation-only and therefore invisible.
- **Auto-hide in Read mode (§11.4): do not implement as specified.** A toolbar
  that vanishes fights every native expectation. Instead add **Focus mode**
  (⌃⌘F) which hides toolbar, sidebar, and rail together and dims everything but
  the current section. That is the feature §11.4 was reaching for.

### 2.2 Breadcrumb — **Replace**

The current `BreadcrumbView` is a full-width strip pinned to the *window's* left
edge, so on a centred 504pt measure it floats alone in the top-left corner,
disconnected from the text, duplicating the title, and costing 26pt of vertical
space permanently.

Replace with a **floating section pill**: centred over the text column, appears
only while scrolling and for 1.5s after, `.hudWindow` material, 6pt radius,
`H2 › H3` truncated from the middle, click to jump to that ancestor. The
elision-menu logic in the current view is good and ports directly.

### 2.3 The navigation rail — **Replace** (the two reference images)

This is the feature from the original brief, and the reference images are the
spec.

**At rest** — right edge of the window, ~28pt track, no background:

- One tick per heading, positioned by document offset.
- Tick length encodes level: H1 26pt, H2 20pt, H3 14pt; below H3 not shown
  unless the document has no H1/H2.
- 1.5pt tall, 2px radius, `textFaint @ 0.35`.
- The section you are currently in: `text @ 0.9`, and 2pt tall.
- Change marks (§8.1) and search hits draw as coloured pips at the tick's
  leading edge — reusing `DensityGutterView.bands(...)` unchanged.
- Reading progress: the ticks above your position sit at 0.5 alpha, below at
  0.3. Subtle enough to be felt rather than read.

**On hover** — a floating overlay expands leftward from the rail:

- `.hudWindow`/`.popover` material, 14pt corner radius, shadow, ~360pt wide,
  max 70% viewport height, scrolls if longer.
- One row per heading: 14pt system font, 44pt row height, 16pt horizontal
  padding, indent 14pt per level, tail-truncated.
- Current section's row: filled rounded rect at `text @ 0.08`.
- Hovered row: `text @ 0.05`. Click jumps; the overlay dismisses.
- 120ms fade + 4pt slide in, 90ms out, 250ms dwell before it opens so it never
  ambushes you on a pointer crossing.
- Reduce Motion: no slide, no fade.
- Full keyboard equivalent: `⌘⇧O` opens it focused, arrows navigate, ⏎ jumps —
  which makes it the outline quick-open panel too, so `OutlineQuickOpenPanel`
  can retire.

**Kept from today:** `DensityGutterView.bands(for:changes:searchHits:)`, the
`DensityGutterDelegate` protocol, scrub-to-jump, accessibility role. **Replaced:**
the drawing, the 14pt band-soup track, and `DensityGutterPreviewWindow`'s
appearance.

### 2.4 Sidebar — **Superseded** (the leading sidebar was dropped, not built)

The plan here was a three-item `NSSplitViewController` whose leading item held
an `NSOutlineView` with **Nearby** (siblings) and **Outline** (headings)
sections, on the argument that the outline should keep living somewhere that
can drag-to-reorder sections (`Restructure.moveSection`) where the rail (§2.3)
cannot.

That argument did not survive the build. The rail already expands into the
document's outline on hover and the command palette already opens headings and
files through its Quick Open providers, so a third list of the same two things
— behind a toolbar button, two View items and a Navigate item that all ran the
same code — was the document's structure told three times. The window is
**document plus inspector**, with no leading item; `⌘⇧K` is the one way in.
`NavigationPanelView`, `OutlinePanelView` and `SiblingSidebarView` are deleted,
along with the `.outlinePanel` / `.toggleSidebar` / `.outlineQuickOpen`
commands and the "Keep the sibling sidebar open" preference. Sibling files are
reached from Quick Open and the Workspace inspector; section reordering stays a
source edit.

What did get built, of the two items that remain:

**Centre — document.**

**Trailing — inspector** (`NSSplitViewItem(inspectorWithViewController:)`,
macOS 14+). One inspector with a segmented picker for Tasks / Search results /
History, replacing three panels that currently fight over the same
`trailingPane` and evict each other silently.

**Transient overlays stay transient:** find bar, conflict bar, change summary,
tidy sheet. Those are correct as bars today; they get the styling pass in §3.

**Retire:** `leadingPane`/`trailingPane`, `leadingWidth`/`trailingWidth`,
`install(_:in:)`, and the `toggleSplitView` teardown path — which currently
calls `buildInterface()` a second time, building a **new** root view, a **new**
toolbar, and orphaning any open panel.

### 2.5 Find bar — **Modify**

Standard find-bar geometry: rounded search field with a leading magnifier, the
match count as a trailing accessory *inside* the field, ⌘G/⇧⌘G chevrons, and the
four option toggles folded into a single `⌥` menu button rather than four pill
buttons in a row.

### 2.6 Preferences — **Replace** (SwiftUI, per §2.0)

`Settings` scene, tabs: General, Appearance, Typography, Editor, Keys, Advanced.
Live theme preview pane showing a miniature rendered document that updates as
you change typography — this is where a user actually decides whether the app
looks good, and it currently requires closing the window and reopening a file.

### 2.7 Launch state — **Add**

No document open currently throws an `NSOpenPanel` in your face at launch. Add a
start window: recent documents as cards with a rendered thumbnail (the
`DownrightThumb` code already renders these), a drop target, and buttons for New
/ Open.

---

## 3. Motion and feedback

**Today:** three unrelated animation helpers (`PanelAnimation.run`,
`GutterChrome.animate`, raw `.animator()` on constraint constants) and three of
§11.4's promises unimplemented — no spring zoom, no content fade-up on open, no
toolbar auto-hide.

- **One motion system.** `Motion.swift` in `MarkdownRender` with three
  durations — `quick` 0.12, `standard` 0.20, `deliberate` 0.32 — and two curves
  (`easeOut`, `spring(damping: 0.86, response: 0.34)`). Every animation in both
  targets goes through it, and it is the single place Reduce Motion is honoured.
  `PanelAnimation` and `GutterChrome.animate` fold into it.
- **Structural zoom on spring physics (§5.2, unimplemented).** Today a zoom
  level change is an `ElisionPlan` swap and an instant relayout. Implement:
  snapshot the anchor heading's y, apply the plan, animate the scroll delta and
  the fragment heights on the spring curve, hold the anchor heading's screen
  position exactly. Budget < 300ms, no dropped frames — `drbench` gets a case.
- **Content fade-up on open (§11.4, unimplemented).** 120ms opacity 0→1 plus a
  6pt upward translate on the first layout pass. This is the single cheapest
  thing that makes launch feel fast.
- **Mode switching** crossfades over 120ms instead of snapping.
- **Hover states everywhere:** heading anchors, code copy, table rows, links,
  checkboxes, rail ticks, sidebar rows. Every one at `Motion.quick`.
- **Scroll.** `scroll(toOffset:)` animates `setBoundsOrigin` inside an
  animation group — it is not interruptible and does not decelerate naturally.
  Replace with a display-link-driven spring that a user scroll can interrupt.
- **Checkbox toggle** gets a 140ms scale-and-check.

---

## 4. Typography and theme

### 4.1 Scale and rhythm
Retuned exponents and tracking per §1.6. Keep `baselineGrid`, keep `snap`.

### 4.2 Optical margins — **Implement**
`TypographyConfig.opticalMargins` exists, is exposed in Preferences, and **is
never read by the renderer.** §11.1 calls it "the thing that makes text look
*set* rather than merely laid out". Implement as: hanging punctuation for
quote-opening glyphs and list bullets — a negative `firstLineHeadIndent` equal
to the measured glyph width for paragraphs starting with `"`, `'`, `“`, `‘`.

### 4.3 Measure
68–72ch is right for a 16pt serif. Add a window-width-responsive cap: below
900pt window width, drop to 66ch and reduce side margins so a narrow window is
not mostly void.

### 4.4 Themes — **Modify**
- Design two signature themes properly as a *pair*: **warm dark** (hero — it is
  what you use) and **paper light**. Verify every foreground/background pair at
  WCAG AA for body and AA-large for secondary text.
- Harmonise the code palette with the prose palette. In `paper-light.json` the
  code colours (`#a03e8c` keyword, `#2e7d5b` string) are considerably more
  saturated than the prose palette they sit inside; desaturate ~15% and pull
  hues toward the accent family.
- New palette slots the elements above need: `calloutTint` (or a documented
  alpha of the callout colour), `inlineCodeBackground` separate from
  `codeBackground`, `railTick`, `railTickCurrent`.
- Selection and caret: `insertionPointColor = accent` is loud for a reading app;
  use `text` in Read mode and `accent` in Live.
- The other four bundled themes (Nord, Solarized, High Contrast, System) get
  mechanically updated for the new slots, not redesigned.

---

## 5. Defect list

Everything verified in the source or in a runtime capture. Several are
one-liners and should land before any redesign work starts.

| # | Defect | Where |
|---|---|---|
| 1 | Read mode draws no bullets, ordinals, or checkboxes | Fixed in `ListOrnamentFragment.swift` |
| 2 | Hard-wrapped paragraphs render double-spaced | Fixed in `MarkdownContentStorage.swift` |
| 3 | Wrapped list lines align under the bullet, not the text | Fixed in `BlockStyle.swift` |
| 4 | Code text collides with the left rule | `CodeBlockFragment.swift:88` |
| 5 | Code band overhangs the measure on the right | `CodeBlockFragment.swift:123` |
| 6 | Language chip costs a blank 24pt line above every fence | `CodeBlockFragment.swift:54` |
| 7 | Callout icon overlaps its own text | `CalloutFragment.swift:44` |
| 8 | `scrollView.backgroundColor` not refreshed on theme change | `MarkdownContainerView.swift:66` |
| 9 | `[[a\|b]]` renders `a\|b` instead of `b` | `Inlines.swift:279` |
| 10 | `OutlinePanelView.currentHeadingIndex` never assigned | Moot: `OutlinePanelView` deleted with §2.4 |
| 11 | `OutlinePanelView.foldedIndices` never assigned | Moot: `OutlinePanelView` deleted with §2.4 |
| 12 | Progress ring visible with zero tasks | `DocumentWindowController+Actions.swift:226` |
| 13 | Panel width animation ignores Reduce Motion (raw `.animator()`) | `DocumentWindowController.swift:459` |
| 14 | `toggleSplitView` teardown rebuilds the root view and toolbar | `DocumentWindowController.swift:624` |
| 15 | `opticalMargins` preference has no effect | `RenderContracts.swift:245` |
| 16 | Table cells truncate rather than wrap | `TableFragment.swift:157` |
| 17 | Quote body dimmed to `textSecondary` throughout | `BlockStyle.swift:97` |
| 18 | Inline code background is an unpadded rectangle | `DecorationEngine.swift:433` |
| 19 | Breadcrumb aligns to the window, not the text column | `BreadcrumbView.swift:172` |
| 20 | H4 is the same size as body text | `StyleSheet.swift:196` |

---

## 6. Sequencing

Each phase is independently shippable and leaves the app better than it found
it. Run `Scripts/check.sh` and `swift run -c release drbench` at every phase
boundary — the performance budget is the product promise.

**Phase A — Defects (≈3 days).** Items 3–9, 12, 13, 17, 18 from §5. No design
decisions, no architecture. The app looks meaningfully better at the end of the
week.

**Phase B — List ornaments and typography (≈1 week).** §1.1, §1.6, §4.1, §4.2.
This is the largest single visual jump for the effort. New golden-image tests in
`MarkdownRenderTests`.

**Phase C — Element treatments (≈1.5 weeks).** §1.3 code, §1.4 tables, §1.5
callouts, §1.7 inline, §1.8 front matter, §1.9 images/rules, §1.10 page.

**Phase D — Chrome (≈2 weeks).** §2.1 toolbar, §2.4 `NSSplitViewController`
inspector (the leading sidebar was dropped instead — see §2.4), §2.2 floating
breadcrumb, §2.5 find bar. Item 14 dies here with the old pane code.

**Phase E — The rail (≈1 week).** §2.3, both states, plus keyboard equivalent
and retiring `OutlineQuickOpenPanel`.

**Phase F — Motion (≈1 week).** §3 in full, including the two unimplemented
§11.4 promises and spring zoom.

**Phase G — Themes, Preferences, launch state (≈1 week).** §4.4, §2.6, §2.7.

**Phase H — Paragraph reflow.** Implemented in `MarkdownContentStorage` with a
source-preserving fallback and an Editor preference for disabling visual
reflow.

Roughly 8–10 weeks of focused work, with the app visibly improving at every
phase boundary rather than at the end.

---

## 7. Open decisions

1. **Callout tint** — accept the 5% tint (Xcode-like, recommended) or hold the
   spec's "never filled boxes"?
2. **Read-mode checkbox interaction** — clicking a checkbox in Read mode writes
   the file immediately (as Live does today). Keep that, or make Read strictly
   read-only?
3. **Full-bleed tables and images** — allowed to break the measure and use the
   margin, or strictly contained?
4. **Focus mode** replacing §11.4's auto-hiding toolbar — agreed?
5. ~~Inspector requires macOS 14~~ — confirmed available: `Package.swift:46`
   already targets `.macOS(.v14)`, so `NSSplitViewItem(inspectorWithViewController:)`
   is usable. No decision needed.
