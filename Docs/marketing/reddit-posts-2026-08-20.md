# Reddit posts: next round

These posts are deliberately different. The first is a visual maker post for general Mac users. The second is a technical discussion for Mac developers. Do not publish them back to back.

## r/IMadeThis

Recommended window: Thursday, August 20, 2026, 8:00-10:00 AM Pacific. Publish only when there is time to answer comments for the next two hours.

Use `reddit-editor-showcase.png` as the image.

### Title

I made a free, open-source Markdown editor for Mac that leaves your files alone

### Body

Downright opens normal `.md` files wherever they already live. There is no library to import, account to create, or sync service to trust. It works offline and has no telemetry.

I built the renderer with AppKit and TextKit 2, not a web view. It has document and source modes, Quick Look and Finder thumbnails, themes, math, Mermaid, tables, footnotes, task lists, and syntax highlighting.

It is free, MIT licensed, and runs on macOS 14 or later.

Download: https://downright.cc/

Source: https://github.com/ezzy1630/Downright

The part I am still working on is how quickly a new user understands the switch between the rendered document and raw source. I would be interested in what feels obvious, and what does not.

## r/macosprogramming

Recommended window: Friday, August 21, 2026, 8:00-10:00 AM Pacific.

### Title

Building a native Markdown renderer with TextKit 2 instead of a web view

### Body

I have been building Downright, a free MIT-licensed Markdown app for macOS. The constraint was simple to state: the rendered document should feel native, but the file on disk must remain exact Markdown.

The hard part was separating parsing from decoration. A web view gives you layout quickly, but it changes the interaction model and makes source-range behavior awkward. With TextKit 2, I parse the source into a block index, preserve source ranges, then decorate the presentation without treating the rendered view as the canonical document.

A few decisions that ended up mattering:

- The raw source remains authoritative.
- Links, tasks, tables, math, Mermaid, footnotes, and code blocks are decorations over known ranges.
- Quick Look and Finder thumbnails reuse the same rendering model.
- External saves are watched at the parent directory because many tools replace a file through an atomic rename.
- Dirty local edits are never overwritten automatically.
- Performance budgets run in CI so large Markdown files do not quietly regress.

I wrote up the architecture here: https://downright.cc/engineering/

The source is here: https://github.com/ezzy1630/Downright

For anyone who has shipped a TextKit 2 document app: where did you draw the boundary between the text model and interactive attachments?

## r/opensource concept

Do not submit this text. The community's current rules say all AI-generated content is ban worthy. Rewrite the idea personally, use the Promotional flair, disclose that you made the project, and stay available for the discussion.

### Suggested title

I wanted a Markdown app that did not own my files, so I made one free and MIT licensed

### Suggested structure

Start with the specific frustration: Markdown apps that require an import, library, vault, account, or sync system. Explain that Downright instead opens ordinary files in place. Mention the native AppKit and TextKit 2 implementation, offline operation, no account or telemetry, and the MIT license. Keep the feature list short. End with the real maintenance question: what should a small desktop project automate first once releases and compatibility testing begin taking serious time?
