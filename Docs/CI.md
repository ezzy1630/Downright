# CI and test evidence

Main pushes enter `release.yml`. Its `validation` job calls the same-commit
`ci.yml` reusable workflow with production acceptance enabled. Source tests and
release performance budgets, development native acceptance, and production
updater acceptance run on separate macOS runners. The archive job depends on
the entire reusable workflow succeeding. There is one source gate per push;
no archive or publication can bypass a failed native lane. Main release runs
are never cancelled halfway through signing or publication.

`ci.yml` also supports manual branch dispatch. It runs source and development
native checks without publishing or requesting production secrets. Pull
requests have no automatic CI or required review. There is no new UI performance
workflow.

## Local entry points

- `Scripts/check-fast.sh`: version consistency, contrast, shell/Python syntax,
  and pinned Actionlint validation. This does not compile or prove the app.
- `Scripts/install-hooks.sh`: install the tracked pre-push hook while preserving
  an existing custom hook. Each proposed commit is archived into a disposable
  directory and checked there, including pushes from a dirty checkout. Deleted
  refs have no tree to check. The hook never pushes or modifies the proposed
  commit, and never substitutes for full integration checks.
- `RUN_DRBENCH=1 Scripts/check.sh`: authoritative complete source gate and
  unchanged release performance budgets.
- `Scripts/check-app.sh`: build, verify, and drive an exact native bundle.
  Main native acceptance runs the complete existing suite.

## Evidence and caches

The reporting wrapper preserves a check's exit status:

```bash
python3 Scripts/ci-report.py --name source --output .build-ci-evidence/source \
  --require-tests -- Scripts/check.sh
```

It retains full logs, and writes `results.json` and `summary.md`. The report binds
the result to HEAD and a content digest of tracked and unignored source files.
Source drift or missing required execution evidence fails validation. Phase
wall times, Swift execution time, skipped coverage, slowest suites, build-log
compilation units, and requested/restored cache keys remain distinct fields.
CI uploads source evidence and native `.xcresult` bundles even on failure.
Artifacts are retained for seven days.

Build caches include the runner OS/architecture, compiler/SDK identity and build
inputs. Native cache keys also separate Debug, Release, development and
production configuration. Production updater acceptance restores its own
intermediates. Cache restore does not skip any test, benchmark or bundle check.
An exact match, a fallback restore and a cold run are reported separately.
Only successful validation saves new build graphs; signing keychains and
shipping archives never enter those caches.

`Scripts/audit-ci.py --workflow ci.yml --limit 30 --output .build-ci-audit.json`
reads historical jobs and step durations through `gh`. For new main runs, use
`--workflow release.yml`. It reports successful-job median and p95 separately
from failed/cancelled runs. Start delay includes dependencies and scheduling;
it is not labelled pure runner queue time. Hosted before/after improvements
require comparable runs on the published workflow. Local cold/warm results
cannot establish hosted cache savings.

## Coverage boundaries

Disabled real-window tests use Swift Testing's enabled trait and appear as
skipped coverage. Setting `RUN_REAL_WINDOW_PERF=1` enables the bounded display
cycle tests; missing window-server support then fails instead of returning
success. The exhaustive case additionally requires `RUN_REAL_WINDOW_50K=1`.
These synchronous layout/display checks do not establish compositor frame rate.

Native-session peak memory, the precise first-pixel deadline, compositor frame
delivery, Finder Spacebar preview, fresh Finder thumbnails and oldest-supported-
OS/Intel runtime acceptance remain separate release evidence. No new local UI
workload or scheduled UI performance job is part of this change. Universal
Mach-O structure does not prove Intel execution.

Fixed-seed document sequences exercise Unicode edits, source/display mapping,
shared panes, selection, undo/redo, exact source preservation and dirty/conflict
state. A failure reports its seed and operation index so it can become a focused
regression. The source gate remains serial. To measure isolated core tests after
a full build, run:

```bash
python3 Scripts/compare-test-parallelism.py --scratch-path .build-main \
  --output .build-core-parallelism
```

It alternates serial/parallel ordering,
requires equal nonzero execution counts, and does not change default parallelism.
