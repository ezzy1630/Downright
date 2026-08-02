import AppKit
import MarkdownCore
import MarkdownRender

/// The transient Contents + Files navigator.  It is also suitable as the
/// content of the native leading split item when the user pins it.
@MainActor
protocol NavigationPanelViewDelegate: AnyObject {
    func navigationPanelDidRequestClose(_ panel: NavigationPanelView)
    func navigationPanelDidRequestPin(_ panel: NavigationPanelView)
    func navigationPanel(_ panel: NavigationPanelView, didSelectHeadingAt index: Int)
    func navigationPanel(_ panel: NavigationPanelView, didMoveHeadingAt index: Int, before targetIndex: Int)
    func navigationPanel(_ panel: NavigationPanelView, didToggleFoldAt index: Int)
    func navigationPanel(_ panel: NavigationPanelView, didSelectFile url: URL, inNewWindow: Bool)
}

@MainActor
final class NavigationPanelView: NSView, PanelSurface {
    weak var delegate: NavigationPanelViewDelegate?

    var styleSheet: StyleSheet {
        didSet {
            backdrop.styleSheet = styleSheet
            contents.styleSheet = styleSheet
            files.styleSheet = styleSheet
            applyStyle()
        }
    }

    var preferredWidth: CGFloat { 312 }
    var headings: [HeadingNode] { get { contents.headings } set { contents.headings = newValue } }
    var sectionMetrics: [ReadingMetrics] { get { contents.sectionMetrics } set { contents.sectionMetrics = newValue } }
    var foldedIndices: Set<Int> { get { contents.foldedIndices } set { contents.foldedIndices = newValue } }
    var currentHeadingIndex: Int? { get { contents.currentHeadingIndex } set { contents.currentHeadingIndex = newValue } }
    var siblings: [SiblingScanner.Sibling] { get { files.siblings } set { files.siblings = newValue } }
    var filterText: String {
        get { contents.filterText }
        set {
            contents.filterText = newValue
            files.filterText = newValue
            if searchField.stringValue != newValue { searchField.stringValue = newValue }
        }
    }

    private let backdrop: PanelBackdrop
    private let searchField = NSSearchField()
    private let pinButton: NSButton
    private let closeButton: NSButton
    private let contents: OutlinePanelView
    private let files: SiblingSidebarView
    private let stack = NSStackView()
    private var searchAction: ButtonAction?
    private var pinAction: ButtonAction?
    private var closeAction: ButtonAction?

    init(styleSheet: StyleSheet = .current) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet, material: .popover)
        contents = OutlinePanelView(styleSheet: styleSheet)
        files = SiblingSidebarView(styleSheet: styleSheet)
        pinButton = PanelButton.symbol("pin", label: "Pin Contents sidebar", action: ButtonAction({}))
        closeButton = PanelButton.symbol("xmark", label: "Close Contents", action: ButtonAction({}))
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        searchField.placeholderString = "Search contents and files"
        searchField.font = PanelFont.row
        searchField.controlSize = .small
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.setAccessibilityLabel("Search contents and files")
        addSubview(searchField)

        pinAction = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.navigationPanelDidRequestPin(self)
        }
        pinButton.target = pinAction
        pinButton.action = #selector(ButtonAction.fire(_:))
        addSubview(pinButton)

        closeAction = ButtonAction { [weak self] in
            guard let self else { return }
            self.delegate?.navigationPanelDidRequestClose(self)
        }
        closeButton.target = closeAction
        closeButton.action = #selector(ButtonAction.fire(_:))
        addSubview(closeButton)

        contents.delegate = self
        files.delegate = self
        stack.orientation = .vertical
        stack.distribution = .fillEqually
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(contents)
        stack.addArrangedSubview(files)
        addSubview(stack)

        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendAction(on: [.keyDown, .keyUp])
        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            searchField.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -6),
            searchField.topAnchor.constraint(equalTo: topAnchor, constant: PanelMetrics.inset),
            pinButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            pinButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 18),
            pinButton.heightAnchor.constraint(equalToConstant: 18),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            closeButton.centerYAnchor.constraint(equalTo: searchField.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 18),
            closeButton.heightAnchor.constraint(equalToConstant: 18),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Contents and Files")
        applyStyle()
    }

    convenience init() { self.init(styleSheet: .current) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
    }

    func setPinned(_ pinned: Bool) {
        pinButton.isHidden = pinned
        pinButton.toolTip = pinned ? nil : "Pin Contents sidebar"
    }

    func reload() {
        contents.reload()
        files.reload()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue
        contents.filterText = query
        files.filterText = query
    }

    private func applyStyle() {
        searchField.textColor = styleSheet.text
        searchField.backgroundColor = styleSheet.background
        needsDisplay = true
    }

    override func cancelOperation(_ sender: Any?) {
        delegate?.navigationPanelDidRequestClose(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            delegate?.navigationPanelDidRequestClose(self)
            return
        }
        super.keyDown(with: event)
    }
}

extension NavigationPanelView: OutlinePanelDelegate {
    func outlinePanel(_ panel: OutlinePanelView, didSelectHeadingAt index: Int) {
        delegate?.navigationPanel(self, didSelectHeadingAt: index)
    }

    func outlinePanel(_ panel: OutlinePanelView, didMoveHeadingAt index: Int, before targetIndex: Int) {
        delegate?.navigationPanel(self, didMoveHeadingAt: index, before: targetIndex)
    }

    func outlinePanel(_ panel: OutlinePanelView, didToggleFoldAt index: Int) {
        delegate?.navigationPanel(self, didToggleFoldAt: index)
    }

    func outlinePanel(_ panel: OutlinePanelView, didChangeZoomLevel level: ZoomLevel) {}
}

extension NavigationPanelView: SiblingSidebarDelegate {
    func siblingSidebar(_ sidebar: SiblingSidebarView, didSelect url: URL, inNewWindow: Bool) {
        delegate?.navigationPanel(self, didSelectFile: url, inNewWindow: inNewWindow)
    }
}

/// Borderless child window used for the transient navigator.  Escape is
/// handled at the panel level so it still works while the search field owns
/// first responder.
final class NavigationPanelWindow: NSPanel {
    var onEscape: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onEscape?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onEscape?()
            return
        }
        super.keyDown(with: event)
    }
}
