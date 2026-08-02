import AppKit
import ObjectiveC
import MarkdownCore

private var reviewPanelAssociationKey: UInt8 = 0
private var reviewStoreAssociationKey: UInt8 = 0

@MainActor
extension DocumentWindowController: ReviewPanelViewDelegate {
    private var reviewPanel: ReviewPanelView? {
        get { objc_getAssociatedObject(self, &reviewPanelAssociationKey) as? ReviewPanelView }
        set {
            objc_setAssociatedObject(self, &reviewPanelAssociationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }

    private var reviewStore: ReviewSidecarStore {
        get {
            if let store = objc_getAssociatedObject(self, &reviewStoreAssociationKey) as? ReviewSidecarStore {
                return store
            }
            let store = LocalReviewSidecarStore()
            objc_setAssociatedObject(self, &reviewStoreAssociationKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return store
        }
    }

    /// Replace the persistence seam before opening the panel.  Production uses
    /// the local JSON store; tests can use an in-memory store.
    func setReviewSidecarStore(_ store: ReviewSidecarStore) {
        objc_setAssociatedObject(self, &reviewStoreAssociationKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func showReviewPanel() {
        if let reviewPanel {
            dismissTrailing(reviewPanel)
            self.reviewPanel = nil
            return
        }
        let panel = ReviewPanelView(styleSheet: activeStyleSheet)
        panel.delegate = self
        reviewPanel = panel
        configureReviewPanel(panel)
        installTrailing(panel)
    }

    func configureReviewPanel(_ panel: ReviewPanelView) {
        panel.sourceText = markdownDocument.text
        guard let url = markdownDocument.url else {
            panel.reviews = []
            return
        }
        panel.reviews = (try? reviewStore.load(for: url))?.reviews ?? []
    }

    func refreshReviewPanelIfVisible() {
        guard let reviewPanel else { return }
        configureReviewPanel(reviewPanel)
    }

    /// Create a local review for the current source selection.  The caller
    /// supplies the text shown to the reviewer; no network account is needed.
    @discardableResult
    func addReview(kind: ReviewKind, body: String, replacement: String? = nil) -> ReviewItem? {
        guard let url = markdownDocument.url else { return nil }
        let review = ReviewSidecarEngine.makeReview(
            kind: kind,
            in: markdownDocument.text,
            range: containerTextView.sourceSelectedRange,
            body: body,
            replacement: replacement
        )
        guard let review else { return nil }
        var sidecar = (try? reviewStore.load(for: url)) ?? ReviewSidecar()
        sidecar.reviews.append(review)
        try? reviewStore.save(sidecar, for: url)
        if let reviewPanel { configureReviewPanel(reviewPanel) }
        return review
    }

    func reviewPanel(_ panel: ReviewPanelView, didSelect review: ReviewItem) {
        let resolution = ReviewAnchorResolver.resolve(review.anchor, in: markdownDocument.text)
        guard let range = resolution.range,
              range.upperBound <= markdownDocument.storage.length else { return }
        containerTextView.setSourceSelectedRanges([range])
        containerTextView.scroll(toOffset: range.location, position: .center, animated: true)
        window?.makeFirstResponder(containerTextView)
    }

    func reviewPanel(_ panel: ReviewPanelView, didApply review: ReviewItem) {
        switch ReviewSidecarEngine.applySuggestion(review, to: markdownDocument.text) {
        case .stale:
            configureReviewPanel(panel)
        case .applied(let edit):
            markdownDocument.apply([edit], actionName: "Apply Suggestion")
            markdownDocument.reparseNow()
            updateReview(review.id, state: .resolved)
            configureReviewPanel(panel)
        }
    }

    func reviewPanel(_ panel: ReviewPanelView, didResolve review: ReviewItem) {
        updateReview(review.id, state: .resolved)
        configureReviewPanel(panel)
    }

    func reviewPanelDidRequestClose(_ panel: ReviewPanelView) {
        dismissTrailing(panel)
        if reviewPanel === panel { reviewPanel = nil }
    }

    private func updateReview(_ id: UUID, state: ReviewState) {
        guard let url = markdownDocument.url else { return }
        var sidecar = (try? reviewStore.load(for: url)) ?? ReviewSidecar()
        guard let index = sidecar.reviews.firstIndex(where: { $0.id == id }) else { return }
        sidecar.reviews[index].state = state
        try? reviewStore.save(sidecar, for: url)
    }
}
