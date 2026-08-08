import AppKit
import MarkdownCore
import MarkdownRender
import ObjectiveC

private var documentLensPanelKey: UInt8 = 0
private var documentLensThemeKey: UInt8 = 0

/// Document Lens is kept in an extension so the existing window controller
/// stays focused on the document surface.  Associated storage gives the
/// transient panel normal lifetime without adding shared controller state.
@MainActor
extension DocumentWindowController: DocumentLensViewDelegate {
    private var documentLensPanel: DocumentLensView? {
        get { objc_getAssociatedObject(self, &documentLensPanelKey) as? DocumentLensView }
        set { objc_setAssociatedObject(self, &documentLensPanelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func toggleDocumentLensPanel() {
        if let panel = documentLensPanel {
            dismissTrailing(panel)
            documentLensPanel = nil
            objc_setAssociatedObject(self, &documentLensThemeKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }

        let panel = DocumentLensView(styleSheet: activeStyleSheet)
        panel.delegate = self
        documentLensPanel = panel
        configureDocumentLens(panel)
        installTrailing(panel, title: Command.documentLens.panelTitle)

        let observation = ThemeStore.shared.observe { [weak self, weak panel] theme in
            guard let self, let panel, let window = self.window else { return }
            panel.styleSheet = StyleSheet(theme: theme, appearance: window.effectiveAppearance)
        }
        objc_setAssociatedObject(self, &documentLensThemeKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func configureDocumentLens(_ panel: DocumentLensView) {
        let parsed = markdownDocument.parsed
        let health = DocumentHealth.analyze(parsed)
        let context = AssetResolutionContext(
            documentURL: markdownDocument.url,
            workspaceRoot: markdownDocument.url?.deletingLastPathComponent()
        )
        let references = AssetDoctor.references(in: parsed, context: context)
        let assets = AssetDoctor.diagnose(parsed, context: context, probe: localAssetProbe())
        // GitHub is the most common interchange target.  The panel remains
        // useful for local files because the target is injected and can later
        // be replaced by a user profile without changing the view.
        let report = MarkdownCompatibility.diagnose(parsed, for: panel.renderTargetProfile)
        let changes = markdownDocument.changes.visibleMarks.enumerated().map { index, mark in
            DocumentLensChange(id: "\(index):\(mark.range.location)", kind: mark.kind, range: mark.range, wordRanges: mark.wordRanges)
        }
        // The rows caption themselves by line number, which needs the source
        // before the model lands or they fall back to raw byte offsets.
        panel.sourceText = markdownDocument.text
        panel.model = DocumentLensModel(input: DocumentLensInput(
            document: parsed, health: health, assetReferences: references, assets: assets,
            renderTarget: report, changes: changes
        ))
    }

    func documentLens(_ view: DocumentLensView, didSelectRenderTarget profile: RenderTargetProfile) {
        view.renderTargetProfile = profile
        configureDocumentLens(view)
    }

    func documentLens(_ view: DocumentLensView, didSelect range: NSRange, item: DocumentLensItem) {
        guard range.location >= 0, range.upperBound <= markdownDocument.storage.length else { return }
        containerTextView.setSourceSelectedRanges([range])
        containerTextView.scroll(toOffset: range.location, position: .visible, animated: true)
        window?.makeFirstResponder(containerTextView)
    }

    func refreshDocumentLensIfVisible() {
        guard let documentLensPanel else { return }
        configureDocumentLens(documentLensPanel)
    }

}
