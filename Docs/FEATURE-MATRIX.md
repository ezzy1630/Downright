# Downright Feature Matrix

This matrix defines the 1.0 scope. Internal phases are build order. They are
not public releases.

## Product scope

| Area | 1.0 commitment | Phase | Acceptance signal |
|---|---|---:|---|
| Platform | macOS 14+, direct download, MIT source | P8 | App launches on supported macOS |
| Source safety | Exact text, byte-stable save and copy | P0 | Round-trip corpus stays byte-identical |
| Modes | Read, Live, Source on one TextKit 2 view | P0/P3 | Mode switch keeps selection and scroll |
| Markdown | CommonMark and GFM | P1 | Parser and render corpus passes |
| Extensions | Math, front matter, callouts, wikilinks, paths, Mermaid | P1 | Extension tests pass, no false math in shell text |
| Code | Native syntax highlighting, diff fences, copy | P1/P7 | Canonical language tests pass |
| Tables | Render, wrap, numeric alignment, edit in Live | P1/P3 | Long cells remain readable and editable |
| Images | Native render, caption, lightbox | P1 | Missing image has safe fallback |
| Navigation | Outline, heading jump, folding, structural zoom | P1/P5 | Levels 1–5 preserve anchor position |
| Tasks | Grouped task panel and direct checkbox toggle | P5 | Toggle writes one source edit |
| Density gutter | Shape, changes, search, tasks, progress | P5 | Gutter state matches document ranges |
| Find | Text, regex, replace, hidden and folded text | P1/P6 | Matches map to source ranges |
| External writes | Watch, rendered diff, unread marks, conflicts | P4 | Dirty buffer never gets clobbered |
| History | Local content-addressed snapshots and timeline | P4 | Restore is undoable and local |
| Paths | Resolve document and git-root paths; open editor | P5 | Existing and missing paths are distinct |
| Workspace | Optional sibling sidebar; no vault or index | P5 | One file works without workspace |
| Workflow | Tidy, move/promote/demote, split, compare, export | P6 | Commands preserve source invariants |
| Quick Look | Preview and thumbnail extensions | P2 | Preview meets time and memory limits |
| Themes | JSON themes, warm light/dark, VS Code/Shiki import | P7 | Theme reload changes semantic tokens |
| Preferences | Appearance, typography, editor, keys, advanced | P8 | Settings round-trip and apply live |
| Accessibility | VoiceOver, keyboard, contrast, motion, transparency | P8 | Accessibility audit has no release blocker |
| CLI | `down` and `md` open files and stdin | P8 | Terminal launch opens the target document |
| AI | Optional on-device Apple Intelligence only | P4/P8 | Core path works with AI unavailable |

## Explicitly out of scope

| Feature | Decision |
|---|---|
| Vault, graph, backlinks, tag database | Excluded |
| Sync, collaboration, multiplayer | Excluded |
| Plugin system or marketplace | Excluded |
| Code execution, shell, notebook evaluation | Excluded |
| Cloud AI or required account | Excluded for 1.0 |
| Windows, Linux, iOS, Mac App Store target | Excluded for 1.0 |
| Reverse editor integration | Deferred; one-way path opening is enough |

## Full phase matrix

| Phase | Scope | Exit gate | Estimate |
|---|---|---|---:|
| P0 | TextKit 2 spike, parser, attribute-only styling, keystroke benchmark | Byte identity proven; 8 ms p95 decision made | 1 week |
| P1 | Render core and Read mode; GFM, extensions, code, math, images, find | Render corpus and first usable reader | 4 weeks |
| P2 | Quick Look preview and thumbnail with memory limits | <400 ms and <60 MB preview target | 2 weeks |
| P3 | Live mode; caret reveal, gutter markers, popovers, tables, paste | Typing and IME behave without layout jumps | 5 weeks |
| P4 | AI-adjacent file layer; watcher, diff, unread, snapshots, conflicts | External writes are reviewable and safe | 3 weeks |
| P5 | Navigation and structure; zoom, gutter, outline, tasks, paths, siblings | Large document navigation is direct | 3 weeks |
| P6 | Commands and workflow; tidy, restructure, split, compare, search, export | Source edits preserve ranges and undo | 3 weeks |
| P7 | Visual system; themes, import, dark mode, motion, print | Theme and accessibility visual pass complete | 3 weeks |
| P8 | Release engineering; preferences, keys, CLI, audit, notarise, docs | Release checklist and package complete | 3 weeks |

Approximate total: 27 weeks of committed part-time work. Run focused tests and
the release benchmark at every phase boundary.

## UI refinement sequence

The UI plan has a second sequence for visual and interaction refinement. It
fits inside the product phases above and does not change the 1.0 scope.

| Sequence | Work | Exit gate | Estimate |
|---|---|---|---:|
| A | Verified visual defects: lists, spacing, code, callouts, themes | Defect list has a test or documented reason | 3 days |
| B | List ornaments, heading scale, rhythm, optical margins | Golden render cases pass | 1 week |
| C | Code, tables, callouts, inline elements, front matter, images | Long content stays readable | 1.5 weeks |
| D | Toolbar, sidebar, breadcrumb, inspector, find bar | Chrome has one owner and stable state | 2 weeks |
| E | Density gutter and keyboard equivalent | Rail agrees with document structure | 1 week |
| F | Motion system, spring zoom, Reduce Motion | Motion budgets and accessibility checks pass | 1 week |
| G | Themes, preferences, and launch state | Settings preview and recent-file start state work | 1 week |
| H | Hard-wrapped paragraph reflow | Source ranges and caret mapping stay exact | 1–2 weeks |
