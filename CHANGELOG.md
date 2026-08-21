# Changelog

All notable changes to Downright are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Version truth lives in a single place — `Config/version.env` — and every
consumer (Xcode project, bundle scripts, the `down` CLI) is verified against it
by `Scripts/sync-versions.sh`. `CFBundleVersion` increases monotonically with
every release; Sparkle orders updates by it.

## [Unreleased]

### Fixed

- Stopped idle history maintenance from rewriting every unchanged index, made
  long-session pruning half-hourly, and added mounted-volume-aware collection
  of stale history and reading-state files.
- Bounded external-change undo history and moved path-existence rechecks to a
  background cache warm so long-lived, frequently rewritten documents cannot
  grow memory indefinitely or stall the main thread on filesystem checks.

- **Made saves fail closed around external file activity.** Downright now
  distinguishes unchanged, changed, missing, and unreadable disk state; an
  implicit save can no longer recreate a deleted file, swallow an atomic
  replacement, or overwrite a generation that arrived at the save boundary.
  Recovery offers explicit Save a Copy, Recreate File, Discard, and Cancel
  choices, and preserves byte-level encoding and line-ending fidelity.
- **Made Quick Look reads bounded under replacement races.** Preview and
  fallback paths now enforce their byte ceiling on the read itself even when
  a file grows or is atomically replaced after its metadata was inspected.
- **Kept large external rewrites off the typing path.** Revision-checked
  background parsing and incremental TextKit commits preserve selection and
  scroll anchors while bounded real-window frame gates cover 10k–50k-line
  documents, IME composition, split view, and concurrent scrolling.
- **Repaired browser-rich paste boundaries.** HTML, WebArchive, RTF, and RTFD
  imports preserve useful paragraph, list, table, code, and link structure
  without guessing at unsupported image or vendor payloads.
- **Fixed a crash on ordinary prose.** Any document containing a one-character
  word before `:digits` — "John 3:16", "meet at 9:30", `` `a:1` `` — fatally
  trapped the path-token scanner during the per-keystroke reparse.
- **Fixed code-fence recovery.** A closing fence may now carry trailing spaces
  or tabs (legal CommonMark) instead of being swallowed into the code content,
  and a same-character run shorter than the opening fence inside an unclosed
  longer fence is content, not a phantom closer.
- **Fixed footnote recovery inside fenced example code.** The source scanner
  no longer ends a fence on an info string (` ```ruby ` inside ` ```` `), which
  used to leak footnote-looking lines out of code blocks.
- **Fixed section moves in mixed-ending files.** `moveSection` now recognizes
  terminators by width and preserves the separator's exact bytes; a CRLF blank
  separator used to be invisible to the walk, gluing the moved sections
  together. Table realigns and list looseness are width-aware for the same
  reason, and re-levelling a setext heading keeps its emphasis and code
  markers instead of the plain-text title.
- **Closed a stored-XSS hole in HTML export.** Wikilink targets now pass the
  same scheme allowlist as ordinary links: `[[javascript:alert(1)//]]` used to
  export as a live `javascript:` URL (the `.html` suffix sits behind a `//`
  comment, so it did not neutralize the payload).
- **Fixed `down export`.** Multi-line paragraphs and code blocks exported as
  one line of visible `\n` garbage; the writer now emits real newlines.
- **Fixed a main-thread freeze in the image lightbox.** Remote (and large
  local) images now decode off the main thread; a slow server no longer hangs
  the app inside the click handler.
- **Fixed watcher events after close.** A file-watcher event already in flight
  when its document closed scheduled one more external-write pass on the
  closed document; and an in-place link hop whose target vanished mid-flight
  now reopens the previous document instead of leaving a window that no longer
  tracks external writes.
- Hardened the release chain: the Apple API key and Developer ID certificate
  materialize under `mktemp`/`RUNNER_TEMP` instead of fixed `/tmp` paths, the
  Sparkle key ceremony no longer runs a binary discovered by globbing `/tmp`,
  the ephemeral signing keychain is deleted on every path, and CI/release
  install a checksum-pinned `xcodegen` (2.46.0) instead of a floating Homebrew
  head, shipping its SettingPresets alongside the binary so the generated
  project keeps `ONLY_ACTIVE_ARCH=YES` (a binary-only install dropped it and
  made the acceptance build fail on universal app extensions).
- **Fixed a workspace-sidebar crash on colliding filenames.** The link graph
  keyed files by a normalized path that folds `a\b.md` into `a/b.md` (and a
  hidden `.x.md` into `x.md`); `uniqueKeysWithValues` trapped on the first
  duplicate. Lookup is now collision-tolerant and prefers the already-normalized
  path deterministically.
- **Fixed "Allow for Folder" over-granting on a directory.** Consenting from a
  directory token stored the directory's *parent*, authorizing every sibling;
  a directory target now grants itself, and revoke targets the same folder.
- **Fixed trust grants silently revoking earlier ones.** A second grant for the
  same path replaced the first instead of extending it, so folder-read and
  editor-launch kept ping-ponging; grants now union their effects.
- **Fixed a hard-wrap reflow overrun on stale documents.** The
  continuation-indent walk indexed the buffer by an unclamped paragraph range
  and could read one character past the end after an external rewrite; it now
  clamps to the buffer length.
- **Fixed agent hook install/uninstall matching the command only.** A foreign
  `PostToolUse` entry that runs `down notify` under another matcher used to
  block a needed install and be deleted by an uninstall; both now match on
  matcher and command together.

### Added

- **Calm, explicit document trust states.** The toolbar now communicates
  Edited, Saving, briefly Saved, Changed on disk, Conflict, and Save failed,
  with accessible labels and focused mutation provenance such as Paste,
  Toggle Task, Replace, panel actions, and Undo.
- **Contents / Outline is a first-class command.** It is visible in the
  toolbar and overflow menu, remains available through View, the command
  palette, accessibility, and configurable keybindings, and reuses the
  pinnable inspector rather than adding a permanent sidebar.
- **Universal clipboard flavors.** Copy now publishes lossless private
  Markdown, plain text, RTF, and sanitized semantic HTML so native and browser
  targets retain headings, lists, emphasis, links, tables, and code structure.
- **Safe native rendering for common README HTML.** Presentational paragraphs,
  headings, emphasis, links, local images, line breaks, disclosures, and basic
  tables render in Document mode without executing HTML or changing source;
  unknown and risky markup stays visible and inert.
- **First-run setup panel.** Downright now installs itself. On first launch it
  offers to become the default Markdown app and to install the `down` command
  line tool, and — with no decision to make — registers its Quick Look
  extensions with Launch Services and `pluginkit` and resets Quick Look's
  caches so existing `.md` files pick up real Finder icons. Everything here
  previously lived only in `Scripts/install.sh`, which runs for people building
  from source and for nobody else: the shipping path of download the DMG, drag
  to Applications, double-click performed none of it.
- The panel detects an app still running from a DMG or Downloads — Gatekeeper
  runs those from a randomised read-only mount where no registration can stick
  — and offers to move it into Applications and relaunch.
- **Settings → General → System integration** repeats every setup step, names
  the app currently holding the Markdown association, and opens the Quick Look
  pane of System Settings for the one switch macOS will not let an app throw.
- **Help → Take the Tour**, so the tour outlives the start window's button.
- **Recent files say what they are about.** Each row carries a second line with
  the document's first heading, so `notes.md` reads as "Agent output" and a
  folder of identically-named agent output stops being a column of
  interchangeable rows. The folder is shown behind it, or alone when there is
  no heading; neither is repeated when the two would say the same thing.
- **⌘1–⌘6 open the corresponding recent file**, with the shortcut spelled out
  once in the list header and each row carrying its own ordinal.

### Changed

- The Welcome tour now derives every displayed shortcut from the configurable
  command table, shows an honest Unassigned state, and remains accurate after
  keybinding customization.
- Development app bundles now use an isolated bundle identifier by default,
  including their Quick Look extensions, so acceptance builds cannot displace
  the installed daily-driver registration.
- **Appearance now follows macOS reliably.** Theme selection no longer
  silently disables system following, the View menu exposes separate light
  and dark palettes, and Light/Dark transitions rebuild cached TextKit
  paragraphs so old foreground colours cannot survive over the new page.
- **Find bar and Tasks panel motion pass.** The find pill now opens above the
  document without moving the page, flows outward from the toolbar lens as one
  liquid-glass body before its readable controls resolve, and grows around the
  replace row as it expands. The match count crossfades
  and its tray glides open and closed, and the invalid-regex glyph pops in on
  a small spring instead of hard-appearing. In the Tasks panel, the empty
  state dissolves as a plan's first rows slide in, and the quick-add row
  crossfades its hint into the editing field instead of swapping them.
- The find bar's **previous/next and Replace buttons park themselves** while
  there is nothing to act on — an empty query or a settled "No matches" — and
  re-arm the moment the text changes, so a control that cannot do anything no
  longer offers a click that lands nowhere.
- Right-clicking a Tasks panel **"N completed" pile** offers Show/Collapse
  Completed and Copy Status Report — the same fold the row's click performs,
  plus the report every other section surface already had.
- The floating Tasks panel's empty state was **clipped at the bottom** — the
  card was sized to a fixed minimum taller than its content, and the centered
  "Add task" button rode past the rounded lower edge. The panel now measures
  the empty chrome's full height (state, gap, button, and the bottom margin)
  so the card fits the whole thing.
- The morph flight now lands on the surface's **actual resting frame** instead
  of a freshly re-derived one, which could be a few points off and left the
  travelling glass resting slightly beside the card it was becoming — the
  "oversized grey slab" that read as a second panel behind the glass.
- The start window's headline adapts: returning users get "Pick up where you
  left off" rather than "Open a Markdown file", which restated the button
  directly beneath it and kept instructing people who had long since learned.
- The six identical document glyphs in the recents list are gone. They said
  only "these are files", which the names already said; the slot now carries
  the ⌘-number that is the fastest way out of the window.
- The recents header shows the shortcut range instead of a file count that
  restated six visible rows.
- The start window is 600pt tall rather than 576 to fit the two-line rows, and
  the no-recents placeholder is now derived from the height a full list
  occupies instead of a fixed 150pt that was already 100pt short of it.
- The welcome window's two entry actions now share one readable control well;
  drag-and-drop feedback appears only while a supported file is over the
  window, and an update failure collapses to a quiet, discoverable warning
  instead of competing with the primary actions.
- Update failures now lead with a clear "your files are safe" message, fit the
  panel to the shorter failure state, and keep technical details behind an
  explicit disclosure.
- The rolling DMG now carries a Finder-aligned install window with a hand-drawn
  background and drag-to-Applications arrangement, while retaining a valid
  headless packaging path for CI.

- The start window's **Take the Tour** button now retires: immediately once the
  tour has been opened, and after three launches regardless. It was permanent,
  which is a standing admission that the app needs explaining and a wasted slot
  on the one screen where the user is trying to reach their work.
- Only `.md`, `.markdown`, `.mdown`, and `.mkd` are claimed as defaults.
  `.mdx`, `.qmd`, and `.rmd` belong to toolchains people have already chosen,
  and are left to them; the bundle still declares them so Downright appears
  under Open With.
- Finder thumbnails are drawn as **pages rather than squares**, from a fixed
  sRGB palette, with task progress shown as a bar. Below 72pt they draw ruled
  lines instead of text that would only be a smudge at that size.

### Fixed

- The circular Find control no longer leaks a rounded-square hover plate. The
  Tasks panel again uses a transparent native child compositor, so it refracts
  the document instead of reading as an opaque grey card, and its close target
  now consumes the click before the editor can receive it. Density-map previews
  inherit the exact resolved Light/Dark appearance of their document window.
- Opening Find and local document edits preserve the same pixel viewport after
  AppKit performs its delayed caret and focus scroll repairs.
- Removed the obsolete surrogate morph vessel and inspector-unfurl pipeline;
  the real floating glass surface now owns its animation and resize retargeting.

- Quick Look and the Markdown file association silently broke whenever the app
  was **moved or renamed** — Launch Services and `pluginkit` both record an
  absolute path. Downright records where it last registered and re-registers
  when that changes.
- Finder thumbnails only ever showed **one line of title and one line of body**
  regardless of how much page was left. A paragraph style set to
  `.byTruncatingTail` does not wrap; it lays the whole string on one line and
  clips it.
- Multi-line thumbnail text rendered in **reverse line order**, because
  `NSLayoutManager` lays out top-down and the glyphs were drawn into an
  unflipped context.

## [1.0.0] - 2026-08-07

The initial release of Downright: a local-first Markdown editor for macOS that
treats the file on disk as the single source of truth.

Nothing shipped before this, so the Changed, Removed, and Fixed entries below
record work against the pre-release development builds rather than against a
published version.

### Added

#### Application

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
- Regression probes locking the mermaid text orientation against the library's
  known-good render path (`MermaidOrientationProbeTests`, `GeometryProbeTests`).

#### Distribution and release engineering

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
  `.rmd`** — the exported `com.ezzy.downright.markdown` UTI is declared
  in both extension bundles.
- **CI gates the §12 performance budget**: `ci.yml` runs `drbench` in release
  with budgets enforced (`RUN_DRBENCH=1`).

### Changed

- **The Tasks panel comes out of the ring that opens it.** The panel unfurls
  downward from the top edge — scaled from its own top, so it grows *away* from
  the toolbar control rather than out of its middle — and folds back up as the
  pane gives its width to the document, instead of blinking out of existence.
  The ring's press belongs to the circle now: the glyph has its own layer, so it
  compresses and springs back while the plate underneath holds still, and the
  release wave carries further on the same clock the panel unfurls on.
- **The titlebar proxy is a real document proxy.** It wears the file's own icon
  instead of a generic `doc.text` symbol, and dragging it hands the file to
  Finder, Mail, or anything else under the pointer.
- **The inspector header only carries a section switcher when there is
  something to switch to.** A lone panel gets a slim title-plus-close row
  instead of a one-segment tab strip; the Search/Tasks/History/Inspector
  segments appear once a second surface actually opens. Hovering the task
  panel's section bar no longer swaps the tally for the same sentence about a
  section — the meter holds still; a click still scrolls. The Tasks toolbar
  ring presses with its own shape now: the glyph dips, springs back with an
  overshoot, and emits one quiet accent ping as the panel's content rises in.
  (Superseded above: the press now lives on the glyph's own layer.)
  The density rail's marks sit closer together (7–11pt pitch, from 8–13) with
  the stack ceiling raised to match, so a tall window keeps the same cluster
  share.

- **The Tasks panel is rebuilt around the plan, not the checkboxes.** The old
  header (percent figure, count caption, progress bar, All/Open filter) is
  replaced by a section-map progress bar — one segment per heading, sized by
  task count, filled by completion, clickable to jump to a section — with the
  tally riding at the bar's trailing end. The list answers "what's next" by
  ordering, not by a duplicate hero card: it is **open-first**, so the next
  task is simply the first row, and finished work collapses into a per-section
  "N completed" pile instead of a wall of struck-through rows. Completion
  itself is a moment — haptic, drawn check, strike sweep, then the row slides
  into the pile — followed by an **Undo pill**, because a tick that writes the
  file immediately deserves an equally immediate way back. The panel is
  two-way: **quick-add** rows (or ⌘N) insert `- [ ] …` into the right section
  of the source, and **drag reorder** moves a task among its siblings with its
  nested children riding along, both as plain undoable source edits
  (`Restructure.insertTask` / `moveTask`). Section headers carry their
  remaining count and fold; rows get a context menu (Jump to Source, Mark
  Complete, Copy Task, **Copy Status Report** as ready-to-paste Markdown); and
  Space / Return / ←→ work the whole list from the keyboard.

### Removed

- **The Contents / Outline navigator, and the leading sidebar it pinned into.**
  The density rail already expands into the document's outline on hover, and the
  command palette already opens headings and files through its Quick Open
  providers — a third list of the same two things, reachable from a toolbar
  button, two View items and a Navigate item that all ran the same code, was the
  document's structure told three times. `⌘⇧K` is the one way in. The window is
  now document-plus-inspector, and `NavigationPanelView`, `OutlinePanelView`,
  `SiblingSidebarView`, the `.outlinePanel` / `.toggleSidebar` /
  `.outlineQuickOpen` commands and the "Keep the sibling sidebar open"
  preference are gone with it.

### Fixed

- **Closing the find bar crashed the app.** The exit animation removed the pill
  from its superview and *then* called `removeArrangedSubview(_:)`. The first
  call already un-arranges the view, so the second raised out of
  `-[NSStackView _removeView:animated:removeFromViewHierarchy:]` and aborted the
  process — every single time ⌘F's bar was dismissed with motion enabled.
  Retirement is now ordered and idempotent, so a repeated Escape during the
  0.16 s fade is harmless too (regression-pinned).
- **The page teleported out from under the caret while typing.** Any parse
  commit that was not a local edit — a debounced second parse, an external
  change, a theme or measure change — restored the reading position by
  scrolling a source offset to `.top`, which parks that line at the container
  inset no matter where the reader actually had it. Every commit therefore shoved
  the page by the leftover fraction of a line plus the inset, and a queued
  scroll-repair could apply an anchor from several edits earlier. Viewport
  restores now keep the pixel gap between the viewport's top edge and the anchor
  line, a scroll repair can never resurrect a stale anchor, and a frame shrink
  pins the anchor across the clamp (regression-pinned).
- **The caret could land in the empty air above a fenced block.** The fence
  lines are kept in the storage on purpose, but in Document mode their glyphs
  are suppressed — so a click in the block's top padding resolved to a character
  part-way along an invisible ```` ```swift ````, leaving the caret blinking over
  nothing and the next keystroke editing a fence the reader could not see. A
  plain click on either chrome row now aims at the code.
- **The window never remembered its size.** `setFrameAutosaveName` restores the
  saved frame the moment it is assigned, and the default content size ran
  unconditionally straight afterwards and threw it away — including for a window
  left in full screen.
- **A window could come back blank from the Dock or from full screen.** TextKit 2
  lays out against a viewport it is told about, and those transitions change the
  bounds without a scroll gesture. The document surface is now re-primed on
  de-miniaturise, on both full-screen transitions, and on a backing-property
  change.
- **Opening the Tasks panel shrank the whole window.** The fit-to-content
  "card" the panel floated in was sized by a required Auto Layout height
  chain, and AppKit's constraint-driven window sizing
  (`_changeWindowFrameFromConstraintsIfNecessary`) resized the window frame to
  the card's height — the window collapsed to ~490pt and never grew back. The
  inspector is now a docked full-height column like every other panel, and the
  fit-to-content machinery is gone with the card.
- The status bar rendered its format strings literally (`\(prefix)Ln
  \(line), Col \(column)`) — two escaped interpolations left over from a
  refactor now show real values again.
- The History inspector's timestamp caption ran under the Restore button at
  the inspector's minimum width; it now truncates inside the timeline's track.
- **Math rendered only on the machine that built the app.** SwiftMath reached
  its fonts through SwiftPM's generated `Bundle.module`, whose two candidates
  are the bundle *root* (where codesign forbids resources) and an absolute path
  inside the build directory — so a shipped bundle found neither and the
  accessor called `fatalError`, taking the whole Quick Look preview down with
  the first formula. SwiftMath 1.7.3 is now vendored at `Vendor/SwiftMath` with
  a three-line patch that resolves the fonts from the layouts we actually ship
  (`Vendor/SwiftMath/PATCHES.md`). `MathFontBundle` still guards every call as
  defence in depth, and `Scripts/verify-bundle.sh` now asserts the fonts in the
  host app as well as in each `.appex`.
- An implicit save could silently clobber a newer on-disk version after an
  external edit (occlusion autosave, quit, checkbox toggle): saves are now
  refused until the user resolves the conflict, and only an explicit
  "keep mine" decision writes over the file.
- FSEvents retransmissions of the same external write were reported repeatedly
  while an external write racing a save could be swallowed; both cases are now
  handled by the suppression window logic in `FileWatcher`.
- **Clicking the Tasks toolbar button crashed the app.** `TaskWorklist` trusted
  each task's `headingIndex` as a live subscript into `headings`, but the panel
  rebuilds on every keystroke and can pair a task array captured one parse
  earlier than the headings it arrives with — the out-of-range subscript was an
  `Index out of range` trap. An out-of-range heading now degrades to the
  "Document" section instead of taking the app down (regression-pinned).
- **An hourglass sliver haunted the task panel's section-map bar.** A segment
  with nothing done gives its fill layer a zero-width frame, and Core
  Animation still rasterises a capsule corner radius on an empty layer — the
  two semicircles met as a tiny bowtie of accent colour in the gap between
  segments. Empty fills are now hidden outright in both bar implementations.
- **Clicking a link, footnote, task, or heading teleported the camera.** Every
  in-document jump scrolled with `position: .center`, which recentres the page
  even when the target is already on screen — yanking whatever you were reading
  out from under the pointer. Navigation now uses `.visible`: a target already
  in view doesn't move the page at all, and an off-screen target gets the
  minimal scroll that brings it in. Back/Forward keep `.center` because they
  restore a *recorded* reading position.
- **Stray shading blocks beside and below code blocks.** TextKit 2 composites
  each layout fragment as an independent, lazily-rendered surface, and the code
  block's closing fence claimed a tinted surface taller than its own band (to
  make room for its copy control) — a fill that reached past the block's edge
  and wasn't always painted over when the neighbouring fragment didn't redraw in
  the same pass. The band now paints exactly its own frame: header and footer
  round only their *outer* corners, the edges they share with code lines are
  square and butt flush, and the footer's copy control collapses to fit its thin
  band instead of forcing the fill to overhang (geometry regression-pinned).
