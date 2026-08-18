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
                let text = markdownDocument.text as NSString
                let lines = text.components(separatedBy: "\n")
                let targetLine = min(max(1, line) - 1, max(0, lines.count - 1))
                var offset = 0
                for index in 0..<targetLine {
                    offset += lines[index].utf16.count + 1
                }
                jump(to: min(offset, text.length), label: "Line \(line)", animated: false)
            }
            if review { ensureReviewPanelVisible() }
        }
    }
}
