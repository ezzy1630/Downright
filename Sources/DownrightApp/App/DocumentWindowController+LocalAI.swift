import AppKit
import ObjectiveC

private var localAIPanelKey: UInt8 = 0
private var localAIProviderKey: UInt8 = 0
private var localAICoordinatorKey: UInt8 = 0

@MainActor
extension DocumentWindowController: LocalAIPanelViewDelegate {
    private var localAIPanel: LocalAIPanelView? {
        get { objc_getAssociatedObject(self, &localAIPanelKey) as? LocalAIPanelView }
        set { objc_setAssociatedObject(self, &localAIPanelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var localAIProvider: LocalAIProvider {
        get {
            if let provider = objc_getAssociatedObject(self, &localAIProviderKey) as? LocalAIProvider { return provider }
            let provider = AppleOnDeviceAIProvider()
            objc_setAssociatedObject(self, &localAIProviderKey, provider, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return provider
        }
    }

    private var localAICoordinator: LocalAILatestWinsController {
        get {
            if let coordinator = objc_getAssociatedObject(self, &localAICoordinatorKey) as? LocalAILatestWinsController { return coordinator }
            let coordinator = LocalAILatestWinsController(provider: localAIProvider)
            objc_setAssociatedObject(self, &localAICoordinatorKey, coordinator, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return coordinator
        }
    }

    /// Tests and future local providers can replace the adapter.  The panel
    /// stays unaware of the provider implementation.
    func setLocalAIProvider(_ provider: LocalAIProvider) {
        objc_setAssociatedObject(self, &localAIProviderKey, provider, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        objc_setAssociatedObject(self, &localAICoordinatorKey, LocalAILatestWinsController(provider: provider), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        localAIPanel?.availability = provider.availability
    }

    func showLocalAIPanel() {
        if let localAIPanel {
            dismissTrailing(localAIPanel)
            self.localAIPanel = nil
            localAICoordinator.cancel()
            return
        }
        let panel = LocalAIPanelView(styleSheet: activeStyleSheet)
        panel.delegate = self
        panel.availability = localAIProvider.availability
        localAIPanel = panel
        installTrailing(panel)
    }

    func localAIPanel(_ panel: LocalAIPanelView, didRequest task: LocalAITask) {
        let selection = containerTextView.sourceSelectedRange
        let range = selection.length > 0 ? selection : nil
        let request = LocalAIRequest(task: task, source: markdownDocument.text, selection: range)
        panel.isRunning = true
        panel.result = nil
        localAICoordinator.submit(request) { [weak self, weak panel] result in
            guard let self, let panel, self.localAIPanel === panel else { return }
            panel.isRunning = false
            switch result {
            case .success(let value): panel.result = value
            case .failure(let error): panel.result = LocalAIResult(task: task, text: Self.message(for: error), preview: nil)
            }
        }
    }

    func localAIPanel(_ panel: LocalAIPanelView, didApply preview: LocalAIPreview) {
        guard let edit = LocalAIEditValidator.edit(for: preview, in: markdownDocument.text) else {
            panel.result = LocalAIResult(task: .improveClarity, text: "The source changed. Run the task again.", preview: nil)
            return
        }
        markdownDocument.apply([edit], actionName: edit.summary)
        markdownDocument.reparseNow()
        panel.result = nil
    }

    func localAIPanelDidCancel(_ panel: LocalAIPanelView) {
        localAICoordinator.cancel()
        dismissTrailing(panel)
        if localAIPanel === panel { localAIPanel = nil }
    }

    private static func message(for error: Error) -> String {
        if let error = error as? LocalAIError {
            switch error {
            case .emptyInput: return "Select or open text first."
            case .cancelled: return "Cancelled."
            case .unavailable: return "On-device AI is not available on this Mac."
            }
        }
        return "Local AI could not complete this task."
    }
}
