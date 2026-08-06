# Changelog

All notable changes to Downright are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Version truth lives in a single place — `Config/version.env` — and every
consumer (Xcode project, bundle scripts, the `down` CLI) is verified against it
by `Scripts/sync-versions.sh`. `CFBundleVersion` increases monotonically with
every release; Sparkle orders updates by it.

## [Unreleased]

### Distribution & release engineering

- **Sparkle 2.9.5 auto-update** with a fully custom UI: update pills in document
  titlebars and the start window, a nonmodal release-notes panel rendered through
  the app's own `MarkdownTextView`, and a fully unit-tested update state machine.
  Dev/ad-hoc bundles omit the Sparkle Info.plist block and ship with the updater
  disabled; only signed production bundles check for updates.
- **Signed + notarized release pipeline** (`.github/workflows/release.yml`):
  Developer ID signing of every nested executable individually (never
  `--deep`), notarization, stapling, Sparkle-signed appcast with delta updates,
  GitHub Release, and GitHub Pages deployment.
- **Manual release path, scripted**: `Scripts/sign-and-notarize.sh` signs,
  notarizes, and staples by hand; `Scripts/make-dmg.sh` packages a drag-install
  DMG. `Scripts/verify-bundle.sh` holds both pipelines to one layout contract.
- **One canonical version source**: `Config/version.env`, verified by
  `Scripts/sync-versions.sh` in `check.sh` and gated in the release workflow.
- **Privacy manifests** (`PrivacyInfo.xcprivacy`) for the app, Quick Look, and
  thumbnail bundles declaring the required-reason APIs in use (UserDefaults,
  file timestamps). No data is collected and nothing tracks.
- **Quick Look and Finder thumbnails now cover `.mdx` / `.mdc` / `.qmd` /
  `.rmd`** — the exported `com.ezzyrappeport.downright.markdown` UTI is declared
  in both extension bundles.
- **CI gates the §12 performance budget**: `ci.yml` runs `drbench` in release
  with budgets enforced (`RUN_DRBENCH=1`).

### Fixed

- An implicit save could silently clobber a newer on-disk version after an
  external edit (occlusion autosave, quit, checkbox toggle): saves are now
  refused until the user resolves the conflict, and only an explicit
  "keep mine" decision writes over the file.
- FSEvents retransmissions of the same external write were reported repeatedly
  while an external write racing a save could be swallowed; both cases are now
  handled by the suppression window logic in `FileWatcher`.

### Added

- Regression probes locking the mermaid text orientation against the library's
  known-good render path (`MermaidOrientationProbeTests`, `GeometryProbeTests`).

## [1.0.0] - upcoming first release

The initial release of Downright: a local-first Markdown editor for macOS that
treats the file on disk as the single source of truth.

### Added

- Live editing with **byte-for-byte file fidelity** (§3.1): read → parse →
  write round-trips a document exactly, including CRLF/CR line endings, BOM,
  UTF-16/32, and mixed endings; nothing is normalised that cannot be faithfully
  restored.
- Structural zoom, document outline, reader profiles, and a density rail.
- Inline rendering for math (LaTeX), mermaid diagrams, callouts, tables, task
  lists, wikilinks, and file/path tokens with resolution.
- Themes: built-in light/dark palettes plus VS Code / Shiki theme import, and a
  custom theme store.
- **No-mutation decoration engine**: keystroke → updated render at a budgeted
  p95 of 8 ms on a 5k-line document (§12), measured by `drbench`.
- Local AI assistance (optional, on-device) with sibling-document scanning,
  change tracking, and an external-edit conflict bar.
- Session restore with per-document state (mode, zoom, fold, scroll, sidebar),
  native tabs, jump history, command palette, keybindings, and vim keys.
- Quick Look preview and Finder thumbnails for Markdown documents.
- `down` CLI for rendering and editing from the terminal, plus the reusable
  `MarkdownCore` and `MarkdownRender` packages.
- Front matter editor, table editor, document health checks, tidy pass, smart
  paste, review sidecars, asset doctor, and diagnostics.
- Plain-text fallback: files are opened and rendered; nothing is ever
  evaluated (`.mdx`/`.qmd` executable chunks are rendered as text).
