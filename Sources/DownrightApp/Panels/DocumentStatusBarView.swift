import AppKit
import MarkdownCore
import MarkdownRender

/// An **opt-in** footer strip showing the live caret position.
///
/// DESIGN.md's "Avoid" list names a permanent status bar outright, so this is
/// off by default and shown only when `Preferences.showStatusBar` asks for it
/// (View ▸ Show Status Bar).  What survives that constraint is the one figure
/// nothing else in the app reports — line and column while editing — plus the
/// unsaved marker.
///
/// Word count and reading time used to sit on the right of this bar.  They were
/// removed rather than restyled: `DensityGutterView` already owns them, and its
/// own note says they belong in its hover summary "rather than as permanent
/// chrome".  Two surfaces reporting one number is how a calm app stops being
/// one.
///
/// The bar never takes the first responder and never scrolls — it is pinned to
/// the bottom of the document root view, just above the window's bottom edge.
@MainActor
final class DocumentStatusBarView: NSView {
    var styleSheet: StyleSheet {
        didSet { applyStyle() }
    }

    /// Set from the text view's selection change handler.
    var cursorPosition: (line: Int, column: Int)? {
        didSet {
            guard cursorPosition?.line != oldValue?.line
                    || cursorPosition?.column != oldValue?.column else { return }
            updateCursorLabel()
        }
    }

    /// Whether the document has ever been saved to disk.  An unsaved new
    /// document shows a different cue so the reader knows saving is required.
    var hasFileURL: Bool = true {
        didSet {
            guard hasFileURL != oldValue else { return }
            updateCursorLabel()
        }
    }

    var isVisible: Bool = true {
        didSet {
            guard isVisible != oldValue else { return }
            isHidden = !isVisible
            invalidateIntrinsicContentSize()
        }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: isVisible ? Metrics.totalHeight : 0)
    }

    private enum Metrics {
        static let height: CGFloat = 22
        static let padding: CGFloat = 12
        static let insetX: CGFloat = 10
        static let totalHeight = height + padding
        static let dotSize: CGFloat = 5
        static let dotGap: CGFloat = 6
    }

    private let cursorLabel = NSTextField(labelWithString: "")
    private let unsavedDot = NSView()
    private let divider = NSView()
    private var trackingAreaRef: NSTrackingArea?

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        super.init(frame: .zero)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        cursorLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        cursorLabel.lineBreakMode = .byTruncatingTail
        cursorLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        addSubview(cursorLabel)

        unsavedDot.wantsLayer = true
        unsavedDot.layer?.cornerRadius = Metrics.dotSize / 2
        addSubview(unsavedDot)

        divider.wantsLayer = true
        addSubview(divider)

        // One-pass layout: the divider runs full width, the cursor sits on the
        // left, metrics on the right.  `translatesAutoresizingMaskIntoConstraints`
        // is off so we use Auto Layout.
        cursorLabel.translatesAutoresizingMaskIntoConstraints = false
        unsavedDot.translatesAutoresizingMaskIntoConstraints = false
        divider.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            divider.leadingAnchor.constraint(equalTo: leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: trailingAnchor),
            divider.topAnchor.constraint(equalTo: topAnchor),
            divider.heightAnchor.constraint(equalToConstant: PanelMetrics.hairline),

            unsavedDot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Metrics.insetX),
            unsavedDot.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Metrics.padding / 2),
            unsavedDot.widthAnchor.constraint(equalToConstant: Metrics.dotSize),
            unsavedDot.heightAnchor.constraint(equalToConstant: Metrics.dotSize),

            cursorLabel.leadingAnchor.constraint(
                equalTo: hasFileURL ? unsavedDot.trailingAnchor : leadingAnchor,
                constant: hasFileURL ? Metrics.dotGap : Metrics.insetX
            ),
            cursorLabel.centerYAnchor.constraint(equalTo: centerYAnchor, constant: Metrics.padding / 2),
            cursorLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: trailingAnchor, constant: -Metrics.insetX),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Document status")
        applyStyle()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    // MARK: - Updates

    private func updateCursorLabel() {
        guard let (line, column) = cursorPosition else {
            cursorLabel.stringValue = ""
            setAccessibilityValue("")
            return
        }
        let prefix = hasFileURL ? "" : "Unsaved · "
        cursorLabel.stringValue = "\(prefix)Ln \(line), Col \(column)"
        cursorLabel.setAccessibilityLabel(cursorLabel.stringValue)
        applyStyle()
    }

    // MARK: - Style

    private func applyStyle() {
        let contrast = styleSheet.increaseContrast
        divider.layer?.backgroundColor = styleSheet.rule
            .withAlphaComponent(contrast ? 0.6 : 0.35).cgColor
        // `textSecondary`, not `textFaint`.  Faint is the marker tier — it
        // measures 3.35:1 against the warm dark page, well under WCAG AA's
        // 4.5:1, and at this bar's 11pt the readout was effectively invisible.
        // Secondary clears AA at 6.25:1 and is still unmistakably chrome
        // (§11.4).
        cursorLabel.textColor = styleSheet.textSecondary
        unsavedDot.layer?.backgroundColor = styleSheet.accent.cgColor
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}
