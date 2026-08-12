import AppKit
import MarkdownCore

/// Front matter editing is a source-preserving panel.  The controller owns
/// the document mutation, so each field change is one normal undo step.
@MainActor
extension DocumentWindowController: FrontMatterEditorDelegate {
    func showFrontMatterEditor(focus: String? = nil) {
        let viewportRepairs = documentPanes.map { $0.textView.makeViewportRepair() }
        assetDoctorPanel = nil
        let editor: FrontMatterEditorView
        if let current = frontMatterEditor {
            editor = current
        } else {
            let created = FrontMatterEditorView(styleSheet: activeStyleSheet)
            created.delegate = self
            frontMatterEditor = created
            editor = created
        }
        editor.document = markdownDocument.parsed
        installTrailing(editor, title: Command.frontMatterEditor.panelTitle)
        viewportRepairs.forEach { $0() }
        DispatchQueue.main.async { [weak editor] in
            viewportRepairs.forEach { $0() }
            editor?.prepareForPresentation(focus: focus)
        }
        // The trailing host performs its own key-loop handoff after layout.
        // Reassert the semantic field once that handoff and the spring's first
        // frame have completed, or AX/keyboard users land on the window itself.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak editor] in
            guard let self, let editor, self.frontMatterEditor === editor else { return }
            viewportRepairs.forEach { $0() }
            editor.focusField(named: focus)
        }
    }

    func frontMatterEditor(
        _ editor: FrontMatterEditorView,
        didRequest operation: FrontMatterEditOperation
    ) {
        markdownDocument.ensureParsedCurrent()
        let result = FrontMatterEditing.propose(markdownDocument.parsed, operation: operation)
        guard let proposal = result.proposal else {
            editor.document = markdownDocument.parsed
            NSSound.beep()
            return
        }

        // `apply` groups the replacement and registers the inverse with the
        // document undo manager.  The editor never writes NSTextStorage itself.
        markdownDocument.apply([proposal.edit], actionName: proposal.summary)
        markdownDocument.reparseNow()
        editor.document = markdownDocument.parsed
    }

    func frontMatterEditorWantsSourceMode(_ editor: FrontMatterEditorView) {
        if let front = markdownDocument.parsed.frontMatter {
            primaryContainer.textView.focusSource(in: front.range)
            window?.makeFirstResponder(primaryContainer.textView)
        }
    }
}
