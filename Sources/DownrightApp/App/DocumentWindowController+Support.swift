import AppKit
import MarkdownCore
import MarkdownRender
import UniformTypeIdentifiers

/// Accessors, copy/export, and the sheets the command switch reaches for.
extension DocumentWindowController {

    // MARK: - Accessors

    var containerTextView: MarkdownTextView {
        guard let split = splitContainer?.textView,
              window?.firstResponder === split else { return primaryContainer.textView }
        return split
    }
    var currentStyleSheet: StyleSheet { activeStyleSheet }

    func caretOffset() -> Int {
        let selection = containerTextView.sourceSelectedRange
        return selection.length > 0 ? selection.location : max(0, selection.location)
    }

    func selectionRange() -> NSRange {
        let selection = containerTextView.sourceSelectedRange
        guard selection.length == 0 else { return selection }
        // With no selection, commands act on the caret's block, which is what
        // makes ⌘B and the convert commands usable without selecting first.
        guard let block = markdownDocument.parsed.root.block(at: selection.location) else { return selection }
        return block.contentRange
    }

    func currentHeadingIndex() -> Int? {
        let offset = caretOffset()
        return markdownDocument.parsed.headings.lastIndex { $0.range.location <= offset }
    }

    // MARK: - Copy flavours (§9.5)

    enum CopyFlavour { case markdown, richText, plain }

    func copy(flavour: CopyFlavour) {
        let range = containerTextView.sourceSelectedRange
        let effective = range.length > 0 ? range : NSRange(location: 0, length: markdownDocument.parsed.length)
        copy(range: effective, flavour: flavour)
    }

    func copy(range: NSRange, flavour: CopyFlavour) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let markdown = (markdownDocument.text as NSString).substring(with: range)

        switch flavour {
        case .markdown:
            pasteboard.setString(markdown, forType: .string)
        case .richText:
            let attributed = containerTextView.attributedStringForRichTextCopy(range: range)
            if let rtf = attributed.rtf(from: NSRange(location: 0, length: attributed.length), documentAttributes: [:]) {
                pasteboard.declareTypes([.rtf, .string], owner: nil)
                pasteboard.setData(rtf, forType: .rtf)
                pasteboard.setString(attributed.string, forType: .string)
            } else {
                pasteboard.setString(attributed.string, forType: .string)
            }
        case .plain:
            pasteboard.setString(PlainTextRenderer.render(markdownDocument.parsed, range: range), forType: .string)
        }
    }

    func copyCurrentSection() {
        guard let index = currentHeadingIndex() else { return }
        copy(range: markdownDocument.parsed.headings[index].sectionRange, flavour: .markdown)
    }

    func copySectionLink() {
        guard let index = currentHeadingIndex(), let url = markdownDocument.url else { return }
        let slug = markdownDocument.parsed.headings[index].slug
        let link = "[\(markdownDocument.parsed.headings[index].title)](\(url.lastPathComponent)#\(slug))"
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(link, forType: .string)
    }

    // MARK: - Saving

    @discardableResult
    func saveDocument() -> Bool {
        do {
            try markdownDocument.save()
            return true
        } catch {
            return false
        }
    }

    func presentSaveError(_ error: Error) {
        presentOperationError("Couldn’t save \(markdownDocument.displayName)", error: error)
    }

    func presentOperationError(_ title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }

    func saveAs() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = DocumentTypes.contentTypes
        panel.nameFieldStringValue = markdownDocument.url?.lastPathComponent ?? "Untitled.md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try DocumentIO.write(markdownDocument.text, to: url, fidelity: .default)
        } catch {
            presentOperationError("Couldn’t save a copy", error: error)
            return
        }
        (NSApp.delegate as? AppDelegate)?.open(url, mode: mode)
    }

    // MARK: - Export (§9.5)

    private func exporter(forPrint: Bool) -> HTMLExporter {
        HTMLExporter(
            document: markdownDocument.parsed,
            theme: currentStyleSheet.theme,
            title: markdownDocument.displayName,
            baseDirectory: markdownDocument.url?.deletingLastPathComponent(),
            imageProvider: NativeFragmentImageProvider(styleSheet: currentStyleSheet),
            forPrint: forPrint
        )
    }

    func exportHTML() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = markdownDocument.displayName + ".html"
        panel.message = "Export a self-contained HTML file"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(exporter(forPrint: false).html().utf8).write(to: url)
        } catch {
            presentOperationError("Couldn’t export HTML", error: error)
        }
    }

    func exportPDF() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = markdownDocument.displayName + ".pdf"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard PrintRenderer.writePDF(html: exporter(forPrint: true).html(), to: url) else {
            let error = NSError(
                domain: "Downright.Export", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "The PDF renderer could not write the selected file."]
            )
            presentOperationError("Couldn’t export PDF", error: error)
            return
        }
    }

    func printDocument() {
        // A stylesheet designed for paper, not a screenshot of the screen
        // theme (§9.5).
        PrintRenderer.print(html: exporter(forPrint: true).html(), jobTitle: markdownDocument.displayName)
    }

    func exportSelectionAsImage() {
        let range = containerTextView.sourceSelectedRange
        guard range.length > 0, let image = containerTextView.imageForSelection(range) else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = markdownDocument.displayName + " selection.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { return }
        do {
            try png.write(to: url)
        } catch {
            presentOperationError("Couldn’t export the selection", error: error)
        }
    }

    // MARK: - Sheets and panels

    func presentTidySheet(_ edits: [TextEdit]) {
        guard let window else { return }
        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 520),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false
        )
        sheetWindow.title = "Tidy Document"

        let sheet = TidySheetView()
        sheet.styleSheet = currentStyleSheet
        sheet.proposals = edits.map { edit in
            (edit: edit,
             before: (markdownDocument.text as NSString).substring(with: edit.range),
             after: edit.replacement)
        }
        sheet.delegate = self
        sheetWindow.contentView = sheet
        sheet.reload()

        tidySheetWindow = sheetWindow
        window.beginSheet(sheetWindow)
    }

    func showSiblingSearch() {
        guard let scanner else { return }
        showFindBar(replace: false)
        if searchResults == nil {
            let panel = SearchResultsPanelView()
            panel.delegate = self
            panel.styleSheet = currentStyleSheet
            searchResults = panel
            searchInspector?.setResults(panel)
        }
        searchResults?.isSearching = true

        let urls = scanner.siblings.map(\.url)
        let query = currentFindQuery
        DispatchQueue.global(qos: .userInitiated).async {
            let hits = SiblingSearch.search(query, in: urls)
            DispatchQueue.main.async { [weak self] in
                self?.searchResults?.hits = hits
                self?.searchResults?.isSearching = false
            }
        }
    }
}

// MARK: - Plain-text rendering (§9.5 "copy with all markup stripped")

enum PlainTextRenderer {
    static func render(_ document: ParsedDocument, range: NSRange) -> String {
        var out = ""
        document.root.walk { block in
            guard NSIntersectionRange(block.range, range).length > 0 else { return }
            switch block.content {
            case .heading, .paragraph:
                let text = document.substring(NSIntersectionRange(block.contentRange, range))
                out += stripInlineMarkers(text) + "\n\n"
            case .codeBlock(_, _, let contentRange):
                out += document.substring(NSIntersectionRange(contentRange, range)) + "\n\n"
            case .listItem(let ordinal, let checkbox):
                let bullet = ordinal.map { "\($0). " } ?? "• "
                let box = checkbox.map { $0.isChecked ? "[x] " : "[ ] " } ?? ""
                out += bullet + box
            default:
                break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Strips emphasis, code, and link syntax without a second parse — the
    /// clipboard does not need a perfect AST, it needs the words.
    private static func stripInlineMarkers(_ text: String) -> String {
        var out = text
        for marker in ["***", "**", "___", "__", "~~", "*", "_", "`"] {
            out = out.replacingOccurrences(of: marker, with: "")
        }
        // [label](target) -> label
        out = out.replacingOccurrences(
            of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1",
            options: .regularExpression
        )
        // [[target|label]] -> label, [[target]] -> target
        out = out.replacingOccurrences(
            of: #"\[\[([^\]|]*)\|([^\]]*)\]\]"#, with: "$2",
            options: .regularExpression
        )
        out = out.replacingOccurrences(
            of: #"\[\[([^\]]*)\]\]"#, with: "$1",
            options: .regularExpression
        )
        return out
    }
}

// MARK: - Print and PDF

/// Print and PDF go through an `NSAttributedString` built from the exported
/// HTML.  That keeps one stylesheet — the print one — describing paper output,
/// rather than a second layout pass that would drift from the export (§9.5).
enum PrintRenderer {
    private static func attributedString(from html: String) -> NSAttributedString? {
        guard let data = html.data(using: .utf8) else { return nil }
        return try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.html,
                      .characterEncoding: String.Encoding.utf8.rawValue],
            documentAttributes: nil
        )
    }

    static func print(html: String, jobTitle: String) {
        guard let attributed = attributedString(from: html) else { return }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        textView.textStorage?.setAttributedString(attributed)

        let info = NSPrintInfo.shared
        info.topMargin = 56; info.bottomMargin = 56
        info.leftMargin = 56; info.rightMargin = 56
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.jobTitle = jobTitle
        operation.showsPrintPanel = true
        operation.run()
    }

    @discardableResult
    static func writePDF(html: String, to url: URL) -> Bool {
        guard let attributed = attributedString(from: html) else { return false }
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 468, height: 648))
        textView.textStorage?.setAttributedString(attributed)

        let info = NSPrintInfo.shared.copy() as! NSPrintInfo
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        info.topMargin = 56; info.bottomMargin = 56
        info.leftMargin = 56; info.rightMargin = 56

        let operation = NSPrintOperation(view: textView, printInfo: info)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        return operation.run()
    }
}

/// Bridges the app's export path to the renderers so exported HTML carries the
/// same math and diagrams the app draws — no WebView, no KaTeX (§3.3).
struct NativeFragmentImageProvider: FragmentImageProvider {
    var styleSheet: StyleSheet

    func image(forMath latex: String, display: Bool, pointSize: CGFloat, color: NSColor) -> NSImage? {
        MathRenderer.image(latex: latex, display: display, pointSize: pointSize, color: color)
    }

    func image(forMermaid source: String, theme: Theme) -> NSImage? {
        MermaidRendererBridge.image(source: source, styleSheet: styleSheet)
    }
}
