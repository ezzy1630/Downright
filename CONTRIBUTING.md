# Contributing to Downright

Downright is a native macOS Markdown reader and editor. Contributions should
keep the product file-first, source-preserving, offline by default, and useful
for ordinary Markdown files that people and coding agents change together.

## Before opening an issue

- Search existing issues and read [Docs/STATUS.md](Docs/STATUS.md).
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

## Pull requests

Describe the user-visible problem, the invariant the change preserves, and the
checks you ran. Keep commits focused. Update `CHANGELOG.md` under
`[Unreleased]` for user-visible behavior, and include screenshots or a short
recording only when the change is visual and the document itself cannot prove
it.

Do not add a sync service, vault database, plugin runtime, remote model
dependency, or chat panel without first changing the product contract and
architecture documentation.

## Releases

The production channel is rolling and main-driven. Update
`Config/version.env` only when the marketing version changes, run the full
check, and merge or push the reviewed commit to `main`. Every push to `main`
gets a monotonically increasing build number, a signed/notarized/stapled
artifact, a GitHub Release, and a signed Sparkle appcast. Feature branches run
CI but do not publish customer-facing builds. See [Docs/RELEASE.md](Docs/RELEASE.md).
