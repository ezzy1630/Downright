import AppKit
import Foundation
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightApp

/// Dropping a file on the document, and previewing the one under the caret.
///
/// The drop half is mostly about *which path* ends up between the parentheses.
/// Downright has four separate consumers of a Markdown destination — the
/// renderer, the Asset Doctor's parser, the diagnostics, and the link
/// classifier — and they do not agree with each other, so most of these tests
/// take a reference the drop produced and push it back through the real
/// parser and the real policy to prove it still names the file that was
/// dropped.  A reference that merely *looks* right is the failure mode: it
/// renders as a grey missing-image box a week later, in somebody else's
/// checkout.
@Suite(.serialized)
struct DocumentDropTests {

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func pngData(width: Int = 8, height: Int = 8) throws -> Data {
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
        return try #require(rep.representation(using: .png, properties: [:]))
    }

    private func pasteboard(files: [URL]) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("DocumentDropTests-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects(files.map { $0 as NSURL })
        return board
    }

    private func pasteboard(png: Data) -> NSPasteboard {
        let board = NSPasteboard(name: NSPasteboard.Name("DocumentDropTests-\(UUID().uuidString)"))
        board.clearContents()
        board.setData(png, forType: .png)
        return board
    }

    // MARK: - Reading the drag

    @Test func aFileDragIsReadAsFilesEvenWhenItAlsoCarriesPixels() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("shot.png")
        try pngData().write(to: file)

        // Finder and Preview both put an image representation on the
        // pasteboard alongside the file URL.  Taking the pixels would copy a
        // file the reader already has, under a name they did not choose.
        let board = NSPasteboard(name: NSPasteboard.Name("DocumentDropTests-\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([file as NSURL])
        board.setData(try pngData(), forType: .png)
        #expect(DroppedAsset.payload(from: board) == .files([file]))
    }

    @Test func rawPixelsAreReadWhenThereIsNoFile() throws {
        let png = try pngData()
        let payload = try #require(DroppedAsset.payload(from: pasteboard(png: png)))
        #expect(payload == .imageData(CapturedImage.Payload(data: png, fileExtension: "png")))
    }

    @Test func aTextDragIsNotAnAssetDrop() {
        let board = NSPasteboard(name: NSPasteboard.Name("DocumentDropTests-\(UUID().uuidString)"))
        board.clearContents()
        board.setString("just some words", forType: .string)
        #expect(DroppedAsset.payload(from: board) == nil)
    }

    /// A dragged file that has since been deleted is not a drop target.  The
    /// reference would be written as a missing asset with no way to tell it
    /// from a typo.
    @Test func aVanishedFileIsNotAPayload() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let board = pasteboard(files: [directory.appendingPathComponent("gone.png")])
        #expect(DroppedAsset.payload(from: board) == nil)
    }

    // MARK: - Which destination a file gets

    @Test func aFileInsideTheDocumentsFolderIsReferencedWhereItStands() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent("assets"), withIntermediateDirectories: true
        )
        let nested = directory.appendingPathComponent("assets/diagram.png")
        #expect(
            DroppedAsset.destination(for: nested, relativeTo: directory) == .relative("assets/diagram.png")
        )
    }

    /// Percent-encoding is *not* the answer here, and this is the test that
    /// pins why: `LocalAssetPolicy` — the renderer — treats the destination as
    /// a literal path and never decodes, so `meeting%20notes.png` would send
    /// it looking for a file with a `%` in the name.  The angle-bracket form
    /// is stripped by the parser before either consumer sees it.
    @Test func aSpaceInTheNameUsesTheAngleBracketFormRatherThanPercentEncoding() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let spaced = directory.appendingPathComponent("meeting notes.png")
        #expect(
            DroppedAsset.destination(for: spaced, relativeTo: directory) == .angled("meeting notes.png")
        )
        #expect(DroppedAsset.Destination.angled("meeting notes.png").markdownText == "<meeting notes.png>")
        #expect(!DroppedAsset.Destination.angled("meeting notes.png").markdownText.contains("%"))
    }

    @Test func aFileOutsideTheFolderHasNoRelativeForm() throws {
        let directory = try makeTemporaryDirectory()
        let elsewhere = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let outside = elsewhere.appendingPathComponent("diagram.png")
        #expect(DroppedAsset.relativePath(of: outside, in: directory) == nil)
        guard case .absolute = DroppedAsset.destination(for: outside, relativeTo: directory) else {
            Issue.record("a file outside the folder must not be given a relative destination")
            return
        }
    }

    /// A `..` path is *not* used for a file one directory up.  A traversal is
    /// not `isSafeRelative`, so an image referenced through one renders only
    /// behind a trust prompt — which is exactly what copying it in avoids.
    @Test func aSiblingFolderDoesNotGetATraversalPath() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("docs", isDirectory: true)
        let images = root.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: documents, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)
        let asset = images.appendingPathComponent("diagram.png")
        #expect(DroppedAsset.relativePath(of: asset, in: documents) == nil)
    }

    /// `/tmp` is a symlink to `/private/tmp`, and a document opened through one
    /// with an image dragged from the other must not look like two folders.
    @Test func symlinkedFoldersStillResolveAsTheSameFolder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolved = directory.resolvingSymlinksInPath()
        let asset = resolved.appendingPathComponent("diagram.png")
        #expect(DroppedAsset.relativePath(of: asset, in: directory) == "diagram.png")
    }

    // MARK: - What a drop becomes

    private func plan(
        _ payload: DroppedAsset.Payload,
        directory: URL?,
        base: String = "notes",
        taken: Set<String> = []
    ) -> [DroppedAsset.Insertion] {
        DroppedAsset.plan(
            for: payload, documentDirectory: directory,
            documentBaseName: base, isTaken: { taken.contains($0) }
        )
    }

    @Test func anImageAlreadyBesideTheDocumentIsNotCopied() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let asset = directory.appendingPathComponent("diagram.png")
        try pngData().write(to: asset)

        let insertions = plan(.files([asset]), directory: directory)
        #expect(insertions.count == 1)
        #expect(insertions[0].write == nil, "a file already in the folder must not be duplicated")
        #expect(insertions[0].markdown == "![diagram](diagram.png)")
        #expect(insertions[0].isBlock)
    }

    @Test func anImageFromOutsideIsCopiedInAndReferencedRelatively() throws {
        let directory = try makeTemporaryDirectory()
        let elsewhere = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let asset = elsewhere.appendingPathComponent("Screen Shot 2026.png")
        try pngData().write(to: asset)

        let insertions = plan(.files([asset]), directory: directory)
        #expect(insertions[0].write == .init(fileName: "Screen-Shot-2026.png", contents: .copyOf(asset)))
        // The alt text keeps the name the reader recognises even though the
        // written file is slugged.
        #expect(insertions[0].markdown == "![Screen Shot 2026](Screen-Shot-2026.png)")
    }

    /// A link is a reference, not an embed.  Copying somebody's document into
    /// this folder because it was linked would duplicate their file behind
    /// their back.
    @Test func aMarkdownFileIsLinkedInlineAndNeverCopied() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = directory.appendingPathComponent("design.md")
        try "# Design\n".write(to: sibling, atomically: true, encoding: .utf8)

        let insertions = plan(.files([sibling]), directory: directory)
        #expect(insertions[0].write == nil)
        #expect(insertions[0].markdown == "[design](design.md)")
        #expect(!insertions[0].isBlock, "a link lands where the pointer was, inline")
    }

    @Test func aFileFromOutsideIsLinkedByFileURL() throws {
        let directory = try makeTemporaryDirectory()
        let elsewhere = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let sibling = elsewhere.appendingPathComponent("spec.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: sibling)

        let insertions = plan(.files([sibling]), directory: directory)
        #expect(insertions[0].write == nil)
        #expect(insertions[0].markdown.hasPrefix("[spec](file://"))
        // The classifier the app uses when the reader clicks it has to
        // recognise the destination, and a bare absolute path does not
        // classify as a local file — it classifies as *relative* and gets
        // appended to the document's own folder.
        let destination = String(
            insertions[0].markdown.drop(while: { $0 != "(" }).dropFirst().dropLast()
        )
        guard case .localFile(let url) = MarkdownLinkDestination.classify(destination) else {
            Issue.record("a dropped outside file must classify as a local file")
            return
        }
        #expect(url.standardizedFileURL.path == sibling.standardizedFileURL.path)
    }

    @Test func droppedPixelsAreWrittenBesideTheDocument() throws {
        let png = try pngData()
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let insertions = plan(
            .imageData(CapturedImage.Payload(data: png, fileExtension: "png")), directory: directory
        )
        #expect(insertions[0].write == .init(fileName: "notes-image.png", contents: .data(png)))
        #expect(insertions[0].markdown == "![notes-image](notes-image.png)")
    }

    /// Bytes have nowhere to go without a document folder.  The same answer
    /// Continuity Camera gives, for the same reason.
    @Test func droppedPixelsAreRefusedWithoutADocumentFolder() throws {
        let png = try pngData()
        #expect(plan(.imageData(CapturedImage.Payload(data: png, fileExtension: "png")),
                     directory: nil).isEmpty)
    }

    @Test func twoDropsInARowNeverCollideOnOneName() throws {
        let directory = try makeTemporaryDirectory()
        let elsewhere = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let first = elsewhere.appendingPathComponent("shot.png")
        let second = elsewhere.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
        let secondFile = second.appendingPathComponent("shot.png")
        try pngData().write(to: first)
        try pngData().write(to: secondFile)

        // Both are called `shot.png`, and one is already on disk beside the
        // document — three claims on one name inside a single drop.
        let insertions = plan(
            .files([first, secondFile]), directory: directory, taken: ["shot.png"]
        )
        #expect(insertions.compactMap { $0.write?.fileName } == ["shot-2.png", "shot-3.png"])
    }

    // MARK: - The single source edit

    @Test func aSingleLinkStaysInlineAtTheDropPoint() {
        let insertions = [DroppedAsset.Insertion(write: nil, markdown: "[a](a.md)", isBlock: false)]
        let edit = DroppedAsset.edit(insertions: insertions, in: "one two three", at: 4)
        #expect(edit?.replacement == "[a](a.md)")
        #expect(edit?.origin == 4)
        #expect(edit?.caret == 4 + 9)
    }

    @Test func anImagePadsItselfIntoItsOwnParagraph() {
        let insertions = [DroppedAsset.Insertion(write: nil, markdown: "![a](a.png)", isBlock: true)]
        let edit = DroppedAsset.edit(insertions: insertions, in: "one two three", at: 4)
        #expect(edit?.replacement == "\n\n![a](a.png)\n\n")
    }

    /// Several files at once is a list, not a sentence.
    @Test func aMultipleFileDropIsLaidOutAsBlocks() {
        let insertions = [
            DroppedAsset.Insertion(write: nil, markdown: "[a](a.md)", isBlock: false),
            DroppedAsset.Insertion(write: nil, markdown: "[b](b.md)", isBlock: false),
        ]
        let edit = DroppedAsset.edit(insertions: insertions, in: "", at: 0)
        #expect(edit?.replacement == "[a](a.md)\n\n[b](b.md)")
    }

    @Test func nothingToInsertIsNoEdit() {
        #expect(DroppedAsset.edit(insertions: [], in: "one", at: 0) == nil)
    }

    // MARK: - The reference has to survive the round trip

    private func diagnostics(_ text: String, documentURL: URL, root: URL) -> [AssetDiagnostic] {
        let probe = AssetProbe { url in
            AssetMetadata(
                exists: FileManager.default.fileExists(atPath: url.path),
                isDirectory: false,
                byteSize: (try? Data(contentsOf: url)).map { Int64($0.count) },
                fileExtension: url.pathExtension
            )
        }
        return AssetDoctor.diagnose(
            MarkdownParser.parse(text),
            context: AssetResolutionContext(documentURL: documentURL, workspaceRoot: root),
            probe: probe
        )
    }

    @Test func aDroppedImageResolvesBackToTheFileThatWasDropped() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")
        let asset = directory.appendingPathComponent("diagram.png")
        try pngData().write(to: asset)

        let markdown = plan(.files([asset]), directory: directory)[0].markdown
        let reference = try #require(AssetDoctor.references(
            in: MarkdownParser.parse(markdown),
            context: AssetResolutionContext(documentURL: documentURL, workspaceRoot: directory)
        ).first)
        #expect(reference.kind == .relativeLocal)
        #expect(reference.url?.standardizedFileURL == asset.standardizedFileURL)
        #expect(try #require(
            LocalAssetPolicy.request(raw: reference.source, documentURL: documentURL)
        ).isSafeRelative)
        #expect(diagnostics(markdown, documentURL: documentURL, root: directory).isEmpty)
    }

    /// The angle-bracket form has to survive all three: the parser strips the
    /// brackets, the doctor stays quiet, and the renderer's own resolver finds
    /// the file with the space still in its name.
    @Test func anAngleBracketDestinationSurvivesTheParserAndTheRenderer() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")
        let asset = directory.appendingPathComponent("meeting notes.png")
        try pngData().write(to: asset)

        let markdown = plan(.files([asset]), directory: directory)[0].markdown
        #expect(markdown == "![meeting notes](<meeting notes.png>)")
        let reference = try #require(AssetDoctor.references(
            in: MarkdownParser.parse(markdown),
            context: AssetResolutionContext(documentURL: documentURL, workspaceRoot: directory)
        ).first)
        #expect(reference.source == "meeting notes.png")
        #expect(reference.url?.standardizedFileURL == asset.standardizedFileURL)
        let request = try #require(
            LocalAssetPolicy.request(raw: reference.source, documentURL: documentURL)
        )
        #expect(request.isSafeRelative)
        #expect(request.url.lastPathComponent == "meeting notes.png")
        #expect(diagnostics(markdown, documentURL: documentURL, root: directory).isEmpty)
    }

    /// A filename holding a bracket would otherwise end the label early and
    /// leave the rest of the reference as literal prose.
    @Test func bracketsInAFileNameAreEscapedInTheLabel() {
        #expect(DroppedAsset.altText(for: "a [draft] plan.md") == "a \\[draft\\] plan")
        #expect(DroppedAsset.altText(for: ".hidden") == ".hidden")
        #expect(DroppedAsset.altText(for: "") == "Image")
    }

    // MARK: - The real window

    @MainActor
    private func makeController(text: String, at url: URL) throws -> DocumentWindowController {
        try text.write(to: url, atomically: true, encoding: .utf8)
        let controller = DocumentWindowController()
        try controller.open(url, mode: .live)
        return controller
    }

    @MainActor
    private func drop(_ board: NSPasteboard, at offset: Int, on controller: DocumentWindowController) -> Bool {
        let view = controller.containerTextView
        return controller.markdownTextView(
            view, didAcceptDrop: DocumentDrop(pasteboard: board, sourceOffset: offset)
        )
    }

    /// End to end, at a source offset the reader chose — not at the caret.
    @Test @MainActor func droppingAnImageInsertsOneUndoableReferenceAtTheDropPoint() throws {
        let directory = try makeTemporaryDirectory()
        let elsewhere = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let url = directory.appendingPathComponent("notes.md")
        let source = "# Title\n\nFirst paragraph.\n\nSecond paragraph.\n"
        let controller = try makeController(text: source, at: url)
        defer { controller.close() }
        // The caret is somewhere else entirely: the drop must ignore it.
        controller.containerTextView.setSourceSelectedRanges([NSRange(location: 0, length: 0)])

        let origin = elsewhere.appendingPathComponent("chart.png")
        let bytes = try pngData()
        try bytes.write(to: origin)

        let dropOffset = (source as NSString).range(of: "Second paragraph.").location
        #expect(drop(pasteboard(files: [origin]), at: dropOffset, on: controller))

        let copied = directory.appendingPathComponent("chart.png")
        #expect(try Data(contentsOf: copied) == bytes)
        #expect(controller.markdownDocument.text
            == "# Title\n\nFirst paragraph.\n\n![chart](chart.png)\n\nSecond paragraph.\n")
        // One boundary, so one Undo puts the document back exactly — and
        // leaves the copied file alone, which is the less destructive half.
        controller.markdownDocument.undoManager.undo()
        #expect(controller.markdownDocument.text == source)
        #expect(FileManager.default.fileExists(atPath: copied.path))
    }

    @Test @MainActor func droppingPixelsWritesAFileNamedAfterTheDocument() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("meeting notes.md")
        let controller = try makeController(text: "# Title\n", at: url)
        defer { controller.close() }

        let bytes = try pngData()
        #expect(drop(pasteboard(png: bytes), at: 8, on: controller))
        let written = directory.appendingPathComponent("meeting-notes-image.png")
        #expect(try Data(contentsOf: written) == bytes)
        #expect(controller.markdownDocument.text
            == "# Title\n\n![meeting-notes-image](meeting-notes-image.png)")
    }

    @Test @MainActor func aNeverSavedWindowTakesFilesButNotLooseImageBytes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let controller = DocumentWindowController()
        defer { controller.close() }
        #expect(controller.markdownDocument.url == nil)

        let view = controller.containerTextView
        let bytes = try pngData()
        let pixels = pasteboard(png: bytes)
        #expect(!controller.markdownTextView(
            view, canAcceptDrop: DocumentDrop(pasteboard: pixels, sourceOffset: 0)
        ))
        let before = controller.markdownDocument.text
        #expect(!drop(pixels, at: 0, on: controller))
        #expect(controller.markdownDocument.text == before)

        let file = directory.appendingPathComponent("design.md")
        try "# Design\n".write(to: file, atomically: true, encoding: .utf8)
        let board = pasteboard(files: [file])
        #expect(controller.markdownTextView(
            view, canAcceptDrop: DocumentDrop(pasteboard: board, sourceOffset: 0)
        ))
        #expect(drop(board, at: 0, on: controller))
        #expect(controller.markdownDocument.text.contains("[design](file://"))
    }

    /// A dropped `.md` sibling lands inline, and the link the reader then
    /// clicks has to open the file it names.
    @Test @MainActor func aDroppedSiblingBecomesALinkThatResolves() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.md")
        let controller = try makeController(text: "See also.\n", at: url)
        defer { controller.close() }
        let sibling = directory.appendingPathComponent("design.md")
        try "# Design\n".write(to: sibling, atomically: true, encoding: .utf8)

        #expect(drop(pasteboard(files: [sibling]), at: 8, on: controller))
        #expect(controller.markdownDocument.text == "See also[design](design.md).\n")

        guard case .relative(let relative) = MarkdownLinkDestination.classify("design.md") else {
            Issue.record("a sibling link must classify as relative")
            return
        }
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent(relative).path
        ))
    }

    /// Nothing is inserted when a write fails, and the files this drop already
    /// created are taken back out.  A half-applied drop leaves the reader with
    /// a reference to a file that was never written.
    @Test @MainActor func aFailedWriteInsertsNothingAndLeavesNoDebris() throws {
        let directory = try makeTemporaryDirectory()
        let elsewhere = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        let url = directory.appendingPathComponent("notes.md")
        let controller = try makeController(text: "# Title\n", at: url)
        defer { controller.close() }

        let good = elsewhere.appendingPathComponent("one.png")
        try pngData().write(to: good)
        // The second source is unreadable, so its copy throws *after* the
        // first one has already landed — the only interesting failure shape.
        let doomed = elsewhere.appendingPathComponent("two.png")
        try pngData().write(to: doomed)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: doomed.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: doomed.path
            )
        }
        let board = pasteboard(files: [good, doomed])

        let before = controller.markdownDocument.text
        #expect(!drop(board, at: 8, on: controller))
        #expect(controller.markdownDocument.text == before)
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("one.png").path
        ), "the file this drop created must be rolled back with it")
    }
}
