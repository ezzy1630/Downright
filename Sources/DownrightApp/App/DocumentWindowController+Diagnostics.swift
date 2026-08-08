import AppKit
import MarkdownCore
import MarkdownRender
import ObjectiveC

private var healthPanelKey: UInt8 = 0
private var targetPanelKey: UInt8 = 0

/// Window hooks for the two source-first diagnostics surfaces.  The panels
/// never mutate the document.  This extension owns validation, one-step undo,
/// and source selection.
@MainActor
extension DocumentWindowController: DocumentHealthViewDelegate, RenderTargetsViewDelegate {
    private var healthPanel: DocumentHealthView? {
        get { objc_getAssociatedObject(self, &healthPanelKey) as? DocumentHealthView }
        set { objc_setAssociatedObject(self, &healthPanelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var renderTargetsPanel: RenderTargetsView? {
        get { objc_getAssociatedObject(self, &targetPanelKey) as? RenderTargetsView }
        set { objc_setAssociatedObject(self, &targetPanelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func toggleDocumentHealthPanel() {
        if let panel = healthPanel {
            dismissTrailing(panel)
            healthPanel = nil
            return
        }
        let panel = DocumentHealthView(styleSheet: activeStyleSheet)
        healthPanel = panel
        configureDocumentHealth(panel)
        installTrailing(panel)
    }

    func configureDocumentHealth(_ panel: DocumentHealthView) {
        panel.delegate = self
        panel.styleSheet = activeStyleSheet
        panel.sourceText = markdownDocument.text
        panel.diagnostics = DocumentHealth.analyze(markdownDocument.parsed)
    }

    func toggleRenderTargetsPanel() {
        if let panel = renderTargetsPanel {
            dismissTrailing(panel)
            renderTargetsPanel = nil
            return
        }
        let panel = RenderTargetsView(styleSheet: activeStyleSheet)
        renderTargetsPanel = panel
        configureRenderTargets(panel)
        installTrailing(panel)
    }

    func configureRenderTargets(_ panel: RenderTargetsView) {
        panel.delegate = self
        panel.styleSheet = activeStyleSheet
        panel.sourceText = markdownDocument.text
        panel.document = markdownDocument.parsed
    }

    func documentHealthView(_ view: DocumentHealthView, didSelect diagnostic: DocumentHealthDiagnostic) {
        selectDiagnosticRange(diagnostic.range)
    }

    func documentHealthView(_ view: DocumentHealthView, didApply fixes: [TextEdit]) {
        applyDiagnosticEdits(fixes, actionName: "Apply health fixes")
        configureDocumentHealth(view)
    }

    func documentHealthViewWantsSourceMode(_ view: DocumentHealthView) {
        openSourceMode()
    }

    func renderTargetsView(_ view: RenderTargetsView, didSelect profile: RenderTargetProfile) {
        view.document = markdownDocument.parsed
    }

    func renderTargetsView(_ view: RenderTargetsView, didSelect diagnostic: CompatibilityDiagnostic) {
        selectDiagnosticRange(diagnostic.range)
    }

    func renderTargetsView(_ view: RenderTargetsView, didApply fixes: [TextEdit]) {
        applyDiagnosticEdits(fixes, actionName: "Apply render target fixes")
        configureRenderTargets(view)
    }

    func renderTargetsViewWantsSourceMode(_ view: RenderTargetsView) {
        openSourceMode()
    }

    /// Call after a parse when a diagnostics panel is visible.
    func refreshDiagnosticsPanels() {
        if let healthPanel { configureDocumentHealth(healthPanel) }
        if let renderTargetsPanel { configureRenderTargets(renderTargetsPanel) }
    }

    private func selectDiagnosticRange(_ range: NSRange) {
        guard range.location >= 0, range.upperBound <= markdownDocument.storage.length else { return }
        containerTextView.setSourceSelectedRanges([range])
        containerTextView.scroll(toOffset: range.location, position: .visible, animated: true)
        window?.makeFirstResponder(containerTextView)
    }

    private func openSourceMode() {
        applyMode(.source)
        window?.makeFirstResponder(containerTextView)
    }

    private func applyDiagnosticEdits(_ edits: [TextEdit], actionName: String) {
        let length = markdownDocument.storage.length
        let safe = edits
            .filter { $0.range.location >= 0 && $0.range.upperBound <= length }
            .sorted { $0.range.location > $1.range.location }
        guard !safe.isEmpty else { return }

        var lastStart = Int.max
        let nonOverlapping = safe.filter {
            guard $0.range.upperBound <= lastStart else { return false }
            lastStart = $0.range.location
            return true
        }
        guard !nonOverlapping.isEmpty else { return }
        markdownDocument.apply(nonOverlapping, actionName: actionName)
        markdownDocument.reparseNow()
        refreshDerivedUI()
        refreshDiagnosticsPanels()
    }
}
