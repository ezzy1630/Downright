# Downright Product

## Product direction

Downright is a free, open-source Markdown app for macOS. It opens a Markdown
file fast, renders it clearly, edits the same text in place, and shows changes
made by an external tool while the user reads.

The default product is local. A user does not need an account, a server, or an
AI service.

## Users

Downright serves these users in this order:

1. Developers and people who use AI coding agents.
2. Casual readers of Markdown files.
3. Technical writers and researchers.

The first group needs safe review of files that change during reading. The
second group needs a fast and pleasant reader. The third group needs exact
source, strong navigation, and useful export.

## The promise

- Open a file in one action.
- Keep the file bytes exact. Rendering never rewrites source text.
- Read, edit, and inspect source in one text surface.
- Show external changes in the rendered document.
- Make document structure visible before the user reads every word.
- Keep file paths, tasks, and sibling documents close to the current file.
- Work without a network connection.

## Default experience

Downright opens in Read mode. The user can switch to Live mode to edit and to
Source mode to inspect Markdown syntax. One text view holds all three modes.

The app has no permanent chat panel. AI output is an input to review, not a
reason to leave the document. File watching, rendered diff, snapshots, and
path checks work without AI.

An optional folder workspace shows related files beside the current document.
The user can open one file without opening a workspace. Workspace scanning is
local and does not create an index or a vault.

An optional on-device Apple Intelligence feature may help with a local task
such as summarising or explaining selected text. It is off by default, needs a
user action, and is never required for open, read, edit, search, save, or diff.

## Product character

- **Calm:** low chrome, stable layout, restrained colour, and motion that can
  be disabled.
- **Exact:** source bytes, ranges, links, paths, and changes must remain
  trustworthy.
- **Fast:** first content appears quickly, typing stays responsive, and large
  documents remain usable.

Preview is the reference for direct file opening and quiet reading. Xcode is
the reference for source-aware navigation and trustworthy developer tools.
Things 3 is the reference for clear tasks and focused hierarchy. Downright
uses these qualities without copying their product models.

## Included in 1.0

- CommonMark and GFM Markdown with math, callouts, front matter, wikilinks,
  paths, Mermaid, tables, images, and footnotes.
- Read, Live, and Source modes on one TextKit 2 surface.
- Structural zoom, folding, outline, task panel, density gutter, find, and
  sibling sidebar.
- Safe external-write review with rendered diff, unread marks, and local
  snapshots.
- Path resolution from the document folder and git root. Existing paths open
  in the user's editor. Missing paths are clear.
- Quick Look preview and Finder thumbnail extensions.
- Tidy and section commands, split view, compare, export, and copy as
  Markdown or rich text.
- Keyboard commands with editable bindings and full pointer interaction.
- JSON themes, shipped light and dark themes, and VS Code/Shiki import.
- Accessibility support for VoiceOver, Reduce Motion, Increase Contrast, and
  Reduce Transparency.

## Explicit boundaries

Downright is not a vault, sync service, collaboration tool, plugin host,
notebook, code runner, or rich-text editor. It does not execute code. It does
not target Windows, Linux, iOS, or the Mac App Store in 1.0. It does not add
backlinks, graph views, tags, or a document database.

## Release and success measures

Downright ships as one finished 1.0, distributed outside the Mac App Store,
with source under the MIT licence. Internal phases are build order, not public
release gates.

The product is ready when the feature matrix is complete, the acceptance tests
pass, and the performance budgets in [Docs/PERFORMANCE.md](Docs/PERFORMANCE.md)
pass on supported hardware. A green test command that runs zero tests is not a
pass.
