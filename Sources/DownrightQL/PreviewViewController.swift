import AppKit
import MarkdownCore
import MarkdownRender
import QuickLookUI

/// The Quick Look preview extension (§10).
///
/// Not a reduced-fidelity fallback: it imports the same `MarkdownRender`
/// package the app draws with, so it *cannot* drift from the app's rendering.
/// That is the entire reason §3.3 forbids a WebView — a `WKWebView` carrying
/// KaTeX and Mermaid.js would not reliably fit under the extension's hard
/// ~120MB ceiling, and an extension that exceeds it is killed outright.
@available(macOS 14.0, *)
final class PreviewViewController: NSViewController, QLPreviewingController {
    private let storage = NSTextStorage()
    private var container: MarkdownContainerView?
    private var parsedDocument: ParsedDocument?
    private var fallbackTextView: NSTextView?

    /// Well under the ~120MB kill threshold, per §10's non-negotiable budget.
    private let memoryCeiling = QuickLookPolicy.memoryCeilingBytes
    /// Number of top-level blocks rendered for an oversized file.
    private let prefixBlockCount = QuickLookPolicy.prefixBlockCount

    private var memoryTimer: Timer?

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 800))
    }

    deinit { memoryTimer?.invalidate() }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(at url: URL) async throws {
        let (text, _) = try DocumentIO.read(contentsOf: url)
        let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? text.utf8.count

        await MainActor.run {
            resetPreview()
            if case .prefix = QuickLookPolicy.presentation(forByteCount: byteCount) {
                presentTruncated(text, url: url)
            } else {
                present(text, url: url)
            }
            startMemoryWatch()
            if PreviewViewController.residentBytes() > memoryCeiling {
                fallBackToPlainText()
            }
        }
    }

    // MARK: - Rendering

    @MainActor
    private func present(_ text: String, url: URL) {
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        let document = MarkdownParser.parse(text)

        let container = MarkdownContainerView(storage: storage)
        container.textView.styleSheet = StyleSheet(
            theme: ThemeStore.shared.current, appearance: view.effectiveAppearance
        )
        container.textView.mode = .read
        container.textView.update(document: document, dirty: .wholesale)
        // Selectable and copyable — most Quick Look previews are dead surfaces,
        // and this one isn't (§10).
        container.textView.isSelectable = true

        // The density gutter only earns its space on a wide enough panel (§10).
        if view.bounds.width >= DensityGutterView.minimumHostWidth {
            let gutter = DensityGutterView(styleSheet: container.textView.styleSheet)
            gutter.bands = DensityGutterView.bands(for: document, changes: [], searchHits: [])
            gutter.delegate = self
            container.leadingAccessory = gutter
        }

        install(container)
        self.container = container
        parsedDocument = document
    }

    @MainActor
    private func presentTruncated(_ text: String, url: URL) {
        let document = MarkdownParser.parse(text, options: .structureOnly)
        let cutoff = document.root.children.prefix(prefixBlockCount).last?.range.upperBound ?? text.utf16.count
        let prefix = (text as NSString).substring(to: min(cutoff, (text as NSString).length))

        present(prefix, url: url)
        installOpenInAppBar(for: url, note: "Showing the first \(prefixBlockCount) blocks")
    }

    /// Plain text is the floor, not a failure: a preview that renders nothing
    /// is worse than a preview that renders the source (§10).
    @MainActor
    private func fallBackToPlainText() {
        guard fallbackTextView == nil else { return }
        memoryTimer?.invalidate()
        memoryTimer = nil
        container?.removeFromSuperview()
        container = nil
        view.subviews.filter { $0 !== fallbackTextView }.forEach { $0.removeFromSuperview() }

        let textView = NSTextView()
        textView.string = storage.string
        textView.isEditable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 16)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        install(scroll)
        fallbackTextView = textView
    }

    /// Quick Look reuses one controller for multiple files.  Release every
    /// prior surface and its backing render graph before installing the next
    /// document; replacing the text storage alone leaves old views, timers,
    /// constraints, and layout fragments reachable.
    @MainActor
    private func resetPreview() {
        memoryTimer?.invalidate()
        memoryTimer = nil
        view.subviews.forEach { $0.removeFromSuperview() }
        container = nil
        parsedDocument = nil
        fallbackTextView = nil
        if storage.length > 0 {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        }
    }

    @MainActor
    private func install(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.topAnchor.constraint(equalTo: view.topAnchor),
            subview.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @MainActor
    private func installOpenInAppBar(for url: URL, note: String) {
        let label = NSTextField(labelWithString: note)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor

        let button = NSButton(title: "Open in Downright", target: self, action: #selector(openInApp(_:)))
        button.bezelStyle = .rounded
        objc_setAssociatedObject(button, &PreviewViewController.urlKey, url as NSURL, .OBJC_ASSOCIATION_RETAIN)

        let bar = NSStackView(views: [label, NSView(), button])
        bar.orientation = .horizontal
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(bar)

        view.addSubview(background)
        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            background.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            bar.topAnchor.constraint(equalTo: background.topAnchor),
            bar.bottomAnchor.constraint(equalTo: background.bottomAnchor),
        ])
    }

    @objc private func openInApp(_ sender: NSButton) {
        guard let url = objc_getAssociatedObject(sender, &PreviewViewController.urlKey) as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private static var urlKey: UInt8 = 0

    // MARK: - Memory discipline (§10, non-negotiable)

    private func startMemoryWatch() {
        memoryTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard PreviewViewController.residentBytes() > self.memoryCeiling else { return }
            MainActor.assumeIsolated { self.fallBackToPlainText() }
        }
        RunLoop.main.add(timer, forMode: .common)
        memoryTimer = timer
    }

    /// Bytes in use across malloc zones.  `malloc_zone_statistics` is what §10
    /// specifies; it is cheap enough to poll and, unlike `task_info`, reports
    /// what this process actually allocated rather than what the kernel has
    /// mapped for it.
    static func residentBytes() -> Int {
        var zoneCount: UInt32 = 0
        var zones: UnsafeMutablePointer<vm_address_t>?
        guard malloc_get_all_zones(mach_task_self_, nil, &zones, &zoneCount) == KERN_SUCCESS,
              let zones else { return 0 }

        var total = 0
        for index in 0..<Int(zoneCount) {
            let zone = UnsafeMutablePointer<malloc_zone_t>(bitPattern: UInt(zones[index]))
            guard let zone else { continue }
            var statistics = malloc_statistics_t()
            malloc_zone_statistics(zone, &statistics)
            total += Int(statistics.size_in_use)
        }
        return total
    }
}

@available(macOS 14.0, *)
extension PreviewViewController: DensityGutterDelegate {
    func densityGutter(_ gutter: DensityGutterView, didRequestScrollToFraction fraction: CGFloat) {
        guard let document = parsedDocument else { return }
        let offset = Int(fraction * CGFloat(document.length))
        container?.textView.scroll(toOffset: offset, position: .top, animated: !gutter.isScrubbing)
    }

    func densityGutter(
        _ gutter: DensityGutterView, previewAtFraction fraction: CGFloat
    ) -> (title: String, snippet: String)? {
        guard let document = parsedDocument else { return nil }
        let offset = min(document.length, Int(fraction * CGFloat(document.length)))
        guard let heading = document.headings.last(where: { $0.range.location <= offset }) else {
            let length = min(120, document.length)
            return ("Top", document.substring(NSRange(location: 0, length: length)))
        }
        let snippetLength = min(160, max(0, document.length - offset))
        return (
            heading.title,
            document.substring(NSRange(location: offset, length: snippetLength))
        )
    }
}
