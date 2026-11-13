# Downright Repository Guide

This file contains Downright-specific context, invariants, and evidence gates. Follow any applicable higher-level instructions as well.

## Project Model and Live State

- Downright is a native macOS 14+ Markdown reader/editor built with AppKit and TextKit 2. It is local-first and source-preserving.
- Boundaries: `MarkdownCore` parses/edits source, `MarkdownRender` presents TextKit, `DownrightApp` owns windows/files/actions, `DownrightQL`/`DownrightThumb` serve Finder, Spotlight targets supply metadata, and `down` is the CLI.
- This checkout is the native app. `/Volumes/Neural/downright-website` is the Astro site; `/Volumes/Neural/product-downright` owns product/media work. Do not substitute these repositories.
- Source, SwiftPM bundles, Xcode bundles, `/Applications/Downright.app`, Finder extensions, mounted DMGs, and public releases are distinct surfaces. Name the surface in scope before changing or validating it.
- Keep durable policy here, not status snapshots, SHAs, counts, versions, or benchmark results. Resolve only state relevant to the task or claim:
  - checkout: `git status --short --branch`, `HEAD`, and refreshed upstream state when current upstream truth is required;
  - local version/build: `Config/version.env`;
  - current tests and budgets: the relevant scripts’ fresh output;
  - public release/update state: the live GitHub Release, DMG/checksum, and Sparkle appcast;
  - running app state: exact bundle path, `Info.plist` version/build, executable identity, and process path.
- If live verification is unavailable or intentionally skipped, label conclusions snapshot-only. If this or a nested instruction file changes during the task, reread the applicable instructions before continuing.
- Update the affected contract when behavior changes. Update this file only when an always-applicable invariant, evidence gate, or documentation route changes; keep feature specifications and procedures in the linked contracts.
- Consult the relevant contract: `PRODUCT.md`, `DESIGN.md`, `Docs/ARCHITECTURE.md`, `Docs/QUICKLOOK.md`, `Docs/PERFORMANCE.md`, or `Docs/RELEASE.md`. `project.yml` owns XcodeGen configuration; `Config/version.env` owns version/build. Report material conflicts; pause only dependent work.

## Product Invariants

- Raw Markdown bytes on disk are authoritative. Rendering, hidden syntax, reflow, attachments, Quick Look, and presentation state must not rewrite the document.
- Source UTF-16 positions are canonical. Route source/display conversions through `DisplayMap`; never reuse a TextKit/display offset as a source offset.
- Preserve selection, undo, revision convergence, and a semantic source/reading anchor for operations expected to preserve position. Explicit navigation may move to its target; verify both the target and post-navigation anchor.
- Keep the one-TextKit-2-surface architecture unless the task explicitly changes that contract. Incremental typing must not cause a whole-document rebuild; length-changing edits must invalidate all shifted ranges and fragments.
- Follow `Docs/ARCHITECTURE.md` for document replacement, shared-pane adoption, navigation history, the Objective-C enumeration bridge, lazy source-length fillers, and bounded native layout geometry. Preserve native viewport/drawing entry points; measure actual app peak memory with kernel lifetime counters.
- Make source mutations and undo boundaries explicit. Storage, autosave, watcher, and external-write changes need focused coverage for the relevant clean/dirty states and, when applicable, atomic replacement, deletion/rename, own-write suppression, conflict/review, failure, and recovery.
- Returning to the exact saved source by editing or undo clears local dirty state without saving; it must not erase a pending external conflict.
- Never translate an I/O failure into “no change,” recreate a deleted file silently, overwrite source after a rendering failure, or save after the user chose Discard.
- Image loading is opt-in: the Mac View > Load Remote Images command grants only the current document. The shared engine never makes network requests and Quick Look never installs a remote loader. Host requests use credential-free HTTPS with response limits while receiving. Mac animations require Play.
- Image-only physical Markdown lines use independent viewport-loaded fragments, including adjacent lines in one parsed paragraph. Prose images, linked badges and same-line rows remain inline; source bytes and UTF-16 positions stay unchanged.
- PlantUML rendering stays local, bounded, and isolated from filesystem and network loaders. Quick Look keeps these fences as code and never starts the worker. See `Docs/ARCHITECTURE.md` for worker limits and `Docs/RELEASE.md` for runtime/license packaging.
- No app telemetry or document uploads. The only autonomous recurring request is a conditional public-appcast `GET` without identifiers; it respects "check automatically" and may trigger Sparkle, but never parses the feed or installs. Acquisition counts GitHub Release `.dmg` requests across stable/versioned assets, excluding Sparkle ZIP/deltas; requests are not people or installs.
- The GitHub star suggestion uses only capped local counters and never queries GitHub identity or star status, sends engagement analytics, steals focus, or reflows the document. Eligibility, retirement, and presentation belong in `Docs/ARCHITECTURE.md`.
- Reuse semantic theme tokens and the shared `Motion` infrastructure. Keep transitions interruptible and idle animation drivers parked; follow `DESIGN.md` rather than adding parallel styling or animation systems.

## Validation by Surface

- CI must retain source-test progress and collect diagnostics only from the gate’s descendant processes. Diagnostic collection must preserve test exit status and existing budgets.
- PRs have no required review or CI checks. Keep unfinished work in draft; Cubic reviews non-draft PRs once. Assess reachable failures against invariants, batch confirmed fixes, and request another review only for a specific unresolved concern or material new risk. See `cubic.yaml` and `Docs/CI.md`.
- For code changes, use focused tests while iterating, then run `Scripts/check.sh` as the authoritative source gate. For documentation-only changes, inspect content, links, and referenced commands without rebuilding the app. Do not substitute bare `swift test`; zero executed tests or a masked pipeline failure is a failed gate.
- Run integration validation after review fixes settle. Before reporting a PR ready, run `python3 Scripts/check-pr-ci.py --pr NUMBER`; reviewer approval is not source/native validation. Pushes and merges do not publish; release dispatch validates its selected commit. Cadence, commands, and coverage boundaries belong in `Docs/CI.md`.
- Give concurrent checks unique scratch/build locations using the supported variables in `Docs/CI.md`. If source, `HEAD`, or relevant outputs change during validation, discard the affected evidence and rerun on the intended snapshot. Caches accelerate builds; they never replace required checks.
- After verification, stop owned processes and verify owned paths are idle before removing task-created builds, scratch, fixtures/profiles, logs/screenshots, and downloaded test assets, including outside this checkout. Preserve source, credentials, installed apps, shared caches, other owners' work, deliverables, and minimal evidence. Report cleanup deferred while artifacts remain in use.
- `Scripts/bundle-app.sh` is appropriate for host-only iteration but does not prove Finder extensions. Use `Scripts/bundle-xcode-app.sh` and `Scripts/check-app.sh` for Quick Look, thumbnails, Finder integration, or production-shaped app acceptance. Development/ad-hoc bundles do not prove production Sparkle behavior. Every nested Mach-O must support all architectures of its host; universal release archives must include Intel and Apple Silicon CLI and Spotlight binaries.
- When the installed app is the acceptance surface, install the intended artifact explicitly with `APP_SOURCE=... Scripts/install.sh`, stop stale Downright instances when safe, and verify bundle path, version/build, executable identity, signature, embedded components, and running process before exercising the feature.
- Use a disposable document copy for destructive editing, Replace All, task toggles, metadata, save/discard, or conflict QA. Restore task-created preferences/state afterward.
- For changed visual or interaction behavior, verify the relevant journey in the exact app: launch, first visible frame, transition, settled state, real pointer/keyboard interaction, dismissal, rapid reopen or interruption, and resize. Check only the relevant light/dark and accessibility states.
- For glass/material work, verify document sampling, crisp foreground content, no first-frame material swap, and working pointer, keyboard, focus, outside-click, and fallback behavior.
- When the report concerns clicking, caret placement, hover, drag, scrolling, or a close/checkbox control, use a real native input path. Accessibility actions, `performClick`, screenshots, hashes, and direct method calls are supporting evidence, not substitutes.
- Quick Look preview and Finder thumbnail are separate acceptance surfaces. Use the packaged installed extensions, verify current registration, test an actual Finder Spacebar preview after startup settles, and generate a fresh thumbnail. Do not infer one from the other or from `qlmanage` generation alone.
- Report performance by the layer measured: edit/storage response, parse/semantic convergence, TextKit layout, and visible frame/scroll stability are different claims. Pair performance-sensitive editor changes with the repository budgets and a real large-document exercise.
- Strengthen existing evidence, bundle, and public-update scripts when failures recur; retain the original failing journey as regression coverage. Avoid parallel success checks or more instruction paragraphs. Acceptance records and resource ownership belong in `Docs/CI.md`.

## Plans and Release Evidence

- For a numbered audit or broad implementation plan, keep an acceptance record mapping each original item and later correction to its reproduction, changed behavior, exact artifact, evidence, and remaining limitation. Reconcile each as proved, explicitly approved as changed, or blocked before claiming completion; use the format in `Docs/CI.md`.
- Obtain explicit authorization immediately before a push or merge to this repository’s `main`. Publishing is a separate consequential action: obtain authorization for the exact `main` commit before dispatching `release.yml`. Feature-branch pushes, main commits and merged PRs are not release proof.
- Documentation lands with the change. Before any PR merges or a land runs, customer-facing behavior has a plain-language `[Unreleased]` entry in `CHANGELOG.md` and the affected README, contracts, and help text are updated. That changelog section becomes the in-app update notes, so write it for someone deciding whether to press Update. Move it into the matching version before publishing; the release request fails without that section. After publishing, refresh the website's app data from the released commit. Never rebuild or overwrite released app artifacts: recover matching retained publication inputs or release a new, higher-build commit. Only the download-counter and `metrics` branch badge files remain mutable. Follow `Docs/RELEASE.md`.
- For release claims, follow `Docs/RELEASE.md` and keep these states distinct: intended `main` SHA, workflow completion, version/build, GitHub Release, signed/notarized/stapled DMG and checksum, stable download URL, signed Sparkle appcast/enclosure, update availability, and installed `/Applications` bundle.
- Verify every release stage the request places in scope and label the rest unverified. “Update available” does not mean existing installations have already updated.
- Requested publication remains unfinished after a workflow failure. Diagnose and repair within scope; continue independent preparation until the customer-facing result is verified or a concrete approval or owner-only prerequisite blocks progress. Follow `Docs/RELEASE.md` for recovery; changed release commits need their own authorization.
