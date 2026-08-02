# Releasing Downright

Downright is distributed **outside the Mac App Store**, signed and notarised,
updated via Sparkle (spec §3.4). That is not a limitation — it is what makes
FSEvents on arbitrary paths, opening `file.ts:42` in your editor, the `down`
CLI, and sibling scanning possible at all. Sandboxed competitors cannot build
those features.

## What SwiftPM can and cannot do here

`Scripts/bundle-app.sh` assembles a complete, runnable `Downright.app` from
SwiftPM build products with no Xcode project involved. What it cannot do:

| Needs Xcode | Why |
|---|---|
| Quick Look `.appex` bundles | App-extension targets, `NSExtension` plists, and nested signed bundles are Xcode-only build products. See [QUICKLOOK.md](QUICKLOOK.md). |
| Sparkle framework embedding | Sparkle ships as an embedded framework with its own XPC helpers, which need a Copy Files phase and per-bundle signing. |
| Developer ID signing and notarisation | Requires a certificate in the login keychain and an App Store Connect API key. |

Everything else — the app, the render packages, the CLI, the tests — builds with
the Command Line Tools alone.

## Signing and notarising

Ad-hoc signing (what `bundle-app.sh` does) is enough to run locally. For
distribution:

```bash
codesign --force --options runtime --timestamp \
  --sign "Developer ID Application: YOUR NAME (TEAMID)" \
  --deep .build-main/bundle/Downright.app
```

```bash
ditto -c -k --keepParent .build-main/bundle/Downright.app Downright.zip
```

```bash
xcrun notarytool submit Downright.zip --keychain-profile "AC_PASSWORD" --wait
```

```bash
xcrun stapler staple .build-main/bundle/Downright.app
```

Store the App Store Connect credentials once with:

```bash
xcrun notarytool store-credentials "AC_PASSWORD" --apple-id you@example.com --team-id TEAMID
```

**Hardened runtime note.** Downright is unsandboxed by design, but the hardened
runtime is still required for notarisation. No special entitlements are needed:
the app reads and writes files the user hands it, spawns `open`/`xed` to reach
external editors, and talks to no network service.

## Sparkle

Add the dependency to `Package.swift`:

```swift
.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
```

Then, in an Xcode wrapper project, embed `Sparkle.framework` into
`Contents/Frameworks` with a Copy Files phase, sign it separately, and add to
`Info.plist`:

```xml
<key>SUFeedURL</key>
<string>https://downright.app/appcast.xml</string>
<key>SUPublicEDKey</key>
<string>YOUR_ED25519_PUBLIC_KEY</string>
```

Generate the key pair with Sparkle's `generate_keys`, sign each release with
`sign_update`, and publish the resulting `appcast.xml` alongside the zip.

The app has one integration point ready for this: `AppDelegate` performs no
update checks of its own, so wiring `SPUStandardUpdaterController` is additive.

## Release checklist

1. `Scripts/check.sh` — all suites run and pass.
2. `Scripts/bundle-app.sh` and launch the bundle; open `Docs/sample.md` and
   check every renderer path.
3. Verify the performance budget (spec §12) on a 5k-line document: cold launch
   under 250ms to first pixel, p95 keystroke under 8ms.
4. Rebuild the Quick Look extensions in the Xcode wrapper and verify previews
   *and* Finder thumbnails on a folder of agent output.
5. Bump `CFBundleShortVersionString` in `Scripts/bundle-app.sh` and the `down`
   CLI's `toolVersion`.
6. Sign, notarise, staple, verify with `spctl -a -vvv Downright.app`.
7. Sign the update with Sparkle and publish the appcast.
8. Tag the release and publish `MarkdownCore` / `MarkdownRender` — they are the
   artifacts other people actually want.
