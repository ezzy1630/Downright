# Releasing Downright

Downright is distributed **outside the Mac App Store**, signed and notarised,
updated via Sparkle 2.9.5 with a fully custom user interface (spec §3.4 and the
custom-updater spec). No standard Sparkle window ever appears; `UpdateCoordinator`
owns every visible interaction.

## What SwiftPM can and cannot do here

`Scripts/bundle-app.sh` assembles a complete, runnable `Downright.app` from
SwiftPM build products — including embedding and ad-hoc-signing Sparkle — with
no Xcode project involved. What it cannot do:

| Needs Xcode | Why |
|---|---|
| Quick Look `.appex` bundles | Use `Scripts/bundle-xcode-app.sh`. It generates the Xcode project and embeds both signed extension targets. See [QUICKLOOK.md](QUICKLOOK.md). |
| Production Sparkle and Spotlight packaging | Release builds sign every nested helper, the classic Spotlight importer, and the framework separately, then notarise and staple. |
| Developer ID signing and notarisation | Requires a certificate in the login keychain and an App Store Connect API key. |

Everything else — the app, the render packages, the CLI, the tests, and the
Spotlight importer — builds with the Command Line Tools alone. `swift build` fetches the Sparkle 2.9.5 binary
XCFramework (pinned exactly in `Package.swift`), so building the app needs
network access the first time.

## The one version source

`Config/version.env` is the single source of truth for `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION`. `Scripts/sync-versions.sh` verifies that `project.yml`,
the `down` CLI version, and the Info.plist templates all agree; `check.sh` runs
it, so a drift fails CI. **`CFBundleVersion` must increase monotonically** —
Sparkle orders updates by it. Never release with a build number ≤ the last
release's.

```bash
Scripts/sync-versions.sh        # verify
Scripts/sync-versions.sh fix    # rewrite the consumers from version.env
```

## Updater architecture

- `Sources/DownrightApp/Updater/UpdateCoordinator.swift` — `@MainActor`
  singleton owning the `SPUUpdater`, the user driver, the state machine, the
  one-shot reply capabilities, and the panel/pills.
- `Sources/DownrightApp/Updater/DownrightUpdateDriver.swift` — the complete
  `SPUUserDriver`; Sparkle owns download, validation, extraction,
  authorization, atomic replacement, and relaunch.
- `UpdateEngine` — internal protocol; production wraps Sparkle, tests use a
  deterministic fake.
- The state machine (`UpdateStateMachine.swift`) is a pure value type: every
  transition is unit-tested without Sparkle.
- Pills live in document titlebars and the start window; the update panel is a
  single nonmodal window that renders release notes through the app's own
  `MarkdownTextView`.

Dev/ad-hoc bundles omit the Sparkle Info.plist block, which disables the
updater entirely (`UpdateCoordinator.start()` refuses to run). Production keys
live in `Config/Downright-Info.plist` with a placeholder public key; the
release workflow injects the real key via `Scripts/prepare-release-info-plist.sh`.

## Signing and notarising

First, generate the Sparkle Ed25519 key pair **offline**:

```bash
Scripts/generate-sparkle-keys.sh --to-file ~/offline-backup
```

Follow its printed instructions: store the public key in the `release`
environment secret `SPARKLE_ED25519_PUBLIC_KEY`, the private key in
`SPARKLE_ED25519_PRIVATE_KEY`, and keep the encrypted backup. Losing the
private key is an explicit recovery event — never weaken feed validation to
work around it.

For a manual (non-workflow) release build:

```bash
export SPARKLE_ED25519_PUBLIC_KEY=...          # real public key
export PRODUCTION=1
Scripts/bundle-xcode-app.sh                     # Xcode path: extensions + Sparkle

IDENTITY="Developer ID Application: Your Name (TEAMID)" \
KEYCHAIN_PROFILE=AC_PASSWORD \
MAKE_DMG=1 \
Scripts/sign-and-notarize.sh                     # sign, notarise, staple (+ DMG)
```

`Scripts/sign-and-notarize.sh` is the manual twin of the workflow's signing
steps: it signs every nested executable individually (Sparkle framework and its
XPC helpers, the Spotlight importer, both Quick Look extensions, the `down` CLI, then the host — never
`codesign --deep`), verifies each, notarises with `notarytool`, staples, and
runs the `codesign`/`spctl`/`stapler validate` battery. Set `NO_NOTARIZE=1` to
sign with a real identity without submitting, and `MAKE_DMG=1` to additionally
notarise and staple the DMG. Credentials come from either a stored
`notarytool` keychain profile or the App Store Connect API key variables.

The GitHub Actions pipeline (`.github/workflows/release.yml`) is the supported
path: it signs every nested executable individually (no `codesign --deep`),
notarises with the App Store Connect API key, staples, runs
`codesign --verify --deep --strict` / `spctl` / `stapler validate`, publishes
the GitHub Release, and deploys the appcast to GitHub Pages.

## DMG packaging

`Scripts/make-dmg.sh` packages a built app into a drag-install DMG (app + an
`/Applications` symlink), using plain `hdiutil` — no external tools:

```bash
Scripts/make-dmg.sh                       # finds the latest built app
OUT_DIR=~/Desktop Scripts/make-dmg.sh /path/to/Downright.app
```

It writes `dist/Downright-<MARKETING_VERSION>.dmg` and verifies the image.
Run it on the *signed and notarised* app. Gatekeeper trusts the ticket stapled
inside the app, and the release workflow additionally notarises and staples the
DMG itself so users can run straight from the image. The DMG is a convenience
for humans; **Sparkle's update archives are always the zip**, so the DMG is
never part of the update feed.

### How the appcast is built

The workflow uses `generate_appcast` natively (no XML rewriting): it reads the
archive's `SUPublicEDKey` to produce per-archive EdDSA signatures, embeds
`RELEASE-NOTES.md` as signed CDATA release notes, builds delta updates from the
previous release zips, and points every enclosure URL at this tag's GitHub
Release assets. Delta archives are uploaded as assets of the same release.

Delta archives are named `<AppName><build>-<fromBuild>.delta` (e.g.
`Downright42-41.delta` — Sparkle's own convention, keyed on `CFBundleVersion`)
and are uploaded and checksum-verified as assets of the same release.
`--maximum-versions 1` keeps the feed a single item while deltas from the
previous archives still ship.

**Feed signing is the final step**: `sign_update appcast.xml` appends a
`sparkle-signatures` comment covering the first `length` bytes of the file, so
nothing may rewrite the XML afterwards — the `SURequireSignedFeed=YES`
contract. The private key is passed to both tools through standard input from
the `SPARKLE_ED25519_PRIVATE_KEY` secret and is never written to disk or logged.
`sign_update --verify` (also via stdin) is the workflow's post-sign validation;
Sparkle 2.9.5 ships no `appcast_validate` binary.

## Bundle verification

Both build paths run `Scripts/verify-bundle.sh` against the same contract:

```bash
Scripts/verify-bundle.sh Downright.app                 # structural checks
Scripts/verify-bundle.sh Downright.app --production    # + feed URL & key checks
```

It checks Sparkle and its nested XPC helpers, bundle-relative runtime paths,
the Quick Look extensions, the `down` CLI, host/extension version equality,
the privacy manifest, and (in production mode) the exact feed URL and a
non-placeholder public key.

## Release checklist (workflow path)

1. Bump `Config/version.env`; run `Scripts/sync-versions.sh fix`.
2. `Scripts/check.sh` — all suites, version gates, and the Sparkle link-scope
   check pass.
3. Push a `vX.Y.Z` SemVer tag pointing into `main`. `release.yml` takes over:
   gates → tests → universal signed/notarized build → zip + DMG → appcast →
   GitHub Release → GitHub Pages. If Pages deployment fails after the Release
   is public, the previous appcast stays active and re-running the deployment
   is safe.
4. Set Pages → Source: **GitHub Actions** in the repository settings (one-time).

For a release that must not go through CI, the manual path is
`bundle-xcode-app.sh` → `sign-and-notarize.sh` → `make-dmg.sh` above; run
`Scripts/verify-bundle.sh Downright.app --production` before distributing.

## Update failure policy

- Bad release not yet broadly installed: remove it from the appcast; keep the
  GitHub artifact for audit. Never move or replace an existing tag or ZIP.
- Installed bad release: ship a higher-build hotfix. Sparkle never downgrades.
- Suspected key compromise: stop publishing, rotate via Sparkle's key-rotation
  path, ship an anchored recovery release, then replace the CI secrets.
