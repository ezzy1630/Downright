# Downright Repository Guide

This file contains Downright-specific context, invariants, and evidence gates. Follow any applicable higher-level instructions as well.

## Project Model and Live State

- Downright is a native macOS 14+ Markdown reader/editor built with AppKit and TextKit 2. It is local-first and source-preserving.
- The main boundaries are `MarkdownCore` for parsing and source edits, `MarkdownRender` for TextKit presentation, `DownrightApp` for windows/files/actions, `DownrightQL` and `DownrightThumb` for Finder, Spotlight targets for metadata, and `down` for the CLI.
- This checkout is the native app. `/Volumes/Neural/downright-website` is the Astro site; `/Volumes/Neural/product-downright` is a separate product/media workspace. Do not substitute one for another.
- Source, SwiftPM bundles, Xcode bundles, `/Applications/Downright.app`, Finder extensions, mounted DMGs, and public releases are distinct surfaces. Name the surface in scope before changing or validating it.
- Treat this file as durable policy, not a status page. Never rely on hard-coded SHAs, branch divergence, version/build numbers, test counts, benchmark results, release tags, download totals, or installed-app identity.
- Resolve volatile state at task start from its live authority:
  - checkout: `git status --short --branch`, `HEAD`, and refreshed upstream state when current upstream truth is required;
  - local version/build: `Config/version.env`;
  - current tests and budgets: the relevant scripts’ fresh output;
  - public release/update state: the live GitHub Release, DMG/checksum, and Sparkle appcast;
  - running app state: exact bundle path, `Info.plist` version/build, executable identity, and process path.
- If live verification is unavailable or intentionally skipped, label conclusions snapshot-only. If this or a nested instruction file changes during the task, reread the applicable instructions before continuing.
- When a change alters an architectural, validation, privacy, or release contract named here, update this file and the relevant project documentation in the same change. Do not append dated status snapshots.
- Consult the relevant contract before changing behavior: `PRODUCT.md`, `DESIGN.md`, `Docs/ARCHITECTURE.md`, `Docs/QUICKLOOK.md`, `Docs/PERFORMANCE.md`, or `Docs/RELEASE.md`. `project.yml` is the XcodeGen source; `Config/version.env` is the canonical version/build source. Report conflicting guidance rather than silently choosing one.

## Product Invariants

- Raw Markdown bytes on disk are authoritative. Rendering, hidden syntax, reflow, attachments, Quick Look, and presentation state must not rewrite the document.
- Source UTF-16 positions are canonical. Route source/display conversions through `DisplayMap`; never reuse a TextKit/display offset as a source offset.
- Preserve selection, undo, revision convergence, and a semantic source/reading anchor for operations expected to preserve position. Explicit navigation may move to its target; verify both the target and post-navigation anchor.
- Keep the one-TextKit-2-surface architecture unless the task explicitly changes that contract. Incremental typing must not cause a whole-document rebuild; length-changing edits must invalidate all shifted ranges and fragments.
- Make source mutations and undo boundaries explicit. Storage, autosave, watcher, and external-write changes need focused coverage for the relevant clean/dirty states and, when applicable, atomic replacement, deletion/rename, own-write suppression, conflict/review, failure, and recovery.
- Never translate an I/O failure into “no change,” recreate a deleted file silently, overwrite source after a rendering failure, or save after the user chose Discard.
- Downright has no app telemetry and does not upload document contents. The one recurring network request a production build makes on its own is a conditional `GET` of the public appcast, carrying no identifier and reading only a version; it stops with the "check automatically" setting, and it may trigger a Sparkle check but never parses the feed or installs anything. Public acquisition means GitHub Release `.dmg` asset requests across stable and versioned DMGs; exclude Sparkle ZIP/delta requests and never describe requests as unique people or completed installs.

## Validation by Surface

- Use focused tests while iterating, then run `Scripts/check.sh` as the authoritative source gate. Do not substitute bare `swift test`; zero executed tests or a masked pipeline failure is a failed gate.
- Give concurrent checks unique scratch/build locations using the supported variables: `SCRATCH`, `TEST_SCRATCH`, `APP_ACCEPTANCE_SCRATCH`, and `SPOTLIGHT_SCRATCH`. If source, `HEAD`, or relevant outputs change during validation, discard the result and rerun on the intended snapshot.
- `Scripts/bundle-app.sh` is appropriate for host-only iteration but does not prove Finder extensions. Use `Scripts/bundle-xcode-app.sh` and `Scripts/check-app.sh` for Quick Look, thumbnails, Finder integration, or production-shaped app acceptance. Development/ad-hoc bundles do not prove production Sparkle behavior.
- When the installed app is the acceptance surface, install the intended artifact explicitly with `APP_SOURCE=... Scripts/install.sh`, stop stale Downright instances when safe, and verify bundle path, version/build, executable identity, signature, embedded components, and running process before exercising the feature.
- Use a disposable document copy for destructive editing, Replace All, task toggles, metadata, save/discard, or conflict QA. Restore task-created preferences/state afterward.
- For changed visual or interaction behavior, verify the relevant journey in the exact app: launch, first visible frame, transition, settled state, real pointer/keyboard interaction, dismissal, rapid reopen or interruption, and resize. Check only the relevant light/dark and accessibility states.
- For glass/material work, verify document sampling, crisp foreground content, no first-frame material swap, and working pointer, keyboard, focus, outside-click, and fallback behavior.
- When the report concerns clicking, caret placement, hover, drag, scrolling, or a close/checkbox control, use a real native input path. Accessibility actions, `performClick`, screenshots, hashes, and direct method calls are supporting evidence, not substitutes.
- Quick Look preview and Finder thumbnail are separate acceptance surfaces. Use the packaged installed extensions, verify current registration, test an actual Finder Spacebar preview after startup settles, and generate a fresh thumbnail. Do not infer one from the other or from `qlmanage` generation alone.
- Report performance by the layer measured: edit/storage response, parse/semantic convergence, TextKit layout, and visible frame/scroll stability are different claims. Pair performance-sensitive editor changes with the repository budgets and a real large-document exercise.

## Plans and Release Evidence

- For a numbered audit or broad implementation plan, expand grouped bullets into concrete acceptance items. Reconcile every original item and later correction as proved, explicitly approved as changed, or blocked before claiming completion.
- A push or merge to this repository’s `main` is a consequential signed-release action, including documentation-only changes. Obtain explicit authorization immediately before it. Feature-branch pushes and merged PRs are not release proof.
- For release claims, follow `Docs/RELEASE.md` and keep these states distinct: intended `main` SHA, workflow completion, version/build, GitHub Release, signed/notarized/stapled DMG and checksum, stable download URL, signed Sparkle appcast/enclosure, update availability, and installed `/Applications` bundle.
- Verify every release stage the request places in scope and label the rest unverified. “Update available” does not mean existing installations have already updated.
