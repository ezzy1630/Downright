import AppKit

/// Applies navigation requested by `down open` after the document's first
/// layout pass has installed its source text view.
@MainActor
extension DocumentWindowController {
    func applyCommandLineOpen(line: Int?, review: Bool) {
        guard line != nil || review else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let line {
                jumpToLine(line, animated: false)
            }
            if review { ensureReviewPanelVisible() }
        }
    }
}
