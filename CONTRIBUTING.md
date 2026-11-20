# Contributing to Downright

Downright is a native macOS Markdown reader and editor. Contributions should
keep the product file-first, source-preserving, offline by default, and useful
for ordinary Markdown files that people and coding agents change together.

## Before you start

Open an issue before building anything cross-cutting: a new language, a new
dependency, a new setting or subsystem, or a change that spans much of the
app. Agree on scope and ongoing maintenance there first; a large pull request
that arrives unannounced may be closed or sent back for changes it could have
avoided.

## Before opening an issue

- Search existing issues and read [README.md](README.md) and the known gaps
  in [Docs/STATUS.md](Docs/STATUS.md).
- For rendering problems, reduce the document to the smallest Markdown that
  still fails.
- For external-write problems, describe the original file, the process that
  changed it, and whether there were dirty local edits.
- Never attach private documents, credentials, or unredacted crash logs.

Security vulnerabilities belong in [SECURITY.md](SECURITY.md), not a public
issue.

## Build and test

Requirements: macOS 14 or newer, Xcode or the Command Line Tools, Swift 6
toolchain, and `xcodegen` for the complete app bundle.

Use the repository gate rather than bare `swift test`:

```bash
Scripts/check.sh
```

For the complete installed app and Quick Look extensions:

```bash
Scripts/bundle-xcode-app.sh
APP_SOURCE=.build-xcode/Build/Products/Release/Downright.app Scripts/install.sh
Scripts/check-app.sh
```

Changes to rendering or storage should include a focused regression test and
must preserve the source file's exact bytes. Changes to external-write review
should cover clean and dirty local-edit states.

## Writing tests

Use a Swift Testing unit or integration test for parser, edit, persistence,
and view-model behavior that can be observed without physical input. For
clicks, drags, typing, hover, scrolling, and Settings changes inside a document
window, use the in-process UI driver: it sends real AppKit events through real
windows inside `swift test`, needs no Automation Mode, and never moves your
cursor. Keep XCUITests (hosted CI) for behavior that needs a packaged,
foreground app, a system dialog such as the save panel, or another process.
Reserve manual checks for surfaces neither can drive, such as Finder's
Spacebar preview. [Native UI testing](Docs/UI-TESTING.md) ·
[CI and test evidence](Docs/CI.md)

Reduce a bug report to a small disposable document and the shortest failing
action sequence. Assert the affected output, file bytes, or user-visible state.
Run the test against the original implementation and confirm it fails for the
reported reason, then rerun it after the fix. To run a Swift suite locally, use
`Scripts/test.sh --filter SuiteName`.

Use real implementations and observe their effects. Wait for a callback,
notification, or completion. When AppKit only exposes state, use the test
target's bounded condition helper and name the expected state in the failure.
The fast gate rejects fixed waits, assertion retries, time-limit overrides, and
untracked known issues. Lower the corresponding allowance when retiring an
existing violation. [Test honesty allowlist](Scripts/test-lint-allowlist.json)

## Pull requests

Describe the user-visible problem, the invariant the change preserves, and the
checks you ran. Keep commits focused. Update `CHANGELOG.md` under
`[Unreleased]` for user-visible behavior, and include screenshots or a short
recording only when the change is visual and the document itself cannot prove
it.

If your change creates something that must stay in sync with other code (a
translation table, a generated file, a mirrored list), include the check that
fails when it drifts. Keeping it in sync must not depend on anyone
remembering.

Do not add a sync service, vault database, plugin runtime, remote model
dependency, or chat panel without first changing the product contract and
architecture documentation.

## Releases

Merging or pushing to `main` does not publish. When preparing a release, move
the pending `[Unreleased]` notes into the matching version section and update
`Config/version.env` only when the marketing version changes. Obtain release
authorization for the exact `main` commit, then explicitly dispatch
`release.yml` on `main`. All source, performance, native and production checks
must pass before signing and publication. Existing release tags and app artifacts
are never overwritten; deployment recovery reuses the original artifacts.
Feature branches can run CI manually without publishing customer-facing
builds. See [Docs/CI.md](Docs/CI.md) and [Docs/RELEASE.md](Docs/RELEASE.md).
