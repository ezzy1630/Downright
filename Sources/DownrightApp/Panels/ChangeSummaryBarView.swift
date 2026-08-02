import AppKit
import MarkdownCore
import MarkdownRender

@MainActor
protocol ChangeSummaryBarDelegate: AnyObject {
    func changeSummaryBar(_ bar: ChangeSummaryBarView, didRequestJump forward: Bool)
    func changeSummaryBarDidRequestDismiss(_ bar: ChangeSummaryBarView)
}

/// The clean-buffer change summary (§8.1).
///
/// The document has already been updated in place underneath the reader — this
/// only reports what happened and offers to walk them, which is the pointer
/// equivalent of `[` and `]` (§7.2).  Same non-modal shape as the conflict bar:
/// it must be ignorable, because most of the time you will just carry on
/// reading and let the change marks fade.
final class ChangeSummaryBarView: MessageBarView {
    weak var delegate: ChangeSummaryBarDelegate?

    /// Hosts build panels before they have a theme in hand and assign
    /// `styleSheet` immediately afterwards.
    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        super.init(styleSheet: styleSheet, stripeColor: styleSheet.changeColor(.inserted))

        message = "Updated on disk"
        addAction("Previous") { [weak self] in
            guard let self else { return }
            self.delegate?.changeSummaryBar(self, didRequestJump: false)
        }
        addAction("Next") { [weak self] in
            guard let self else { return }
            self.delegate?.changeSummaryBar(self, didRequestJump: true)
        }
        onDismiss = { [weak self] in
            guard let self else { return }
            self.delegate?.changeSummaryBarDidRequestDismiss(self)
        }

        setAccessibilityLabel("Document updated on disk")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func applyStyle() {
        stripeColor = styleSheet.changeColor(.inserted)
        super.applyStyle()
    }
}
