import AppKit
import MarkdownCore

/// The visual table editor is transient. It writes through MarkdownDocument,
/// then refreshes both surfaces from the new parsed snapshot.
extension DocumentWindowController: TableEditorDelegate {
    func presentTableEditor() {
        guard let window else { return }
        markdownDocument.ensureParsedCurrent()
        let index = tableIndex(at: caretOffset()) ?? 0
        let editor = TableEditorView(
            document: markdownDocument.parsed,
            tableIndex: index,
            styleSheet: currentStyleSheet
        )
        editor.delegate = self

        let sheetWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 480),
            styleMask: [.titled, .resizable],
            backing: .buffered,
            defer: false
        )
        sheetWindow.title = "Edit Table"
        sheetWindow.minSize = NSSize(width: 520, height: 320)
        sheetWindow.contentView = editor
        tableEditorWindow = sheetWindow
        window.beginSheet(sheetWindow)
    }

    func tableEditor(_ editor: TableEditorView, didApply proposal: TableEditProposal) {
        guard proposal.applying(to: markdownDocument.text) != nil else {
            editor.update(document: markdownDocument.parsed)
            return
        }
        guard markdownDocument.replace(proposal.range, with: proposal.replacement, actionName: proposal.summary) else { return }
        markdownDocument.reparseNow()
        editor.update(document: markdownDocument.parsed)
    }

    func tableEditor(_ editor: TableEditorView, didRequestSource range: NSRange) {
        closeTableEditor()
        containerTextView.focusSource(in: range)
        window?.makeFirstResponder(containerTextView)
    }

    func closeTableEditor() {
        guard let sheetWindow = tableEditorWindow else { return }
        window?.endSheet(sheetWindow)
        tableEditorWindow = nil
    }

    private func tableIndex(at offset: Int) -> Int? {
        var index = 0
        var result: Int?
        markdownDocument.parsed.root.walk { block in
            guard case .table = block.content else { return }
            if result == nil, block.range.touches(offset: offset) { result = index }
            index += 1
        }
        return result
    }
}
