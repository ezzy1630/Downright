import AppKit

@MainActor
final class StartWindowController: NSWindowController {
    var onOpen: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onNew: (() -> Void)?

    convenience init(recents: [RecentDocument]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "Downright"
        window.titleVisibility = .hidden
        window.center()
        self.init(window: window)
        window.contentView = StartView(recents: recents, owner: self)
    }

    @objc func openRecent(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue else { return }
        onOpen?(URL(fileURLWithPath: path))
    }

    @objc func openPanel(_ sender: Any?) { onOpenPanel?() }
    @objc func newDocument(_ sender: Any?) { onNew?() }
}

private final class StartView: NSView {
    private weak var owner: StartWindowController?

    init(recents: [RecentDocument], owner: StartWindowController) {
        self.owner = owner
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL])

        let title = NSTextField(labelWithString: "Downright")
        title.font = .systemFont(ofSize: 30, weight: .semibold)
        let subtitle = NSTextField(labelWithString: "Read and edit Markdown as a native document.")
        subtitle.font = .systemFont(ofSize: 14)
        subtitle.textColor = .secondaryLabelColor

        let open = NSButton(title: "Open…", target: owner, action: #selector(StartWindowController.openPanel(_:)))
        open.bezelStyle = .rounded
        open.keyEquivalent = "\r"
        let create = NSButton(title: "New", target: owner, action: #selector(StartWindowController.newDocument(_:)))
        create.bezelStyle = .rounded
        let actions = NSStackView(views: [open, create])
        actions.orientation = .horizontal
        actions.spacing = 8

        let heading = NSTextField(labelWithString: recents.isEmpty ? "Drop a Markdown file here" : "Recent Documents")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)

        let cards = NSStackView()
        cards.orientation = .vertical
        cards.alignment = .leading
        cards.spacing = 8
        for recent in recents.prefix(8) {
            let button = NSButton(title: "", target: owner, action: #selector(StartWindowController.openRecent(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(recent.path)
            button.bezelStyle = .regularSquare
            button.isBordered = true
            button.attributedTitle = Self.cardTitle(recent)
            button.alignment = .left
            button.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
            button.imagePosition = .imageLeading
            button.widthAnchor.constraint(equalToConstant: 620).isActive = true
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            cards.addArrangedSubview(button)
        }

        let stack = NSStackView(views: [title, subtitle, actions, heading, cards])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -48),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 52),
        ])
    }

    required init?(coder: NSCoder) { nil }

    private static func cardTitle(_ recent: RecentDocument) -> NSAttributedString {
        let title = NSMutableAttributedString(string: recent.displayName, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        let detail = recent.firstHeading.isEmpty ? "\n\(recent.wordCount) words" : "\n\(recent.firstHeading) · \(recent.wordCount) words"
        title.append(NSAttributedString(string: detail, attributes: [
            .font: NSFont.systemFont(ofSize: 11),
            .foregroundColor: NSColor.secondaryLabelColor,
        ]))
        return title
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let value = sender.draggingPasteboard.string(forType: .fileURL),
              let url = URL(string: value) else { return false }
        owner?.onOpen?(url)
        return true
    }
}
