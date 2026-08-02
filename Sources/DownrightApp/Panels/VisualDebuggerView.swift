import AppKit
import MarkdownRender

@MainActor
protocol VisualDebuggerViewDelegate: AnyObject {
    func visualDebugger(_ view: VisualDebuggerView, didCopy summary: String)
}

/// Read-only source, AST, render, and layout facts for the current caret.
/// The view owns no document state and never edits source text.
@MainActor
final class VisualDebuggerView: NSView, PanelSurface {
    weak var delegate: VisualDebuggerViewDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            applyStyle()
        }
    }

    var model: VisualDebuggerModel = VisualDebuggerModel(input: .init(
        document: .empty, selection: NSRange(location: 0, length: 0), mode: .read
    )) {
        didSet { reload() }
    }

    var preferredWidth: CGFloat { 380 }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Visual Debugger")
    private let locationLabel = NSTextField(labelWithString: "")
    private let summaryView = NSTextView()
    private let copyButton = NSButton(title: "Copy Summary", target: nil, action: nil)
    private let scrollView = NSScrollView()

    convenience init() { self.init(styleSheet: .current) }

    init(styleSheet: StyleSheet) {
        self.styleSheet = styleSheet
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        titleLabel.font = PanelFont.header
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        locationLabel.font = PanelFont.secondary
        locationLabel.alignment = .right
        locationLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(locationLabel)

        summaryView.isEditable = false
        summaryView.isSelectable = true
        summaryView.isRichText = false
        summaryView.drawsBackground = false
        summaryView.textContainerInset = NSSize(width: PanelMetrics.inset, height: 8)
        summaryView.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        summaryView.delegate = self
        summaryView.setAccessibilityRole(.textArea)
        summaryView.setAccessibilityLabel("Visual debugger details")
        summaryView.translatesAutoresizingMaskIntoConstraints = false

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = summaryView
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrollView)

        copyButton.target = self
        copyButton.action = #selector(copySummary(_:))
        copyButton.bezelStyle = .rounded
        copyButton.controlSize = .small
        copyButton.setAccessibilityLabel("Copy visual debugger summary")
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(copyButton)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            locationLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            locationLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            locationLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            copyButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            copyButton.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 6),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: copyButton.bottomAnchor, constant: 4),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            summaryView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
            summaryView.heightAnchor.constraint(greaterThanOrEqualTo: scrollView.contentView.heightAnchor),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Visual Debugger")
        applyStyle()
        reload()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func reload() {
        locationLabel.stringValue = "Line (model.line), column (model.column)"
        locationLabel.setAccessibilityLabel(locationLabel.stringValue)
        summaryView.string = model.summary
        summaryView.sizeToFit()
        summaryView.setAccessibilityValue(model.summary)
    }

    func copySummaryForTesting() {
        copySummary(copyButton)
    }

    func summaryTextForTesting() -> String { summaryView.string }

    override var acceptsFirstResponder: Bool { true }

    override func becomeFirstResponder() -> Bool {
        summaryView.window?.makeFirstResponder(summaryView) ?? super.becomeFirstResponder()
    }

    override func keyDown(with event: NSEvent) {
        if event.modifierFlags.contains(.command), event.keyCode == 8 {
            copySummary(event)
            return
        }
        super.keyDown(with: event)
    }

    @objc private func copySummary(_ sender: Any?) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.summary, forType: .string)
        delegate?.visualDebugger(self, didCopy: model.summary)
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.textSecondary
        locationLabel.textColor = styleSheet.textFaint
        summaryView.textColor = styleSheet.text
        summaryView.insertionPointColor = styleSheet.accent
        copyButton.contentTintColor = styleSheet.textSecondary
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyStyle()
    }
}

extension VisualDebuggerView: NSTextViewDelegate {}
