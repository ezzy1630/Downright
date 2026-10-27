# Downright Performance

Performance is a product promise. Use release builds and measure the real
pipeline. Do not replace a failed measurement with a claim.

## Budgets

| Metric | Target | Method | Pass condition |
|---|---:|---|---|
| Cold launch to first rendered pixel, 100 KB | <250 ms | App launch capture | p95 below target · *manual release gate* |
| Keystroke response, 5,000-line file | <8 ms | Source edit, paragraph map, dirty decoration (`drbench`, release) | p95 below target |
| Scroll | 120 fps on ProMotion | Long-document scroll trace | No sustained frame drop · *manual release gate* |
| Structural zoom | <300 ms | Level 1–5 transition trace | Anchor stays fixed; no dropped frames · *manual release gate* |
| Document↔Source swipe, engage and abandon (give path) | <8 ms | `PresentationSwipeBudgetTests`, 2,000-line file | Below target; nothing rendered inside the gesture |
| Document↔Source swipe, engage (drag path) | <50 ms | `PresentationSwitchBudget`, documents under its line budget | Below target; measured 6 ms at 240 lines, 26 ms at 950 |
| Document↔Source swipe, per tracking frame | <1 ms | `PresentationSwipeBudgetTests` | Below target |
| Quick Look preview | <400 ms | Preview extension render | p95 below target · *no automated measurement yet — manual* |
| Quick Look peak memory | <60 MB | Resident memory polling | Never exceeds target |
| 1 MB document memory | <150 MB | Fresh native session; kernel lifetime physical-footprint counter | Peak below 150,000,000 bytes · *manual release gate* |
| Quick Look safety fallback | 60 MB | Memory guard | Plain text fallback above guard |
| Large Quick Look file | 2 MB | Preview policy | Initial blocks plus Open in App |

Rows marked *manual release gate* have no automated enforcement vehicle in
the repository today. They are claims to re-measure at release time, not
gates a CI run proves; do not cite them as enforced. The memory-guard and
policy rows are asserted by unit tests, the swipe rows by dedicated budget
suites, and the keystroke/convergence rows by `drbench` with
`RUN_DRBENCH=1`.

The swipe budgets exist because the obvious implementation misses them by an
order of magnitude. Dragging the Source presentation in under the fingers
requires rendering it first, which is a whole-document TextKit rebuild. The
gesture therefore measures before it promises: `PresentationSwitchBudget` holds
a per-line cost, seeded from a release sweep and recalibrated from every switch
the app performs, and the swipe takes the drag only where the estimate fits
inside the engagement budget. Above it the gesture translates one layer instead
and switches on release through the same path the toolbar rail uses, for the
same cost and no more.

Two things make the drag affordable at all. The outgoing page is captured by
`CALayer.render` at half resolution — 3 ms, against 30 ms for a full-resolution
`cacheDisplay`, because it composites what is already rasterised rather than
re-running TextKit — and the incoming side is not captured at all, since it is
the live text view with the mode change already applied behind the still.

The 8 ms keystroke target is the P0 architecture gate. Semantic parsing runs
outside this synchronous path. Its result is revision checked before the app
applies dirty decoration.

## Release pipeline comparison (2026-10-27)

All ten unchanged pipeline cases exceed the requested 25% improvement. These
are Apple M4 / macOS 27.0 release measurements against a fresh same-machine
baseline at `ce2cad6deb287fa34d3561615c6655e3eb29a17e`. The candidate is the
clean integration snapshot at `8c0b6f340d95fd0110946a17e3bf44779813e551`,
identified in [the evidence manifest](Benchmarks/2026-10-27/landing/snapshot.json).
Each candidate value below is the worst p95 from three isolated runs, with the
original sample counts. The comparison checks conservative bounds for the
benchmark's 0.001 ms rounding.

| Measurement | Baseline p95 | Candidate p95 | Faster |
|---|---:|---:|---:|
| cmark conversion | 13.947 ms | 9.007 ms | 35.4% |
| Full parse | 30.876 ms | 19.636 ms | 36.4% |
| AST diff | 0.031 ms | 0.018 ms | 41.9% |
| Text diff | 1.617 ms | 0.454 ms | 71.9% |
| Incremental decoration | 0.117 ms | 0.063 ms | 46.2% |
| Wholesale decoration | 162.957 ms | 69.677 ms | 57.2% |
| Typing/storage | 0.159 ms | 0.090 ms | 43.4% |
| Semantic convergence | 28.521 ms | 19.792 ms | 30.6% |
| Parse 100 KB | 23.512 ms | 16.367 ms | 30.4% |
| Syntax highlighting | 0.115 ms | 0.059 ms | 48.7% |

The pipeline corpus remains 120,825 characters / 4,885 lines, and the cold-parse
corpus is exactly 100,000 characters. The historical 100 KB row below used an
older corpus; it is not the baseline for these percentages. These measurements
cover parsing, diffing, storage and decoration; they do not establish first-pixel
time, visible scroll frames, or complete native transition latency.

[Raw runs and machine/artifact identity](Benchmarks/2026-10-27/landing/snapshot.json) ·
[Machine-readable comparison](Benchmarks/2026-10-27/landing/timings.json) ·
[Source gate](Benchmarks/2026-10-27/landing/final-clean-source-gate.txt)

### Native memory certification is incomplete

The latest measured isolated native release host opened the unchanged 1,032,709-byte
stress document with a **126.2 MB lifetime peak**. That is an open-only
observation, not an interactive-session certificate. The latest executable and
source digest are recorded in [the native observation](Benchmarks/2026-10-27/native-open-only.json).

Earlier interactive trials still exceeded 150 MB. The last change releases the
previous parsed tree before fresh decoration/layout during synchronous undo;
an actual document-class regression failed before the change and passes after
it. Three complete fresh native sessions on that final snapshot remain required.
Native control then returned `cgWindowNotFound`, preventing those repeats.
The separately built Xcode UI runner also [timed out enabling automation mode](Benchmarks/2026-10-27/ui-automation-blocker.txt).
The packaged app, CLI, Spotlight importer and both Finder extensions passed
[structural bundle verification](Benchmarks/2026-10-27/packaged-verification.txt).

The 150 MB session target remains uncertified. The owner approved landing with
that evidence gap and unavailable visual testing on 2026-10-27; this approval
does not turn the open-only observation into a session result. The final integration
source gate passed 1,461 Swift tests and 52 script checks, with the two existing
headless known-issue sites. The open-only observation predates the final image
permission fixes; it is not a measurement of the signed release. Finder
Spacebar preview, thumbnail registration, native frame delivery and production
updater behavior remain separate acceptance surfaces.

## Local optimization check (2026-10-25)

Release builds on Apple M4, macOS 27.0 (26A5406e), based on checkout
`9be0680ec7131dffb8af9a64b6cdbcdb274d3292` plus the local performance changes.
These are same-machine observations, not cross-machine promises.

| Measurement | Before | After |
|---|---:|---:|
| Unicode inline-heavy parse, p95 | 48.811 ms | 11.212 ms |
| Fuzzy match, 12-character query / 1,500-character heading, single invocation | 11.036 ms | 0.912 ms |
| Fresh-open live heap allocations | 402.0 MiB | 132.3 MiB |
| Fresh-open settled physical footprint | 423.6 MiB | 224.6 MiB |
| Fresh-open peak physical footprint | 637.9 MiB | 369.6 MiB |

The native stress document is 1,032,709 UTF-8 bytes, 57,043 lines, and 16,298
tasks. Memory compares fresh isolated host apps before and after the layout
fixes; both already include the parser and search changes. `heap` measures live
allocations, while `vmmap -summary` measures footprint including allocator
overhead and compressed memory. These are different from resident memory.
The first post-change resident sample was 184,736 KiB, so this stress case
still does **not** satisfy the 150 MB peak memory target. Idle CPU sampled at
0%; that observation is not an enforced energy budget. After the editing,
mode-switching, and scrolling exercise, footprint sampled at 350 MiB. The
fresh-open improvement does not establish a bounded interactive-session peak.

The gate run accompanying this first measurement, `RUN_DRBENCH=1 Scripts/check.sh`, passed 1,386 tests (with the two
existing headless known-issue sites) and the automated release
budgets (typing/storage p95 0.16 ms; semantic convergence p95 29.02 ms).
The native host exercised editing, undo, save, source/rendered presentation,
scrolling, and window resizing; undo/save restored the fixture's exact bytes.
Finder extensions, cold-launch first-pixel timing, and 120 Hz frame delivery
were not validated by this pass.

### Session-memory continuation

On the same machine and stress document, the subsequent lazy-marker and
autorelease-lifetime changes were measured against the first pass's code:

| Native session measurement | Before | After |
|---|---:|---:|
| Lifetime peak physical footprint | 449.2 MiB | 204.1–252.2 MiB |
| Post-workload physical footprint | 394.8 MiB | 113.8–155.7 MiB |
| Post-workload live heap, first optimized run | 146.7 MiB | 116.1 MiB |

The workload starts with a fresh isolated release host and the same file, enters
Source, inserts seven characters, saves, undoes seven times, saves again, scrolls
down and up two pages, and performs three further Source/Document cycles. The
fixture's 1,032,709 bytes were restored exactly. Kernel lifetime peak counters
(`rusage_info_v4.ri_lifetime_max_phys_footprint`, cross-checked with `heap`) include
brief spikes beyond the periodic sampler's window. Live heap and physical
footprint remain distinct metrics; shared-library RSS is not either of them.
The optimized range covers two fresh-process runs. It is an observed range,
not a percentile or a guaranteed ceiling. The source gate accompanying those continuation measurements passed 1,389
tests with the two existing headless known-issue sites, and release p95 was
0.15 ms for typing/storage and 28.35 ms for semantic convergence.

The memory regression initially failed because every hidden marker retained an
attributed string. Maps now retain source-styled range descriptors and resolve
text only for requested paragraphs. Per-block and per-pass autorelease pools
bound decoration temporaries. Speech, clipboard, theme, projected-edit, and
caret checks cover the dependent paths. An additional per-marker pool experiment
did not improve the fresh-open peak and was removed.

At that snapshot, the 150 MB **peak** target was unmet by this stress case. Those session
numbers do not establish a universal memory ceiling or a 120 Hz scroll budget.

## Historical pipeline baseline

Measured with the release executable from `Sources/drbench/main.swift` on
2026-08-06. Corpus: 120,825 characters and 4,885 lines of generated agent-like
Markdown. The host machine is not recorded here, so use these numbers as a
baseline, not a cross-machine claim.

| Measurement | p50 | p95 | Result |
|---|---:|---:|---|
| cmark parse | 12.827 ms | 13.309 ms | Informational |
| Full MarkdownParser.parse | 29.463 ms | 30.372 ms | Runs outside typing path |
| AST dirty set, one-character edit | 0.030 ms | 0.031 ms | Runs outside typing path |
| Text diff, external rewrite | 2.099 ms | 2.164 ms | Informational |
| Incremental decoration | 0.097 ms | 0.104 ms | Under 8 ms budget |
| Wholesale decoration | 103.722 ms | 171.493 ms | Informational |
| Source edit and paragraph map | 0.146 ms | 0.153 ms | Under 8 ms budget |
| End-to-end semantic convergence | 30.583 ms | 31.445 ms | Under 100 ms budget |
| Parse 100 KB | 12.078 ms | 12.395 ms | Under 250 ms parse gate |
| Syntax highlight, 10 KB Swift | 0.093 ms | 0.094 ms | Informational |

The synchronous typing work and incremental decoration now fit the 8 ms
budget. The benchmark does not yet measure TextKit layout, scroll-frame
delivery, IME input, or live window frame time. Those checks remain release
gates. The end-to-end convergence row measures the full parse, diff, and
decoration work. Production performs parse and diff away from the main actor,
then applies the newest result on the main actor.

## Measurement procedure

CI runs automatically on pushes to `main`, including PR merges, with a manual
workflow trigger for branches. PRs do not run CI automatically and have no
required review or status checks. The release workflow retains its own checks
before publication.

On Xcode, `Scripts/check.sh` shares compiled debug modules between the build
and all source tests. CLT uses a separate test graph because its framework
flags differ; `TEST_SCRATCH` can override either default. With `RUN_DRBENCH=1`,
the release benchmark replaces the informational debug benchmark rather than
running the same corpus twice. Sample counts and enforced budgets are unchanged.

CI caches source and native build intermediates by OS, architecture, compiler,
SDK, and build inputs. A cache hit still rebuilds changed sources and executes
every test and benchmark. Native acceptance always rebuilds/verifies its exact
bundle and runs the activated-app suite; cached test results are not accepted.

Run from the repository root:

```bash
Scripts/check.sh
swift run -c release drbench
```

For a render capture:

```bash
swift run -c release drbench render Docs/sample.md /tmp/downright.png read 1000 1400
```

The benchmark warms each case, then reports p50, p95, the maximum, and the
sample count. Keep the corpus shape, build mode, and budget labels stable, and
add a focused case when a new pipeline or document type can change the cost.

The Unicode inline-heavy case uses one 16,800-byte line containing accented
text, CJK, emoji, and repeated formatting/link spans. Keep it alongside the
ASCII corpus: repeatedly converting cmark's UTF-8 columns by copying and
rescanning the entire line makes this shape quadratic. Source positions use
sparse, parse-local checkpoints on long Unicode lines and read the existing
UTF-16 buffer between checkpoints. ASCII and short lines allocate no
checkpoints; no per-byte conversion table is retained in the document.

Outline search has a separate regression case in
`OptimizationRegressionTests.fuzzyMatcherHandlesLongRepeatedHeadings`: a
12-character query against a 1,500-character heading. Its printed duration is
informational and depends on build configuration. The matcher keeps the same
scoring and highlight positions while using a running prefix maximum for gap
scores, bounding matching work to query length times heading length. Alignment
tests cover consecutive, separated, boundary, and case-sensitive bonuses.

Large-document opening must keep offscreen elements lazy while preserving
AppKit's viewport lifecycle and native top-aligned geometry. A shared pane is
attached to its scroll surface while empty, then adopts the shared storage and
parsed presentation in one content-storage editing transaction. During an open,
the controller defers selection-driven geometry until the new display map is
installed, so AppKit's transient storage-repair selection cannot force layout to
EOF. Small documents use the native origin getter. Above the eager-layout
budget, or while the paragraph index and storage lengths differ, the origin
returns the top-aligned inset without asking AppKit to resolve used bounds
through EOF. Native viewport and drawing entry points remain intact. Width
repairs keep the text view at least as wide as its container plus insets;
geometry regressions compare the bounded origin with native layout.
`EditingKeyReproTests.openingLargeDocumentDoesNotMaterializeEveryParagraph`
checks the existing element cache after displaying the viewport. Do not count
fragments by enumerating the document: that enumeration creates fragments and
invalidates the measurement.

Hidden-marker substitutions retain descriptors rather than attributed word-joiner
strings for every marker in the document. A requested paragraph resolves the
fillers against current storage attributes; speech and rich-copy projection use
the same resolver so source coordinates remain intact. The decorator drains
Foundation temporaries per block and per pass, and its reported elapsed time
includes that cleanup. Measure session peaks with the kernel's lifetime maximum
physical-footprint counter as well as periodic samples: polling alone can miss
a short allocation spike during a presentation change.

Percentiles are nearest-rank, which makes the sample count part of the gate's
meaning: the nearest-rank p95 of fewer than 20 samples **is** the maximum
sample (the index is `ceil(0.95n) - 1`, which reaches `n - 1` for every
`n` below 20). A budgeted case measured over 15 runs is really asserting "the worst of
15 runs passes", so on a shared CI runner a single scheduler stall fails a
signed release on unchanged code. Budgeted cases therefore take enough runs for
the 95th percentile to be a percentile; do not lower the run count of a case
that gates a release.

The convergence case always prints its parse, diff, and decoration phases, so a
miss is diagnosable from the log the failing run already wrote rather than
needing a rerun on a machine that is no longer stalling. Full release benchmark
output is retained in gate failure logs, and the benchmark's scratch directory
follows `SCRATCH` (or an explicit `BENCH_SCRATCH`) to isolate concurrent checks.

The cold-open corpus is truncated to exactly 100 KB, the size §12 states the
budget for; generate past the target before truncating, because `prefix` on a
shorter document silently measures the shorter document.

## Phase gates

- P0: record baseline; decide whether the 8 ms target is attainable.
- P1: keep parse and first-pixel budgets below target on representative files.
- P2: test Quick Look time, resident memory, and fallback behavior.
- P3: test typing, IME, mode switch, and marker reveal under the keystroke gate.
- P4–P6: test watcher, diff, zoom, search, and task actions on large files.
- P7–P8: repeat with themes, accessibility settings, bundled app, and release
  signing.

## Engineering rules

Keep parser, diff, and policy helpers pure. Reparse the full document when that
is simpler, but restyle only dirty blocks. Cancel stale asynchronous work.
Measure layout and decoration separately from parsing. Keep Quick Look on the
same render path, with lazy fragments and a hard memory guard.

## Image budgets

Animated pictures decode at the displayed size, bounded to 2048 pixels per
axis, and retain only the displayed and pending frame rather than every frame.
Mac playback is explicit and schedules one frame timer at a time; invisible,
occluded, detached, or inactive views stop scheduling work. Inline animation
placement must inspect the visible TextKit range rather than force layout from
the document start to every image. Remote responses are capped while receiving
before image decode, with a separate bounded image cache.

Keep the existing source and release benchmark budgets when changing image
presentation. Verify large documents on the native Mac surface; decoder unit
tests alone do not prove visible scroll stability or peak memory.
