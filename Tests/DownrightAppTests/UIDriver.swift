import AppKit
import MarkdownRender
import NativeUITestSupport
import Testing

@testable import DownrightApp

/// The app fixture owns the controller and files. WindowInput is also usable
/// by renderer tests that host their own views without the app executable.
@MainActor
final class UIDriver {
    let controller: DocumentWindowController
    let input: WindowInput
    let root: URL
    let fixture: URL
    var window: NSWindow { input.window }
    var textView: MarkdownTextView { controller.containerTextView }
    var source: String { controller.markdownDocument.text }
    var selectedSourceRange: NSRange { textView.sourceSelectedRange }
    var selectedSourceText: String? {
        let text = source as NSString
        let range = selectedSourceRange
        guard range.location >= 0, range.location <= text.length,
              range.length >= 0, range.length <= text.length - range.location else { return nil }
        return text.substring(with: range)
    }
    var isDirty: Bool { controller.markdownDocument.isDirty }

    static func withDocument(
        _ markdown: String, mode: RenderMode = .live,
        files: [String: Data] = [:],
        test: String = #function,
        run: (UIDriver) async throws -> Void
    ) async throws {
        // These app services are process singletons. Select the isolated
        // support root before swift test starts, as check.sh already does.
        let environment = ProcessInfo.processInfo.environment
        let support = try #require(environment["DOWNRIGHT_SUPPORT_DIRECTORY"], "Set a temporary DOWNRIGHT_SUPPORT_DIRECTORY before launching swift test")
        let supportURL = URL(fileURLWithPath: support).resolvingSymlinksInPath()
        let userSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let userSupportPath = userSupport?.resolvingSymlinksInPath().path
        try #require(
            !support.isEmpty && userSupportPath.map {
                supportURL.path != $0 && !supportURL.path.hasPrefix($0 + "/")
            } != false,
            "UI tests need a disposable support directory"
        )
        _ = NSApplication.shared

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("downright-ui-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("original.md")
        try Data(markdown.utf8).write(to: fixture)
        for (name, bytes) in files {
            try bytes.write(to: root.appendingPathComponent(name))
        }

        let controller = DocumentWindowController()
        defer {
            controller.window?.orderOut(nil)
            controller.window?.resignKey()
            controller.close()
        }
        try controller.open(fixture, mode: mode)
        let window = try #require(controller.window)
        let input = WindowInput(window)
        let ui = UIDriver(controller: controller, input: input, root: root, fixture: fixture, test: test)
        do {
            try #require(!window.isKeyWindow && !NSApp.isActive, "The fixture must stay out of the system focus chain")
            try #require(window.makeFirstResponder(ui.textView), "The editor did not accept the window responder")
            ui.layout()
            try await run(ui)
            try #require(!window.isKeyWindow && !NSApp.isActive, "The test took system focus")
        } catch {
            ui.saveFailureSnapshot()
            throw error
        }
    }

    private let test: String
    private var failureSnapshot: URL?

    private init(controller: DocumentWindowController, input: WindowInput, root: URL, fixture: URL, test: String) {
        self.controller = controller
        self.input = input
        self.root = root
        self.fixture = fixture
        self.test = test
    }

    func layout() {
        window.layoutIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        textView.resizeToFitContent()
        textView.prepareForDisplay()
    }

    func range(of uniqueText: String) throws -> NSRange {
        let ns = source as NSString
        let range = ns.range(of: uniqueText, options: .literal)
        guard range.location != NSNotFound, range.length > 0,
              ns.range(of: uniqueText, options: .literal, range: NSRange(range.upperBound..<ns.length)).location == NSNotFound else {
            throw WindowInput.Failure("Expected one occurrence of \(uniqueText.debugDescription) in \(window.title)")
        }
        return range
    }

    func point(atSourceOffset offset: Int, in pane: MarkdownTextView? = nil) throws -> NSPoint {
        let view = pane ?? textView
        let caret = try #require(view.rect(forOffset: offset), "TextKit did not lay out source UTF-16 offset \(offset)")
        let local = NSPoint(x: caret.minX, y: caret.midY)
        try #require(view.visibleRect.contains(local), "Source UTF-16 offset \(offset) is outside the visible editor")
        return view.convert(local, to: nil)
    }

    func point(onText text: String) throws -> NSPoint {
        let range = try range(of: text)
        return try point(insideGlyphAt: range.location + (range.length - 1) / 2)
    }

    /// A point a quarter into the glyph at `offset`, which AppKit resolves to
    /// the insertion boundary before it. A point exactly on a line's leading
    /// boundary also touches the margin rail's edge and can miss the editor.
    func point(insideGlyphAt offset: Int) throws -> NSPoint {
        let glyph = (source as NSString).rangeOfComposedCharacterSequence(at: offset)
        let start = try point(atSourceOffset: glyph.location)
        let end = try point(atSourceOffset: glyph.upperBound)
        guard start.y == end.y else { return start }
        // Aim inside the glyph but before its midpoint, so a plain click
        // resolves to the insertion boundary at offset.
        return NSPoint(x: start.x + (end.x - start.x) * 0.25, y: start.y)
    }

    func click(onText text: String, modifiers: NSEvent.ModifierFlags = []) throws {
        try input.click(at: point(onText: text), modifiers: modifiers)
    }

    func doubleClick(onText text: String) throws {
        let point = try point(onText: text)
        try input.click(at: point, count: 2)
    }

    func drag(fromText start: String, toText end: String) throws {
        let from = try point(insideGlyphAt: range(of: start).location)
        let to = try point(atSourceOffset: range(of: end).upperBound)
        try requireEditorHit(at: from)
        try input.drag(from: from, to: to)
    }

    /// A mouse-down outside the editor leaves its selection untouched, which
    /// otherwise reads as a selection bug. Name the view that took the point.
    private func requireEditorHit(at point: NSPoint) throws {
        let content = window.contentView
        let hit = content?.hitTest(content?.superview?.convert(point, from: nil) ?? point)
        try #require(
            hit.map { $0 === textView || $0.isDescendant(of: textView) } == true,
            "Window point \(point) hits \(hit.map { String(describing: Swift.type(of: $0)) } ?? "nothing"), not the editor"
        )
    }

    func hover(onText text: String) throws { try input.move(to: point(onText: text)) }

    func scroll(lines: Int32) throws {
        let visible = textView.visibleRect
        let delta = -CGFloat(lines) * textView.styleSheet.lineHeight
        guard let pixels = Int32(exactly: delta.rounded()) else {
            throw WindowInput.Failure("Scroll distance is outside CGEvent's pixel range")
        }
        try input.scroll(deltaY: pixels, at: textView.convert(NSPoint(x: visible.midX, y: visible.midY), to: nil))
    }

    func resize(width: CGFloat) {
        window.setContentSize(NSSize(width: width, height: window.contentView?.bounds.height ?? window.frame.height))
        layout()
    }

    func press(_ key: WindowInput.Key, modifiers: NSEvent.ModifierFlags = []) throws {
        try input.press(key, modifiers: modifiers)
    }

    func press(_ character: Character, modifiers: NSEvent.ModifierFlags = []) throws {
        try press(.character(character), modifiers: modifiers)
    }

    func type(_ text: String) throws { try input.type(text) }

    func wait(until condition: @escaping () -> Bool, _ description: String) async throws {
        try await input.wait(until: condition, description)
    }

    func snapshot() throws -> Data { try input.snapshot() }

    func check(
        _ condition: Bool, _ message: String, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard !condition else { return }
        saveFailureSnapshot()
        Issue.record(
            Comment(rawValue: failureSnapshot.map { "\(message). Window PNG: \($0.path)" } ?? message),
            sourceLocation: sourceLocation
        )
    }

    private func saveFailureSnapshot() {
        guard failureSnapshot == nil else { return }
        do {
            let artifacts = ProcessInfo.processInfo.environment["DOWNRIGHT_UI_TEST_ARTIFACTS"]
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("downright-ui-failures", isDirectory: true)
            try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
            let url = artifacts.appendingPathComponent("\(test)-\(UUID()).png")
            try snapshot().write(to: url)
            failureSnapshot = url
            print("Downright UI failure snapshot: \(url.path)")
        } catch {
            print("Could not capture Downright UI failure snapshot: \(error)")
        }
    }
}
