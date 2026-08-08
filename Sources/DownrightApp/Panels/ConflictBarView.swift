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

        message = "Changed on disk while you were editing"

        // Both resolutions throw one version away, and neither verb says which:
        // "Keep Mine" writes over the agent's file, "Take Theirs" drops your
        // unsaved edits.  A two-word button cannot carry that, so the help text
        // does — named consequences rather than named actions, because this is
        // the one moment in the app where guessing wrong costs work.
        let review = addAction("Review") { [weak self] in
            guard let self else { return }
            self.delegate?.conflictBarDidRequestReview(self)
        }
        describe(review, "Compare your version with the one on disk. Changes nothing.")

        let keepMine = addAction("Keep Mine") { [weak self] in
            guard let self else { return }
            self.delegate?.conflictBarDidRequestKeepMine(self)
        }
        keepMine.hasDestructiveAction = true
        describe(keepMine, "Save your version over the file, discarding the change on disk.")

        let takeTheirs = addAction("Take Theirs") { [weak self] in
            guard let self else { return }
            self.delegate?.conflictBarDidRequestTakeTheirs(self)
        }
        takeTheirs.hasDestructiveAction = true
        describe(takeTheirs, "Load the version on disk, discarding your unsaved edits.")

        onDismiss = { [weak self] in
            guard let self else { return }
            self.delegate?.conflictBarDidRequestDismiss(self)
        }

        setAccessibilityLabel(
            "File changed on disk while you were editing. "
                + "Review compares the two versions. Keep Mine saves yours over the file. "
                + "Take Theirs loads the file and discards your unsaved edits."
        )
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Attaches a consequence to a button for both pointer and VoiceOver.  The
    /// help text is the same string in both places on purpose: an explanation
    /// that only a sighted hovering user gets is not an explanation.
    private func describe(_ button: NSButton, _ consequence: String) {
        button.toolTip = consequence
        button.setAccessibilityHelp(consequence)
    }

    override func applyStyle() {
        stripeColor = styleSheet.changeColor(.modified)
        super.applyStyle()
    }
}
