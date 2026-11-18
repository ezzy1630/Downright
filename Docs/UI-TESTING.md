# Native UI testing

Use the in-process driver for document interaction you can express as AppKit input and verify against the window or document. It opens real controllers and uses the same TextKit layout, source mapping, responder chain, and model as Downright. It runs in the source gate on macOS with a WindowServer session. The fixture stays transparent, ignores desktop pointer input, and stays out of macOS focus. It doesn’t need Automation Mode or Accessibility permission.

Use the activated XCUITest suite on hosted CI for behavior that depends on a packaged, foreground app, system dialogs, or another process. Use manual QA for judgments like material legibility or animation quality, and for hardware and OS combinations the automated lanes can’t exercise. See [CI and test evidence](CI.md) for the supported gates.

## Run a focused test

On an Xcode toolchain, create a disposable support directory before SwiftPM starts. App services load their support paths at initialization. The source gate already sets and cleans this directory.

```bash
(
  DOWNRIGHT_SUPPORT_DIRECTORY="$(mktemp -d)" || exit 1
  export DOWNRIGHT_SUPPORT_DIRECTORY
  trap 'find "$DOWNRIGHT_SUPPORT_DIRECTORY" -depth -delete' EXIT
  swift test --no-parallel --scratch-path .build-ui-test --filter 'Native(UIDriver|RenderInput|PreviewInput)Tests'
)
```

Run `Scripts/check.sh` for the authoritative check, including Command Line Tools configurations. Check for the concluding Swift Testing summary from each target that had a selected suite. In particular, AppKit event posting can stop the SwiftPM runner before it emits a result. A zero exit code with a missing summary does not establish a pass. [Swift runtime issue](https://github.com/swiftlang/swift/issues/91716)

## Driver API

In `DownrightAppTests`, use a main-actor test and the scoped fixture. Extra files sit alongside the document for relative links and images. The fixture closes the window and removes its files when the body finishes, including on a thrown error.

```swift
@Test @MainActor
func selectsRenderedHeadingExactly() async throws {
    try await UIDriver.withDocument("# Title\n\nBody\n") { ui in
        try ui.doubleClick(onText: "Title")
        ui.check(ui.selectedSourceRange == NSRange(location: 2, length: 5),
                 "Expected the five heading characters at source UTF-16 offset 2")
    }
}
```

| API | Behavior |
| --- | --- |
| `UIDriver.withDocument(_:mode:files:run:)` | Opens disposable Markdown in a real `DocumentWindowController`. |
| `click(onText:modifiers:)`, `doubleClick(onText:)`, `drag(fromText:toText:)` | Resolve explicit visible source text through TextKit. Drag starts before the first match and ends after the second. |
| `point(atSourceOffset:in:)`, `point(onText:)` | Locate a UTF-16 insertion boundary or the interior of a glyph. A target must be in the visible viewport. An explicit pane can be selected in Split View. |
| `hover(onText:)`, `scroll(lines:)`, `resize(width:)` | Dispatch pointer movement or a pixel-wheel event at the current document, or change the native window’s content size. |
| `type(_:)`, `press(_:modifiers:)` | Send key-down and key-up to the window. `type` sends graphemes as event text. Use a named key for Return, Delete, Escape, and arrows. |
| `source`, `selectedSourceRange`, `selectedSourceText`, `isDirty`, `window` | Observe the live document and window. Selection offsets are always UTF-16 source positions. |
| `wait(until:_:)` | Await an observed condition with a one-second deadline and a specific failure description. Use a completion or notification when one is available. |
| `snapshot()`, `check(_:_:)` | Read an AppKit content bitmap as PNG data or record a Swift Testing issue and retain the first failure bitmap. Errors thrown inside the fixture also trigger capture. Set `DOWNRIGHT_UI_TEST_ARTIFACTS` to collect images in a specific directory. The default is `downright-ui-failures` in the system temp directory. |

`WindowInput` is also available in renderer and Quick Look tests. Those tests install the view or view controller and own window and file teardown. Events use `NSWindow.sendEvent`. For selection and native control tracking, the bridge supplies drag and mouse-up events when AppKit asks that window for them. It also keeps AppKit’s repost of those same events in the fixture. For hover, AppKit’s ordinary synthetic mouse move goes through the registered tracking owner. WindowServer-generated entered/exited transitions, physical cursor changes, and cross-window pointer handoffs remain activated acceptance surfaces.

Use `input.sendAction(_:to:)` for Undo, Redo, Copy, Cut, and Paste. These menu commands normally resolve against the system key window. Supplying the fixture window or its actual first responder runs AppKit’s action dispatch without requiring system focus. Use `input.withPrivatePasteboard` for clipboard tests. This scope supplies a real named pasteboard in place of the general pasteboard inside the test process. Settings tests exercise real controls, notifications, and support-directory persistence. The test-only bridge suppresses the four mirrored global Quick Look writes while the source gate runs.

Typography tests choose an item and dispatch the real popup action. AppKit’s native popup menu tracking and keyboard menu targeting require activated coverage. A bitmap from `cacheDisplay` covers the view-tree drawing path. Desktop compositing, animation frames, and the accessibility tree of the packaged app have their own acceptance surface.

## Turn a report into a driver test

1. Reduce the report to a short Markdown fixture, an actual gesture, and the expected source or visible state. Capture the exact UTF-16 range, dirty flag, disk bytes, or viewport anchor that identifies the bug.
2. Put the test in the lowest suite that can exercise the real boundary. Use the app driver for document, settings, and file interactions. Host the renderer or Quick Look view directly when the app shell is irrelevant.
3. Resolve targets from the actual text layout or a view’s bounds. Send input through the window. Check the expected state without setting selection, editing the storage, or calling the subject’s event handler as fixture setup.
4. Run the check on the buggy source and confirm the assertion fails. If the fix belongs to another lane, leave the regression disabled with the issue or owning change in the reason. Enable it when that change lands and run the full gate.

## Activated coverage kept in CI

The current activated suite remains intact. Its link and navigation, split-pane editing, dirty-state reversal, and inline image source-preservation journeys now have source-gate counterparts. Each activated case still exercises the extra packaged or foreground surface below.

| Activated coverage | What CI still exercises |
| --- | --- |
| Plain and encoded links, Back and Forward | Real cursor arrival, native menu targets, foreground window identity, and compositor readback of the destination heading. |
| Split View and clean-close cases in Document and Source modes | Window menu tracking, packaged accessibility state, and the presence or absence of a real save alert on close. |
| Unterminated prose and the activated render/edit smoke | First launch, toolbar controls and accessibility, composited prose, and real keyboard undo targeting. |
| Inline image animation, many images, and adjacent image rows | Play/Pause controls, restart behavior, and image pixels that remain visible during real pointer movement. |
| Last-document-close preferences | App lifecycle and actual switching, staying open, or termination. |
| HTML export | User interaction with the system save panel service and exported file readback. |
| Production updater | Packaged Sparkle, signed feed, release configuration, and foreground dismissal. |
| Star suggestion cases | Active-app sampling, idle timing, foreground focus, native dismissal and resize, and retirement across relaunch. |
