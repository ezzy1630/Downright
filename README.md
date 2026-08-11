<p align="center">
  <img src="Resources/AppIcon.png" width="144" height="144" alt="Downright app icon">
</p>

<h1 align="center">Downright</h1>

<p align="center">
  A fast, native Markdown reader and editor for macOS.<br>
  Built for files that people and coding agents change together.
</p>

<p align="center">
  macOS 14+ &nbsp;&middot;&nbsp; Swift 6 &nbsp;&middot;&nbsp; Native AppKit &nbsp;&middot;&nbsp; MIT
</p>

---

Downright opens Markdown as a calm document, keeps its source exact, and shows
external edits without pulling you out of the page. It works offline, has no
account requirement, and never uses a WebView.

## Highlights

| Read and edit | Review agent output |
|---|---|
| Native CommonMark/GFM rendering | Live external-change tracking |
| One adaptive rendered/source surface | Word-level rendered diffs |
| Math, Mermaid, tables, tasks, and callouts | Local snapshots and version timeline |
| Structural zoom and density navigation | Missing path and render-target checks |

| Work with the whole folder | Use Markdown everywhere |
|---|---|
| Sibling-file search without a vault | Quick Look previews and Finder thumbnails |
| Task worklist with undo and quick-add | `down` and `md` terminal commands |
| Clickable `file.swift:42` references | HTML/PDF export, Services, and Spotlight |
| Themes that follow macOS Light/Dark mode | Optional on-device Apple Intelligence |

Supported files: `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx`, `.mdc`, `.qmd`,
and `.rmd`.

## Why Downright

- **Exact source.** Rendering decorates the original text storage; it does not
  rebuild or normalize the document.
- **Safe live updates.** External writes refresh in place while preserving the
  reading position. Dirty local edits are never silently replaced.
- **Native performance.** TextKit 2, Core Text, SwiftMath, and native Mermaid
  rendering keep the app and Quick Look extensions lean.
- **File-first design.** Open one file. No workspace setup, database, sync
  service, plugin runtime, or chat panel.

## Quick start

Requirements: macOS 14 or newer and a Swift 6 toolchain.

```bash
git clone https://github.com/ezzy1630/Downright.git
cd Downright
Scripts/bundle-app.sh
open .build-main/bundle/Downright.app
```

Install the app and CLI:

```bash
Scripts/install.sh
down README.md
```

Add the native Quick Look preview and thumbnail extensions:

```bash
Scripts/bundle-quicklook.sh
Scripts/install.sh
```

For the complete Xcode build path, including embedded extensions and bundle
validation:

```bash
Scripts/bundle-xcode-app.sh
APP_SOURCE=.build-xcode/Build/Products/Release/Downright.app Scripts/install.sh
```

The Xcode path requires Xcode and `xcodegen`. See
[Quick Look](Docs/QUICKLOOK.md) and [Release](Docs/RELEASE.md) for details.

## Everyday commands

```bash
down PLAN.md                              # open a file
printf '# Draft\n' | down                 # open piped Markdown
down read --json README.md                # inspect without launching the app
down outline --json README.md             # emit document structure
down export --format html -o out.html README.md
down check --target github Docs/sample.md # validate a render target
```

`md` is installed as an alias for `down`. Run `down --help` for every command.

## Keyboard essentials

All bindings are editable in **Settings → Keys**.

| Shortcut | Action | Shortcut | Action |
|---|---|---|---|
| `⌘F` | Find | `⌘⇧F` | Search sibling files |
| `⌘⇧E` | Source Focus | `⌘⇧K` | Command palette |
| `⌥⇧⌘3` | Task worklist | `⌥⌘V` | Version timeline |
| `⌃⌥⌘1`–`5` | Structural zoom | `⌥⇧↑` / `↓` | Previous / next change |
| `⌘\` | Split view | `⌘L` | Toggle task at caret |

## Themes and appearance

Downright follows macOS Light/Dark appearance by default. Light and dark
palettes are chosen separately under **Settings → Appearance** or
**View → Theme**. Turning off **Follow macOS Appearance** deliberately keeps
the selected light palette active.

Six themes ship with the app. VS Code and Shiki themes can be imported, and
custom JSON themes hot-reload from:

```text
~/Library/Application Support/Downright/Themes/
```

## Architecture

```text
MarkdownCore     parsing, extensions, AST diff
MarkdownRender   native decoration and layout
DownrightApp     windows, commands, panels, file watching
DownrightQL      Quick Look preview
DownrightThumb   Finder thumbnails
drdownright      shared CLI and integration support
down             terminal entry point
```

The core rule is simple: raw text remains the source of truth. One `NSTextView`
moves between rendered editing, scoped source, and full Source Focus while
preserving selection, undo, and byte fidelity.

More detail: [Architecture](Docs/ARCHITECTURE.md) ·
[Feature matrix](Docs/FEATURE-MATRIX.md) · [Performance](Docs/PERFORMANCE.md)

## Test and verify

Use the repository gate instead of bare `swift test`:

```bash
Scripts/check.sh
```

It builds every package target, verifies versions and dependencies, runs the
test suites, checks theme contrast, and exercises the benchmark. Release
performance budgets can be enforced with:

```bash
RUN_DRBENCH=1 Scripts/check.sh
```

Bundle verification:

```bash
Scripts/verify-bundle.sh .build-main/bundle/Downright.app
```

## Privacy

Opening, reading, editing, searching, diffing, and exporting are local. No
account or telemetry is required. Optional Apple Intelligence actions are
on-device, off by default, and receive only text selected by the user.

See [Privacy](Docs/PRIVACY.md).

## Project status

Downright is an active source build targeting version 1.0. The repository
contains app, CLI, Quick Look, updater, signing, notarization, DMG, and release
automation. See [Status](Docs/STATUS.md) for current implementation notes and
[Changelog](CHANGELOG.md) for recent work.

## License

Downright is available under the [MIT License](LICENSE). Vendored components
retain their own license files and notices.
