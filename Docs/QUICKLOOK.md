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

Build and install with `Scripts/bundle-xcode-app.sh` followed by
`Scripts/install.sh`. The installer registers and enables both embedded
extensions and resets Quick Look's cache. If you copy the app manually,
follow these steps:

1. **Launch Downright once.** A freshly copied `.app` that has never been
   opened may not contribute its extensions to the system.
2. If previews don't appear, enable the extension manually:
   **System Settings → General → Login Items & Extensions → Quick Look**, then
   tick **Downright**.
3. If a preview is still stale, reset the Quick Look daemon:

```bash
qlmanage -r && qlmanage -r cache && killall Finder
```

## What the preview does

- Read-mode rendering with the app's full typography.
- The leading-edge density gutter, when the panel is wide enough (≥ 520pt).
  Hover shows the current section and reading metrics; click or drag scrubs the
  document; dwelling opens the outline.
- Arrow keys scroll; `n`/`p` jump between headings.
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

The repository includes an XcodeGen specification and extension plists. Run
the wrapper script from the repository root:

```bash
Scripts/bundle-xcode-app.sh
```

This generates the ignored `Downright.xcodeproj`, builds the host app, and
embeds `DownrightQL.appex` and `DownrightThumb.appex` in
`Contents/PlugIns/`. Set `CONFIGURATION=Debug` or `SCRATCH=/path/to/build` to
change the build. The script uses ad-hoc local settings; release builds need a
Developer ID identity and notarisation (see [RELEASE.md](RELEASE.md)).

The extension targets use these plists and principal classes:

- `Config/DownrightQL-Info.plist` → `DownrightQL.PreviewViewController`
- `Config/DownrightThumb-Info.plist` → `DownrightThumb.ThumbnailProvider`

Both declare the Markdown UTIs listed above. XcodeGen wires `MarkdownCore` and
`MarkdownRender` into both extensions and embeds both into the host app.

For reference, each extension plist contains an `NSExtension` dictionary like
this:

```xml
<!-- DownrightQL -->
<key>NSExtension</key>
<dict>
    <key>NSExtensionAttributes</key>
    <dict>
        <key>QLSupportedContentTypes</key>
        <array>
            <string>net.daringfireball.markdown</string>
            <string>com.ezzy.downright.markdown</string>
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
            <string>com.ezzy.downright.markdown</string>
        </array>
    </dict>
    <key>NSExtensionPointIdentifier</key>
    <string>com.apple.quicklook.thumbnail</string>
    <key>NSExtensionPrincipalClass</key>
    <string>DownrightThumb.ThumbnailProvider</string>
</dict>
```
