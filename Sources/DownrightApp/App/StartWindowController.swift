import AppKit
import QuickLookThumbnailing

@MainActor
final class StartWindowController: NSWindowController {
    var onOpen: ((URL) -> Void)?
    var onOpenPanel: (() -> Void)?
    var onNew: (() -> Void)?

    convenience init(recents: [RecentDocument]) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        window.title = "Downright"
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 360, height: 360)
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
        open.focusRingType = .default
        open.setAccessibilityLabel("Open a Markdown document")
        let create = NSButton(title: "New", target: owner, action: #selector(StartWindowController.newDocument(_:)))
        create.bezelStyle = .rounded
        create.keyEquivalent = "n"
        create.keyEquivalentModifierMask = [.command]
        create.focusRingType = .default
        create.setAccessibilityLabel("Create a new Markdown document")
        let actions = NSStackView(views: [open, create])
        actions.orientation = .horizontal
        actions.spacing = 8

        let heading = NSTextField(labelWithString: recents.isEmpty ? "No recent documents" : "Recent Documents")
        heading.font = .systemFont(ofSize: 13, weight: .semibold)
        heading.setAccessibilityRole(.staticText)

        let dropHint = NSTextField(wrappingLabelWithString: recents.isEmpty
            ? "Open a file above, or drop one or more Markdown files anywhere in this window."
            : "Drop one or more Markdown files here to open them.")
        dropHint.font = .systemFont(ofSize: 12)
        dropHint.textColor = .secondaryLabelColor
        dropHint.maximumNumberOfLines = 0
        dropHint.setAccessibilityLabel(dropHint.stringValue)

        let cards = NSStackView()
        cards.orientation = .vertical
        cards.alignment = .width
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
            button.imageScaling = .scaleProportionallyDown
            button.heightAnchor.constraint(equalToConstant: 48).isActive = true
            button.focusRingType = .default
            button.setAccessibilityRole(.button)
            button.setAccessibilityLabel("Open \(recent.displayName)")
            button.setAccessibilityValue("Preview loading")
            cards.addArrangedSubview(button)
            Self.loadThumbnail(for: URL(fileURLWithPath: recent.path), into: button)
        }

        let stack = NSStackView(views: [title, subtitle, actions, heading, dropHint, cards])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.setAccessibilityLabel("Start window content")
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor, constant: 48),
            stack.trailingAnchor.constraint(equalTo: scroll.contentView.trailingAnchor, constant: -48),
            stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor, constant: 52),
            stack.bottomAnchor.constraint(equalTo: scroll.contentView.bottomAnchor, constant: -52),
            stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor, constant: -96),
        ])

        setAccessibilityRole(.group)
        setAccessibilityLabel("Downright start window")
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

    private static func loadThumbnail(for url: URL, into button: NSButton) {
        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: NSSize(width: 40, height: 40),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail
        )
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak button] thumbnail, error in
            DispatchQueue.main.async {
                guard let button, button.identifier?.rawValue == url.path else { return }
                if let image = thumbnail?.nsImage {
                    button.image = image
                    button.image?.accessibilityDescription = "Preview of \(url.lastPathComponent)"
                    button.setAccessibilityValue("Preview ready")
                } else {
                    button.setAccessibilityValue(error == nil ? "Preview unavailable" : "Preview unavailable: \(error!.localizedDescription)")
                }
            }
        }
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        droppedURLs(from: sender.draggingPasteboard).isEmpty ? [] : .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingEntered(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = droppedURLs(from: sender.draggingPasteboard)
        guard !urls.isEmpty else { return false }
        urls.forEach { owner?.onOpen?($0) }
        return true
    }

    private func droppedURLs(from pasteboard: NSPasteboard) -> [URL] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true,
        ]) as? [URL] ?? []
        return urls.filter {
            DocumentTypes.isMarkdown($0.pathExtension) &&
            FileManager.default.fileExists(atPath: $0.path)
        }
    }
}
