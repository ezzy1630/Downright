# Quick Look

Downright contains code for two Quick Look extensions: a **preview**
(`DownrightQL`) and a **thumbnail generator** (`DownrightThumb`). The default
SwiftPM app bundle does not include their `.appex` bundles. Both import the same
`MarkdownRender` package the app draws with, so neither can drift from the app's
rendering — that is the whole reason the renderer is native rather than a
WebView (spec §3.3).

## Enabling it — read this first

**This is the number one support question for every app in this category**, so
it is documented up front rather than in a FAQ:

First build and embed the extension bundles with the steps below. Then:

1. **Launch Downright once.** Quick Look extensions only register with the
   system after the host app has been run at least once. A freshly copied
   `.app` that has never been opened contributes no extensions.
2. If previews still don't appear, enable the extension manually:
   **System Settings → General → Login Items & Extensions → Quick Look**, then
   tick **Downright**.
3. If a preview is still stale, reset the Quick Look daemon:

```bash
qlmanage -r && qlmanage -r cache && killall Finder
```

## What the preview does

- Read-mode rendering with the app's full typography.
- The density gutter, when the panel is wide enough (≥ 520pt).
- Arrow keys scroll, `n`/`p` jump between headings.
- Text is selectable and copyable. Most Quick Look previews are dead surfaces;
  this one isn't.

## Memory discipline

A Quick Look extension has a hard ceiling around **120MB** and is **killed
outright** if it exceeds it. The preview therefore:

- Polls `malloc_zone_statistics` and falls back to plain text above **60MB** —
  well under the kill threshold.
- Renders only the first 60 blocks of files over **2MB**, with an
  "Open in Downright" affordance.
- Renders math, mermaid, and images lazily, only for fragments in the viewport.

A `WKWebView` carrying KaTeX and Mermaid.js would not reliably fit in that
budget. Native rendering is the only way the Quick Look experience matches the
app's.

## Thumbnails

`DownrightThumb` gives `.md` files real Finder icons showing the document's
**first heading**, its opening line, and — when the document is a plan — its
task completion count.

On a folder full of agent output this is transformative: twelve files called
`plan.md`, `output.md`, and `summary.md` become twelve distinguishable
documents.

The thumbnail reads only the first 64KB of the file and parses with
`ParseOptions.structureOnly`, so it never touches math, mermaid, or images.

## Registered file types

`.md`, `.markdown`, `.mdown`, `.mkd`, `.mdx`, `.mdc`, `.qmd`, `.rmd`.

`.txt` is deliberately **not** claimed by default — taking plain text away from
TextEdit is not a decision an app should make for you. Opt in per-file with
Finder's *Get Info → Open with → Change All*.

## Building the extensions

**This is the one part of the project that needs Xcode.** An `.appex` bundle
cannot be produced by SwiftPM: it needs an app-extension target, an embedded
`Info.plist` with an `NSExtension` dictionary, and a signed bundle nested inside
the host app's `Contents/PlugIns/`.

The sources are complete and compile as libraries against the same package. To
ship them:

1. Create an Xcode project wrapping this SwiftPM package (File → Add Package
   Dependencies → Add Local, pointing at this directory).
2. Add a **Quick Look Preview Extension** target. Set its principal class to
   `PreviewViewController` and add `Sources/DownrightQL/` to it.
3. Add a **Quick Look Thumbnail Extension** target. Set its principal class to
   `ThumbnailProvider` and add `Sources/DownrightThumb/` to it.
4. Add `MarkdownCore` and `MarkdownRender` to both targets' Frameworks phases.
5. Set both extensions' `QLSupportedContentTypes` to the UTIs listed above.
6. Embed both into the host app's `Contents/PlugIns/`.

The `Info.plist` fragments each extension needs:

```xml
<!-- DownrightQL -->
<key>NSExtension</key>
<dict>
    <key>NSExtensionAttributes</key>
    <dict>
        <key>QLSupportedContentTypes</key>
        <array>
            <string>net.daringfireball.markdown</string>
            <string>com.unrulyagency.downright.markdown</string>
        </array>
        <key>QLSupportsSearchableItems</key><false/>
    </dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.quicklook.preview</string>
    <key>NSExtensionPrincipalClass</key>
    <string>DownrightQL.PreviewViewController</string>
</dict>
```

```xml
<!-- DownrightThumb -->
<key>NSExtension</key>
<dict>
    <key>NSExtensionAttributes</key>
    <dict>
        <key>QLSupportedContentTypes</key>
        <array>
            <string>net.daringfireball.markdown</string>
            <string>com.unrulyagency.downright.markdown</string>
        </array>
    </dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.quicklook.thumbnail</string>
    <key>NSExtensionPrincipalClass</key>
    <string>DownrightThumb.ThumbnailProvider</string>
</dict>
```
