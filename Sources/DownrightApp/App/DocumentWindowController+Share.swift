import AppKit
import MarkdownCore
import ObjectiveC

private var sharePickerKey: UInt8 = 0

/// Share (§9.5's other half).
///
/// Export writes a file the user then has to go and find; Share hands the same
/// document straight to Mail, Messages, AirDrop, or Notes.  Both end at a real
/// file on disk — see `DocumentShareSource` for why a text blob is the wrong
/// thing to give a share sheet — so the only work here is deciding which file,
/// producing it, and putting the picker somewhere the reader is looking.
@MainActor
extension DocumentWindowController: @preconcurrency NSSharingServicePickerDelegate,
    NSSharingServiceDelegate {

    // MARK: - Commands

    func shareDocument() {
        let source = DocumentShareSource.choose(
            url: markdownDocument.url,
            hasUnsavedChanges: markdownDocument.isDirty,
            displayName: markdownDocument.displayName
        )
        let url: URL
        do {
            url = try DocumentShareStaging.fileURL(
                for: source,
                text: markdownDocument.text,
                fidelity: markdownDocument.fidelity
            )
        } catch {
            // Never translate an I/O failure into "nothing happened": the
            // reader chose Share and would otherwise be left watching a menu
            // close on silence.
            presentOperationError("Couldn’t prepare this document for sharing", error: error)
            return
        }
        presentSharingPicker(items: [url])
    }

    func shareDocumentAsPDF() {
        // The same renderer Print and Export PDF use, so what the receiver
        // opens is what the printer would have produced — a stylesheet made
        // for paper, not a screenshot of the current theme (§9.5).
        let exporter = HTMLExporter(
            document: markdownDocument.parsed,
            theme: currentStyleSheet.theme,
            title: markdownDocument.displayName,
            baseDirectory: markdownDocument.url?.deletingLastPathComponent(),
            imageProvider: NativeFragmentImageProvider(styleSheet: currentStyleSheet),
            forPrint: true
        )
        beginActivity()
        defer { endActivity() }
        let url: URL
        do {
            url = try DocumentShareStaging.pdfURL(displayName: markdownDocument.displayName)
        } catch {
            presentOperationError("Couldn’t prepare this document for sharing", error: error)
            return
        }
        guard PrintRenderer.writePDF(html: exporter.html(), to: url) else {
            presentOperationError(
                "Couldn’t prepare this document for sharing",
                error: NSError(
                    domain: "Downright.Export", code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "The PDF renderer could not produce a file to share."]
                )
            )
            return
        }
        presentSharingPicker(items: [url])
    }

    // MARK: - The picker

    /// Held for as long as the sheet is up.  `NSSharingServicePicker` does not
    /// retain itself, and a picker released at the end of the command's stack
    /// frame takes its popover with it before the user can pick anything.
    private var sharingPicker: NSSharingServicePicker? {
        get { objc_getAssociatedObject(self, &sharePickerKey) as? NSSharingServicePicker }
        set { objc_setAssociatedObject(self, &sharePickerKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private func presentSharingPicker(items: [Any]) {
        guard let (anchor, rect) = sharingAnchor() else { return }
        // A second Share while one is open would leave the first picker
        // orphaned with no way to dismiss it.
        sharingPicker?.close()
        let picker = NSSharingServicePicker(items: items)
        picker.delegate = self
        sharingPicker = picker
        picker.show(relativeTo: rect, of: anchor, preferredEdge: .maxY)
    }

    /// Where the sheet flies out of.
    ///
    /// The `···` overflow is the toolbar control that already carries Export,
    /// so a share invoked from the File menu appears from the same corner as
    /// one invoked from the toolbar.  When the window is too narrow for the
    /// cluster the button is gone, and the top edge of the document is the
    /// honest fallback — a picker pinned to a control that is not on screen
    /// would open in the wrong place or not at all.
    private func sharingAnchor() -> (NSView, NSRect)? {
        if let button = toolbarOverflowButton, button.window != nil, !button.isHiddenOrHasHiddenAncestor {
            return (button, button.bounds)
        }
        guard let content = window?.contentView else { return nil }
        let rect = NSRect(x: content.bounds.midX, y: content.bounds.maxY - 1, width: 1, height: 1)
        return (content, rect)
    }

    // MARK: - NSSharingServicePickerDelegate

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        delegateFor sharingService: NSSharingService
    ) -> (any NSSharingServiceDelegate)? {
        self
    }

    func sharingServicePicker(
        _ sharingServicePicker: NSSharingServicePicker,
        didChoose service: NSSharingService?
    ) {
        // Called with a nil service when the picker was dismissed, so this is
        // the one place that reliably fires either way.
        if sharingPicker === sharingServicePicker { sharingPicker = nil }
    }

    // MARK: - NSSharingServiceDelegate

    func sharingService(
        _ sharingService: NSSharingService,
        sourceWindowForShareItems items: [Any],
        sharingContentScope: UnsafeMutablePointer<NSSharingService.SharingContentScope>
    ) -> NSWindow? {
        // `.full`: the item being shared is the whole document, not a fragment
        // of it, which is what makes the Mail/Messages composer animate out of
        // this window rather than the middle of the screen.
        sharingContentScope.pointee = .full
        return window
    }
}
