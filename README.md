# Downright

A native macOS markdown reader and editor, built for a world where most
markdown is written by machines.

Every markdown app on macOS is built on an assumption that stopped being true:
that a `.md` file is a static document a human wrote and a human will read. In
an agent workflow it is neither. It's a file that gets rewritten under you while
you're reading it, that arrives 3,000 words long when you needed 200, and that
makes claims about your codebase you can't verify without leaving the document.

Downright opens instantly, renders anything, edits in place without ever
touching your bytes, and shows you what the agent changed while you were
reading.

It opens `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx`, `.mdc`, `.qmd`, and
`.rmd` files. CommonMark/GFM parsing, math, Mermaid, callouts, wikilinks,
front matter, tables, tasks, images, and code highlighting are handled in the
native render path.

---

## What makes it different

| | |
|---|---|
| **Rendered diff** | The file is watched. When an agent rewrites it, the view updates *in place* — scroll position held by heading anchor, changed words highlighted inside the rendered prose, `[` and `]` to jump between changes. If your buffer is dirty, nothing is clobbered: a non-modal bar offers Review / Keep mine / Take theirs. |
| **Structural zoom** | `1`–`5` change the document's *resolution in place*. Level 4 is the one that matters for agent output: every heading, the first sentence of each section, and every code block, table, and task list — none of the connective padding. |
| **Local time travel** | Every external write is snapshotted to a content-addressed store. `⌘⇧V` scrubs through a month of an agent's rewrites, rendered, with changes highlighted between steps. Agents don't commit; git doesn't help you here. |
| **Live path resolution** | `src/auth/session.ts:42` resolves against the document's directory and the git root. Present files are clickable and open at the right line in your editor. **Missing files get a dotted red underline** — so you can see at a glance which files an agent claims to have touched that aren't there. |
| **Density gutter** | Replaces the scrollbar with the shape of the whole document: headings by level, code, tables, math, tasks, search hits, and changed regions. |
| **Task panel** | `⌘T` lists every checkbox grouped by heading. Toggling writes to the file immediately. A plan document becomes something you work through. |
| **Sibling sidebar** | Agents write six files into a folder, not one. `⌘0` shows the others, newest first, with dots for changed-since-you-last-looked. No index, no vault, no "open folder" ceremony. |
| **Adaptive document surface** | Read rendered Markdown and edit it in place without switching modes. Selection stays rendered; a caret reveals local syntax; scoped and full Source Focus expose exact Markdown on demand. |
| **Document inspectors** | Outline, tasks, search, history, workspace, health, render-target checks, assets, and document-lens views keep review work beside the document instead of in modal dialogs. |

And the things it deliberately **is not**: no vault, no sync, no collaboration,
no plugin system, no rich-text document model, no code execution, and — load
bearing — **no AI chat panel**. This is the surface where you review what agents
produce, not another place to generate more.

## Architecture in one screen

Five decisions determine everything else:

1. **Raw text is the only source of truth.** The `NSTextStorage` holds the
   file's exact bytes, always. Rendering is a decoration layer — attributes and
   layout, never character mutation. So round-trips are byte-identical, Copy
   can expose visible text without losing Markdown internally, and undo is
   plain text undo. Every WYSIWYG markdown
   editor that builds a document model and re-serialises will eventually
   normalise something and corrupt somebody's file. This one structurally
   cannot.
2. **One adaptive document surface.** It reads like a finished page and edits
   in place. Markdown markers appear only near a caret, selection stays
   rendered, and explicit actions reveal scoped or full source. Every state
   uses one `NSTextView` on TextKit 2, preserving scroll and selection.
3. **No WebView. Anywhere.** Math via SwiftMath, diagrams via
   beautiful-mermaid-swift, code via a native lexer, everything else through
   Core Text. This is what lets the Quick Look extension fit under its hard
   ~120MB ceiling and share exactly one render path with the app.
4. **Unsandboxed, outside the App Store.** Which is what makes FSEvents on
   arbitrary paths, `file.ts:42` → your editor, the `down` CLI, and sibling
   scanning possible at all.
5. **Full reparse, incremental restyle.** cmark parses megabytes per second;
   the expensive part is layout. So reparse everything, diff the AST by subtree
   hash, and re-decorate only the changed blocks.

```
Sources/
  MarkdownCore/     parse + extension passes + AST diff        (no UI)
  MarkdownRender/   decoration engine, layout fragments        (AppKit)
  DownrightApp/     windows, modes, panels, the agent layer
  DownrightQL/      Quick Look preview extension
  DownrightThumb/   Quick Look thumbnail extension
  down/             terminal launcher
```

`MarkdownCore` and `MarkdownRender` carry no dependency on the app and are the
pieces worth using on their own.

## Build and run

Requires macOS 14+ and a Swift 6 toolchain. Xcode is **not** required for the
app itself.

```bash
swift build
```

```bash
Scripts/bundle-app.sh
```

That assembles `.build-main/bundle/Downright.app` — executable, resource
bundles, `Info.plist` with the document types and UTIs, ad-hoc signature, and
Launch Services registration.

```bash
Scripts/install.sh
```

Copies the app to `/Applications` and links the CLI into `/usr/local/bin` as
both `down` and `md`.

```bash
down PLAN.md
```

```bash
claude -p "summarise this repo" | down
```

Run the tests with:

```bash
Scripts/check.sh
```

The script supplies the Swift Testing framework path when the active toolchain
needs it. It also fails if Swift runs zero tests.

For the release-path performance checks:

```bash
swift run -c release drbench
```

## Performance and resource bounds

The app keeps the interactive path small and lets background work converge
later. Parsing is latest-wins and coalesced, decoration is incremental, and
derived navigation metrics are computed once per refresh. External file
changes are coalesced through directory FSEvents, while sibling content hashes
are cached by path, size, and modification date.

Memory-heavy surfaces are bounded: rendered images, math, and Mermaid output
use cost-aware LRU caches; image files are downsampled to the viewport; Quick
Look releases prior render graphs and falls back to plain text when it crosses
its memory ceiling. Workspace indexing streams files through a small worker
pool with 10 MB per-file and 100 MB total-byte limits.

Latest local release benchmark (`drbench`, arm64 macOS):

| Metric | p95 | Budget |
|---|---:|---:|
| Typing response | 0.15 ms | 8 ms |
| Incremental decoration | 0.106 ms | 8 ms |
| Semantic convergence | 47.54 ms | 100 ms |
| 100 KB cold parse | 16.56 ms | 250 ms |

Run the complete validation suite with `Scripts/check.sh`. The current suite
covers 443 tests in 54 suites and fails if the test runner executes nothing.

## CLI

`down` opens Markdown in the installed app. `md` is installed as an alias.
With no subcommand, `down` preserves the familiar open-file behavior; piped
input becomes a temporary Markdown document.

```bash
down README.md
printf '# Draft\n' | down
md --edit PLAN.md
```

The same executable also provides source and review commands that do not launch
the app:

```bash
down read README.md
down read --json README.md
down outline --json README.md
down export --format html -o README.html README.md
down check --target github Docs/sample.md
```

`check` exits with status 1 when it finds diagnostics. Built-in compatibility
targets include Downright, CommonMark, GitHub, Obsidian, Pandoc, MultiMarkdown,
Jekyll, Hugo, and Quarto. Use `down --help` for the complete command list.

## Keyboard

Document mode is always editable. Every binding is remappable in Settings →
Keys, which is generated from the same command table as the menus.

| | | | |
|---|---|---|---|
| `⌘E` | Use selection for Find | `⌥↓` / `⌥↑` | Next / previous change |
| `⌘⇧E` | Toggle full Source Focus | `⌘⇧O` | Jump to heading |
| `⌘0` | Sibling sidebar | `[` / `]` | Previous / next change |
| `⌘⌥1` | Outline panel | `1`–`5` | Structural zoom in the outline |
| `⌘T` | Task panel | `⌘F` | Find |
| `⌘⇧V` | Version timeline | `⌘G` / `⌘⇧G` | Next / previous match |
| `⌘\` | Split view | `⌘⇧F` | Search sibling files |
| `⌘C` / `⌘⇧C` | Copy visible text / Markdown | `⌘⌥←` / `⌘⌥→` | Promote / demote heading |

The vim-style `j`/`k`/`g`/`G` layer is off by default; turn it on in
Settings → Keys.

## Quick Look

The repository contains native preview and thumbnail providers. They can give
`.md` files full previews and Finder icons that show the first heading.

The default SwiftPM app bundle does not include the required `.appex` bundles.
With Xcode and `xcodegen` installed, run `Scripts/bundle-xcode-app.sh` to
generate the Xcode project, build the host app, and embed the preview and
thumbnail extensions. See
[Docs/QUICKLOOK.md](Docs/QUICKLOOK.md) for details. After those bundles are
installed, launch the host app once. You may then need to enable Downright
under **System Settings → General → Login Items & Extensions → Quick Look**.

## Themes

Themes are JSON, not CSS. Six ship with the app, including a dark mode that is
*designed rather than inverted* — warm-tinted background, body text at ~85%
white, because pure white on black is genuinely fatiguing across a long
document. Drop your own in
`~/Library/Application Support/Downright/Themes/`; they hot-reload as you edit.

VS Code and Shiki themes import directly, so code blocks and mermaid diagrams
share one palette.

## Status and known gaps

See [Docs/STATUS.md](Docs/STATUS.md) for what is implemented, what is
approximate, and where this build deviates from the spec.

## Licence

MIT. See [LICENSE](LICENSE).

The spec left this open, weighing MIT's pull for contributors against copyleft's
protection of `MarkdownRender` from a paid App Store fork. MIT wins here: the
renderer's value compounds through adoption, a fork has to keep pace with the
original, and a licence that discourages contribution costs more than the fork
it prevents.
