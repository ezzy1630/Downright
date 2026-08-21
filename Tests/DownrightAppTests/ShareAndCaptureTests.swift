import AppKit
import Foundation
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightApp

/// Share and Continuity Camera: the two places where the document leaves the
/// app and where something from outside it comes back in.
///
/// Both have the same failure mode — they look like they worked.  A share that
/// sends the file instead of the buffer arrives as a stale document nobody
/// notices until the receiver reads it, and a capture that writes an
/// unresolvable path renders as a broken image only after the window is closed.
/// So these tests are mostly about *which bytes* and *which path*.
@Suite(.serialized)
struct ShareAndCaptureTests {

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareAndCaptureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    // MARK: - What Share actually sends

    @Test func savedAndUnmodifiedDocumentSharesItsOwnFile() {
        let url = URL(fileURLWithPath: "/tmp/notes/design.md")
        let source = DocumentShareSource.choose(
            url: url, hasUnsavedChanges: false, displayName: "design"
        )
        #expect(source == .documentFile(url))
    }

    /// The case that would otherwise be a silent lie: AirDropping "the
    /// document" while the reader is looking at ten minutes of unsaved typing.
    @Test func modifiedDocumentSharesTheBufferNotTheStaleFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("design.md")
        try "on disk\n".write(to: url, atomically: true, encoding: .utf8)

        let source = DocumentShareSource.choose(
            url: url, hasUnsavedChanges: true, displayName: "design"
        )
        #expect(source == .bufferSnapshot(fileName: "design.md"))

        let staged = try DocumentShareStaging.fileURL(
            for: source, text: "in the buffer\n", fidelity: .default, root: directory
        )
        #expect(staged != url)
        // The receiver sees the document's own filename, not a staging name.
        #expect(staged.lastPathComponent == "design.md")
        #expect(try String(contentsOf: staged, encoding: .utf8) == "in the buffer\n")
        // Share is not a save: the original must be exactly as it was.
        #expect(try String(contentsOf: url, encoding: .utf8) == "on disk\n")
    }

    @Test func neverSavedDocumentSharesANamedMarkdownFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = DocumentShareSource.choose(
            url: nil, hasUnsavedChanges: true, displayName: "Untitled"
        )
        #expect(source == .bufferSnapshot(fileName: "Untitled.md"))

        let staged = try DocumentShareStaging.fileURL(
            for: source, text: "# Draft\n", fidelity: .default, root: directory
        )
        // The whole point of staging a file rather than sharing a string: what
        // lands in AirDrop is a `.md` the receiver can open.
        #expect(staged.pathExtension == "md")
        #expect(FileManager.default.fileExists(atPath: staged.path))
    }

    /// A shared copy is a copy (§3.1).  A CRLF document that arrives normalised
    /// to LF is not the document that was shared.
    @Test func snapshotKeepsTheDocumentsByteFidelity() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let fidelity = ByteFidelity(
            encoding: .utf8, hasBOM: false, lineEnding: .crlf, hasTrailingNewline: true
        )
        let staged = try DocumentShareStaging.fileURL(
            for: .bufferSnapshot(fileName: "crlf.md"),
            text: "one\ntwo\n", fidelity: fidelity, root: directory
        )
        let data = try Data(contentsOf: staged)
        #expect(String(decoding: data, as: UTF8.self) == "one\r\ntwo\r\n")
    }

    /// A display name is arbitrary text.  `/` in it would redirect the write.
    @Test func stagedNamesCannotEscapeTheStagingDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = DocumentShareSource.choose(
            url: nil, hasUnsavedChanges: true, displayName: "../../etc/passwd"
        )
        #expect(source == .bufferSnapshot(fileName: "etc-passwd.md"))
        let staged = try DocumentShareStaging.fileURL(
            for: source, text: "x\n", fidelity: .default, root: directory
        )
        #expect(staged.deletingLastPathComponent().deletingLastPathComponent()
            .lastPathComponent == "Downright-Share")

        let pdf = try DocumentShareStaging.pdfURL(displayName: "notes/../secret", root: directory)
        #expect(pdf.lastPathComponent == "notes-..-secret.pdf")
    }

    /// Two shares in the same second must not collide on one path.
    @Test func everyShareGetsItsOwnStagingDirectory() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try DocumentShareStaging.fileURL(
            for: .bufferSnapshot(fileName: "a.md"), text: "one\n", fidelity: .default, root: directory
        )
        let second = try DocumentShareStaging.fileURL(
            for: .bufferSnapshot(fileName: "a.md"), text: "two\n", fidelity: .default, root: directory
        )
        #expect(first != second)
        #expect(try String(contentsOf: first, encoding: .utf8) == "one\n")
        #expect(try String(contentsOf: second, encoding: .utf8) == "two\n")
    }

    // MARK: - Share in the command table

    @Test @MainActor func shareIsAFileMenuCommandWithItsOwnChord() {
        _ = NSApplication.shared
        #expect(Command.share.menu == .file)
        #expect(Command.shareAsPDF.menu == .file)
        #expect(KeybindingDefaults.table[.share] == [KeyBinding("s", [.command, .control])])
        // Save and Save As keep theirs.
        #expect(KeybindingDefaults.table[.save] == [KeyBinding("s", .command)])
        #expect(KeybindingDefaults.table[.saveAs] == [KeyBinding("s", [.command, .shift])])

        var found: NSMenuItem?
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if MainMenu.command(for: item) == .share { found = item }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(MainMenu.build())
        let item = found
        #expect(item?.title == "Share…")
        // The chord shown is read back out of the binding store, so a remap
        // cannot leave the menu advertising a shortcut that does nothing.
        #expect(item?.keyEquivalent == "s")
        #expect(item?.keyEquivalentModifierMask == [.command, .control])
    }

    /// An Untitled window is exactly where a reader most wants Share, so the
    /// precondition is `.document`, not `.documentWithFile`.
    @Test func shareIsAvailableBeforeTheDocumentHasEverBeenSaved() {
        #expect(Command.share.isEnabled(in: CommandContext(hasDocument: true)))
        #expect(Command.shareAsPDF.isEnabled(in: CommandContext(hasDocument: true)))
        #expect(!Command.share.isEnabled(in: .applicationOnly(canCheckForUpdates: false)))
        #expect(!Command.shareAsPDF.isEnabled(in: .applicationOnly(canCheckForUpdates: false)))
    }

    // MARK: - The Continuity Camera menu host

    /// AppKit substitutes Take Photo / Scan Documents for the placeholder, and
    /// the identifier is the only thing that marks it.  Lose that and the
    /// feature disappears with no other symptom.
    @Test @MainActor func editMenuCarriesTheImportFromDevicePlaceholder() {
        _ = NSApplication.shared
        let edit = MainMenu.build().items.compactMap(\.submenu).first { $0.title == "Edit" }
        let insert = edit?.items.first { $0.title == "Insert" }
        #expect(insert?.submenu != nil)
        let placeholder = insert?.submenu?.items.first
        #expect(placeholder?.identifier == NSMenuItem.importFromDeviceIdentifier)
        // No action of our own: the substituted items carry theirs, and a
        // hand-written selector would be a second, wrong answer.
        #expect(placeholder?.action == nil)
    }

    // MARK: - Decoding a capture

    private func bitmap(width: Int = 8, height: Int = 8) -> NSBitmapImageRep {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private func makePasteboard(
        _ data: Data, type: NSPasteboard.PasteboardType
    ) -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShareAndCaptureTests-\(UUID().uuidString)"))
        pasteboard.clearContents()
        pasteboard.setData(data, forType: type)
        return pasteboard
    }

    @Test func pngCapturesAreWrittenVerbatim() throws {
        let png = try #require(bitmap().representation(using: .png, properties: [:]))
        let pasteboard = makePasteboard(png, type: .png)
        defer { pasteboard.releaseGlobally() }
        let payload = try #require(CapturedImage.payload(from: pasteboard))
        #expect(payload.fileExtension == "png")
        #expect(payload.data == png)
    }

    /// TIFF is not in `AssetResolutionContext.supportedExtensions`, so passing
    /// it through would hand the Asset Doctor a diagnostic on arrival.
    @Test func unsupportedCaptureFormatsAreReencodedAsPNG() throws {
        let tiff = try #require(bitmap().representation(using: .tiff, properties: [:]))
        let pasteboard = makePasteboard(tiff, type: .tiff)
        defer { pasteboard.releaseGlobally() }
        let payload = try #require(CapturedImage.payload(from: pasteboard))
        #expect(payload.fileExtension == "png")
        #expect(NSBitmapImageRep(data: payload.data) != nil)
        #expect(AssetResolutionContext().supportedExtensions.contains(payload.fileExtension))
    }

    @Test func nonImagePasteboardsAreDeclined() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("ShareAndCaptureTests-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("not an image", forType: .string)
        #expect(CapturedImage.payload(from: pasteboard) == nil)
        #expect(CapturedImage.acceptsReturnType(.png))
        #expect(!CapturedImage.acceptsReturnType(.string))
    }

    // MARK: - Naming the written asset

    /// The written name and the parsed destination have to be the same string.
    /// `AssetReferenceParser` ends a destination at a space, `#`, or `?`, and
    /// percent-decodes the rest.
    @Test func assetNamesSurviveTheDestinationParser() {
        #expect(CapturedImage.slug("meeting notes") == "meeting-notes")
        #expect(CapturedImage.slug("q3 #plan (final) 50%") == "q3-plan-final-50")
        #expect(CapturedImage.slug("Reunión") == "Reunión")
        #expect(CapturedImage.slug("../etc/passwd") == "etcpasswd")
        #expect(CapturedImage.slug("   ") == "")
    }

    @Test func repeatedCapturesNeverOverwriteAnEarlierOne() {
        var taken: Set<String> = []
        let first = CapturedImage.uniqueFileName(
            documentBaseName: "notes", fileExtension: "png"
        ) { taken.contains($0) }
        #expect(first == "notes-photo.png")
        taken.insert(first)
        let second = CapturedImage.uniqueFileName(
            documentBaseName: "notes", fileExtension: "png"
        ) { taken.contains($0) }
        #expect(second == "notes-photo-2.png")
        taken.insert(second)
        let third = CapturedImage.uniqueFileName(
            documentBaseName: "notes", fileExtension: "jpg"
        ) { taken.contains($0) }
        #expect(third == "notes-photo.jpg")
    }

    // MARK: - The inserted Markdown

    @Test func insertionPadsItselfIntoItsOwnParagraph() {
        // Mid-paragraph: needs a blank line on both sides.
        let middle = CapturedImage.insertion(
            destination: "a.png", altText: "a", in: "one two\n", at: 3
        )
        #expect(middle.replacement == "\n\n![a](a.png)\n\n")
        #expect(middle.caret == 3 + "\n\n![a](a.png)".utf16.count)

        // Already on a blank line between two paragraphs: pad nothing.
        let blank = CapturedImage.insertion(
            destination: "a.png", altText: "a", in: "one\n\n\n\ntwo\n", at: 5
        )
        #expect(blank.replacement == "![a](a.png)")

        // One newline short on the trailing side: pad exactly that one.
        let nearlyBlank = CapturedImage.insertion(
            destination: "a.png", altText: "a", in: "one\n\n\n\ntwo\n", at: 6
        )
        #expect(nearlyBlank.replacement == "![a](a.png)\n")

        // Start of an empty document.
        #expect(CapturedImage.insertion(
            destination: "a.png", altText: "a", in: "", at: 0
        ).replacement == "![a](a.png)")

        // End of a document that ends in a single newline.
        let end = CapturedImage.insertion(
            destination: "a.png", altText: "a", in: "body\n", at: 5
        )
        #expect(end.replacement == "\n![a](a.png)")
    }

    @Test func insertionClampsAnOutOfRangeCaretRatherThanTrapping() {
        let insertion = CapturedImage.insertion(
            destination: "a.png", altText: "a", in: "abc", at: 9_999
        )
        #expect(insertion.caret <= ("abc" as NSString).length + insertion.replacement.utf16.count)
        #expect(insertion.replacement.hasSuffix("![a](a.png)"))
    }

    /// The reference has to come back out of the parser pointing at the exact
    /// file that was written, as a *safe relative* asset — anything else needs
    /// a trust prompt before it will draw.
    @Test func theInsertedReferenceResolvesBackToTheWrittenFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("meeting notes.md")
        let fileName = CapturedImage.uniqueFileName(
            in: directory, documentBaseName: "meeting notes", fileExtension: "png"
        )
        #expect(fileName == "meeting-notes-photo.png")
        let asset = directory.appendingPathComponent(fileName)
        try #require(bitmap().representation(using: .png, properties: [:])).write(to: asset)

        let insertion = CapturedImage.insertion(
            destination: fileName,
            altText: CapturedImage.altText(forFileNamed: fileName),
            in: "", at: 0
        )
        let text = insertion.replacement
        let context = AssetResolutionContext(documentURL: documentURL, workspaceRoot: directory)
        let reference = try #require(
            AssetDoctor.references(in: MarkdownParser.parse(text), context: context).first
        )
        #expect(reference.kind == .relativeLocal)
        #expect(reference.url?.standardizedFileURL == asset.standardizedFileURL)

        let request = try #require(
            LocalAssetPolicy.request(raw: reference.source, documentURL: documentURL)
        )
        #expect(request.isSafeRelative)

        // And it arrives with no diagnostics of its own — alt text present,
        // relative, supported format, inside the workspace.
        let probe = AssetProbe { url in
            let exists = FileManager.default.fileExists(atPath: url.path)
            return AssetMetadata(
                exists: exists, isDirectory: false,
                byteSize: (try? Data(contentsOf: url)).map { Int64($0.count) },
                fileExtension: url.pathExtension
            )
        }
        let diagnostics = AssetDoctor.diagnose(
            MarkdownParser.parse(text), context: context, probe: probe
        )
        #expect(diagnostics.isEmpty, "a fresh capture must not arrive pre-diagnosed")
    }

    // MARK: - The responder chain and the real insertion

    @MainActor
    private func makeController(text: String, at url: URL) throws -> DocumentWindowController {
        try text.write(to: url, atomically: true, encoding: .utf8)
        let controller = DocumentWindowController()
        try controller.open(url, mode: .live)
        return controller
    }

    /// The text view holds Markdown source, not attachments, so it declines
    /// image return types and the question reaches the controller.  If it ever
    /// stops reaching it, Continuity Camera silently vanishes from the menu.
    @Test @MainActor func imageRequestsReachTheWindowControllerThroughTheTextView() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.md")
        let controller = try makeController(text: "# Title\n", at: url)
        defer { controller.close() }
        controller.showWindow(nil)

        let textView = controller.primaryContainer.textView
        #expect(textView.importsGraphics == false)
        let requestor = textView.validRequestor(forSendType: nil, returnType: .png)
        #expect(requestor as? DocumentWindowController === controller)
        // A service that also wants to read a selection out of us gets nothing.
        #expect(controller.validRequestor(forSendType: .png, returnType: .png) == nil)
    }

    @Test @MainActor func captureWritesNextToTheDocumentAndInsertsOneUndoableReference() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("meeting notes.md")
        let source = "# Title\n\nBody text.\n"
        let controller = try makeController(text: source, at: url)
        defer { controller.close() }
        controller.containerTextView.setSourceSelectedRanges([
            NSRange(location: (source as NSString).length, length: 0)
        ])

        let png = try #require(bitmap().representation(using: .png, properties: [:]))
        let pasteboard = makePasteboard(png, type: .png)
        defer { pasteboard.releaseGlobally() }

        #expect(controller.readSelection(from: pasteboard))

        let asset = directory.appendingPathComponent("meeting-notes-photo.png")
        #expect(FileManager.default.fileExists(atPath: asset.path))
        #expect(try Data(contentsOf: asset) == png)
        #expect(controller.markdownDocument.text
            == source + "\n![meeting-notes-photo](meeting-notes-photo.png)")

        // One explicit boundary, so one Undo puts the document back exactly.
        controller.markdownDocument.undoManager.undo()
        #expect(controller.markdownDocument.text == source)
    }

    /// The capture is triggered on a phone; whatever was selected here is out
    /// of sight by the time it lands, so it must survive.
    @Test @MainActor func captureNeverConsumesTheSelection() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.md")
        let source = "# Title\n\nBody text.\n"
        let controller = try makeController(text: source, at: url)
        defer { controller.close() }
        let selection = NSRange(location: 9, length: 4)   // "Body"
        controller.containerTextView.setSourceSelectedRanges([selection])

        let png = try #require(bitmap().representation(using: .png, properties: [:]))
        let pasteboard = makePasteboard(png, type: .png)
        defer { pasteboard.releaseGlobally() }
        #expect(controller.readSelection(from: pasteboard))

        #expect(controller.markdownDocument.text
            == "# Title\n\n![notes-photo](notes-photo.png)\n\nBody text.\n")
        #expect(controller.markdownDocument.text.contains("Body text."))
    }

    /// The never-saved window: nothing is advertised, so AppKit never offers a
    /// capture there, and the write path refuses it a second time.
    @Test @MainActor func anUntitledWindowNeitherAdvertisesNorAcceptsACapture() throws {
        let controller = DocumentWindowController()
        defer { controller.close() }
        #expect(controller.markdownDocument.url == nil)
        #expect(controller.validRequestor(forSendType: nil, returnType: .png) == nil)

        let png = try #require(bitmap().representation(using: .png, properties: [:]))
        let pasteboard = makePasteboard(png, type: .png)
        defer { pasteboard.releaseGlobally() }
        let before = controller.markdownDocument.text
        #expect(!controller.readSelection(from: pasteboard))
        #expect(controller.markdownDocument.text == before)
    }
}
