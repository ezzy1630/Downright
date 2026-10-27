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

Source-test hosts do not run `NSApplication.run()`. Document windows disable
native transform animations in that host so they cannot strand dispatch workers;
running applications keep the native animation policy. Activated-app acceptance
remains a separate gate from source tests.

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

Document-wide layout maps retain range descriptors for hidden markers, rather
than an attributed string per marker. A requested paragraph resolves its
source-length word joiners against the current storage attributes through
`DisplaySubstitution.resolvedReplacement(in:)`. Source-edit projection moves
the descriptors along with the source ranges; it does not retain old styles
or create replacement text for offscreen elements.
Custom paragraph content and separator ranges partition the source element
without overlap, including empty paragraphs and two-unit CRLF separators.

Block markers live in the gutter. Inline markers reveal per span near the
primary caret. IME composition suspends hiding in the composing paragraph.
After a source edit, retain its exact source caret while its native projection
is unchanged: hidden markers make a source-to-display round trip lossy. A new
native selection retires that edit position and resolves against visible text.
A split pane adopts the existing parsed presentation during construction, before
any setter can decorate the shared storage. Each pane owns its layout caches;
opening a split must preserve source attributes and avoid a full decoration pass.
AppKit owns the text-container origin and viewport surface lifecycle. Preserve
its native geometry calculation and all text-view drawing entry points. The
container supplies the opaque page behind a transparent native text view.
Clipped, viewport-sized background and foreground views draw page ornaments
below text and hover underlines/drop carets above fragment backgrounds. Neither
receives input or owns another text surface; fragments retain glyph/object drawing.
Keep large-file layout lazy by suppressing
synthetic selection work and bounding explicit layout requests.
Attach a shared pane's scroll surface while empty, then bind the shared storage
and adopt its presentation in one content-storage editing transaction. This
establishes native geometry without sizing an entire file during attachment.
Replacing a document discards the previous buffer's queued viewport/resize repairs
before sizing the new presentation. Its shrink must not capture a reading anchor
from the old camera; ordinary edits and mode changes continue preserving anchors.

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

Dirty state compares exact UTF-16 source with the last saved generation. Returning
to that text by deletion or undo clears the edited state without writing the
file; pending external conflicts remain independent and cannot be overwritten.

Autosave is opt-in. Actual local source edits reset its idle deadline even when
the buffer is already dirty. Discard suppresses implicit saves until a fresh
source edit; parser and presentation updates cannot re-arm saving.

Snapshots deduplicate by content hash. Retention applies the configured age,
per-document, and global byte caps without rewriting unchanged indexes; a
half-hour maintenance interval bounds long-running sessions. The newest
snapshot for each document is retained even after the document moves or its
path disappears. Reading-position state is not deleted based on path presence;
broader cleanup requires an explicit user action.

Snapshot restore is a text edit, not a hidden file replacement. Persistence
tests inject temporary support roots, and the repository gate also refuses to
run them without an isolated Application Support directory.

## Workspace and path resolution

Local document links resolve URL encoding and heading fragments separately from
filesystem paths. The text surface routes native link activation through the app
so Launch Services cannot independently open the same click. Back/Forward commit
a history move only after the destination opens successfully and restore semantic
reading anchors across files.

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

CI streams source-test progress while retaining the complete scratch-specific
log. If the test phase remains running, a diagnostic helper captures its own
descendant process tree and test/compiler stacks. This distinguishes compilation
stalls from runtime waits without changing test deadlines, exit status, or budgets.

Shared-pane parse commits capture each pane's reading anchor before either pane
decorates their shared storage. Projected edit anchors and explicit pixel locks
take precedence. Navigation that moves the viewport replaces any older pending
resize camera while retaining the height repair; already-visible no-ops leave
queued repairs intact. Applying a resize camera retires an animated scroll's
obsolete pixel target before restoring the source anchor.

Activated-app acceptance writes a per-run `.xcresult` under its scratch directory.
CI retains that result bundle so screenshots and native interaction evidence can
be reviewed against the exact tested host.
The native editor journeys inspect WindowServer screenshot pixels inside each
prose viewport, excluding chrome and margin controls, and read AppKit's native
scrollbar for link/history positions. Diagnostic `cacheDisplay` captures are
kept out of that user-path acceptance; a PNG's existence or size does not prove
that the document was visible.

The UI-test runner also hosts framework lifecycle windows covering initially
empty storage, mounting before load, and zero-sized viewports that later resize.
These inspect WindowServer pixels and record native observer/viewport state;
they isolate rendering lifecycle failures without adding alternate app paths.
The activated-app journeys remain required for the actual document host.
