# Markdown App — Product & Technical Spec

**v2** · Native macOS markdown reader and editor, built for a world where most markdown is written by machines.

---

## 1. Thesis

Every markdown app on macOS is built on an assumption that stopped being true: that a `.md` file is a static document a human wrote and a human will read.

In an agent workflow it is neither. It's a file that gets rewritten under you while you're reading it, that arrives 3,000 words long when you needed 200, and that makes claims about your codebase you can't verify without leaving the document.

The apps that exist split cleanly into two failures. **Viewers** (Readdown, QuickMD, MacMD Viewer, Prism MD, MDHero) render beautifully and can't write. **Editors** (Typora, Obsidian, iA Writer, Bear) can write but treat reading as an afterthought — a separate render pass that loses your scroll position and your place.

This app is one surface that does both, and it is the only one that models the file as *live*.

**The one-sentence pitch:** a native Mac markdown app that opens instantly, renders anything, edits in place without ever touching your bytes, and shows you what the agent changed while you were reading.

**Release model:** one finished 1.0. No public beta, no staged feature rollout. The phases in §14 are internal build order, not release checkpoints.

---

## 2. Non-goals

Being explicit here is what keeps the project from becoming Obsidian. This app will **not**:

- Be a vault. No graph view, no backlinks, no tag index, no `[[wikilink]]` database. (Rendering a wikilink as a link is fine; indexing them is not.)
- Sync anything. Files live on your disk. iCloud/Dropbox/git are somebody else's job.
- Support collaboration or multiplayer editing.
- Ship a plugin system in 1.0.
- Build a rich-text document model. Markdown source is the only model.
- Execute code blocks, run shells, or evaluate notebooks.
- Target Windows, Linux, iOS, or the Mac App Store.
- **Contain an AI chat panel.** Deliberate and load-bearing. The app is where you read and control what agents produce. The moment it becomes another place to talk to a model, it competes with Cursor and Claude Code on their terms and loses. Its value is being the *reviewing* surface, not another generating one.

---

## 3. Load-bearing architectural decisions

These five determine everything downstream. Get them wrong and the app is a rewrite.

### 3.1 Raw text is the only source of truth

The `NSTextStorage` holds the exact bytes of the file, always. Rendering is a **decoration layer** applied on top — attributes and layout, never character mutation.

This guarantees:

- Byte-identical round-trips. An agent-written file that passes through this app is unchanged, character for character, including its odd spacing and its trailing newline.
- `⌘C` always yields markdown. Rich text is a separate, explicit command.
- Read mode and Live mode are *the same view with a different decoration policy*, not two renderers that can disagree.
- Undo is plain text undo. No transformation to invert.

Every WYSIWYG markdown editor that builds a document model and re-serializes on save will eventually normalize something and corrupt somebody's file. This one structurally cannot.

### 3.2 One text surface, three modes

Not a viewer with an edit button. Not an editor with a preview pane. One `NSTextView` subclass on TextKit 2, with three decoration policies:

| Mode | Insertion caret | Markers | Purpose |
|---|---|---|---|
| **Read** | none | fully hidden | Reading, navigating, restructuring |
| **Live** | yes | hidden except at caret | Writing and editing |
| **Source** | yes | all visible, highlighted | Debugging the markdown itself |

"No insertion caret" in Read mode means exactly what it means in Preview or Books: there's no blinking I-beam waiting for you to type. **Every pointer interaction remains fully live** — clicking, selecting, dragging, folding, following links, ticking checkboxes, scrubbing the gutter. See §7.

Switching modes is instant and preserves scroll position and selection, because it's the same layout manager over the same storage. This is the thing Obsidian gets wrong.

### 3.3 No WebView. Anywhere.

Math, diagrams, code highlighting, and tables all render through native Core Text / Core Graphics. Three reasons, in order:

1. **The Quick Look extension has a hard ~120MB ceiling** and is killed outright if it's exceeded. A `WKWebView` with KaTeX and Mermaid.js loaded will not reliably fit. Native rendering is the only way the Quick Look experience matches the app's.
2. Launch time. Target is first rendered pixel under 250ms.
3. The render core becomes a reusable Swift package — app, preview extension, and thumbnail generator share exactly one code path, so they can never drift.

Every dependency in §13 is chosen to hold this line.

### 3.4 Unsandboxed, distributed outside the App Store

Signed and notarized, updated via Sparkle, source on GitHub. Not a limitation — an unlock. Several core features depend on it:

- Watching arbitrary file paths with FSEvents
- Resolving `src/auth/session.ts:42` and opening it in your editor
- A `md` CLI that opens files from the terminal
- Reading sibling files in a directory without a file-picker ritual per folder

Sandboxed competitors *cannot* build the features in §8. That's the moat.

### 3.5 Full reparse, incremental restyle

`swift-markdown` (cmark-gfm underneath) has no incremental parsing. It doesn't need one — cmark parses megabytes per second. The expensive part is applying attributes and building layout fragments.

So: **reparse the whole document on every edit, diff the resulting AST against the previous one by subtree hash, and re-decorate only the changed blocks.** Simple, correct, fast enough. Verify in P0 (§14) before building on it.

---

## 4. Document pipeline

```
file bytes
   ↓  read + encoding detect (UTF-8, UTF-16, Latin-1)
NSTextStorage  ← the only mutable state
   ↓  swift-markdown parse (full)
Markdown AST + source ranges
   ↓  extension pass (§4.1)
Extended AST
   ↓  block subtree-hash diff vs. previous AST
Dirty block set
   ↓  decorate
   ├─ Attribute decorations → fonts, colors, hidden ranges
   └─ Fragment decorations  → math, mermaid, tables, images, rules
   ↓
TextKit 2 layout → NSTextView
```

### 4.1 The extension pass

`swift-markdown` covers CommonMark + GFM. It does not cover what agent output is full of. A post-parse pass over the AST adds:

- **Math** — inline `$…$`, block `$$…$$`, `\(…\)`, `\[…\]`. Requires care: `$` is common in shell snippets, so only match outside code and on plausible delimiter boundaries.
- **YAML front matter** — parsed and lifted out of the body.
- **Callouts** — `> [!NOTE]`, `> [!WARNING]`, etc. Agents emit these constantly.
- **Wikilinks** — `[[Name]]` rendered as a link, resolved against the sibling directory only.
- **Path tokens** — `src/foo.ts`, `src/foo.ts:42`, `` `path/to/file` `` (§8.4).
- **Fenced language flags** — mermaid and `diff` marked for special fragment rendering.

Each extension is a small, independently testable AST transform, kept in one module so contributors can add more.

---

## 5. Read mode

The mode the app opens in, and where most of the value lives.

**It is a mouse-first reading surface.** Everything is clickable, hoverable, draggable, selectable. The keyboard layer in §7.2 is an addition for people who want it, not a substitute for pointer interaction.

### 5.1 What it renders

- All markdown markers fully hidden.
- **Sticky heading breadcrumb** — `H1 › H2 › H3` pinned at the top of the viewport, updating as you scroll. On a long agent document this is the difference between knowing where you are and not.
- Code blocks over 20 lines auto-collapse to a one-line chip: language, line count, click to expand. State persists per document.
- Images, math, mermaid, and tables render as real objects.
- Front matter renders as a compact metadata card, not a code block.
- Footnotes and reference links resolve in a hover popover rather than jumping to the bottom of the document.
- Typography gets its full measure (§12) — this is the mode that has to look genuinely beautiful.
- Reading progress shown in the density gutter (§8.6).

### 5.2 Structural zoom

The headline navigation feature, and the answer to "the agent wrote 3,000 words and I need the shape of it."

The document changes *resolution in place* — not a sidebar you glance at:

| Level | Shows |
|---|---|
| 1 | H1 only |
| 2 | H1 + H2 |
| 3 | All headings |
| 4 | All headings + first sentence of each section + every code block, table, and task list |
| 5 | Everything (default) |

Level 4 is the sweet spot for agent output: every claim's headline plus all the concrete artifacts, and none of the connective padding.

Controls: `1`–`5`, trackpad pinch, a segmented control in the toolbar, and a slider in the outline panel header. Headings hold their vertical position through the transition so you never lose your place. Transitions animate on spring physics (§12).

Sentence segmentation uses `NLTokenizer` from Apple's NaturalLanguage framework — native, no dependency, handles abbreviations correctly.

Zoom level persists per file.

---

## 6. Live mode — the hard part

Roughly 55% of total engineering effort and the highest-risk piece of the project.

The goal: rendered by default, raw where the caret is, **with no visual jump when the caret arrives.**

The known failure mode is well documented in Obsidian: when the editor toggles between hiding and showing markers, lines shift and the cursor jumps, which makes continuous typing miserable. The Obsidian community also learned the hard way that hiding markers via `display: none` breaks cursor placement outright. Solving this properly is the app's central craft problem.

### 6.1 The three-part solution

**a) Block markers live in the gutter.** `#`, `##`, `>`, `-`, `1.`, `- [ ]` are never inline. They render permanently in a narrow left gutter, dimmed when inactive, full-strength when the caret is in that block. Heading text never moves horizontally, and line height never changes, because the block's style is stable whether or not it's active. **This eliminates all vertical jump** — the part that actually hurts.

**b) Inline markers reveal per-span, not per-line.** When the caret enters `**bold**`, only that span's `**` pairs appear. Every other emphasis, code span, and link on the line stays collapsed. The shift is a few characters near the caret instead of a full line reflow.

**c) Caret-anchored reveal.** The character under the caret is pinned to its current screen x-position and markers expand *around* it. The caret does not move on screen when a reveal happens. This is what makes the whole thing feel calm, and it's what nobody has built.

Marker hiding uses a custom `NSTextLayoutFragment` subclass that omits marker glyph runs from layout entirely, with a maintained source↔display index map — not zero-width fonts or transparent color, both of which produce subtly broken caret arithmetic.

### 6.2 Per-element behavior

| Element | Inactive | Caret inside |
|---|---|---|
| Heading | gutter `##`, styled text | gutter brightens |
| Bold / italic / strike | markers hidden | that span's markers only |
| Inline code | markers hidden, code style | backticks appear |
| Link | display text only | **floating popover** below the line with the URL, editable — never expand a 90-character URL inline |
| Image | rendered | popover with path + alt |
| Inline math | rendered glyph | swaps to `$…$` source |
| Block math | rendered, centered | source, in place |
| Fenced code | source, tree-sitter highlighted, language chip + copy button | identical (already source) |
| Mermaid | rendered diagram | source, with the diagram moving to a live side-preview |
| Table | rendered grid | table edit mode (§6.3) |
| Task list | checkbox glyph, clickable | gutter shows `- [ ]` |
| Callout | styled panel | gutter shows `> [!NOTE]` |
| Front matter | metadata card | raw YAML, highlighted |

### 6.3 Table editing

Tables are where Typora earned its reputation and where everyone else gave up.

Live mode renders a real grid. Clicking a cell enters table edit: that row becomes aligned pipe syntax, `⇥`/`⇧⇥` move between cells, `⌘⏎` adds a row, and a hover control on the header row sets column alignment. On exit, the whole table's pipes are re-aligned in the source.

### 6.4 Text editing behavior

- **Multiple cursors** — `⌥`-drag for a column selection, `⌘`-click to add a caret, `⌘D` to add the next occurrence. Expected by anyone arriving from VS Code; not optional in 2026.
- List continuation on `⏎`; outdent-and-exit on an empty item.
- `⇥`/`⇧⇥` indent and outdent list items, renumbering ordered lists automatically.
- **Smart paste** — a URL over a selection makes a link; HTML on the clipboard converts to markdown; spreadsheet data becomes a markdown table; a dragged image file is copied next to the document and linked relatively.
- `⌘B` / `⌘I` / `⌘K` wrap the selection.
- Typographic substitution (`--` → en dash, smart quotes) defaults **off** — agents and code hate smart quotes — with a toggle.
- Trailing whitespace and final-newline behavior preserved exactly as found.

---

## 7. Input model

### 7.1 Pointer — the primary interaction path

Most sessions are mouse-driven. Every capability below is reachable without touching the keyboard.

**Structure and navigation**

- Hover a heading → an anchor glyph appears in the gutter. Click it to copy a link to that section; `⌥`-click to fold the section.
- Click any gutter marker to fold or unfold that block. Fold state persists per document.
- **Drag headings in the outline panel to reorder entire sections of the document.** Agent output is frequently in a poor order; this turns restructuring into a drag instead of a cut-and-paste. Multi-level drag moves the heading and everything beneath it.
- Click the density gutter (§8.6) to jump; drag to scrub with a live preview tooltip.
- **Link peek** — hovering a `.md` link, a wikilink, or a footnote shows a popover with the rendered target.
- `⌘`-click a `.md` link to open it in a new window.
- Two-finger swipe left/right navigates back and forward through jump history, including outline jumps and followed links.

**Manipulation**

- Click any checkbox to toggle it; the file is written immediately.
- Click a code block's language chip to change the language.
- Hover a code block → copy button, line count, and "open in editor" for fenced blocks that came from a file.
- Click an image → lightbox with zoom and pan; alt text renders as a caption.
- Drag a rendered selection out to another app; markdown is the default flavor, rich text is offered as an alternate.

**Zoom**

- Pinch → structural zoom level.
- `⌘` + scroll → text size, persisted app-wide rather than per document.

**Context menus** — real ones, not a generic stub:

| Right-click on | Offers |
|---|---|
| Heading | copy section as markdown / as rich text, promote, demote, fold siblings, move section |
| Code block | copy, save as file, change language, open in editor |
| Path token | open in editor, reveal in Finder, copy path |
| Image | open in lightbox, save a copy, reveal, copy |
| Link | open, copy target, edit |
| Table | insert/delete row or column, set alignment, realign source |
| Selection | copy as markdown / rich text / plain, convert to list, quote, or task list |

### 7.2 Keyboard

A complete parallel path, not the only path. Every binding is remappable through a preferences editor backed by one declarative table.

**Read mode single keys** (no caret means the letter keys are free). `space`, arrows, `n`/`p`, `[`/`]`, and `1`–`5` are on by default; the vim-style `j`/`k`/`g`/`G` layer is off by default behind a toggle.

| Key | Action |
|---|---|
| `space` / `⇧space` | page down / up |
| `↓` `↑` (or `j` `k`) | scroll |
| `n` / `p` | next / previous heading |
| `[` / `]` | previous / next change (§8.1) |
| `1`–`5` | structural zoom level |
| `g` / `G` | top / bottom |
| `o` | outline quick-open |
| `t` | task panel |
| `f` | find |
| `e` | switch to Live mode |
| `⇥` then `⏎` | cycle links and path tokens, then open |

**Global** (all modes)

| Shortcut | Action |
|---|---|
| `⌘E` | toggle Read ⇄ Live |
| `⌘⇧E` | Source mode |
| `⌘0` | toggle sibling sidebar |
| `⌘⇧O` | outline quick-open (fuzzy heading jump) |
| `⌘T` | task panel |
| `⌘⇧V` | version timeline |
| `⌥↓` / `⌥↑` | next / previous change |
| `⌘F` / `⌘G` | find / find next |
| `⌘⇧F` | search across sibling files |
| `⌘⌥F` | find & replace |
| `⌘⌥←` / `⌘⌥→` | promote / demote heading |
| `⌥⌘↑` / `⌥⌘↓` | move block up / down |
| `⌘\` | split view |
| `⌘C` | copy as markdown |
| `⌘⇧C` | copy as rich text |
| `⌘⌥C` | copy current section |
| `⌘P` | print / export PDF |
| `⌘⇧P` | export self-contained HTML |

Find searches the source and highlights in the rendered output, correctly handling matches that span hidden markers, and expanding a collapsed section when a match lands inside one.

---

## 8. The AI layer

The differentiators. Everything here exists because the file is written by a machine.

### 8.1 Rendered diff — "what changed while I was reading"

The single most valuable feature in the app.

The file is watched. When an external process rewrites it:

- **Buffer clean:** the diff is computed, applied to storage, and the rendered view updates *in place*. Scroll position is preserved by anchoring to the nearest unchanged heading plus an offset, never by byte offset. Changed blocks get a colored bar in the margin. Changed words inside a modified paragraph are highlighted **in the rendered prose** — not as `+`/`-` source lines. `[` and `]` (or `⌥↑`/`⌥↓`) jump between changes. Marks fade after ten minutes or on visit.
- **Buffer dirty:** never clobber. A non-modal bar appears — *"Changed on disk — 3 blocks"* — with **Review**, **Keep mine**, **Take theirs**. Review opens a rendered three-way comparison.

This is a real, unsolved, actively painful problem. The current state of the art across editors is that the standard advice when an agent writes a file you have open is to close and reopen it, because each editor keeps its own buffer and they don't reliably refresh.

**Implementation gotcha, do not skip:** most tools and every agent CLI write atomically — temp file, then `rename()`. A vnode watch on the original inode will silently stop firing. **Watch the parent directory with FSEvents and match on filename**, re-establishing any inode watch after each event.

### 8.2 Unread-since-last-read

On close, snapshot the file's content hash and your scroll position. On reopen, if the bytes differ, §8.1 change marks are applied automatically and the app offers to jump to the first one.

Reading position persists per file regardless. Long documents behave like books.

### 8.3 Local time-travel

Every external write is snapshotted to a content-addressed store in `~/Library/Application Support/<app>/history/`, deduplicated by hash, capped by age and total size (defaults: 30 days, 500MB).

`⌘⇧V` opens a timeline scrubber: drag through every version of this file from the past month, rendered, with changes highlighted between steps.

Agents don't commit. Git doesn't help you here. Nothing else has this.

### 8.4 Live path resolution

Agent docs are dense with file references. The extension pass finds path-like tokens and resolves them against the document's directory, then the nearest git root.

- **Exists** → subtly styled, clickable, opens at the right line in your configured editor (VS Code, Cursor, Zed, Xcode, or `$EDITOR`)
- **Doesn't exist** → dotted red underline

That second case is the point. You can look at a completion summary and immediately see which files the agent claims to have touched that aren't there. It's a trust instrument, not a convenience.

### 8.5 Task panel

Agent plans are `- [ ]` all the way down.

`⌘T` opens a panel listing every checkbox in the document grouped by nearest heading, with a filter for incomplete. Toggling writes back to the file immediately. A progress ring appears in the toolbar whenever a document has tasks.

This turns a plan document from something you read into something you work through.

### 8.6 Density gutter

Replaces the scrollbar with a thin track showing the document's structure as colored bands: headings (indented by level), code blocks, tables, math, task lists, search matches, and — most importantly — changed regions.

The whole shape of a 3,000-word document at a glance. Click to jump, hover for the heading text, drag to scrub with a preview tooltip.

The mature version of the ChatGPT-style side rail: same instinct, far more signal.

### 8.7 Sibling sidebar

Agents don't write one file, they write six into the same folder.

On opening a document, the app scans its containing directory — plus one level into `docs/`, `plans/`, `.claude/` and similar — for other `.md` files, and offers them sorted by modification time with dots for changed-since-you-last-looked.

Hidden by default. `⌘0` toggles, `⌥⌘←`/`⌥⌘→` cycle. **No indexing, no vault, no "open folder" ceremony.** The app still opens one file at a time; the context is just there when you want it.

---

## 9. Commands & workflow

### 9.1 Document repair

**Tidy Document** — one command that normalizes skipped heading levels (agents jump H2 → H4 constantly), aligns table pipes, collapses runs of blank lines, adds missing language hints to code fences, renumbers ordered lists, and normalizes list markers. Shows a rendered diff before applying, with per-change accept/reject.

High value for very little code. Run it on any agent document and it stops looking machine-made.

### 9.2 Restructuring

- Promote / demote headings, moving the entire subtree.
- Move a block or section up and down.
- Convert a selection between paragraph, bullet list, numbered list, task list, and blockquote.
- Sort list items alphabetically or by checkbox state.
- Insert a table of contents that auto-updates on save.
- Outline drag-reorder (§7.1) as the pointer equivalent of all of the above.

### 9.3 Windows and views

- **Split view on a single document** (`⌘\`) — two panes over the same buffer, scroll-locked or independent. Read the spec at the top while editing the bottom. Enormous for long documents and nothing native does it well.
- **Compare any two files** as a rendered diff, not just two versions of the same file.
- **Pin window** — always-on-top, so a plan stays visible while you work in another app.
- Focus mode (dim everything except the current paragraph) and typewriter scrolling.
- Full session restore: every window reopens with its mode, zoom level, scroll position, fold state, and sidebar state.
- Recent files with rendered thumbnails.

### 9.4 Search

- Find-as-you-type with a live match count, matches ticked into the density gutter, and automatic expansion of collapsed sections containing hits.
- Find and replace with regex and selection-scoped modes.
- `⌘⇧F` searches all sibling files, showing rendered context per hit.

### 9.5 Export and copy

- `⌘C` markdown, `⌘⇧C` rich text, `⌘⌥C` current section.
- Copy as plain text with all markup stripped.
- Print and PDF with a stylesheet designed for paper, not a screenshot of the screen theme.
- Self-contained HTML export with styles inlined and images embedded as data URIs.
- Export selection as an image (for pasting a rendered table or diagram into a message).

### 9.6 Reading metadata

Word count, character count, and estimated read time, shown on hover over the density gutter rather than as permanent chrome. **Per-section read time appears in the outline panel** — it tells you where the bulk of a document actually is, which is not usually where you'd guess.

---

## 10. Quick Look

A separate app extension target importing the same `MarkdownRender` package. Not a reduced-fidelity fallback — the same renderer, so it can never drift from the app.

**Registered UTIs:** `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx`, `.mdc`, `.qmd`, `.rmd`, and `.txt` (opt-in).

**Design**

- Read mode rendering with full typography.
- Density gutter shown if the panel is wide enough.
- Arrow keys scroll, `n`/`p` jump headings, text is selectable and copyable. Most Quick Look previews are dead surfaces; this one isn't.

**Memory discipline (non-negotiable)**

- Poll `malloc_zone_statistics` and fall back to plain text above 60MB — well under the ~120MB kill threshold.
- Files over 2MB render the first *N* blocks with an "Open in app" affordance.
- Math, mermaid, and images render lazily, only for fragments in the viewport.

**Also ship a `QLThumbnailProvider`** so `.md` files get real Finder icons showing the document's first heading. Nobody does this, and on a folder full of agent output it's transformative.

**Document prominently in the README:** Quick Look extensions only register after the host app has been launched once, and users may need to enable the extension under System Settings → General → Login Items & Extensions → Quick Look. This is the number one support question for every app in the category.

---

## 11. Visual design

"Beautiful" is a requirement, so it gets specified rather than left to taste.

### 11.1 Typography

- Two body presets: **Reading** (New York — Apple's serif, ships with macOS, excellent at long-form) and **Working** (SF Pro Text). Both system, both free.
- Mono: SF Mono, with a picker for any installed monospace face and a ligatures toggle.
- **Measure capped at 68–72 characters.** Full-width text is the single most common thing markdown viewers get wrong; fixing it alone makes the app feel better than most competitors.
- **Modular type scale** — selectable ratio (1.2 / 1.25 / 1.333) driving all heading sizes, rather than six arbitrary numbers.
- Fixed baseline grid, so structural zoom transitions animate cleanly instead of jittering.
- **Hanging punctuation and optical margin alignment** on quotes and list bullets. Small, and it's the thing that makes text look *set* rather than merely laid out.

### 11.2 Color and theming

- **Real theme files** — JSON, not CSS. Five to six shipped, user-importable, hot-reloading while you edit one.
- Semantic palette derived from `NSColor` system colors, so it adapts to light/dark, the user's accent color, and Increase Contrast automatically.
- Code themes are tree-sitter capture → style maps, with **VS Code / Shiki theme import**. `beautiful-mermaid-swift` already supports Shiki conversion, so code blocks and diagrams share one palette. That consistency is rare and immediately noticeable.
- **Dark mode designed, not inverted.** Warm-tinted background, body text at roughly 85% white rather than pure — pure white on black is genuinely fatiguing across a long document. A matching warm "paper" light theme.

### 11.3 Element treatments

- **Code blocks** — subtle tint plus a left rule, never heavy bordered cards. Language chip top-right. ```diff fences get real diff coloring.
- **Tables** — no gridlines. Horizontal rules only, zebra on hover, numeric columns auto right-aligned.
- **Quotes and callouts** — colored left rule plus icon, never filled boxes.
- **Images** — rounded corners, restrained shadow, alt text as a caption, click for lightbox.
- **Math sized optically against body text.** Most apps render KaTeX visibly too large next to their body font. Getting this right is instantly noticeable and almost nobody does it.
- **Mermaid** themed from the active code theme.
- **Horizontal rules** as a hairline with generous space, not a thick divider.

### 11.4 Motion and chrome

- Structural zoom on spring physics, not linear fades.
- Content fades up as fragments lay out on open — makes fast feel fast.
- Unified toolbar, auto-hiding in Read mode until the pointer moves.
- No permanent sidebars, panels, or status bar. Everything summonable, nothing resident.
- Full respect for Reduce Motion, Increase Contrast, and Reduce Transparency.

---

## 12. Stack

| Concern | Choice | Notes |
|---|---|---|
| Text engine | `NSTextView` on **TextKit 2**, AppKit | Own this layer directly (§15) |
| UI chrome | SwiftUI, hosted | Not for the text surface |
| Parser | **swift-markdown** (Apple) | cmark-gfm, real AST with source ranges |
| Code highlighting | **SwiftTreeSitter** + **Neon** (ChimeHQ) | Built for exactly this: a fast low-latency first pass, then tree-sitter for quality |
| Math | **SwiftMath** or **iosMath** | Pure Core Text, substantially faster than a WebView, and the only option that fits the Quick Look budget |
| Diagrams | **beautiful-mermaid-swift** (lukilabs) | Native, ELK layout, flowchart/state/sequence/class/ER/XY, Shiki theme bridge. `swift-mermaid` is the lighter alternative |
| Sentence segmentation | **NaturalLanguage** (`NLTokenizer`) | System framework |
| File watching | **FSEvents** | Directory-level, see §8.1 |
| Updates | **Sparkle** | Standard for notarized direct downloads |

**Two projects to read before writing a line:**

- `nodes-app/swift-markdown-engine` — a native AppKit markdown editor on TextKit 2 with live styling, LaTeX, and code blocks. Closest existing thing to this architecture.
- `krzyzanowskim/STTextView` — a solid TextKit 2 text view to use or learn from.

### Package layout

```
MarkdownCore/       parse + extension passes + AST diff   (no UI)
MarkdownRender/     decoration engine, layout fragments   (AppKit)
MarkdownApp/        windows, modes, sidebar, AI layer
MarkdownQL/         Quick Look preview extension
MarkdownThumb/      Quick Look thumbnail extension
mdcli/              terminal launcher
```

`MarkdownCore` and `MarkdownRender` ship as standalone SPM packages. That's the piece of this project other people will actually want, and releasing it separately is how the project attracts contributors rather than just stars.

### Performance budget

| Metric | Target |
|---|---|
| Cold launch → first rendered pixel (100KB file) | < 250ms |
| Keystroke → updated render (5k-line doc) | < 8ms p95 |
| Scroll | 120fps on ProMotion |
| Structural zoom transition | < 300ms, no dropped frames |
| Quick Look render | < 400ms, < 60MB peak |
| Memory, 1MB document | < 150MB |

Wire these into a benchmark suite in P0 and run them in CI. They are the product promise.

---

## 13. Build plan

Internal phases toward a single finished 1.0. Nothing here is a public release; the sequencing exists to de-risk the hard parts and to get you dogfooding the app early enough that the later phases are informed by real use.

| Phase | Scope | Est. |
|---|---|---|
| **P0** | Spike: TextKit 2 view + swift-markdown + attribute-only styling. Prove the no-mutation decoration model. Benchmark keystroke→render on a 5k-line file. | 1 wk |
| **P1** | Render core + Read mode: full GFM, extension pass, tree-sitter code, native math, images, front matter card, breadcrumb, folding, find. | 4 wks |
| **P2** | Quick Look preview + thumbnail extensions with the memory discipline in §10. | 2 wks |
| **P3** | Live mode: caret-anchored reveal, gutter markers, per-span inline reveal, link popovers, table editing, multiple cursors, smart paste. | 5 wks |
| **P4** | AI layer: file watching, rendered diff, change marks and navigation, snapshot history, unread-since-last-read, dirty-buffer conflict handling. | 3 wks |
| **P5** | Navigation & structure: structural zoom, density gutter, outline panel with drag-reorder, task panel, path resolution, sibling sidebar. | 3 wks |
| **P6** | Commands & workflow: Tidy Document, restructuring commands, split view, file compare, cross-file search, pin, focus mode, session restore, export. | 3 wks |
| **P7** | Visual system: theme file format, shipped themes, Shiki import, dark mode design pass, motion, element treatments, print stylesheet. | 3 wks |
| **P8** | Release engineering: preferences, keybinding editor, `md` CLI, accessibility audit, notarization, Sparkle, docs, site, open-source packaging. | 3 wks |

**Roughly 27 weeks — about six months of committed part-time work** to a complete 1.0.

**P0's kill criterion:** if p95 keystroke latency won't come under 8ms with block-diffed restyling, rethink the architecture before building six months on top of it.

**On the ordering:** P1 before P3 isn't about shipping early, it's that Live mode is built on the same decoration engine Read mode needs, and you want a month of using the app yourself before you design the hardest interaction in it. P7 late because theming a system that's still changing shape is wasted work.

---

## 14. Risks and known traps

**Live mode is the project's center of gravity.** Building it in P3 rather than P1 means the decoration engine is proven and you're using the app daily before you attempt the part with genuine research risk.

**TextKit 2 rendering attributes are unreliable under SwiftUI.** An Apple DTS thread confirms that adding rendering attributes plus invalidating layout does not reliably refresh, and that this reproduces even without SwiftUI. Own the AppKit layer directly; apply attributes to the text storage rather than relying on the rendering-attributes mechanism for anything dynamic.

**Atomic writes break naive file watching.** Watch the directory, not the inode. Costs an afternoon if discovered late, thirty seconds if planned for.

**`swift-markdown` doesn't cover what agents write.** Math, callouts, wikilinks, and front matter all need the extension pass. Budget it into P1, not as an afterthought.

**Structural zoom × hidden markers × find × folding is a four-way interaction.** Searching for text inside a collapsed section at zoom level 2 needs defined behavior. Specify these interactions before implementing or you'll accumulate special cases.

**Multiple cursors × per-span marker reveal is a genuine complexity multiplier.** Decide early: reveal markers at every caret, or only at the primary. (Recommendation: primary only, with the others rendering as thin markers on hidden syntax.)

**Outline drag-reorder is more expensive than it looks.** Moving a heading means moving its subtree, fixing up sibling heading levels, and preserving the exact blank-line structure around it. Real work, high payoff.

**The market is crowded and moving.** A dozen native Mac markdown viewers shipped in the last eighteen months, several explicitly aimed at AI output. Nothing in §5.2, §8.1, §8.3, or §8.4 exists in any of them today — but a six-month build with no public release is a six-month window for someone else. Worth knowing you're taking that bet deliberately.

**Scope creep toward vault features.** Every markdown app drifts into becoming Obsidian. §2 is the defense; re-read it before adding anything.

---

## 15. Open questions

1. **Name.** Settle early — it shapes the icon, the bundle ID, and the CLI verb.
2. **License.** MIT attracts contributors; something copyleft prevents someone shipping a paid App Store fork of your renderer. Since `MarkdownRender` is the valuable artifact, this deserves a real decision.
3. **`.mdx` and `.qmd`** — render the markdown and gray out the JSX/executable parts, or refuse to open them?
4. **Very large files** — at what size does Read mode switch to windowed rendering? (Suggest 5MB.)
5. **Editor integration direction** — is opening `file.ts:42` in VS Code enough, or does the reverse matter (a command that opens the current document's section in your editor)?
6. **Version timeline placement** — separate window or in-window overlay?
7. **Theme format** — hand-rolled JSON schema, or adopt an existing one so people can reuse work?

---

*Built on research current as of August 2026.*
