# SwiftMath, vendored

| | |
|---|---|
| Upstream | <https://github.com/mgriebling/SwiftMath> |
| Version | `1.7.3` |
| Commit | `fa8244ed032f4a1ade4cb0571bf87d2f1a9fd2d7` |
| Licence | MIT — `LICENSE`, © 2023 Computer Inspirations. Unmodified. |
| Copied from | `.build/checkouts/SwiftMath` at that tag, verbatim (minus `.git`) |

Everything here is upstream source except the two items under **The patch**
and the four under **Rendering patches**. Every patched line carries a
`Downright patch` comment; `grep -rn 'Downright patch' Vendor/SwiftMath/Sources`
lists them.

## Why it is vendored

SwiftMath keeps its fonts in a SwiftPM resource bundle and reaches them through
the generated `Bundle.module`, which offers exactly two candidates:

```swift
let mainPath  = Bundle.main.bundleURL.appendingPathComponent("SwiftMath_SwiftMath.bundle").path
let buildPath = "/Users/…/.build/arm64-apple-macosx/debug/SwiftMath_SwiftMath.bundle"
guard let bundle = Bundle(path: mainPath) ?? Bundle(path: buildPath) else {
    Swift.fatalError("could not load resource bundle: from \(mainPath) or \(buildPath)")
}
```

Neither survives shipping:

* `Bundle.main.bundleURL` is a macOS bundle's **root**, and codesign forbids any
  entry there other than `Contents` (it fails with "unsealed contents present in
  the bundle root"). The copy we ship in `Contents/Resources` is therefore never
  found.
* The build path exists on the machine that compiled the code and nowhere else.

So the accessor resolved only on the build machine — `Scripts/bundle-app.sh`
produced an app that rendered math here and nowhere else — and everywhere else
it called `fatalError`. That is not a degraded formula: two crash reports in
`~/Library/Logs/DiagnosticReports/` show the Xcode-built `.appex` dying with
`EXC_BREAKPOINT` in `_assertionFailure` from this accessor, i.e. one formula
taking down the whole Quick Look preview.

The accessor is generated, so it cannot be fixed from outside the package, and
`MTFont.fontBundle` / `MTFont.init(fontWithName:size:)` are both `internal`, so
there is no supported way to hand SwiftMath a bundle we resolved ourselves. A
three-line change inside the package is the whole fix, which is what makes
vendoring cheap enough to prefer over a fork or a runtime shim.

`Sources/MarkdownRender/Fragments/MathFontBundle.swift` still guards every call
into SwiftMath as defence in depth: it predicts the resolver's candidate list
and declines the work when the fonts are genuinely absent, so a broken install
degrades to "Formula could not be typeset" instead of trapping. **Its candidate
list must stay in step with `MathResourceBundle.resources` below** — a candidate
here that is missing there is a false negative (a formula silently not
rendered); a candidate there that is missing here is a false positive (a trap).

## The patch

**1. Added `Sources/SwiftMath/MathBundle/MathResourceBundle.swift`** — one
internal resolver that probes the layouts we actually ship (`Bundle.main`'s
resource directory, the `Bundle(for:)` bundle's resource directory, that
bundle's parent directory, the flat bundle root) and falls back to
`Bundle.module` for `swift run` / `swift test`. It follows the shape of
`Sources/MarkdownRender/Theme/ThemeStore.swift`'s `resourceBundle`, which solves
the same problem for our own resources. The file is new, so re-applying it after
an upstream update is a copy.

**2. Replaced the three — and only three — `Bundle.module` uses** with
`MathResourceBundle.resources`. Nothing else in the package touches
`Bundle.module`; confirm with
`grep -rn 'Bundle.module' Vendor/SwiftMath/Sources` after any update.

```diff
--- a/Sources/SwiftMath/MathBundle/MathFont.swift
+++ b/Sources/SwiftMath/MathBundle/MathFont.swift
@@ -92,7 +92,7 @@
     private func registerCGFont(mathFont: MathFont) throws {
-        guard let frameworkBundleURL = Bundle.module.url(forResource: "mathFonts", withExtension: "bundle"),
+        guard let frameworkBundleURL = MathResourceBundle.resources.url(forResource: "mathFonts", withExtension: "bundle"),
               let resourceBundleURL = Bundle(url: frameworkBundleURL)?.path(forResource: mathFont.rawValue, ofType: "otf") else {
@@ -119,7 +119,7 @@
     private func registerMathTable(mathFont: MathFont) throws {
-        guard let frameworkBundleURL = Bundle.module.url(forResource: "mathFonts", withExtension: "bundle"),
+        guard let frameworkBundleURL = MathResourceBundle.resources.url(forResource: "mathFonts", withExtension: "bundle"),
               let mathTablePlist = Bundle(url: frameworkBundleURL)?.url(forResource: mathFont.rawValue, withExtension:"plist") else {

--- a/Sources/SwiftMath/MathRender/MTFont.swift
+++ b/Sources/SwiftMath/MathRender/MTFont.swift
@@ -41,7 +41,7 @@
     static var fontBundle:Bundle {
         // Uses bundle for class so that this can be access by the unit tests.
-        Bundle(url: Bundle.module.url(forResource: "mathFonts", withExtension: "bundle")!)!
+        Bundle(url: MathResourceBundle.resources.url(forResource: "mathFonts", withExtension: "bundle")!)!
     }
```

## Rendering patches

Issue #55 asked for the LaTeX people write for KaTeX, MathJax, Typora and
Obsidian. Most of that is a different spelling of something SwiftMath already
draws, and `Sources/MarkdownRender/Fragments/SwiftMathDialect.swift` handles
it outside the package: it rewrites the string handed to SwiftMath and
registers missing symbols through the public
`MTMathAtomFactory.add(latexSymbol:value:)`. The four changes below are what
cannot be done from outside. Each is a parser-level bug or gap, and none
touches layout or fonts.

**3. Non-ASCII characters become atoms** (`MTMathAtomFactory.atom(forCharacter:)`).
Upstream returns `nil` for any non-ASCII character outside a small accented
Latin and Cyrillic list, and the builder then skips it *without an error*.
`\text{中文}` therefore rendered as nothing, and a typed `α` or `≤` vanished
from the formula. Now a character the symbol table knows (`α`, `≤`, `∑`)
becomes the same atom as its command, and any other character becomes an
ordinary atom. Core Text's line layout supplies a fallback font for glyphs the
math font lacks, such as CJK and emoji. Upstream `main` (unreleased) accepts
any character, but only inside `\text{}`; this patch also covers math mode and
the typed symbols.

**4. Every text-mode command keeps its spaces** (`buildInternal`). Upstream
allows unescaped spaces only for `\text`, so `\textbf{two words}` rendered as
"twowords".

**5. `\operatorname{name}`** (`atomForCommand`). This is the same construct as
upstream `main`: an upright large operator with operator spacing. The
`\operatorname*` star is rewritten to a trailing `\limits` by
`SwiftMathDialect`, because the 1.7.3 command reader only reads letters.

**6. `\&`** (`readCommand`). The symbol table defines `&`, but the parser's
single-character command list omitted it, so `\&` failed as "Invalid command".

```diff
--- a/Sources/SwiftMath/MathRender/MTMathAtomFactory.swift
+++ b/Sources/SwiftMath/MathRender/MTMathAtomFactory.swift
@@ -623,4 +623,14 @@ public class MTMathAtomFactory {
 				return atom(fromAccentedCharacter: ch)
+            case _ where !ch.isASCII:
+                if let name = textToLatexSymbolName[chStr], let symbol = atom(forLatexSymbol: name) {
+                    return symbol
+                }
+                return MTMathAtom(type: .ordinary, value: chStr)
             case _ where ch.utf32Char < 0x0021 || ch.utf32Char > 0x007E:

--- a/Sources/SwiftMath/MathRender/MTMathListBuilder.swift
+++ b/Sources/SwiftMath/MathRender/MTMathListBuilder.swift
@@ -258,5 +258,7 @@ public struct MTMathListBuilder {
-                    spacesAllowed = command == "text"
+                    spacesAllowed = command.hasPrefix("text")
@@ -574,4 +576,15 @@ public struct MTMathListBuilder {
             return newInner;
+        } else if command == "operatorname" {
+            let content = self.buildInternal(true)
+            let name = content?.atoms.map(\.nucleus).joined() ?? ""
+            if name.isEmpty {
+                self.setError(.invalidCommand, message: "Missing operator name for \\operatorname")
+                return nil
+            }
+            return MTLargeOperator(value: name, limits: false)
         } else if command == "overline" {
@@ -966,5 +979,7 @@ public struct MTMathListBuilder {
-        let singleChars = "{}$#%_| ,>;!\\"
+        let singleChars = "{}$#%_| ,>;!\\&"
```

(Comment lines omitted from the diff above; they are in the source.)

`Tests/MarkdownRenderTests/MathDialectTests.swift` covers all four patches and
the dialect. After an upstream update, a rendering patch that upstream now
covers can be dropped if that suite still passes. `SwiftMathDialect` registers
a symbol only when SwiftMath lacks it, so upstream definitions take precedence
automatically, with one deliberate exception: `\square` is always replaced,
because SwiftMath's own `\square` is a blue editing placeholder and a
document needs the end-of-proof box. Keep that override after an update.

## Updating to a new upstream version

1. `git clone --depth 1 --branch <tag> https://github.com/mgriebling/SwiftMath /tmp/SwiftMath`
2. `rsync -a --delete --exclude .git /tmp/SwiftMath/ Vendor/SwiftMath/`
   (this deletes `PATCHES.md` and `MathResourceBundle.swift` — restore both from
   git: `git checkout -- Vendor/SwiftMath/PATCHES.md Vendor/SwiftMath/Sources/SwiftMath/MathBundle/MathResourceBundle.swift`)
3. `grep -rn 'Bundle.module' Vendor/SwiftMath/Sources` — replace every hit with
   `MathResourceBundle.resources`. If a hit resolves a resource *other than*
   `mathFonts.bundle`, stop and think: the resolver answers one question only.
4. Re-apply the **Rendering patches** whose behaviour upstream still lacks
   (the `MathDialectTests` suite tells you which).
5. Update the version, commit, and diff in this file.
6. `swift build && LC_ALL=en_US.UTF-8 Scripts/check.sh`, then
   `Scripts/bundle-app.sh && Scripts/bundle-quicklook.sh` — `verify-bundle.sh`
   asserts the fonts land where the resolver looks in every bundle we ship.
