import AppKit
import MarkdownCore
import MarkdownRender

/// Everything that puts a new asset into the document: a drag dropped on the
/// text surface, and — through the one shared insertion below — a Continuity
/// Camera capture.
///
/// The two arrive by completely different routes and have exactly one thing in
/// common: a file lands next to the document and one Markdown reference to it
/// lands in the source, as a single explicit mutation with its own undo
/// boundary.  That last part is why they share `insertAssetMarkdown` rather
/// than each having their own copy — two implementations of "insert an asset"
/// would eventually disagree about the undo boundary, the caret, or the
/// refresh, and all three are invisible until they are wrong.
@MainActor
extension DocumentWindowController {

    // MARK: - Drops (§7.1)

    /// Asked once per drag, before anything is drawn.
    ///
    /// This is where the never-saved window is answered.  A drag carrying real
    /// *files* is always accepted: even with no folder to be relative to, a
    /// `file:` destination points at something that exists.  A drag carrying
    /// only image *bytes* is refused, because there is nowhere to put them —
    /// see `DroppedAsset.plan` for the full reasoning, which is the same one
    /// Continuity Camera uses to decline an untitled window.
    func markdownTextView(_ view: MarkdownTextView, canAcceptDrop drop: DocumentDrop) -> Bool {
        switch DroppedAsset.payload(from: drop.pasteboard) {
        case .files: return true
        case .imageData: return markdownDocument.url != nil
        case nil: return false
        }
    }

    func markdownTextView(_ view: MarkdownTextView, didAcceptDrop drop: DocumentDrop) -> Bool {
        guard let payload = DroppedAsset.payload(from: drop.pasteboard) else { return false }
        let directory = markdownDocument.url?.deletingLastPathComponent()
        let insertions = DroppedAsset.plan(
            for: payload,
            documentDirectory: directory,
            documentBaseName: markdownDocument.url?.deletingPathExtension().lastPathComponent
                ?? markdownDocument.displayName,
            isTaken: { name in
                guard let directory else { return false }
                return FileManager.default.fileExists(
                    atPath: directory.appendingPathComponent(name).path
                )
            }
        )
        guard !insertions.isEmpty else { return false }
        return commitDrop(insertions, into: directory, at: drop.sourceOffset)
    }

    /// Writes first, then inserts — and inserts nothing at all if a write
    /// fails.
    ///
    /// A half-applied drop is the worst outcome available here: three images
    /// dragged in together, two on disk, and a reference to a third that was
    /// never written, drawn as a missing asset in a document the reader now has
    /// to repair by hand.  So the files this operation created are removed
    /// again on failure — which is a rollback of this operation's own writes,
    /// not a deletion of anything the reader owns — and the error is reported
    /// rather than being quietly turned into "nothing happened" (§3.1).
    private func commitDrop(
        _ insertions: [DroppedAsset.Insertion],
        into directory: URL?,
        at offset: Int
    ) -> Bool {
        let writes = insertions.compactMap(\.write)
        // Only a plan that writes needs a folder, and `DroppedAsset` never
        // produces one that does without checking.  Refusing here as well is
        // the same invariant enforced at the point of the write rather than
        // only at the point of the plan.
        guard writes.isEmpty || directory != nil else { return false }

        var created: [URL] = []
        for write in writes {
            guard let directory else { break }
            let target = directory.appendingPathComponent(write.fileName)
            do {
                switch write.contents {
                case .data(let data):
                    // `.withoutOverwriting` closes the gap between picking a
                    // free name and using it: a drop must never be able to
                    // replace a file that appeared in between, because that
                    // file could be an asset the document already references.
                    try data.write(to: target, options: .withoutOverwriting)
                case .copyOf(let origin):
                    try FileManager.default.copyItem(at: origin, to: target)
                }
                created.append(target)
            } catch {
                created.forEach { try? FileManager.default.removeItem(at: $0) }
                presentOperationError("Couldn’t add the dropped file", error: error)
                return false
            }
        }

        guard let edit = DroppedAsset.edit(
            insertions: insertions, in: markdownDocument.text, at: offset
        ) else {
            created.forEach { try? FileManager.default.removeItem(at: $0) }
            return false
        }
        // The name is what the reader reads in Edit ▸ Undo, so it names what
        // they did rather than what the code did.
        let actionName: String
        if insertions.count > 1 {
            actionName = "Insert Files"
        } else {
            actionName = insertions[0].isBlock ? "Insert Image" : "Insert Link"
        }
        insertAssetMarkdown(edit, actionName: actionName)
        return true
    }

    // MARK: - The one insertion

    /// One insertion, with an undo boundary, and nothing else.
    ///
    /// Deliberately inserts at a zero-length range rather than replacing the
    /// selection.  A drop lands where the pointer is, not where the caret is,
    /// and a capture arrives seconds after the reader last looked at the
    /// document — in both cases whatever happens to be selected is not part of
    /// what they asked for, and consuming it would delete a paragraph they
    /// cannot see.
    ///
    /// Undo takes the reference back out and leaves the written file where it
    /// is.  Deleting a file the reader has not asked to delete is the more
    /// destructive half of the pair, and for a capture the file is the only
    /// copy.
    func insertAssetMarkdown(
        _ insertion: (replacement: String, origin: Int, caret: Int),
        actionName: String
    ) {
        applyInPlaceDocumentEdits(
            [TextEdit(
                range: NSRange(location: insertion.origin, length: 0),
                replacement: insertion.replacement,
                summary: actionName
            )],
            actionName: actionName
        )
        containerTextView.setSourceSelectedRanges([NSRange(location: insertion.caret, length: 0)])
        // The file appeared after the last render pass, so the image fragment
        // is holding a "missing asset" result for a path that now exists.
        documentPanes.forEach { $0.textView.refreshLocalAssets() }
    }
}
