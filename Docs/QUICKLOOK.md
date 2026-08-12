# Quick Look

Downright contains code for two Quick Look extensions: a **preview**
(`DownrightQL`) and a **thumbnail generator** (`DownrightThumb`). The default
SwiftPM app bundle does not include their `.appex` bundles. Both import the same
`MarkdownRender` package the app draws with, so neither can drift from the app's
rendering — that is the whole reason the renderer is native rather than a
WebView (spec §3.3).

## Enabling it — read this first

**This is the number one support question for every app in this category**, so
it is documented up front rather than in a FAQ.

**The answer for a normal install is: nothing.** Launch Downright once. The
first-run setup panel registers the bundle with Launch Services, hands both
extensions to `pluginkit`, enables them, and resets Quick Look's caches — the
last of those being what makes `.md` files you already have drop their generic
icons. This used to live only in `Scripts/install.sh`, which meant the shipping
path (download the DMG, drag to Applications, double-click) ran none of it and
the one user who mattered most got nothing.

`Scripts/install.sh` still does the same work for a source install, so building
from the repository does not depend on launching the app first.

Three things can still go wrong, and the app handles each:

- **Running from the DMG or Downloads.** Gatekeeper runs the app out of a
  randomised read-only mount, and extensions registered from there never stick.
  The setup panel leads with moving the app into Applications and relaunching.
- **The app moved after setup.** Launch Services and `pluginkit` both record an
  absolute path. Downright stores where it last registered and re-registers
  when that changes, so a rename or a move repairs itself on next launch.
- **macOS declines to enable the extension.** Only the user can switch it on:
  **System Settings → General → Login Items & Extensions → Quick Look**, then
  tick **Downright**. The setup panel detects this and offers a button that
  opens that exact pane.

To reset by hand:

```bash
qlmanage -r && qlmanage -r cache && killall Finder
```

Settings → General → System integration repeats every step at any time.

## What the preview does

- Read-mode rendering with the app's full typography.
- The leading-edge density gutter, when the panel is wide enough (≥ 520pt).
  Hover shows the current section and reading metrics; click or drag scrubs the
  document; dwelling opens the outline. In compact Finder panels the hover card
  becomes a small translucent overlay rather than disappearing or covering the
  whole page.
- Arrow keys scroll; `n`/`p` jump between headings.
- Text is selectable and copyable. Most Quick Look previews are dead surfaces;
  this one isn't.
- Appearance follows macOS by default. Choose **Settings → Appearance → Quick
  Look appearance** to pin previews to Light or Dark; the setting is shared with
  the sandboxed extension.

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
**first heading**, its opening line, and — when the document is a plan — a
progress bar for its task completion.

On a folder full of agent output this is transformative: twelve files called
`plan.md`, `output.md`, and `summary.md` become twelve distinguishable
documents.

The thumbnail reads only the first 64KB of the file and parses with
`ParseOptions.structureOnly`, so it never touches math, mermaid, or images.

Three rules the drawing code exists to obey, each of which was broken once:

- **It is a page, not a square.** `QLFileThumbnailRequest.maximumSize` is a
  bounding box. Handing it back as the context size produces a square icon
  sitting among every other app's portrait documents, which reads as a mistake
  before it reads as a file. The reply is sized to 8.5:11 inside the box.
- **The palette is fixed sRGB, never `labelColor` or `textBackgroundColor`.** A
  thumbnail is drawn once by a background process with no appearance context
  and then cached by the system for months, so a dynamic colour bakes in
  whatever that process happened to resolve to and can strand a light icon in a
  dark Finder. Document icons are artwork; Pages and TextEdit are white pages
  in both appearances too.
- **Text wraps.** `NSMutableParagraphStyle.lineBreakMode = .byTruncatingTail`
  does not wrap — it lays the whole string on one line and clips it. Wrapping
  belongs on the paragraph style and truncation on the `NSTextContainer`.
  Relatedly, `NSLayoutManager` lays out top-down, so glyphs drawn into an
  unflipped context come out in reverse line order; the text is drawn through
  a flipped context of its own.

Below 72pt the icon stops drawing real text — at Finder's list and column sizes
it is a grey smudge — and draws proportioned rules that read as a page instead.

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
