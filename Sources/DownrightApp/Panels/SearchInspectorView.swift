import AppKit
import MarkdownRender

/// One search surface for document find and optional cross-file results.
/// The controller owns the search session; this view owns only composition.
@MainActor
final class SearchInspectorView: NSView {
    let findBar: FindBarView

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            findBar.styleSheet = styleSheet
            guidance.textColor = styleSheet.textFaint
        }
    }

    var showsReplace: Bool {
        get { findBar.showsReplace }
        set {
            findBar.showsReplace = newValue
            findHeight.constant = newValue ? 178 : 132
        }
    }

    private let backdrop: PanelBackdrop
    private let guidance = NSTextField(wrappingLabelWithString:
        "Matches are highlighted in the document. Press Return for the next match and Shift-Return for the previous match."
    )
    private let resultHost = NSView()
    private var findHeight: NSLayoutConstraint!
    private weak var results: NSView?

    init(styleSheet: StyleSheet = .current) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet)
        findBar = FindBarView(styleSheet: styleSheet, presentation: .inspector)
        super.init(frame: .zero)

        installBackdrop(backdrop)

        findBar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(findBar)

        guidance.font = PanelFont.secondary
        guidance.textColor = styleSheet.textFaint
        guidance.maximumNumberOfLines = 0
        guidance.translatesAutoresizingMaskIntoConstraints = false
        resultHost.addSubview(guidance)

        resultHost.translatesAutoresizingMaskIntoConstraints = false
        addSubview(resultHost)

        findHeight = findBar.heightAnchor.constraint(equalToConstant: 132)
        NSLayoutConstraint.activate([
            findBar.leadingAnchor.constraint(equalTo: leadingAnchor),
            findBar.trailingAnchor.constraint(equalTo: trailingAnchor),
            findBar.topAnchor.constraint(equalTo: topAnchor),
            findHeight,
            resultHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            resultHost.trailingAnchor.constraint(equalTo: trailingAnchor),
            resultHost.topAnchor.constraint(equalTo: findBar.bottomAnchor),
            resultHost.bottomAnchor.constraint(equalTo: bottomAnchor),
            guidance.leadingAnchor.constraint(equalTo: resultHost.leadingAnchor, constant: PanelMetrics.inset),
            guidance.trailingAnchor.constraint(equalTo: resultHost.trailingAnchor, constant: -PanelMetrics.inset),
            guidance.topAnchor.constraint(equalTo: resultHost.topAnchor, constant: 12),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Search")
    }

    required init?(coder: NSCoder) { nil }

    func setResults(_ view: NSView?) {
        results?.removeFromSuperview()
        results = view
        guidance.isHidden = view != nil
        guard let view else { return }
        view.translatesAutoresizingMaskIntoConstraints = false
        resultHost.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: resultHost.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: resultHost.trailingAnchor),
            view.topAnchor.constraint(equalTo: resultHost.topAnchor),
            view.bottomAnchor.constraint(equalTo: resultHost.bottomAnchor),
        ])
    }
}
