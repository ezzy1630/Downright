import AppKit
import MarkdownCore
import MarkdownRender

/// The version timeline (§8.3, `⌘⇧V`).
///
/// A separate window rather than an in-window overlay (§15 Q6): scrubbing
/// through a month of an agent's rewrites is a *comparison* activity, and the
/// document you are comparing against needs to stay visible next to it.
@MainActor
final class VersionTimelineWindowController: NSWindowController {
    private let markdownDocument: MarkdownDocument
    private let previewStorage = NSTextStorage()
    private var preview: MarkdownContainerView!
    private let timeline = VersionTimelineView()
    private var versions: [SnapshotStore.VersionRecord] = []
    private var styleSheet: StyleSheet

    init(document: MarkdownDocument, styleSheet: StyleSheet) {
        self.markdownDocument = document
        self.styleSheet = styleSheet
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered, defer: false
        )
        window.title = "History — \(markdownDocument.displayName)"
        super.init(window: window)
        build()
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func build() {
        versions = markdownDocument.versions()
        preview = MarkdownContainerView(storage: previewStorage)
        preview.textView.styleSheet = styleSheet
        preview.textView.mode = .read
        preview.translatesAutoresizingMaskIntoConstraints = false

        timeline.styleSheet = styleSheet
        timeline.versions = versions
        timeline.selectedIndex = max(0, versions.count - 1)
        timeline.delegate = self
        timeline.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(preview)
        root.addSubview(timeline)
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            preview.topAnchor.constraint(equalTo: root.topAnchor),

            timeline.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            timeline.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            timeline.topAnchor.constraint(equalTo: preview.bottomAnchor),
            timeline.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            timeline.heightAnchor.constraint(equalToConstant: 96),
        ])
        window?.contentView = root

        if versions.isEmpty {
            showEmptyState(in: root)
        } else if let newest = versions.last {
            show(newest)
        }
    }

    private func showEmptyState(in root: NSView) {
        let label = NSTextField(labelWithString: """
        No history yet.

        Downright snapshots this file every time something outside the app \
        rewrites it. Come back after an agent has touched it.
        """)
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        label.maximumNumberOfLines = 0
        root.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: root.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    /// Renders one version, highlighting what changed relative to the version
    /// immediately before it — so scrubbing shows changes *between steps*
    /// rather than against the current buffer.
    private func show(_ record: SnapshotStore.VersionRecord) {
        guard let text = SnapshotStore.shared.text(for: record) else { return }
        previewStorage.replaceCharacters(
            in: NSRange(location: 0, length: previewStorage.length), with: text
        )
        let parsed = MarkdownParser.parse(text)
        preview.textView.update(document: parsed, dirty: .wholesale)

        guard let index = versions.firstIndex(of: record), index > 0,
              let previous = SnapshotStore.shared.text(for: versions[index - 1])
        else {
            preview.textView.changeMarks = []
            return
        }
        preview.textView.changeMarks = TextDiff.hunks(old: previous, new: text).map {
            (kind: $0.kind, range: $0.newRange, words: $0.wordRanges)
        }
    }
}

extension VersionTimelineWindowController: VersionTimelineDelegate {
    func versionTimeline(_ view: VersionTimelineView, didScrubTo record: SnapshotStore.VersionRecord) {
        show(record)
    }

    func versionTimeline(_ view: VersionTimelineView, didRequestRestore record: SnapshotStore.VersionRecord) {
        let alert = NSAlert()
        alert.messageText = "Restore this version?"
        alert.informativeText = """
        The current text is replaced with the version from \
        \(record.date.formatted(date: .abbreviated, time: .shortened)). \
        This is an ordinary edit — ⌘Z undoes it.
        """
        alert.addButton(withTitle: "Restore")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        markdownDocument.restore(version: record)
        close()
    }
}
