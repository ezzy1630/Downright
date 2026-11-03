## What this changes

<!-- One paragraph. What was wrong or missing, and what you did about it. -->

## Why this way

<!-- Only if the approach is not obvious. Alternatives you rejected and why. -->

## Checks

- [ ] Relevant checks pass on the final revision, with the run linked below
      (see `Docs/CI.md`). Use `Scripts/check.sh` for the source gate; bare
      `swift test` can silently run zero tests on Command Line Tools machines.
- [ ] New behaviour has a test, or the reason it cannot have one is in the
      description.
- [ ] No new compiler warnings.
- [ ] User-visible changes appear in the matching version section of
      `CHANGELOG.md` (see `Docs/RELEASE.md`).

<!-- Link final-revision hosted checks, or describe the documentation-only review. -->

## If it touches the render or storage path

- [ ] Round trips stay byte-identical — the text storage still holds the file's
      exact bytes and decoration mutates no characters.
- [ ] `RUN_DRBENCH=1 Scripts/check.sh` passes the automated budgets in
      `Docs/PERFORMANCE.md`; relevant native acceptance passes as well.
