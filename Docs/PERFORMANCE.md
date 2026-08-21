# Downright Performance

Performance is a product promise. Use release builds and measure the real
pipeline. Do not replace a failed measurement with a claim.

## Budgets

| Metric | Target | Method | Pass condition |
|---|---:|---|---|
| Cold launch to first rendered pixel, 100 KB | <250 ms | App launch capture | p95 below target |
| Keystroke response, 5,000-line file | <8 ms | Source edit, paragraph map, dirty decoration | p95 below target |
| Scroll | 120 fps on ProMotion | Long-document scroll trace | No sustained frame drop |
| Structural zoom | <300 ms | Level 1–5 transition trace | Anchor stays fixed; no dropped frames |
| Document↔Source swipe, engage and abandon (give path) | <8 ms | `PresentationSwipeBudgetTests`, 2,000-line file | Below target; nothing rendered inside the gesture |
| Document↔Source swipe, engage (drag path) | <50 ms | `PresentationSwitchBudget`, documents under its line budget | Below target; measured 6 ms at 240 lines, 26 ms at 950 |
| Document↔Source swipe, per tracking frame | <1 ms | `PresentationSwipeBudgetTests` | Below target |
| Quick Look preview | <400 ms | Preview extension render | p95 below target |
| Quick Look peak memory | <60 MB | Resident memory polling | Never exceeds target |
| 1 MB document memory | <150 MB | App open and idle measurement | Peak below target |
| Quick Look safety fallback | 60 MB | Memory guard | Plain text fallback above guard |
| Large Quick Look file | 2 MB | Preview policy | Initial blocks plus Open in App |

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

## Current local benchmark

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

Run from the repository root:

```bash
Scripts/check.sh
swift run -c release drbench
```

For a render capture:

```bash
swift run -c release drbench render Docs/sample.md /tmp/downright.png read 1000 1400
```

The benchmark warms each case, then reports p50 and p95. Keep the corpus shape,
build mode, run count, and budget labels stable. Add a focused case when a new
pipeline or document type can change the cost.

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
