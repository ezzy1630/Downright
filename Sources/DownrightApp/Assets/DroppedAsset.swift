import AppKit
import Foundation
import MarkdownRender

/// Turning something dropped on the document surface into files on disk and
/// Markdown in the source.
///
/// The render layer resolves *where* a drop lands (see `DocumentDrop`); this
/// decides *what* it becomes, and it is deliberately all pure functions over a
/// pasteboard, a document URL, and a "is this name taken?" closure.  The
/// window controller does the writing.
///
/// The hard part is not the drag.  It is that a Markdown destination has to
/// satisfy four consumers at once, and they do not agree with each other:
///
///   * `LocalAssetPolicy` — the renderer — resolves a destination as a *path*,
///     with no percent-decoding at all.  `%20` in a reference is a filename
///     containing the three characters `%`, `2`, `0`.
///   * `AssetReferenceParser` — the Asset Doctor — ends a bare destination at
///     the first space or tab, truncates at `#` or `?`, and *does*
///     percent-decode.  It also understands the CommonMark `<…>` form.
///   * `AssetDoctor` warns about absolute paths ("not portable") and
///     unsupported formats, so a drop should not arrive pre-diagnosed.
///   * `MarkdownLinkDestination` — what happens when the reader clicks the
///     thing afterwards — resolves `file:` URLs and paths relative to the
///     document, and nothing else.  A bare absolute path such as
///     `/Users/…/notes.md` classifies as *relative* there and is appended to
///     the document's folder, which opens nothing.
///
/// The intersection those four leave is small, and it is what every rule below
/// is derived from: prefer a bare relative path, fall back to the angle-bracket
/// form, and use a `file:` URL when nothing relative will do.  Percent-encoding
/// is never used, because the renderer would not decode it.
enum DroppedAsset {

    // MARK: - Reading the drag

    enum Payload: Equatable {
        /// Real files: Finder, Preview, an attachment dragged out of Mail.
        case files([URL])
        /// Bytes with no file behind them: an image dragged straight out of a
        /// browser or a preview window.
        case imageData(CapturedImage.Payload)
    }

    /// Files are read first on purpose.  A file drag also exposes its path as
    /// a string and often an image representation as well, and taking the
    /// bytes instead of the file would copy an image the reader already has,
    /// under a name they did not choose, next to a document that could have
    /// referenced the original where it stood.
    static func payload(from pasteboard: NSPasteboard) -> Payload? {
        let urls = pasteboard.readObjects(
            forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] ?? []
        let existing = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !existing.isEmpty { return .files(existing) }
        if let image = CapturedImage.payload(from: pasteboard) { return .imageData(image) }
        return nil
    }

    // MARK: - Where a reference points

    /// The three forms a destination may take, in preference order.
    enum Destination: Equatable {
        /// `assets/diagram.png` — portable, and the only form the renderer
        /// draws without a trust prompt (`LocalAssetPolicy.isSafeRelative`).
        case relative(String)
        /// `<meeting notes.png>` — still relative and still trusted, and the
        /// CommonMark-sanctioned way to carry a space.  The parser strips the
        /// brackets before either the Asset Doctor or the renderer sees the
        /// path, so both still resolve the real file.
        case angled(String)
        /// `file:///Users/…` — not portable and not trusted-by-default, but
        /// unambiguous.  Used only when there is nothing to be relative *to*.
        case absolute(URL)

        var markdownText: String {
            switch self {
            case .relative(let path): return path
            case .angled(let path): return "<\(path)>"
            // `absoluteString` percent-encodes exactly the characters a URL
            // needs encoded, and `URL(string:)` — which is what both the Asset
            // Doctor and the link classifier use for a `file:` destination —
            // decodes them again.  This is the one place percent-encoding is
            // correct, because here it round-trips.
            case .absolute(let url): return url.absoluteString
            }
        }

        /// True when the reference is relative to the document's own folder,
        /// which is what makes it portable and prompt-free.
        var isRelative: Bool {
            switch self {
            case .relative, .angled: return true
            case .absolute: return false
            }
        }
    }

    /// Characters that end or re-point a *bare* destination.  A path holding
    /// any of them has to use the angle-bracket form.
    private static let bareHazards: Set<Character> = [" ", "\t", "#", "?", "%", "(", ")"]
    /// Characters the angle-bracket form cannot carry either.
    private static let angledHazards: Set<Character> = ["<", ">", "\n", "\r"]

    /// The best destination for a file that already exists on disk.
    ///
    /// A file *inside* the document's folder is referenced where it stands and
    /// never copied: it is already portable, the reader put it there, and
    /// duplicating it would leave two copies of an asset the document may
    /// already reference once.
    static func destination(for file: URL, relativeTo directory: URL?) -> Destination {
        guard let directory, let relative = relativePath(of: file, in: directory) else {
            return .absolute(file.standardizedFileURL)
        }
        if !relative.contains(where: bareHazards.contains) { return .relative(relative) }
        if !relative.contains(where: angledHazards.contains) { return .angled(relative) }
        return .absolute(file.standardizedFileURL)
    }

    /// `file`'s path relative to `directory`, or nil when it is not inside it.
    ///
    /// Both sides are canonicalised through `LocalAssetPolicy`, because that is
    /// what the renderer will do when it resolves the reference back.  Without
    /// it a document opened through `/tmp` (a symlink to `/private/tmp`) and an
    /// image dropped from `/private/tmp` would look like they were in different
    /// folders and the image would be copied for no reason.
    ///
    /// Never produces a `..` path.  A traversal is not `isSafeRelative`, so an
    /// image referenced through one renders only behind a trust prompt — the
    /// same reason the capture path writes next to the document.
    static func relativePath(of file: URL, in directory: URL) -> String? {
        guard let child = LocalAssetPolicy.canonicalFileURL(file),
              let root = LocalAssetPolicy.canonicalFileURL(directory),
              LocalAssetPolicy.isWithin(child, root) else { return nil }
        let components = child.pathComponents.dropFirst(root.pathComponents.count)
        guard !components.isEmpty else { return nil }
        return components.joined(separator: "/")
    }

    /// Formats Downright can actually draw — the Asset Doctor's own set, so a
    /// dropped file becomes an `![…]` only when it would not be diagnosed as an
    /// unsupported format the moment it lands.
    private static let imageExtensions = AssetResolutionContext().supportedExtensions

    static func isImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    // MARK: - What a drop becomes

    /// A file the drop has to create before its reference means anything.
    struct Write: Equatable {
        var fileName: String
        var contents: Contents

        enum Contents: Equatable {
            case copyOf(URL)
            case data(Data)
        }
    }

    /// One dropped item, resolved.
    struct Insertion: Equatable {
        /// Nil when the reference points at a file that is already in place.
        var write: Write?
        var markdown: String
        /// Images are padded out into a paragraph of their own; a link is
        /// inline text and lands exactly where the pointer was.
        var isBlock: Bool
    }

    /// Everything a drop turns into, in order.
    ///
    /// `documentDirectory` is nil for a window that has never been saved, and
    /// that case is answered differently for each payload rather than refused
    /// wholesale:
    ///
    ///   * A dropped **file** still exists somewhere the reader can point at,
    ///     so it gets a `file:` destination.  A link to it works immediately.
    ///     An image does not *draw* yet — `LocalAssetPolicy.request` resolves
    ///     nothing at all without a document URL, so the reference renders as
    ///     a missing asset until the window is saved and the reader grants the
    ///     absolute path trust.  That is a real cost, and it is still the
    ///     better half of the trade: the Markdown is correct, it names the
    ///     file the reader actually dropped, and it becomes portable the
    ///     moment they Save As beside it.  Refusing the drag outright would
    ///     leave them with nothing and no explanation.
    ///   * Dropped **bytes** have nowhere to go.  Writing them into a temporary
    ///     folder would produce a reference that the Asset Doctor flags, that
    ///     needs trust to draw, and that breaks the first time macOS reclaims
    ///     the folder — the same reasoning that makes Continuity Camera decline
    ///     an untitled window.  Refused, and refused up front so the drag is
    ///     never accepted in the first place.
    static func plan(
        for payload: Payload,
        documentDirectory: URL?,
        documentBaseName: String,
        isTaken: (String) -> Bool
    ) -> [Insertion] {
        var taken: Set<String> = []
        func claim(stem: String, fileExtension: String) -> String {
            let name = CapturedImage.uniqueFileName(stem: stem, fileExtension: fileExtension) {
                taken.contains($0) || isTaken($0)
            }
            taken.insert(name)
            return name
        }

        switch payload {
        case .imageData(let image):
            guard documentDirectory != nil else { return [] }
            let base = CapturedImage.slug(documentBaseName)
            let name = claim(
                stem: base.isEmpty ? "image" : base + "-image",
                fileExtension: image.fileExtension
            )
            return [Insertion(
                write: Write(fileName: name, contents: .data(image.data)),
                markdown: imageMarkdown(alt: altText(for: name), destination: .relative(name)),
                isBlock: true
            )]

        case .files(let urls):
            return urls.map { url in
                let placement = destination(for: url, relativeTo: documentDirectory)
                guard isImage(url) else {
                    // A link is a *reference*, never an embed.  Copying
                    // somebody's document into this folder because it was
                    // linked would be a surprising, unasked-for duplication of
                    // their file — so a non-image is linked where it stands,
                    // relatively when it can be and by `file:` URL when it
                    // cannot.
                    return Insertion(
                        write: nil,
                        markdown: linkMarkdown(label: altText(for: url.lastPathComponent),
                                               destination: placement),
                        isBlock: false
                    )
                }
                if placement.isRelative || documentDirectory == nil {
                    return Insertion(
                        write: nil,
                        markdown: imageMarkdown(alt: altText(for: url.lastPathComponent),
                                                destination: placement),
                        isBlock: true
                    )
                }
                // An image from outside the folder is copied in, which is the
                // convention the rest of the app already holds to: an absolute
                // image path is flagged non-portable by the Asset Doctor and
                // draws only behind a trust prompt, and neither is a reasonable
                // thing to hand somebody who just dragged a picture in.
                let stem = CapturedImage.slug(url.deletingPathExtension().lastPathComponent)
                let name = claim(
                    stem: stem.isEmpty ? "image" : stem,
                    fileExtension: url.pathExtension.lowercased()
                )
                return Insertion(
                    write: Write(fileName: name, contents: .copyOf(url)),
                    markdown: imageMarkdown(
                        // The alt text keeps the file's real name even though
                        // the copy is slugged: the reader recognises "Screen
                        // Shot 2026-08-21", not "Screen-Shot-2026-08-21".
                        alt: altText(for: url.lastPathComponent),
                        destination: .relative(name)
                    ),
                    isBlock: true
                )
            }
        }
    }

    /// The one source edit a whole drop becomes.
    ///
    /// A drop of more than one item is a list, not a sentence, so it is laid
    /// out as blocks even when every item in it is a link.  A single link stays
    /// inline: the reader aimed the pointer at a word, and pushing their
    /// sentence apart to make room for `[notes](notes.md)` would throw away the
    /// precision the drop point exists to give them.
    static func edit(
        insertions: [Insertion],
        in source: String,
        at offset: Int
    ) -> (replacement: String, origin: Int, caret: Int)? {
        guard !insertions.isEmpty else { return nil }
        let isBlock = insertions.count > 1 || insertions.contains(where: \.isBlock)
        let body = insertions.map(\.markdown).joined(separator: isBlock ? "\n\n" : " ")
        guard isBlock else {
            let text = source as NSString
            let position = min(max(0, offset), text.length)
            return (body, position, position + body.utf16.count)
        }
        return CapturedImage.insertion(block: body, in: source, at: offset)
    }

    // MARK: - Markdown text

    static func imageMarkdown(alt: String, destination: Destination) -> String {
        "![\(alt)](\(destination.markdownText))"
    }

    static func linkMarkdown(label: String, destination: Destination) -> String {
        "[\(label)](\(destination.markdownText))"
    }

    /// A label safe to sit between `[` and `]`.
    ///
    /// A filename is arbitrary text and may hold brackets or a backslash, any
    /// of which would end the label early and leave the rest of the reference
    /// as literal prose.  Escaped rather than stripped, because unlike a
    /// *filename* — which the app is free to slug when it writes it — a label
    /// is the only human-readable trace of what the reader actually dropped.
    static func altText(for fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        let base = stem.isEmpty ? fileName : stem
        var out = ""
        for character in base {
            if character == "\\" || character == "[" || character == "]" { out.append("\\") }
            if character.isNewline { out.append(" "); continue }
            out.append(character)
        }
        let trimmed = out.trimmingCharacters(in: .whitespaces)
        // Never empty: the Asset Doctor reports a missing alt as a warning, and
        // an image that arrives already carrying a diagnostic is a worse first
        // impression than a placeholder the reader can edit.
        return trimmed.isEmpty ? "Image" : trimmed
    }
}
