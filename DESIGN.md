# Downright Design

## Design character

Downright should feel calm, exact, and fast.

- Calm means the document is the focus. Chrome appears when needed.
- Exact means the source, layout, and change state agree.
- Fast means the app responds before the user questions the action.

Preview informs the quiet document surface. Xcode informs source-aware tools,
inspectable states, and precise navigation. Things 3 informs task grouping,
clear hierarchy, and low-friction completion. These are reference qualities,
not visual copies.

## Surface model

Use one adaptive document surface. Idle content is rendered and writable. A
caret reveals only the local markers needed to edit. A non-empty selection is
observation, not edit intent, so selection never changes presentation. Context
actions can reveal one flat, monospaced source region. Source Focus is a
transient full-document state with line numbers and an explicit Done action.

All presentations share one source buffer and preserve scroll and selection.
Pointer actions remain live: select, follow links, tick tasks, fold sections,
and drag the density gutter.

## Layout

- Keep a readable measure of about 68–72 characters.
- Use a single document column with generous side space.
- Keep the toolbar unified and quiet. Show Source Focus chrome only while it
  is active.
- Treat the titlebar band, find bar, and emphasized toolbar capsules as one
  chrome-glass material family. Focus belongs to the containing surface, not
  to a second field bezel nested inside it.
- Use summonable panels for outline, tasks, find, history, and siblings.
- Align breadcrumb, gutter, and document text to the same text column.
- Use a folder workspace only when the user opens or asks for it. Do not show
  a vault, graph, or permanent file index.

The density gutter replaces the normal scrollbar with document shape: heading
levels, code, tables, tasks, search hits, changed regions, and progress.

## Typography and colour

- Reading preset: New York. Working preset: SF Pro Text. Code: SF Mono.
- Use a modular scale for headings. H1–H4 carry size; H5–H6 use treatment,
  tracking, and weight.
- Use a fixed baseline grid and optical hanging punctuation.
- Use a warm paper light theme and a warm dark theme. Do not invert light
  colours into dark mode.
- Use semantic theme tokens. Do not place raw colour literals in render code.
- Use subtle code tint and a left rule, open tables, coloured quote rules, and
  restrained image shadows. Avoid heavy cards and decoration.
- Check body text for WCAG AA contrast. Respect Increase Contrast.

## Motion and feedback

Use one motion system. Standard durations are 0.12 s, 0.20 s, and 0.32 s.
Use spring motion for structural zoom and a short fade-up for first layout.
Hover, copy, task, and change states need clear feedback. User scroll must
interrupt animated scrolling. Reduce Motion disables non-essential movement.

Do not move the caret when local editing reveals syntax. Do not change line height
because the caret entered a span. A stable layout is more important than a
clever transition.

## AI and change review

AI is optional and secondary. The main review tools are rendered diff,
unread-since-last-read, local snapshots, and a non-modal dirty-buffer conflict
bar. Use plain labels: Review, Keep Mine, Take Theirs.

Optional on-device Apple Intelligence actions operate on selected local text.
They do not block document work, hide changes, or write without a clear user
action.

## Interaction rules

- Prefer direct manipulation over modal steps.
- Keep names and commands stable across menus, toolbar, and key settings.
- Give every action a pointer path and a keyboard path where it saves time.
- Make missing files, external writes, and unsaved edits visible without alarm.
- Keep destructive actions reversible where possible.
- Preserve exact source on undo and save. Standard Copy exports visible text;
  a private Markdown flavour preserves lossless internal paste, and Copy as
  Markdown remains explicit.

## Jane Street house style

Design and implementation use explicit ownership and small effect boundaries.

- Give each panel and controller one clear owner.
- Keep pure layout and policy helpers separate from AppKit effects.
- Represent states with typed values, not string flags.
- Use one source of truth for commands, menus, and key bindings.
- Keep lifecycle pairs symmetric: start/stop, add/remove, show/hide.
- Use references for continuous values such as the active document and scroll
  anchor; do not capture stale values in long-lived callbacks.
- Test behavior at boundaries: dirty buffers, external writes, hidden markers,
  zoom, folding, find, and accessibility settings.

## Avoid

Do not add a chat sidebar, permanent status bar, rich-text document model,
plugin marketplace, sync layer, graph view, or decorative gradients. Do not
trade byte identity or typing latency for visual effects.
