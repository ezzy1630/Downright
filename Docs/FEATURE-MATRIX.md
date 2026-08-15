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
| Workspace | Optional folder tree, local index, search, links, and backlinks | P7 | One file works without workspace |
| Workflow | Tidy, move/promote/demote, split, compare, export | P6 | Commands preserve source invariants |
| Smart Paste | URL, HTML, TSV, code-safe plain text | P3 | One reversible source edit |
| Front matter | Visual fields with exact source fallback | P3 | Unknown fields and formatting survive |
| Asset Doctor | Find, relink, copy, rename, optimise, and inspect assets | P3/P5 | Actions preview their source changes |
| Document Lens | Structure, health, links, assets, tasks, and changes | P4/P5 | A selection maps to an exact source range |
| Document Health | Structure, access, references, links, media, syntax, prose | P5 | Stable findings and safe local fixes |
| Render Targets | Built-in and custom renderer profiles | P5 | Exact findings and reversible proposals |
| Review | Local comments, suggestions, and resolved state in sidecars | P6 | Markdown stays clean; stale anchors are visible |
| Reader profiles | Saved typography, width, chrome, and motion sets | P4/P10 | Profiles do not change source |
| Visual Debugger | Source range, AST block, style, target, and asset state | P5 | A render element explains its inputs |
| Command palette | Searchable actions, keys, scope, and recent use | P4 | Every action has one command owner |
| Trust | Per-file and per-folder link, asset, and automation trust | P7/P8 | Untrusted content cannot cause an external effect |
| Quick Look | Preview and thumbnail extensions | P2 | Preview meets time and memory limits |
| Themes | JSON themes, warm light/dark, VS Code/Shiki import | P7 | Theme reload changes semantic tokens |
| Preferences | Appearance, typography, editor, keys, advanced | P8 | Settings round-trip and apply live |
| Accessibility | VoiceOver, keyboard, contrast, motion, transparency | P8 | Accessibility audit has no release blocker |
| CLI | `down` and `md` open files and stdin | P8 | Terminal launch opens the target document |
| System integration | Quick Look, unopened-file Spotlight metadata, Services, Share, App Intents | P8 | Each entry opens or indexes the exact file or command |
| AI | Optional on-device Apple Intelligence tools only | P9 | Core path works with AI absent or disabled |

## Explicitly out of scope

| Feature | Decision |
|---|---|
| Required vault or global content database | Excluded; files and optional folder workspaces are equal entry points |
| Cloud graph or social knowledge network | Excluded; local workspace links and backlinks are allowed |
| Sync, collaboration, multiplayer | Excluded |
| Plugin system or marketplace | Excluded |
| Code execution, shell, notebook evaluation | Excluded |
| Cloud AI or required account | Excluded for 1.0 |
| Windows, Linux, iOS, Mac App Store target | Excluded for 1.0 |
| Reverse editor integration | Deferred; one-way path opening is enough |

## Full phase matrix

| Phase | Scope | Exit gate |
|---|---|---|
| P0 | Baseline, product docs, source contracts, tests, performance gates | Byte identity and test execution are proven |
| P1 | Complete and verify the current reader and UI plan | The existing surface has no known release blocker |
| P2 | Correctness, concurrency, incremental render, large-file policy | Typing stays under budget; stale work cannot commit |
| P3 | Smart Paste, visual tables, front matter, assets, Source mode | Each tool creates one safe source edit and one undo step |
| P4 | Navigation, command palette, reader profiles, Document Lens | Large documents are direct to inspect and move through |
| P5 | Document Health, Render Targets, Asset Doctor, Visual Debugger | Findings have exact ranges, clear reasons, and safe proposals |
| P6 | Review sidecars, suggestions, and history | Review state stays local and never pollutes Markdown |
| P7 | Optional folder workspace, local links, backlinks, search, trust | A single file stays first class |
| P8 | Quick Look, Spotlight, Services, Share, App Intents, CLI, updates | Native entry points share safe command owners |
| P9 | Optional on-device Apple Intelligence tools | AI never delays open, render, edit, search, or save |
| P10 | Accessibility, motion, themes, reader profiles, micro-interactions | Keyboard, VoiceOver, contrast, motion, and polish pass |
| P11 | Packaging, signing, notarisation, docs, launch verification | A clean Mac installs, opens, edits, previews, and updates safely |

Run focused tests during each phase. Run the full suite and release benchmark
at every phase boundary.

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
