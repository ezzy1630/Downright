import Foundation
import MarkdownCore

/// What Share hands to `NSSharingServicePicker`, and where a throwaway copy of
/// it goes.
///
/// Everything here is a *file*, deliberately.  AirDrop, Mail, Messages, and
/// Notes all attach what they are given: hand them an `NSString` and the
/// receiver gets pasted text with no name and no extension, and nothing they
/// can open in a Markdown reader.  Hand them a URL and AirDrop sends a real
/// `.md`.  So the only question Share has to answer is *which* file, and the
/// answer is not always the document's own.
///
/// Split out of the window controller because the decision is pure and the
/// consequences of getting it wrong are silent: sharing the wrong bytes looks
/// exactly like sharing the right ones until the receiver opens it.
enum DocumentShareSource: Equatable {
    /// The document's own file, byte for byte what is on disk.  Used only when
    /// the buffer and the file agree.
    case documentFile(URL)
    /// A copy of the live buffer, written under `fileName` in a staging
    /// directory.  Covers two states the document file cannot: the never-saved
    /// window, which has no file at all, and the dirty one, whose file is a
    /// stale version of what the reader is looking at.
    case bufferSnapshot(fileName: String)

    /// A saved, clean document shares itself; anything else shares a snapshot.
    ///
    /// The dirty case is the one worth being deliberate about.  Sharing the
    /// file would be the cheaper implementation and a silent lie: the reader
    /// AirDrops "the document", the receiver gets the version from before the
    /// last ten minutes of typing, and nothing in either app says so.  Saving
    /// first would be worse — Share is not a save, and §8.1 does not let an
    /// implicit path decide to write the user's file for them.  A snapshot of
    /// the buffer is the only option that sends what is on screen without
    /// touching the original.
    static func choose(url: URL?, hasUnsavedChanges: Bool, displayName: String) -> DocumentShareSource {
        if let url, !hasUnsavedChanges { return .documentFile(url) }
        return .bufferSnapshot(fileName: snapshotFileName(url: url, displayName: displayName))
    }

    /// The name the receiver sees.  Keeps the document's own filename when
    /// there is one — including its extension, because `.markdown` and `.mkd`
    /// are the user's choice and re-spelling them `.md` would rename their file
    /// behind their back.
    static func snapshotFileName(url: URL?, displayName: String) -> String {
        if let url, !url.lastPathComponent.isEmpty { return url.lastPathComponent }
        let base = sanitizedFileBaseName(displayName)
        return base.isEmpty ? "Untitled.md" : base + ".md"
    }

    /// Strips what a filename cannot carry.  A document display name is
    /// arbitrary text, and `/` in it would silently redirect the write into
    /// another directory.
    static func sanitizedFileBaseName(_ name: String) -> String {
        var cleaned = name.components(separatedBy: CharacterSet(charactersIn: "/:\0"))
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Every leading dot, not just the first: a name that still begins with
        // one would arrive hidden in the receiver's Downloads folder, and
        // dropping one dot off `..-..-etc` leaves a name that still does.  A
        // leading `-` goes with them, because it turns the file into a flag for
        // whatever command line the receiver eventually points at it.
        while let first = cleaned.first, first == "." || first == "-" {
            cleaned.removeFirst()
        }
        return cleaned
    }
}

/// Where throwaway share copies live, and how they get written.
///
/// A fresh subdirectory per share rather than one flat folder: the receiver
/// should see `notes.md`, not `notes-3.md`, and two shares in the same second
/// must not race on one path.  These are the system's temporary directory, so
/// macOS reclaims them; Downright never deletes them out from under a share
/// that may still be uploading.
enum DocumentShareStaging {
    static func makeDirectory(root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let directory = root
            .appendingPathComponent("Downright-Share", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// Materialises `source` into something the share sheet can attach.
    ///
    /// The snapshot is written with the document's own `fidelity` for the same
    /// reason Save As is (§3.1): a CRLF / UTF-16 / BOM / no-final-newline
    /// document that arrives normalised is not the document that was shared.
    static func fileURL(
        for source: DocumentShareSource,
        text: @autoclosure () -> String,
        fidelity: ByteFidelity,
        root: URL = FileManager.default.temporaryDirectory
    ) throws -> URL {
        switch source {
        case .documentFile(let url):
            return url
        case .bufferSnapshot(let fileName):
            let directory = try makeDirectory(root: root)
            let destination = directory.appendingPathComponent(fileName)
            try DocumentIO.write(text(), to: destination, fidelity: fidelity)
            return destination
        }
    }

    /// The path a rendered PDF is staged at.  Always a snapshot: there is no
    /// PDF of the document on disk to share instead.
    static func pdfURL(displayName: String, root: URL = FileManager.default.temporaryDirectory) throws -> URL {
        let base = DocumentShareSource.sanitizedFileBaseName(displayName)
        let directory = try makeDirectory(root: root)
        return directory.appendingPathComponent((base.isEmpty ? "Untitled" : base) + ".pdf")
    }
}
