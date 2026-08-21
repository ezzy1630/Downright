import AppKit
import Foundation

/// Turning a Continuity Camera capture into a file next to the document and a
/// Markdown reference to it.
///
/// Everything here is a pure function over a pasteboard, a directory listing,
/// or a source string: the window controller decides *when* an image arrives,
/// this decides *what* gets written and *what text* the document gains.  The
/// naming rules in particular are worth stating once and testing, because they
/// have to satisfy three separate consumers at the same time:
///
///   * `LocalAssetPolicy` renders a local asset without a trust prompt only
///     when the destination is relative, traversal-free, and resolves inside
///     the document's own folder.  So the file goes next to the document and
///     the reference is a bare filename.
///   * `AssetReferenceParser` ends a destination at the first space, `#`, or
///     `?`, and percent-decodes what is left.  A filename containing any of
///     those — or a literal `%` — parses as a different path than it names.
///   * `AssetDoctor` warns about absolute paths, unsupported formats, and
///     missing alt text.  A capture should not arrive pre-diagnosed.
enum CapturedImage {

    // MARK: - Reading the capture

    /// Image bytes plus the extension they should be written under.
    struct Payload: Equatable {
        var data: Data
        var fileExtension: String
    }

    /// Types taken verbatim, in preference order.
    ///
    /// Verbatim matters: re-encoding a photo to get it onto disk would throw
    /// away the capture's own compression and colour for nothing.  These three
    /// are exactly the camera-shaped formats in
    /// `AssetResolutionContext.supportedExtensions`, so a capture never lands
    /// as an asset the Asset Doctor immediately flags as unsupported.
    static let passthroughTypes: [(type: NSPasteboard.PasteboardType, fileExtension: String)] = [
        (.png, "png"),
        (NSPasteboard.PasteboardType("public.jpeg"), "jpg"),
        (NSPasteboard.PasteboardType("public.heic"), "heic"),
    ]

    /// True for the return types this app can actually turn into a Markdown
    /// image.  Used both to advertise the responder to AppKit and to decode.
    static func acceptsReturnType(_ type: NSPasteboard.PasteboardType) -> Bool {
        NSImage.imageTypes.contains(type.rawValue)
    }

    static func payload(from pasteboard: NSPasteboard) -> Payload? {
        for candidate in passthroughTypes {
            guard pasteboard.availableType(from: [candidate.type]) != nil,
                  let data = pasteboard.data(forType: candidate.type), !data.isEmpty
            else { continue }
            return Payload(data: data, fileExtension: candidate.fileExtension)
        }
        // Anything else — TIFF from an older capture path, a PDF page from a
        // scan — is re-encoded to PNG rather than written under its own
        // extension.  `.tiff` is not in the supported set and no browser opens
        // a `.pdf` from an `![…]()`, so passing those through would produce a
        // reference that renders as a broken image in Downright and in every
        // exported HTML file.
        guard let image = NSImage(pasteboard: pasteboard),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return nil }
        return Payload(data: png, fileExtension: "png")
    }

    // MARK: - Naming the file

    /// A filename component that survives both the filesystem and
    /// `AssetReferenceParser`.
    ///
    /// Whitespace becomes `-` and the characters that would end or re-point the
    /// destination are dropped outright, so the written path and the parsed
    /// path are the same string and no percent-encoding is needed anywhere.
    /// Non-ASCII letters are kept: a document called `Reunión.md` should not
    /// have its assets renamed to `Reunin`.
    static func slug(_ name: String) -> String {
        var out = ""
        var lastWasDash = false
        for scalar in name.unicodeScalars {
            let character = Character(scalar)
            if character.isWhitespace || scalar == "_" {
                if !lastWasDash, !out.isEmpty { out.append("-"); lastWasDash = true }
                continue
            }
            // `/ : \0` break the write; `# ? %` break the parse; the rest are
            // ordinary shell and Markdown hazards not worth carrying.
            if "/\\:#?%()[]<>|\"'*\u{0}".unicodeScalars.contains(scalar) { continue }
            if scalar.properties.generalCategory == .control { continue }
            out.append(character)
            lastWasDash = false
        }
        while out.hasSuffix("-") || out.hasSuffix(".") { out.removeLast() }
        while out.hasPrefix("-") || out.hasPrefix(".") { out.removeFirst() }
        return out
    }

    /// The first free `<stem>[-n].<ext>` in a directory.
    ///
    /// Numbered rather than timestamped so the name is deterministic and this
    /// is testable without injecting a clock, and never reused so a second
    /// write cannot overwrite the first.  The cap is a guard against a
    /// pathological directory, not an expected path; past it the name carries a
    /// UUID, which is ugly but still writes.
    ///
    /// Shared with the drop path (`DroppedAsset`), which names a copied-in
    /// file after the file the reader dragged rather than after the document.
    /// The collision rule has to be the same one in both places: two different
    /// answers to "is this name free?" is how one of them ends up clobbering an
    /// asset the document already references.
    static func uniqueFileName(
        stem: String,
        fileExtension: String,
        exists: (String) -> Bool
    ) -> String {
        for index in 1...999 {
            let candidate = index == 1
                ? "\(stem).\(fileExtension)"
                : "\(stem)-\(index).\(fileExtension)"
            if !exists(candidate) { return candidate }
        }
        return "\(stem)-\(UUID().uuidString).\(fileExtension)"
    }

    /// The capture's own naming rule: `<document>-photo[-n].<ext>`.
    static func uniqueFileName(
        documentBaseName: String,
        fileExtension: String,
        exists: (String) -> Bool
    ) -> String {
        let base = slug(documentBaseName)
        return uniqueFileName(
            stem: base.isEmpty ? "photo" : base + "-photo",
            fileExtension: fileExtension,
            exists: exists
        )
    }

    static func uniqueFileName(
        in directory: URL,
        documentBaseName: String,
        fileExtension: String
    ) -> String {
        uniqueFileName(documentBaseName: documentBaseName, fileExtension: fileExtension) { name in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
        }
    }

    // MARK: - Writing the reference

    /// The text to insert, the zero-length source range to insert it at, and
    /// where the caret lands afterwards.
    ///
    /// A Markdown image is an inline span, so `![…](…)` at the caret is already
    /// valid wherever the caret is — but a photograph dropped into the middle
    /// of a sentence is almost never what the reader meant, and a reference
    /// glued to the previous line is not even rendered as its own block.  So
    /// the insertion pads itself out to a paragraph of its own, and pads
    /// exactly as much as the surrounding blank lines are missing.
    ///
    /// The padding is part of the inserted string.  Nothing outside
    /// `[origin, origin)` is touched — see `readSelection(from:)` for why that
    /// matters when the capture happens on a different device.  `origin` is
    /// returned rather than recomputed by the caller so the clamp that produced
    /// the padding and the clamp that produces the edit range cannot drift.
    static func insertion(
        destination: String,
        altText: String,
        in source: String,
        at caret: Int
    ) -> (replacement: String, origin: Int, caret: Int) {
        insertion(block: "![\(altText)](\(destination))", in: source, at: caret)
    }

    /// The same padding rule for any block of generated Markdown.
    ///
    /// Shared with the drop path, which arrives with a block that may hold
    /// several references at once.  One implementation because the padding is
    /// the fiddly part: it has to count the newlines that are *already* there
    /// on each side, so dropping into an existing blank line adds nothing and
    /// dropping mid-sentence adds exactly two.
    static func insertion(
        block: String,
        in source: String,
        at caret: Int
    ) -> (replacement: String, origin: Int, caret: Int) {
        let text = source as NSString
        let position = min(max(0, caret), text.length)

        var leadingNewlines = 0
        var index = position - 1
        while index >= 0, leadingNewlines < 2, text.character(at: index) == 0x0A {
            leadingNewlines += 1
            index -= 1
        }
        let prefix = position == 0 ? "" : String(repeating: "\n", count: 2 - leadingNewlines)

        var trailingNewlines = 0
        index = position
        while index < text.length, trailingNewlines < 2, text.character(at: index) == 0x0A {
            trailingNewlines += 1
            index += 1
        }
        let suffix = position == text.length ? "" : String(repeating: "\n", count: 2 - trailingNewlines)

        return (
            prefix + block + suffix,
            position,
            position + (prefix + block).utf16.count
        )
    }

    /// Alt text for a capture.  Never empty — the Asset Doctor flags a missing
    /// alt as a warning, and a photo that arrives already carrying a diagnostic
    /// is a worse first impression than a placeholder the user can edit.
    static func altText(forFileNamed fileName: String) -> String {
        let stem = (fileName as NSString).deletingPathExtension
        return stem.isEmpty ? "Photo" : stem
    }
}
