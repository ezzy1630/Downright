import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol ConflictBarDelegate: AnyObject {
    func conflictBarDidRequestReview(_ bar: ConflictBarView)
    func conflictBarDidRequestKeepMine(_ bar: ConflictBarView)
    func conflictBarDidRequestTakeTheirs(_ bar: ConflictBarView)
    func conflictBarDidRequestDismiss(_ bar: ConflictBarView)
}

/// The dirty-buffer conflict bar (§8.1).
///
/// **Never clobber, never interrupt.**  An agent rewriting the file you are
/// editing is an ordinary event in this app, so the response is a bar you can
/// ignore for an hour — not a sheet that stops the world, and not a dialog that
/// makes you answer before you can keep reading.  Nothing here takes the
/// keyboard: no default button, no first responder, no modal session.
final class ConflictBarView: MessageBarView {
    weak var delegate: ConflictBarDelegate?

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        super.init(styleSheet: styleSheet, stripeColor: styleSheet.changeColor(.modified))

        message = "Changed on disk"
        addAction("Review") { [weak self] in
            guard let self else { return }
            self.delegate?.conflictBarDidRequestReview(self)
        }
        addAction("Keep Mine") { [weak self] in
            guard let self else { return }
            self.delegate?.conflictBarDidRequestKeepMine(self)
        }
        addAction("Take Theirs") { [weak self] in
            guard let self else { return }
            self.delegate?.conflictBarDidRequestTakeTheirs(self)
        }
        onDismiss = { [weak self] in
            guard let self else { return }
            self.delegate?.conflictBarDidRequestDismiss(self)
        }

        setAccessibilityLabel("File changed on disk")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func applyStyle() {
        stripeColor = styleSheet.changeColor(.modified)
        super.applyStyle()
    }
}
