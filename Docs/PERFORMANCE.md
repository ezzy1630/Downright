# Downright Performance

Performance is a product promise. Use release builds and measure the real
pipeline. Do not replace a failed measurement with a claim.

## Budgets

| Metric | Target | Method | Pass condition |
|---|---:|---|---|
| Cold launch to first rendered pixel, 100 KB | <250 ms | App launch capture | p95 below target |
| Keystroke to updated render, 5,000-line file | <8 ms | Parse, AST diff, dirty decoration | p95 below target |
| Scroll | 120 fps on ProMotion | Long-document scroll trace | No sustained frame drop |
| Structural zoom | <300 ms | Level 1–5 transition trace | Anchor stays fixed; no dropped frames |
| Quick Look preview | <400 ms | Preview extension render | p95 below target |
| Quick Look peak memory | <60 MB | Resident memory polling | Never exceeds target |
| 1 MB document memory | <150 MB | App open and idle measurement | Peak below target |
| Quick Look safety fallback | 60 MB | Memory guard | Plain text fallback above guard |
| Large Quick Look file | 2 MB | Preview policy | Initial blocks plus Open in App |

The 8 ms keystroke target is the P0 architecture gate. If block-diffed
restyling cannot meet it, stop and revise the architecture before adding later
phases.

## Current local benchmark

Measured with the release executable from `Sources/drbench/main.swift` on
2026-08-01. Corpus: 120,825 characters and 4,885 lines of generated agent-like
Markdown. The host machine is not recorded here, so use these numbers as a
baseline, not a cross-machine claim.

| Measurement | p50 | p95 | Result |
|---|---:|---:|---|
| cmark parse | 13.578 ms | 13.993 ms | Informational |
| Full MarkdownParser.parse | 48.220 ms | 49.742 ms | Informational |
| AST dirty set, one-character edit | 0.035 ms | 0.042 ms | Informational |
| Text diff, external rewrite | 4.017 ms | 4.120 ms | Informational |
| Incremental decoration | 12.579 ms | 12.742 ms | Fails 8 ms budget |
| Wholesale decoration | 106.532 ms | 169.001 ms | Informational |
| Full keystroke pipeline | 61.089 ms | 65.151 ms | Fails 8 ms budget |
| Parse 100 KB | 17.087 ms | 17.406 ms | Under 250 ms parse gate |
| Syntax highlight, 10 KB Swift | 0.094 ms | 0.108 ms | Informational |

The current result is not release-ready for the keystroke promise. Parsing and
AST diff are not the main cost. Decoration and the full pipeline need profiling
and repair.

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
