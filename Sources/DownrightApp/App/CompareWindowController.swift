import AppKit
import MarkdownCore
import MarkdownRender

/// Compare any two files, or two versions of one file, as a **rendered** diff
/// (§9.3) — not two columns of `+`/`-` source lines.  Changed blocks get a
/// margin bar and changed words are highlighted inside the prose on the side
/// they belong to, which is the same treatment §8.1 gives an external write.
@MainActor
final class CompareWindowController: NSWindowController {
    private let leftStorage = NSTextStorage()
    private let rightStorage = NSTextStorage()
    private var leftContainer: MarkdownContainerView!
    private var rightContainer: MarkdownContainerView!
    private var scrollLocked = true
    private var isSyncingScroll = false
    private var styleSheet = StyleSheet(theme: ThemeStore.shared.current, appearance: NSApp.effectiveAppearance)

    convenience init(left: URL, right: URL) {
        let leftText = (try? DocumentIO.read(contentsOf: left).text) ?? ""
        let rightText = (try? DocumentIO.read(contentsOf: right).text) ?? ""
        self.init(
            leftText: leftText, leftTitle: left.lastPathComponent,
            rightText: rightText, rightTitle: right.lastPathComponent,
            documentURL: left
        )
    }

    init(leftText: String, leftTitle: String, rightText: String, rightTitle: String, documentURL: URL?) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "\(leftTitle) ⟷ \(rightTitle)"
        super.init(window: window)
        build(leftText: leftText, leftTitle: leftTitle, rightText: rightText, rightTitle: rightTitle)
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build(leftText: String, leftTitle: String, rightText: String, rightTitle: String) {
        leftStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: leftText)
        rightStorage.replaceCharacters(in: NSRange(location: 0, length: 0), with: rightText)

        leftContainer = MarkdownContainerView(storage: leftStorage)
        rightContainer = MarkdownContainerView(storage: rightStorage)

        let leftDocument = MarkdownParser.parse(leftText)
        let rightDocument = MarkdownParser.parse(rightText)

        for (container, document) in [(leftContainer!, leftDocument), (rightContainer!, rightDocument)] {
            container.textView.styleSheet = styleSheet
            container.textView.mode = .read
            container.textView.update(document: document, dirty: .wholesale)
        }

        // Diff each direction so deletions mark up on the left and insertions
        // on the right, rather than both sides showing the same hunk list.
        let forward = TextDiff.hunks(old: leftText, new: rightText)
        rightContainer.textView.changeMarks = forward.map {
            MarkdownTextView.ChangeMark(
                kind: $0.kind,
                range: TextDiff.anchorRange(for: $0, inNewTextOfLength: (rightText as NSString).length),
                words: $0.wordRanges,
                deletedText: $0.kind == .deleted
                    ? (leftText as NSString).substring(with: $0.oldRange) : ""
            )
        }
        let backward = TextDiff.hunks(old: rightText, new: leftText)
        leftContainer.textView.changeMarks = backward.map {
            MarkdownTextView.ChangeMark(
                kind: $0.kind,
                range: TextDiff.anchorRange(for: $0, inNewTextOfLength: (leftText as NSString).length),
                words: $0.wordRanges,
                deletedText: $0.kind == .deleted
                    ? (rightText as NSString).substring(with: $0.oldRange) : ""
            )
        }

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(pane(titled: leftTitle, content: leftContainer))
        split.addArrangedSubview(pane(titled: rightTitle, content: rightContainer))

        let root = NSView()
        root.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])
        window?.contentView = root

        observeScroll(leftContainer, mirror: rightContainer)
        observeScroll(rightContainer, mirror: leftContainer)

        let toolbar = NSToolbar(identifier: "CompareToolbar")
        toolbar.delegate = self
        window?.toolbar = toolbar
    }

    private func pane(titled title: String, content: NSView) -> NSView {
        let header = NSTextField(labelWithString: title)
        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.textColor = .secondaryLabelColor
        header.translatesAutoresizingMaskIntoConstraints = false

        let pane = NSView()
        content.translatesAutoresizingMaskIntoConstraints = false
        pane.addSubview(header)
        pane.addSubview(content)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: pane.leadingAnchor, constant: 12),
            header.topAnchor.constraint(equalTo: pane.topAnchor, constant: 6),
            content.leadingAnchor.constraint(equalTo: pane.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: pane.trailingAnchor),
            content.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            content.bottomAnchor.constraint(equalTo: pane.bottomAnchor),
        ])
        return pane
    }

    /// Scroll-locked by default: comparing two documents means reading the same
    /// place in both.  Locking on *fraction* rather than on point offset keeps
    /// the panes together even when one side is substantially longer.
    private func observeScroll(_ source: MarkdownContainerView, mirror: MarkdownContainerView) {
        source.scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: source.scrollView.contentView, queue: .main
        ) { [weak self, weak source, weak mirror] _ in
            MainActor.assumeIsolated {
                guard let self, self.scrollLocked, !self.isSyncingScroll,
                      let source, let mirror else { return }
                self.isSyncingScroll = true
                defer { self.isSyncingScroll = false }

                let sourceHeight = max(1, (source.scrollView.documentView?.bounds.height ?? 1)
                    - source.scrollView.contentView.bounds.height)
                let fraction = min(1, max(0, source.scrollView.contentView.bounds.origin.y / sourceHeight))
                let mirrorHeight = max(1, (mirror.scrollView.documentView?.bounds.height ?? 1)
                    - mirror.scrollView.contentView.bounds.height)
                mirror.scrollView.contentView.scroll(to: NSPoint(x: 0, y: fraction * mirrorHeight))
                mirror.scrollView.reflectScrolledClipView(mirror.scrollView.contentView)
            }
        }
    }

    @objc private func toggleScrollLock(_ sender: NSButton) {
        scrollLocked = sender.state == .on
    }

    deinit { NotificationCenter.default.removeObserver(self) }
}

extension CompareWindowController: NSToolbarDelegate {
    private static let lockItem = NSToolbarItem.Identifier("scrollLock")

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.lockItem]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.flexibleSpace, Self.lockItem]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard identifier == Self.lockItem else { return nil }
        let button = NSButton(
            image: NSImage(systemSymbolName: "link", accessibilityDescription: "Scroll lock") ?? NSImage(),
            target: self, action: #selector(toggleScrollLock(_:))
        )
        button.setButtonType(.pushOnPushOff)
        button.state = .on
        button.bezelStyle = .texturedRounded
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.view = button
        item.label = "Scroll Lock"
        return item
    }
}
