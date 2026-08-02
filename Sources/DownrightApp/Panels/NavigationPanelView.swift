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

    var preferredWidth: CGFloat { NavigationPanelGeometry.width }
    var preferredHeight: CGFloat {
        let sectionGap = contents.hasVisibleContent && files.hasVisibleContent ? sectionSpacing : 0
        let contentHeight = 92 + contents.preferredHeight + files.preferredHeight + sectionGap
        return min(
            NavigationPanelGeometry.maximumHeight,
            max(NavigationPanelGeometry.minimumHeight, contentHeight)
        )
    }

    /// The host owns the child-window animation and calls this after the
    /// panel's filtered content changes its natural height.
    var onLayoutNeedsUpdate: (() -> Void)?
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
            updateSectionLayout()
        }
    }
    var visibleHeadingCountForTesting: Int { contents.visibleRowCountForTesting }
    var visibleFileCountForTesting: Int { files.visibleFileCountForTesting }
    var visibleSectionCountForTesting: Int {
        [contents.hasVisibleContent, files.hasVisibleContent].filter { $0 }.count
    }
    var emptyStateVisibleForTesting: Bool { !emptyState.isHidden }

    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Navigate")
    private let summaryLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let pinButton: NSButton
    private let closeButton: NSButton
    private let contents: OutlinePanelView
    private let files: SiblingSidebarView
    private let sections = NSView()
    private let emptyLabel = NSTextField(labelWithString: "No headings or files")
    private let emptyState = NSStackView()
    private let sectionSpacing: CGFloat = 8
    private var pinAction: ButtonAction?
    private var closeAction: ButtonAction?
    private var lastPreferredHeight: CGFloat = 0

    init(styleSheet: StyleSheet = .current) {
        self.styleSheet = styleSheet
        backdrop = PanelBackdrop(styleSheet: styleSheet, material: .popover)
        contents = OutlinePanelView(styleSheet: styleSheet)
        files = SiblingSidebarView(styleSheet: styleSheet)
        pinButton = PanelButton.symbol("pin", label: "Keep navigation sidebar open", action: ButtonAction({}))
        closeButton = PanelButton.symbol("xmark", label: "Close navigation", action: ButtonAction({}))
        super.init(frame: .zero)

        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        titleLabel.font = PanelFont.title
        titleLabel.textColor = styleSheet.text
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)

        summaryLabel.font = PanelFont.secondary
        summaryLabel.alignment = .right
        summaryLabel.textColor = styleSheet.textFaint
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(summaryLabel)

        searchField.placeholderString = "Search headings and files"
        searchField.font = PanelFont.row
        searchField.controlSize = .regular
        searchField.bezelStyle = .roundedBezel
        searchField.focusRingType = .default
        searchField.drawsBackground = true
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
        sections.translatesAutoresizingMaskIntoConstraints = false
        sections.addSubview(files)
        sections.addSubview(contents, positioned: .above, relativeTo: nil)
        addSubview(sections)

        emptyState.orientation = .vertical
        emptyState.alignment = .centerX
        emptyState.spacing = 5
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = PanelFont.row
        emptyLabel.alignment = .center
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyState.addArrangedSubview(emptyLabel)
        addSubview(emptyState)
        emptyState.isHidden = true

        searchField.target = self
        searchField.action = #selector(searchChanged(_:))
        searchField.sendAction(on: [.keyDown, .keyUp])
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: PanelMetrics.inset),
            summaryLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            summaryLabel.trailingAnchor.constraint(equalTo: pinButton.leadingAnchor, constant: -8),
            summaryLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pinButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -4),
            pinButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            pinButton.widthAnchor.constraint(equalToConstant: 28),
            pinButton.heightAnchor.constraint(equalToConstant: 28),
            closeButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            closeButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            closeButton.widthAnchor.constraint(equalToConstant: 28),
            closeButton.heightAnchor.constraint(equalToConstant: 28),
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            searchField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),
            searchField.heightAnchor.constraint(equalToConstant: 26),
            sections.leadingAnchor.constraint(equalTo: leadingAnchor),
            sections.trailingAnchor.constraint(equalTo: trailingAnchor),
            sections.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: sectionSpacing),
            sections.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -PanelMetrics.inset),
            emptyState.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            emptyState.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            emptyState.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 32),
            emptyState.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -PanelMetrics.inset),
        ])

        // Keep the header controls above the section surface while AppKit
        // resolves the child frames.
        for view in [titleLabel, summaryLabel, searchField, pinButton, closeButton] {
            addSubview(view, positioned: .above, relativeTo: nil)
        }

        setAccessibilityRole(.group)
        setAccessibilityLabel("Contents and Files")
        applyStyle()
    }

    convenience init() { self.init(styleSheet: .current) }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func focusSearch() {
        window?.makeFirstResponder(searchField)
        searchField.selectText(nil)
    }

    func setPinned(_ pinned: Bool) {
        pinButton.isHidden = pinned
        pinButton.toolTip = pinned ? nil : "Keep navigation sidebar open"
    }

    func reload() {
        contents.reload()
        files.reload()
        updateSectionLayout()
    }

    @objc private func searchChanged(_ sender: NSSearchField) {
        let query = sender.stringValue
        contents.filterText = query
        files.filterText = query
        updateSectionLayout()
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.text
        summaryLabel.textColor = styleSheet.textFaint
        emptyLabel.textColor = styleSheet.textSecondary
        searchField.textColor = styleSheet.text
        searchField.backgroundColor = styleSheet.background
        pinButton.contentTintColor = styleSheet.textSecondary
        closeButton.contentTintColor = styleSheet.textSecondary
        needsDisplay = true
    }

    private func updateSectionLayout() {
        let showsContents = contents.hasVisibleContent
        let showsFiles = files.hasVisibleContent
        let previousHeight = lastPreferredHeight

        contents.isHidden = !showsContents
        files.isHidden = !showsFiles
        let showsEmptyState = !showsContents && !showsFiles
        sections.isHidden = showsEmptyState
        emptyState.isHidden = !showsEmptyState

        let headingCount = contents.visibleRowCountForTesting
        let fileCount = files.visibleFileCountForTesting
        switch (headingCount, fileCount) {
        case (0, 0):
            summaryLabel.stringValue = ""
        case (0, let files):
            summaryLabel.stringValue = "\(files) file\(files == 1 ? "" : "s")"
        case (let headings, 0):
            summaryLabel.stringValue = "\(headings) heading\(headings == 1 ? "" : "s")"
        case (let headings, let files):
            summaryLabel.stringValue = "\(headings) heading\(headings == 1 ? "" : "s") · \(files) file\(files == 1 ? "" : "s")"
        }
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        emptyLabel.stringValue = query.isEmpty
            ? "No headings or files"
            : "No headings or files match \u{201c}\(query)\u{201d}"
        emptyLabel.setAccessibilityLabel(emptyLabel.stringValue)
        setAccessibilityValue(summaryLabel.stringValue)

        let nextHeight = preferredHeight
        lastPreferredHeight = nextHeight
        guard abs(nextHeight - previousHeight) > 0.5 else { return }
        onLayoutNeedsUpdate?()
    }

    override func layout() {
        super.layout()
        backdrop.frame = bounds

        let showsContents = !contents.isHidden
        let showsFiles = !files.isHidden
        let availableHeight = sections.bounds.height
        let gap = showsContents && showsFiles ? sectionSpacing : 0

        guard showsContents || showsFiles else {
            contents.frame = .zero
            files.frame = .zero
            return
        }

        let contentHeight = contents.preferredHeight
        let filesHeight = files.preferredHeight
        let desiredHeight = contentHeight + filesHeight + gap
        let scale = desiredHeight > availableHeight && desiredHeight > gap
            ? max(0, (availableHeight - gap) / (desiredHeight - gap))
            : 1
        let fittedContentsHeight = showsContents ? contentHeight * scale : 0
        let fittedFilesHeight = showsFiles ? filesHeight * scale : 0

        files.frame = NSRect(
            x: 0,
            y: 0,
            width: sections.bounds.width,
            height: fittedFilesHeight
        )
        contents.frame = NSRect(
            x: 0,
            y: fittedFilesHeight + gap,
            width: sections.bounds.width,
            height: fittedContentsHeight
        )
    }

    override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        layoutSubtreeIfNeeded()
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

enum NavigationPanelGeometry {
    static let width: CGFloat = 312
    static let edgeInset: CGFloat = 12
    static let minimumHeight: CGFloat = 210
    static let maximumHeight: CGFloat = 560

    static func frame(
        contentScreenFrame: NSRect,
        visibleScreenFrame: NSRect,
        preferredHeight: CGFloat? = nil
    ) -> NSRect {
        let availableWidth = max(0, visibleScreenFrame.width - edgeInset * 2)
        let panelWidth = min(width, availableWidth)
        let availableHeight = max(
            0,
            min(contentScreenFrame.height, visibleScreenFrame.height) - edgeInset * 2
        )
        let minimumHeight = min(Self.minimumHeight, availableHeight)
        let targetHeight = preferredHeight ?? contentScreenFrame.height * 0.7
        let panelHeight = min(
            maximumHeight,
            max(minimumHeight, min(targetHeight, availableHeight))
        )
        var frame = NSRect(
            x: contentScreenFrame.minX + edgeInset,
            y: contentScreenFrame.maxY - panelHeight - edgeInset,
            width: panelWidth,
            height: panelHeight
        )
        frame.origin.x = min(
            max(visibleScreenFrame.minX + edgeInset, frame.minX),
            visibleScreenFrame.maxX - frame.width - edgeInset
        )
        frame.origin.y = min(
            max(visibleScreenFrame.minY + edgeInset, frame.minY),
            visibleScreenFrame.maxY - frame.height - edgeInset
        )
        return frame
    }
}
