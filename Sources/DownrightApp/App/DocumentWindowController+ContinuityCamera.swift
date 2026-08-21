import AppKit
import MarkdownCore

/// Continuity Camera: "Take Photo" and "Scan Documents", served by a nearby
/// iPhone or iPad straight into the document at the caret.
///
/// The machinery is the Services one.  AppKit inserts the two menu items into
/// `MainMenu`'s Insert submenu (the placeholder carrying
/// `NSMenuItem.importFromDeviceIdentifier`) only when something in the
/// responder chain says it can accept an image, and delivers the capture by
/// calling `readSelection(from:)` on whatever said so.
///
/// The window controller is the responder that says so, not the text view: the
/// text view has `importsGraphics` off — it holds Markdown source, not an
/// attributed string with attachments — so it correctly declines image return
/// types and passes the question up the chain to here, which is the object that
/// knows where the document lives on disk.
@MainActor
extension DocumentWindowController: @preconcurrency NSServicesMenuRequestor {

    /// Advertises the image return types Continuity Camera looks for.
    ///
    /// Gated on the document having a file, and this is the deliberate answer
    /// to the never-saved window.  A Markdown image reference is a *path*, and
    /// until the document exists on disk there is no folder to make that path
    /// relative to.  Every alternative is worse than not offering the capture:
    /// an absolute path into a temporary folder is flagged non-portable by the
    /// Asset Doctor, renders only behind a trust prompt (`LocalAssetPolicy`
    /// trusts a local asset without asking only inside the document's own
    /// directory), and breaks the moment macOS reclaims the folder.  Declining
    /// here means AppKit simply does not offer Take Photo for an untitled
    /// window — the standard macOS presentation for "not available yet" —
    /// rather than accepting a photo the reader has already taken and then
    /// failing to place it.
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // A send type means the service also wants to *read* a selection out of
        // this object, which it cannot: nothing here writes to a pasteboard.
        let wantsNothingFromUs = sendType == nil || sendType?.rawValue.isEmpty == true
        if let returnType, wantsNothingFromUs,
           markdownDocument.url != nil,
           CapturedImage.acceptsReturnType(returnType) {
            return self
        }
        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    /// Receives the capture.
    ///
    /// Writes the image next to the document and inserts one Markdown
    /// reference at the caret as a single explicit source mutation with its own
    /// undo boundary.  Returning false leaves the capture unconsumed, which is
    /// what AppKit needs in order to report the failure itself.
    func readSelection(from pasteboard: NSPasteboard) -> Bool {
        // `validRequestor` already refuses an untitled window, so this is the
        // same invariant enforced at the point of the write rather than only at
        // the point of the advertisement — a Service invoked another way must
        // not be able to reach the insertion path with nowhere to put the file.
        guard let documentURL = markdownDocument.url else { return false }
        guard let payload = CapturedImage.payload(from: pasteboard) else { return false }

        let directory = documentURL.deletingLastPathComponent()
        let fileName = CapturedImage.uniqueFileName(
            in: directory,
            documentBaseName: documentURL.deletingPathExtension().lastPathComponent,
            fileExtension: payload.fileExtension
        )
        do {
            // `.withoutOverwriting` closes the gap between picking a free name
            // and using it.  A capture must never be able to replace a file
            // that appeared in between — that file could be an asset the
            // document already references.
            try payload.data.write(to: directory.appendingPathComponent(fileName), options: .withoutOverwriting)
        } catch {
            presentOperationError("Couldn’t save the captured image", error: error)
            return false
        }

        insertCapturedImageReference(fileName: fileName)
        return true
    }

    /// One insertion at the caret, with an undo boundary, and nothing else.
    ///
    /// Deliberately inserts at the *start* of the selection instead of
    /// replacing it.  Everywhere else in the app a command that acts on a
    /// selection may consume it, because the user can see the selection while
    /// they invoke the command.  Here they cannot: the capture is triggered on
    /// a phone, seconds pass, and whatever the document had selected when the
    /// menu item was chosen is off screen and out of mind.  Letting a photo
    /// arrive and silently delete a paragraph would be unrecoverable in every
    /// sense except the undo stack.
    ///
    /// The insertion itself — the edit, the boundary, the caret, the asset
    /// refresh — is `insertAssetMarkdown`, shared with the drop path so the two
    /// routes an image can take into a document cannot drift apart.
    private func insertCapturedImageReference(fileName: String) {
        // Source coordinates throughout: `sourceSelectedRange` is already in
        // the document's own UTF-16 space, never a TextKit display offset.
        insertAssetMarkdown(
            CapturedImage.insertion(
                destination: fileName,
                altText: CapturedImage.altText(forFileNamed: fileName),
                in: markdownDocument.text,
                at: containerTextView.sourceSelectedRange.location
            ),
            actionName: "Insert Photo"
        )
    }
}
