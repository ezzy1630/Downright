<p align="center">
  <a href="https://downright.cc/">
    <img src="Resources/AppIcon.png" width="128" alt="Downright app icon">
  </a>
</p>

<h1 align="center">Downright</h1>

<p align="center"><strong>A beautiful native Markdown editor and reader for macOS.</strong></p>

<p align="center">
  Open ordinary Markdown files as polished Mac documents, edit their exact source,<br>
  and preview them throughout Finder. Fast, private, offline, and genuinely native.
</p>

<p align="center">
  <a href="https://downright.cc/download/"><img src="https://img.shields.io/badge/Download_for_macOS-007AFF?style=for-the-badge&amp;logo=apple&amp;logoColor=white" alt="Download Downright for macOS"></a>
  <a href="https://github.com/ezzy1630/Downright"><img src="https://img.shields.io/github/stars/ezzy1630/Downright?style=for-the-badge&amp;logo=github&amp;label=Star" alt="Star Downright on GitHub"></a>
  <a href="https://github.com/sponsors/ezzy1630"><img src="https://img.shields.io/badge/Sponsor-EA4AAA?style=for-the-badge&amp;logo=githubsponsors&amp;logoColor=white" alt="Sponsor Downright"></a>
</p>

<p align="center">
  <strong>Free and open source · macOS 14+ · Signed and notarized · Offline · No account · MIT</strong>
</p>

<p align="center">
  <a href="https://downright.cc/">Website</a> ·
  <a href="https://github.com/ezzy1630/Downright/releases">Releases</a> ·
  <a href="CHANGELOG.md">Changelog</a> ·
  <a href="CONTRIBUTING.md">Contributing</a>
</p>

<p align="center">
  <a href="https://github.com/ezzy1630/Downright/actions/workflows/ci.yml"><img src="https://github.com/ezzy1630/Downright/actions/workflows/ci.yml/badge.svg" alt="CI status"></a>
  <a href="https://github.com/ezzy1630/Downright/releases"><img src="https://img.shields.io/github/v/release/ezzy1630/Downright?display_name=tag&amp;sort=semver" alt="Latest release"></a>
  <a href="https://downright.cc/download/"><img src="https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fezzy1630%2FDownright%2Fautomation%2Fdownload-count%2Fdownloads.json&amp;cacheSeconds=3600" alt="DMG downloads"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-307afe" alt="MIT license"></a>
</p>

---

<p align="center">
  <a href="https://downright.cc/assets/downright-one-journey-master.mp4">
    <img src="Docs/downright-readme-demo.gif" alt="Downright opens a Markdown file from Finder, renders it as a native Mac document, switches to exact source, and reviews an external rewrite." width="800">
  </a>
</p>

<p align="center"><a href="https://downright.cc/assets/downright-one-journey-master.mp4">Watch the 23-second product film</a></p>

## Markdown, treated like a Mac document

Downright opens the files you already have, wherever they already live. There
is no library to import, vault to maintain, account to create, or web view
pretending to be a desktop app.

The interface and renderer are built with AppKit and TextKit 2. That means
native selection, keyboard behavior, menus, typography, accessibility, and
performance, with the original Markdown remaining authoritative on disk.

| Read naturally | Edit precisely |
|---|---|
| Native CommonMark and GFM rendering | Exact source remains authoritative |
| Beautiful typography and six themes | Document and Source views share position and selection |
| Math, Mermaid, tables, tasks, callouts, images, and footnotes | Safe external-change tracking and conflict protection |
| Quick Look previews and Finder thumbnails | Local snapshots and a version timeline |
| Outline, structural zoom, and density navigation | Search sibling files without creating a vault |
| HTML/PDF export, Services, and Spotlight metadata | `down` and `md` terminal commands |

Supported files: `.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx`, `.mdc`, `.qmd`,
and `.rmd`.

## Installation

### Download the app

Download the latest signed and notarized release from
[downright.cc/download](https://downright.cc/download/).

1. Open `Downright.dmg`.
2. Drag Downright into Applications.
3. Launch it once to configure Markdown file associations, Quick Look, and the
   CLI.

### Homebrew

The public tap installs the same production app into `/Applications`:

```bash
brew tap ezzy1630/downright && brew trust --cask ezzy1630/downright/downright && brew install --cask downright
```

The app keeps its Sparkle updater after a cask install. GitHub records the DMG
request in the release asset download count.

This is the developer tap. The tap-free `brew install --cask downright`
command is not advertised until an official Homebrew Cask is accepted.

### Terminal installer

The first-party installer downloads the latest signed build, verifies its
published checksum and app signature, installs it into `/Applications`,
registers the Finder integrations, and links `down` and `md` when possible:

```bash
curl -fsSL https://downright.cc/install | bash
```

If Node.js 18 or newer is already installed, the npm launcher runs the same
first-party installer:

```bash
npx --yes downright-installer
```

Every installation path leaves automatic Sparkle updates enabled. The curl
path needs no Node.js; the npm path is macOS-only and requires Node.js 18+.

## Why Downright

- **Exact source.** Rendering decorates the original text storage; it does not
  rebuild or normalize the document.
- **Safe live updates.** External writes refresh in place while preserving the
  reading position. Dirty local edits are never silently replaced.
- **Native and file-first.** TextKit 2, Core Text, SwiftMath, and native Mermaid
  rendering keep the app and Quick Look extensions lean. There is no WebView,
  workspace requirement, sync service, plugin runtime, or chat panel.
- **Polished for everyday use.** Six themes, precise typography, native menus,
  configurable shortcuts, and Finder integration make Markdown feel at home on
  macOS.

### Review external edits when you need to

If another app or coding agent rewrites an open file, Downright can show the
change in place, preserve dirty local edits, and let you review word-level
differences. It is a useful extra, not a different way of owning your files.

## Everyday commands

```bash
down PLAN.md                              # open a file
down open --line 42 --review PLAN.md      # open an agent plan at a line for review
down open --reveal PLAN.md                # reveal a document in Finder
printf '# Draft\n' | down                 # open piped Markdown
down read --json README.md                # inspect without launching the app
down outline --json README.md             # emit document structure
down export --format html -o out.html README.md
down check --target github Docs/sample.md # validate a render target
down doctor                               # diagnose app, CLI, Quick Look, and updater setup
```

`md` is installed as an alias for `down`. `down doctor --json` emits a
machine-readable support report without modifying the machine; use
`down doctor --app path/to/Downright.app` to inspect a development bundle. Run
`down --help` for every command.

## Keyboard essentials

All bindings are editable in **Settings → Keys**.

| Shortcut | Action | Shortcut | Action |
|---|---|---|---|
| `⌘F` | Find | `⌘E` | Find selected text |
| `⌘⇧F` | Search sibling files | `⌘⇧E` | Source Focus |
| `⌥⌘1`–`6` | Set heading level | `⌥⌘0` | Convert heading to body |
| `⌘[` / `⌘]` | Promote / demote heading | `⌘⇧K` | Command palette |
| `⌥⇧⌘3` | Task worklist | `⌥⌘V` | Version timeline |
| `⌃⌥⌘1`–`5` | Structural zoom | `⌥⇧↑` / `↓` | Previous / next change |
| `⌘\` | Split view | `⌘L` | Toggle task at caret |

## Themes and appearance

Downright follows macOS Light and Dark appearances by default. Light and dark
palettes are chosen separately under **Settings → Appearance** or
**View → Theme**. Turning off **Follow macOS Appearance** deliberately keeps
the selected light palette active.

Six themes ship with the app. VS Code and Shiki themes can be imported, and
custom JSON themes hot-reload from:

```text
~/Library/Application Support/Downright/Themes/
```

## Privacy

Opening, reading, editing, searching, diffing, and exporting are local. No
account or telemetry is required. Optional Apple Intelligence actions are
on-device, off by default, and receive only text selected by the user.

See [Privacy](Docs/PRIVACY.md).

## Support Downright

Downright is built and maintained independently. It is free, MIT-licensed,
offline-first, and contains no advertising or app telemetry.

If Downright earns a place in your workflow, you can help sustain its
development by:

- [Starring the repository](https://github.com/ezzy1630/Downright)
- [Sponsoring the project](https://github.com/sponsors/ezzy1630)
- Sharing [downright.cc](https://downright.cc/) with someone who works in
  Markdown

Sponsorship helps cover signing, distribution, ongoing macOS compatibility,
and the time required to keep Downright polished. The
[sponsorship policy](Docs/SPONSORING.md) explains what support does and does not
change.

The first goal is 10 monthly sponsors to cover the Apple Developer membership
and the routine infrastructure behind signed, notarized releases.

## Development

Requirements: macOS 14 or newer, Xcode, xcodegen, and a Swift 6 toolchain.

Clone, build the complete app, and install it with Finder integration:

```bash
git clone https://github.com/ezzy1630/Downright.git
cd Downright
Scripts/bundle-xcode-app.sh
APP_SOURCE=.build-xcode/Build/Products/Release/Downright.app Scripts/install.sh
down README.md
```

For a faster SwiftPM development build without Finder extensions:

```bash
Scripts/bundle-app.sh
open .build-main/bundle/Downright.app
```

The complete build requires Xcode and `xcodegen`; it embeds both the Quick Look
preview and Finder thumbnail extensions. Launch Downright once after
installation: the first-run setup offers default-app and CLI registration,
registers Quick Look, and can repeat every step later under **Settings →
General → System integration**. See [Quick Look](Docs/QUICKLOOK.md) and
[Release](Docs/RELEASE.md) for details.

## Architecture

```text
MarkdownCore     parsing, extensions, AST diff
MarkdownRender   native decoration and layout
DownrightApp     windows, commands, panels, file watching
DownrightQL      Quick Look preview
DownrightThumb   Finder thumbnails
DownrightSpotlightMetadata  shared unopened-file metadata extraction
DownrightSpotlightImporter  macOS filesystem Spotlight importer
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
Scripts/check-app.sh
```

See [CONTRIBUTING.md](CONTRIBUTING.md) before opening a pull request.

## Project status

The current rolling release is tracked in
[GitHub Releases](https://github.com/ezzy1630/Downright/releases), and current
polish is tracked under [Unreleased](CHANGELOG.md). The repository contains
the app, CLI, Quick Look extensions, updater, signing, notarization, DMG, and
release automation. See [Status](Docs/STATUS.md) for known gaps and
implementation notes.

## License

Downright is available under the [MIT License](LICENSE). Vendored components
retain their own license files and notices.
