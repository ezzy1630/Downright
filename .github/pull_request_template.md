## What this changes

<!-- One paragraph. What was wrong or missing, and what you did about it. -->

## Why this way

<!-- Only if the approach is not obvious. Alternatives you rejected and why. -->

## Checks

- [ ] `Scripts/check.sh` passes. Bare `swift test` runs zero tests here and
      exits 0 — never trust it (`Docs/STATUS.md`).
- [ ] New behaviour has a test, or the reason it cannot have one is in the
      description.
- [ ] No new compiler warnings.
- [ ] `CHANGELOG.md` updated under `## [Unreleased]` if this is user-visible.

## If it touches the render or storage path

- [ ] Round trips stay byte-identical — the text storage still holds the file's
      exact bytes and decoration mutates no characters.
- [ ] `swift run -c release drbench` is still inside the budgets in
      `Docs/PERFORMANCE.md`. Typing p95 under 8 ms is the P0 gate.
