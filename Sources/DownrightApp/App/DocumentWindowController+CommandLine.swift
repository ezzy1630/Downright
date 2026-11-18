import AppKit

/// Applies navigation requested by `down open` after the document's first
/// layout pass has installed its source text view.
@MainActor
extension DocumentWindowController {
    func applyCommandLineOpen(line: Int?, review: Bool) {
        guard line != nil || review else { return }
        let url = markdownDocument.url
        Task { @MainActor [weak self] in
            guard let self, self.markdownDocument.url == url else { return }
            if let line {
                jumpToLine(line, animated: false)
            }
            if review { ensureReviewPanelVisible() }
        }
    }
}
