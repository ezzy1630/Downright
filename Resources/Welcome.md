# Welcome to Downright

This document is the tour. Everything it describes is happening on this page
while you read it.

Downright opens a Markdown file, renders it, and lets you edit the same text in
place. This is not a preview of something else. The words below are the file.

## The strip down the left edge

That narrow lane is the density gutter, and it replaces the scrollbar. It draws
the shape of the document: heading levels, code, tables, tasks, search hits, and
anything that changed while you were reading. Drag it to move through the file.

The marks you can see now are the headings below. You are looking at the map and
the territory at the same time.

## Structural zoom

Press {{shortcut:zoomLevel1}}. The document collapses to its top-level headings.
{{shortcut:zoomLevel2}} adds the level under those. {{shortcut:zoomLevel5}}
brings everything back.

Nothing is removed from the file, only from your eye. Use it on a long document
when you want the argument before the detail.

## Editing, without changing surfaces

Click into this paragraph and type. The markers for the word you are in appear,
and only those. Nothing else on the page moves.

Press {{shortcut:sourceMode}} for Source Focus: the whole document becomes plain Markdown with line
numbers, and Done brings you back. The caret keeps its place in both directions,
and the file keeps its bytes.

## What a document is made of

A table:

| Press | What happens |
| --- | --- |
| {{shortcut:commandPalette}} | Command palette, for anything you cannot remember |
| {{shortcut:taskPanel}} | Tasks |
| {{shortcut:nextHeading}} | Jump to the next heading |

A task list. Click a box — it edits one character of the file, and undo puts it
back:

- [x] Open a Markdown file
- [ ] Press {{shortcut:zoomLevel1}}, then {{shortcut:zoomLevel5}}
- [ ] Drag the gutter
- [ ] Tick this box

Code, fenced and highlighted:

```swift
func greet(_ name: String) -> String {
    "Hello, \(name)."
}
```

A callout, of the kind agents write constantly:

> [!NOTE]
> A blockquote that opens with a marker becomes a panel. NOTE, TIP, WARNING and
> a dozen others are recognised, in any casing.

And a path: `Sources/MarkdownCore/Parser.swift`. Downright checks whether a path
written in a document exists. One that does opens in your editor when you click
it. One that does not is underlined, which is the point.[^paths]

## When something else writes the file

Leave a file open, let an agent edit it, and come back. The changed regions are
marked in the text and in the gutter, and {{shortcut:nextChange}} walks through
them one at a time.

Every outside write is snapshotted first. {{shortcut:versionTimeline}} opens the version timeline, so a
change you did not want is a change you can take back.

> [!TIP]
> None of this needs an account, a server, or an AI service.

## Where to go next

Settings ({{shortcut:preferences}}) has focused panes and a search field. Keys is where every shortcut
printed here can be changed — these are only the defaults.

You can close this document whenever you like. It is a copy, opened from a
temporary folder, so nothing you do to it touches your own files.

[^paths]: A wrong path is the cheapest thing to write and the most expensive
thing to find later.
