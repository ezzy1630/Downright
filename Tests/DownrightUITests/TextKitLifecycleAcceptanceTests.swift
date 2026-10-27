import AppKit
import MarkdownCore
import MarkdownRender
import XCTest

/// WindowServer coverage for the empty-to-loaded transition that offscreen
/// package tests cannot establish. These windows belong to the test runner;
/// no diagnostic switches or alternate views are installed in Downright.app.
@MainActor
final class TextKitLifecycleAcceptanceTests: XCTestCase {
    func testNativeTextSystemConstructedWithContentRenders() throws {
        try exercise(markdown: false, initiallyEmpty: false)
    }

    func testNativeTextSystemLoadedAfterConstructionRenders() throws {
        try exercise(markdown: false, initiallyEmpty: true)
    }

    func testMarkdownTextSystemConstructedWithContentRenders() throws {
        try exercise(markdown: true, initiallyEmpty: false)
    }

    func testMarkdownTextSystemLoadedAfterConstructionRenders() throws {
        try exercise(markdown: true, initiallyEmpty: true)
    }

    func testMarkdownTextSystemMountedBeforeLoadingRenders() throws {
        try exercise(markdown: true, initiallyEmpty: true, mountBeforeLoad: true)
    }

    func testMarkdownNativeViewLayoutAfterLoadingRenders() throws {
        try exercise(markdown: true, initiallyEmpty: true, mountBeforeLoad: true, forceNativeLayout: true)
    }

    func testMarkdownContentSynchronizationAfterLoadingRenders() throws {
        try exercise(markdown: true, initiallyEmpty: true, mountBeforeLoad: true, synchronizeContent: true)
    }

    func testMarkdownPrimaryLayoutManagerAfterLoadingRenders() throws {
        try exercise(markdown: true, initiallyEmpty: true, mountBeforeLoad: true, synchronizeContent: true, declarePrimary: true)
    }

    func testNativeInitiallyZeroSizedViewportRecoversAfterLoading() throws {
        try exercise(markdown: false, initiallyEmpty: true, mountBeforeLoad: true, initiallyZeroSized: true)
    }

    func testMarkdownInitiallyZeroSizedViewportRecoversAfterLoading() throws {
        try exercise(markdown: true, initiallyEmpty: true, mountBeforeLoad: true, initiallyZeroSized: true)
    }

    func testMarkdownNativeViewLayoutRecoversZeroSizedViewport() throws {
        try exercise(markdown: true, initiallyEmpty: true, mountBeforeLoad: true, forceNativeLayout: true, initiallyZeroSized: true)
    }

    private func exercise(markdown: Bool, initiallyEmpty: Bool,
                          mountBeforeLoad: Bool = false, forceNativeLayout: Bool = false,
                          synchronizeContent: Bool = false, declarePrimary: Bool = false,
                          initiallyZeroSized: Bool = false) throws {
        continueAfterFailure = false
        let text = String(repeating: "Native text rendering has plain prose with predictable source positions.\n\n", count: 20)
        let storage = NSTextStorage(string: initiallyEmpty ? "" : text)
        let viewport = NSRect(x: 0, y: 0, width: 700, height: 480)
        let textView: NSTextView
        let surface: NSView
        let nativeContent: NSTextContentStorage?
        let markdownPane: MarkdownContainerView?
        if markdown {
            let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
            let sheet = StyleSheet(theme: .fallback, appearance: appearance)
            let pane = MarkdownContainerView(storage: storage, styleSheet: sheet)
            markdownPane = pane
            nativeContent = nil
            textView = pane.textView
            surface = pane
        } else {
            let content = NSTextContentStorage()
            let layout = NSTextLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
            container.widthTracksTextView = false
            container.lineFragmentPadding = 0
            layout.textContainer = container
            content.addTextLayoutManager(layout)
            content.textStorage = storage
            nativeContent = content
            markdownPane = nil
            let view = NSTextView(frame: viewport, textContainer: container)
            view.isVerticallyResizable = true
            view.isHorizontallyResizable = false
            view.minSize = NSSize(width: 600, height: 0)
            view.maxSize = NSSize(width: 700, height: CGFloat.greatestFiniteMagnitude)
            view.textContainerInset = NSSize(width: 44, height: 36)
            view.backgroundColor = .white
            let scroll = NSScrollView(frame: viewport)
            scroll.documentView = view
            textView = view
            surface = scroll
        }
        surface.frame = initiallyZeroSized ? .zero : viewport
        surface.autoresizingMask = []
        let root = NSView(frame: viewport)
        root.addSubview(surface)
        let window = NSWindow(contentRect: viewport, styleMask: [.titled, .closable],
                              backing: .buffered, defer: false)
        window.title = name
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        defer { window.close() }
        if mountBeforeLoad {
            window.contentView = root
            surface.layoutSubtreeIfNeeded()
        }
        trace("constructed", storage: storage, view: textView)
        if initiallyEmpty {
            storage.beginEditing()
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
            storage.endEditing()
        }
        trace("characters inserted", storage: storage, view: textView)
        if let pane = markdownPane {
            pane.textView.update(document: MarkdownParser.parse(text), dirty: .wholesale)
        } else {
            storage.addAttributes([.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black],
                                  range: NSRange(location: 0, length: storage.length))
        }
        if synchronizeContent {
            let content = try XCTUnwrap(textView.textContentStorage)
            XCTAssertFalse(content.hasEditingTransaction, "Loading left an active native editing transaction")
            if declarePrimary { content.primaryTextLayoutManager = textView.textLayoutManager }
            content.performEditingTransaction {}
            content.synchronizeTextLayoutManagers { error in
                print("LIFECYCLE synchronization error: \(String(describing: error))")
            }
        }
        if !mountBeforeLoad { window.contentView = root }
        if initiallyZeroSized { surface.frame = viewport }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        window.layoutIfNeeded()
        surface.layoutSubtreeIfNeeded()
        markdownPane?.textView.prepareForDisplay()
        if forceNativeLayout {
            textView.needsLayout = true
            textView.layoutSubtreeIfNeeded()
        }
        trace("prepared", storage: storage, view: textView)
        withExtendedLifetime(nativeContent) {
            assertVisibleProse(in: surface, window: window)
            trace("after display", storage: storage, view: textView)
            window.close()
        }
        XCTAssertEqual(storage.string, text)
    }

    private func trace(_ phase: String, storage: NSTextStorage, view: NSTextView) {
        let content = view.textContentStorage
        let observer = storage.textStorageObserver
        let controller = view.textLayoutManager?.textViewportLayoutController
        print("LIFECYCLE \(name) \(phase): appRunning=\(NSApp.isRunning) observer=\(String(describing: observer)) owns=\((observer as AnyObject?) === content) editing=\(String(describing: content?.hasEditingTransaction)) range=\(String(describing: content?.documentRange)) viewport=\(String(describing: controller?.viewportRange)) bounds=\(String(describing: controller?.viewportBounds)) visible=\(view.visibleRect) shown=\(view.window?.isVisible ?? false) delegate=\(String(describing: controller?.delegate))")
    }

    private func assertVisibleProse(in surface: NSView, window: NSWindow) {
        var screenshot: XCUIScreenshot?
        var edgeCount = 0
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            window.displayIfNeeded()
            let capture = XCUIScreen.main.screenshot()
            screenshot = capture
            guard let image = NSBitmapImageRep(data: capture.pngRepresentation)?.cgImage,
                  let screen = NSScreen.main else { return false }
            let rect = window.convertToScreen(surface.convert(surface.bounds, to: nil))
            let scale = CGFloat(image.width) / screen.frame.width
            let crop = CGRect(x: (rect.minX + rect.width * 0.20) * scale,
                              y: (screen.frame.maxY - rect.maxY + 24) * scale,
                              width: rect.width * 0.60 * scale,
                              height: max(0, rect.height - 48) * scale).integral
            guard let prose = image.cropping(to: crop) else { return false }
            let width = prose.width, height = prose.height
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
                guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                              bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                context.draw(prose, in: CGRect(x: 0, y: 0, width: width, height: height))
                return true
            }
            guard rendered else { return false }
            edgeCount = 0
            for y in stride(from: 0, to: height, by: 2) {
                for x in stride(from: 1, to: width, by: 2) {
                    let i = (y * width + x) * 4
                    let r = abs(Int(pixels[i]) - Int(pixels[i - 4]))
                    let g = abs(Int(pixels[i + 1]) - Int(pixels[i - 3]))
                    let b = abs(Int(pixels[i + 2]) - Int(pixels[i - 2]))
                    if max(r, max(g, b)) > 40 { edgeCount += 1 }
                }
            }
            return edgeCount > 80
        }, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: 10)
        if let screenshot {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertEqual(result, .completed, "Native lifecycle prose missing (\(edgeCount) contrasting pixel edges)")
    }
}
