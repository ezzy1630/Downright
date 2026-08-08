<p align="center">
  <img src="Resources/AppIcon.png" width="160" height="160" alt="Downright app icon">
</p>

# Downright

A native macOS markdown reader and editor, built for a world where most
markdown is written by machines.

Every markdown app on macOS is built on an assumption that stopped being true:
that a `.md` file is a static document a human wrote and a human will read. In
an agent workflow it is neither. It's a file that gets rewritten under you while
you're reading it, that arrives 3,000 words long when you needed 200, and that
makes claims about your codebase you can't verify without leaving the document.

Downright opens quickly, renders Markdown natively, edits in place without ever
touching your bytes, and shows you what the agent changed while you were
reading.

It opens `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx`, `.mdc`, `.qmd`, and
`.rmd` files. CommonMark/GFM parsing, math, Mermaid, callouts, wikilinks,
front matter, tables, tasks, images, and code highlighting are handled in the
native render path.

## Current status

Downright is an active source build. The repository builds the app, the
`down` CLI, the `MarkdownCore` and `MarkdownRender` libraries, test targets,
and the release benchmark. It also contains Sparkle 2.9.5 updater code, a
custom update pill and release-notes window, scripted sign-and-notarize /
make-dmg / verify-bundle paths, one canonical version source in
`Config/version.env`, and privacy manifests. Dev bundles use ad-hoc signing
and omit production updater configuration. The checked-in release workflow
automates Developer ID signing, notarization, appcast generation, and GitHub
Release/Pages publication. Until a tagged production run is verified, treat
distribution as release automation rather than a proven release artifact.

The app and Quick Look extensions can be assembled from the SwiftPM products
with the Command Line Tools: run `Scripts/bundle-app.sh`, then
`Scripts/bundle-quicklook.sh`. `Scripts/bundle-xcode-app.sh` remains the
XcodeGen/Xcode alternative. The generated `Downright.xcodeproj` is ignored and
not committed.

Recent work fixed a launch hang — opening any document could spin forever —
and drove a full UI/UX audit: invisible zero-width characters no longer leak
into the pasteboard, callout / table / list rendering was corrected, and eight
shortcut conflicts with macOS were removed. The current reading surface also
has five-level structural zoom, heading navigation, footnote support, a
section-mapped task worklist, and a density gutter without the old vertical
rail. Earlier passes brought a file-first start window and stable
document/tab workflow; unread external-change review with bounded diff and
resource work; an interactive Quick Look preview; and immediate checkbox
writes from the task panel.

---

## What makes it different

| | |
|---|---|
| **Rendered diff** | The file is watched. When an agent rewrites it, the view updates *in place* — scroll position held by heading anchor, changed words highlighted inside the rendered prose, unread changes marked until you review them, and `[` / `]` to jump between changes. If your buffer is dirty, nothing is clobbered: a non-modal bar offers Review / Keep mine / Take theirs. |
| **Structural zoom** | `⌃⌥⌘1`–`⌃⌥⌘5` change the document's *resolution in place*. Level 4 is the one that matters for agent output: every heading, the first sentence of each section, and every code block, table, and task list — none of the connective padding. |
| **Local time travel** | Every external write is snapshotted to a content-addressed store. `⌥⌘V` scrubs through a month of an agent's rewrites, rendered, with changes highlighted between steps. Agents don't commit; git doesn't help you here. |
| **Live path resolution** | `src/auth/session.ts:42` resolves against the document's directory and the git root. Present files are clickable and open at the right line in your editor. **Missing files get a dotted red underline** — so you can see at a glance which files an agent claims to have touched that aren't there. |
| **Density gutter** | Replaces the scrollbar with the shape of the whole document: headings by level, code, tables, math, tasks, search hits, and changed regions. |
| **Task worklist** | `⌥⌘3` opens every checkbox in the document, grouped by heading and ordered open-first, under a section-map bar that fills by completion and jumps on click. Select a row to go to it; tick it to write the file immediately, with an Undo pill because a write that fast deserves an equally fast way back. Quick-add and drag-reorder go back into the source as plain undoable edits. |
| **Sibling awareness** | Agents write six files into a folder, not one. The containing directory — plus one level into `docs/`, `plans/`, `.claude/` and friends — is scanned on open and kept to hand: newest first, with a dot on anything that changed since you last looked. Reach them from the command palette's Quick Open or the Workspace inspector; `⌘⇧F` searches across them. One shallow directory listing. No index, no vault, no "open folder" ceremony. |
| **Adaptive document surface** | Read rendered Markdown and edit it in place without switching modes. Selection stays rendered; a caret reveals local syntax; scoped and full Source Focus expose exact Markdown on demand. |
| **Reading chrome that stays out of the way** | The current heading trail owns a slim lane above the page instead of floating over prose. Block and list markers use one aligned ornament column; wrapped list text keeps one content edge. |
| **Document inspectors** | Tasks, search, history, workspace, health, render-target checks, assets, and document-lens views keep review work beside the document instead of in modal dialogs. There is no separate outline navigator: the density gutter expands into the document's structure on hover, and the command palette opens headings and files. |
| **Native system surfaces** | Quick Look previews, Finder thumbnails, the `down` / `md` CLI, macOS Services, App Intents, and Spotlight indexing for opened documents keep Markdown available from the places you already work. |

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
  drdownright/      shared agent bridge and CLI support
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

To add the native Quick Look preview and thumbnail extensions to that app:

```bash
Scripts/bundle-quicklook.sh
```

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

Run the tests and repository gates with:

```bash
Scripts/check.sh
```

The script supplies the Swift Testing framework path when the active toolchain
needs it, builds the package, checks version and dependency boundaries, runs
the test suites, runs the debug benchmark, and rejects a run where Swift
Testing executed zero tests. Set `RUN_DRBENCH=1` to enforce the release
benchmark budgets as CI does. For render work, set `DOWNRIGHT_RENDER_DUMP` to
keep the smoke-test PNGs for visual comparison:

```bash
DOWNRIGHT_RENDER_DUMP=/tmp/downright-render Scripts/check.sh
```

If a locally built window looks stale, close other Downright processes and
launch the exact bundle path. Multiple build directories can register the same
bundle identifier with Launch Services:

```bash
open -n .build-main/bundle/Downright.app --args README.md
```

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

Latest local release benchmark for this checkout (`drbench`, measured
2026-08-08):

| Metric | p95 | Budget |
|---|---:|---:|
| Typing response | 0.147 ms | 8 ms |
| Incremental decoration | 0.105 ms | 8 ms |
| Semantic convergence | 30.708 ms | 100 ms |
| 100 KB cold parse | 14.432 ms | 250 ms |

Run the complete validation suite with `Scripts/check.sh`. The test count is
reported by the run and changes with the source; the script deliberately fails
if the test runner executes nothing. Set `RUN_DRBENCH=1` when the release
performance budgets must be enforced. See [Docs/PERFORMANCE.md](Docs/PERFORMANCE.md)
for the benchmark baseline and its measurement limits.

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
| `⌘E` | Use selection for Find | `⌥⇧↓` / `⌥⇧↑` | Next / previous change |
| `⌘⇧E` | Toggle full Source Focus | `⌃⌥⌘N` / `⌃⌥⌘P` | Next / previous heading |
| `⌘⇧K` | Command palette | `⌃⌥⌘1`–`⌃⌥⌘5` | Structural zoom |
| `⌥⇧⌘2` | Document lens | `⌘F` | Find |
| `⌥⇧⌘3` | Task worklist | `⌘G` / `⌘⇧G` | Next / previous match |
| `⌥⌘V` | Version timeline | `⌘⇧F` | Search sibling files |
| `⌘\` | Split view | `⌘⌥←` / `⌘⌥→` | Promote / demote heading |
| `⌘C` / `⌥⇧⌘C` | Copy visible text / Markdown | `⌘⌃[` / `⌘⌃]` | Back / forward |

Nothing here shadows a macOS convention: `⌘0` stays Actual Size, `⌘⇧V` stays
Paste and Match Style, and `⌘T` / `⌘⇧T` stay free for the tab chords.

Navigation uses modifier-safe shortcuts in every document state. Arrow keys,
Space, Page Up/Down, and letter keys remain available to AppKit and text input.

## Quick Look

The repository contains native preview and thumbnail providers. They give
`.md` files full previews and Finder icons that show the first heading, opening
line, and — for plans — task progress. The preview is interactive: when the
panel is at least 520pt wide, its leading density gutter shows the current
section and reading metrics, scrubs on click or drag, and opens the outline on
dwell. Arrow keys scroll; `n` / `p` jump between headings; text is selectable
and copyable.

Nothing has to be run by hand to turn this on. On its first launch Downright
registers itself with Launch Services, hands both extensions to `pluginkit`,
and resets Quick Look's caches so `.md` files you already have pick up their
new icons. Settings → General → System integration repeats any of it later,
which is also where to go if a macOS update knocks the extensions loose.

The `.appex` bundles are embedded with `Scripts/bundle-quicklook.sh`, which
builds them on the same Command-Line-Tools-only path as the rest of the app —
no Xcode required. With Xcode and `xcodegen` installed,
`Scripts/bundle-xcode-app.sh` remains an alternative that builds the app and
extensions through the generated project. `Scripts/install.sh` does the same
registration for a source install without launching the app. See
[Docs/QUICKLOOK.md](Docs/QUICKLOOK.md) for details.

## Privacy and AI

Open, read, edit, search, save, watch, diff, and export work offline without
an account, telemetry, or a remote model. Optional Apple Intelligence actions
are on-device, off by default, and receive only text the user selects. AI is
never required for the document path. See [Docs/PRIVACY.md](Docs/PRIVACY.md).

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
approximate, and how this build deviates from the original design.

## Licence

MIT. See [LICENSE](LICENSE).

`Vendor/SwiftMath` is a vendored copy of
[SwiftMath](https://github.com/mgriebling/SwiftMath) 1.7.3, MIT, © 2023
Computer Inspirations — its own `LICENSE` travels with it. It carries a
three-line patch so the math fonts resolve inside a shipped app bundle;
[`Vendor/SwiftMath/PATCHES.md`](Vendor/SwiftMath/PATCHES.md) records what and
why.

The licence choice left this open, weighing MIT's pull for contributors against
copyleft's protection of `MarkdownRender` from a paid App Store fork. MIT wins
here: the renderer's value compounds through adoption, a fork has to keep pace
with the original, and a licence that discourages contribution costs more than
the fork it prevents.
