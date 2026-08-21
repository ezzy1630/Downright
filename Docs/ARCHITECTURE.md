# Downright Architecture

## Goals and invariants

Downright is a native macOS app. The architecture must keep these rules true:

1. Raw file text is the only source of truth.
2. Rendering adds attributes and fragments. It never changes source characters.
3. Read, Live, and Source use one TextKit 2 text surface.
4. AI is optional. Core reading and editing do not call a model or a network.
5. A failed parser or renderer must not destroy the source buffer.
6. File writes and external changes must be visible and recoverable.

## Package layout

```text
Sources/
  MarkdownCore/     parse, extensions, ranges, AST diff, text edits
  MarkdownRender/   TextKit 2 decoration, fragments, layout, themes
  DownrightApp/     windows, commands, panels, file and agent workflows
  DownrightQL/      Quick Look preview extension
  DownrightThumb/   Quick Look thumbnail extension
  DownrightSpotlightMetadata/  shared parser-backed metadata extraction
  DownrightSpotlightImporter/  classic macOS MDImporter plug-in
  down/             terminal launcher
```

`MarkdownCore` has no UI dependency. `MarkdownRender` owns AppKit rendering.
The app owns windows, file access, and user actions. Quick Look uses the same
core and render contracts as the app. The Spotlight targets share only the
parser-backed metadata contract and never start an AppKit surface.

## Document pipeline

```text
file bytes
  -> encoding and line-ending detection
  -> NSTextStorage (exact text)
  -> full swift-markdown parse
  -> extension pass
  -> AST subtree-hash diff
  -> dirty block set
  -> attribute and fragment decoration
  -> TextKit 2 layout
  -> one NSTextView surface
```

The extension pass adds math, YAML front matter, callouts, wikilinks, path
tokens, Mermaid fences, and language metadata. The parser uses disabled smart
punctuation so quotes and dashes are not rewritten in the AST.

The parser can reparse the full document. The expensive work is layout, so the
renderer diffs blocks and restyles only dirty blocks. A wholesale restyle is
used for mode or theme changes.

## Text and editing

TextKit 2 stores the exact source. Marker hiding uses a source-to-display index
map and custom layout fragments. It does not use zero-width fonts, transparent
text, or shortened replacement strings.

Block markers live in the gutter. Inline markers reveal per span near the
primary caret. IME composition suspends hiding in the composing paragraph.
Undo remains text undo. Copy as Markdown reads the source range. Rich-text copy
is a separate explicit command.

Document commands apply source edits, reparse, and decorate inside one undo
group. List indentation and ordered-list repair use this sequence:

```text
apply edit -> reparse -> plan tidy rules -> apply tidy edit
```

## File watching and snapshots

Watch the parent directory with FSEvents. Do not watch only the inode; atomic
writes replace the inode. On an external write:

1. Read and validate the new bytes.
2. Create a content-addressed snapshot.
3. Compute text and rendered changes.
4. Keep the current scroll anchor by heading when possible.
5. If the buffer is clean, apply the new text.
6. If the buffer is dirty, show Review, Keep Mine, and Take Theirs.

Snapshots deduplicate by content hash. Retention applies the configured age,
per-document, and global byte caps without rewriting unchanged indexes; a
half-hour maintenance interval bounds long-running sessions. History for a
deleted document becomes eligible after the configured snapshot age; its
reading-position state uses a fixed 30-day age. Both require two distinct
observations that the path is absent, and the containing volume must be
mounted. An unreadable path, an I/O error, an unmounted volume, or a path
restored between observations is preserved. These checks deliberately fail
closed around atomic replacements.

Snapshot restore is a text edit, not a hidden file replacement. Persistence
tests inject temporary support roots, and the repository gate also refuses to
run them without an isolated Application Support directory.

## Workspace and path resolution

The app can open one file or an optional folder workspace. Workspace mode scans
the folder for sibling documents and shows them newest first. It does not build
a global index.

Path tokens resolve relative to the document directory and then the git root.
Existing files open in the user's editor at the requested line. Missing paths
use a dotted red underline and do not run a command.

## AI boundary

The AI boundary is a small adapter owned by the app layer. The default adapter
is disabled. Optional on-device Apple Intelligence receives only user-selected
local text and returns text for review. It cannot block parser, renderer,
watcher, save, or navigation work.

No remote model, telemetry, or background prompt runs in the core path. A
future provider must be explicit, opt-in, and separately reviewed.

## Quick Look and Spotlight

The filesystem Spotlight importer lives at
`Downright.app/Contents/Library/Spotlight`. Its `schema.xml` declares only
title, text content, keywords, and kind. It extracts metadata from unopened
Markdown files, while `CoreSpotlight` remains the fast path for documents the
app has already opened.

Quick Look and thumbnail targets share parser, theme, and render contracts but
have strict limits:

- Poll resident memory and fall back to plain text above 60 MB.
- For files above 2 MB, render an initial block set and show Open in App.
- Render math, Mermaid, and images only when in the viewport.
- Keep preview work below 400 ms and 60 MB peak.

The host app must be launched once before the extensions register. Xcode is
needed to bundle the `.appex` targets; the Spotlight importer is bundled by
both the SwiftPM and Xcode paths.

## Concurrency and effects

Keep parsing, AST diff, text diff, and policy helpers pure where possible.
Perform AppKit layout and text-storage mutation on the main actor. Give file
watch callbacks a clear lifecycle and stop them when the document closes.
Cancel stale parse and render work before applying newer results. Apply results
only when their document revision still matches the active revision.

## Failure handling and tests

Use plain text fallback when decoding or rendering fails. Never overwrite the
source because a decoration pass failed. Test byte identity, source ranges,
external writes, dirty-buffer conflicts, scroll anchoring, hidden markers,
zoom, folding, find, tasks, paths, Quick Look limits, and accessibility.

Performance gates are defined in [PERFORMANCE.md](PERFORMANCE.md). The
implementation must pass `Scripts/check.sh` and the release benchmark before a
phase is complete.
