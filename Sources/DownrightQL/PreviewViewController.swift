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
    private enum LoadResult: Sendable {
        case full(String)
        case prefix(String)
        case failure
    }
    private let storage = NSTextStorage()
    private var container: MarkdownContainerView?
    private var densityGutter: DensityGutterView?
    private var parsedDocument: ParsedDocument?
    private var fallbackTextView: NSTextView?
    private var sourceURL: URL?

    private var contentBottomConstraint: NSLayoutConstraint?
    private var noticeBar: NSView?
    private var scrollObserver: NSObjectProtocol?
    private var keyMonitor: Any?
    private var currentHeadingIndex: Int?
    private var previewAppearance: PreviewAppearance { PreviewAppearanceStore.appearance }

    /// Well under the ~120MB kill threshold, per §10's non-negotiable budget.
    private let memoryCeiling = QuickLookPolicy.memoryCeilingBytes
    /// Quick Look's host process already owns AppKit, TextKit, and extension
    /// infrastructure before our document is presented. Budget the preview's
    /// incremental footprint, not the host's unrelated baseline, or every
    /// normal preview falls back to raw source a moment after rendering.
    private var memoryBaselineBytes = 0
    /// Number of top-level blocks rendered for an oversized file.
    private let prefixBlockCount = QuickLookPolicy.prefixBlockCount

    private var memoryTimer: Timer?
    private var previewTask: Task<Void, Never>?
    private var previewGeneration: UInt = 0

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 720, height: 800))
        // nil preserves the host's native macOS appearance. An explicit user
        // choice is applied only to this preview surface, never globally.
        view.appearance = previewAppearance.nsAppearance
    }

    deinit {
        previewTask?.cancel()
        memoryTimer?.invalidate()
        if let scrollObserver { NotificationCenter.default.removeObserver(scrollObserver) }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        updateDensityGutterVisibility()
        updateDensityGutterState()
    }

    // MARK: - QLPreviewingController

    func preparePreviewOfFile(
        at url: URL,
        completionHandler handler: @escaping (Error?) -> Void
    ) {
        previewTask?.cancel()
        previewGeneration &+= 1
        let generation = previewGeneration

        let task = Task { [weak self] in
            guard let self else {
                handler(CocoaError(.coderInvalidValue))
                return
            }

            // Finder owns the main thread that presents this controller. File
            // coordination and decoding must not occupy it, especially for the
            // multi-megabyte prefix path. The load runs detached (off the main
            // actor), and cancellation is forwarded to it: a superseded or
            // dismissed preview stops paying for bytes nobody will present.
            let load = Task.detached(priority: .userInitiated) { () -> LoadResult in
                if Task.isCancelled { return LoadResult.failure }
                let byteCount =
                    (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                switch QuickLookPolicy.presentation(forByteCount: byteCount) {
                case .prefix:
                    guard let head = DocumentIO.readHead(
                        contentsOf: url,
                        limit: QuickLookPolicy.prefixReadLimitBytes
                    ) else { return LoadResult.failure }
                    if Task.isCancelled { return LoadResult.failure }
                    return LoadResult.prefix(head)
                case .full:
                    guard let (text, _) = try? DocumentIO.read(contentsOf: url) else {
                        return LoadResult.failure
                    }
                    if Task.isCancelled { return LoadResult.failure }
                    return LoadResult.full(text)
                }
            }
            let loadResult = await withTaskCancellationHandler {
                await load.value
            } onCancel: {
                load.cancel()
            }

            guard !Task.isCancelled else {
                handler(CocoaError(.userCancelled))
                return
            }

            await MainActor.run {
                guard !Task.isCancelled, self.previewGeneration == generation else {
                    handler(CocoaError(.userCancelled))
                    return
                }

                // Quick Look may reuse this controller for another file after
                // the user changes the setting in Downright. Re-resolve the
                // explicit override for every preview instead of pinning the
                // appearance from the first file shown in this process.
                self.view.appearance = self.previewAppearance.nsAppearance
                self.resetPreview()
                switch loadResult {
                case .prefix(let head): self.presentTruncated(head, url: url)
                case .full(let text): self.present(text, url: url)
                case .failure:
                    handler(CocoaError(.fileReadCorruptFile))
                    return
                }
                self.startMemoryWatch()
                if self.previewGeneration == generation {
                    self.previewTask = nil
                }
                handler(nil)
            }
        }
        previewTask = task
    }

    // MARK: - Rendering

    @MainActor
    private func present(_ text: String, url: URL) {
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        let document = MarkdownParser.parse(text)
        parsedDocument = document
        sourceURL = url

        let container = MarkdownContainerView(storage: storage)
        container.textView.styleSheet = makeStyleSheet()
        container.textView.mode = .read
        container.textView.update(document: document, dirty: .wholesale)
        // Selectable and copyable — most Quick Look previews are dead surfaces,
        // and this one isn't (§10).
        container.textView.isSelectable = true

        let gutter = makeDensityGutter(for: document, styleSheet: container.textView.styleSheet)

        install(container)
        self.container = container
        densityGutter = gutter
        updateDensityGutterVisibility()
        startInteractionObservation()
        DispatchQueue.main.async { [weak self] in self?.updateDensityGutterState() }
    }

    @MainActor
    private func presentTruncated(_ text: String, url: URL) {
        let document = MarkdownParser.parse(text, options: .structureOnly)
        let cutoff = document.root.children.prefix(prefixBlockCount).last?.range.upperBound
            ?? text.utf16.count
        let prefix = Self.boundedPrefix(
            text,
            utf16Limit: min(cutoff, QuickLookPolicy.prefixRenderLimitUTF16),
            byteLimit: QuickLookPolicy.prefixRenderLimitBytes
        )

        present(prefix, url: url)
        installOpenInAppBar(for: url, note: "Showing the first \(prefixBlockCount) blocks")
    }

    /// Keep the rendered prefix bounded in both Foundation's UTF-16 coordinate
    /// space and its UTF-8 storage size.  Walking character boundaries avoids
    /// returning a string with a split surrogate when a limit lands mid-scalar.
    static func boundedPrefix(_ text: String, utf16Limit: Int, byteLimit: Int) -> String {
        guard utf16Limit > 0, byteLimit > 0 else { return "" }
        var utf16Count = 0
        var byteCount = 0
        var end = text.startIndex
        while end < text.endIndex {
            let next = text.index(after: end)
            let scalar = text[end..<next]
            let scalarUTF16Count = scalar.utf16.count
            let scalarByteCount = scalar.utf8.count
            guard utf16Count + scalarUTF16Count <= utf16Limit,
                  byteCount + scalarByteCount <= byteLimit else { break }
            utf16Count += scalarUTF16Count
            byteCount += scalarByteCount
            end = next
        }
        return String(text[..<end])
    }

    /// Plain text is the floor, not a failure: a preview that renders nothing
    /// is worse than a preview that renders the source (§10).
    @MainActor
    private func fallBackToPlainText() {
        guard fallbackTextView == nil else { return }
        memoryTimer?.invalidate()
        memoryTimer = nil
        stopInteractionObservation()
        let styleSheet = container?.textView.styleSheet ?? makeStyleSheet()
        view.subviews.forEach { $0.removeFromSuperview() }
        container = nil
        densityGutter = nil
        parsedDocument = nil
        noticeBar = nil
        contentBottomConstraint = nil
        currentHeadingIndex = nil

        let textView = NSTextView()
        textView.string = storage.string
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textColor = styleSheet.text
        textView.backgroundColor = styleSheet.background
        textView.textContainerInset = NSSize(width: 24, height: 20)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        scroll.drawsBackground = true
        scroll.backgroundColor = styleSheet.background
        install(scroll)
        fallbackTextView = textView
        if let sourceURL {
            installOpenInAppBar(for: sourceURL, note: "Plain text preview — open in Downright for full rendering")
        }
    }

    /// Quick Look has its own bundle and defaults domain. Resolve the palette
    /// from the shared setting, falling back to the bundled System theme so a
    /// dark macOS desktop can never inherit the app's old Paper Light default.
    @MainActor
    private func makeStyleSheet() -> StyleSheet {
        let mode = previewAppearance
        let appearance = mode.nsAppearance ?? view.effectiveAppearance
        let preferredName = PreviewAppearanceStore.themeName(for: appearance)
        let theme = preferredName.flatMap { name in
            ThemeStore.shared.themes.first { $0.name == name }
        } ?? ThemeStore.shared.themes.first {
            switch mode {
            case .dark: return $0.appearance == .dark
            case .light: return $0.appearance != .dark
            case .system:
                let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                return isDark ? $0.appearance == .dark : $0.appearance != .dark
            }
        } ?? .fallback
        return StyleSheet(theme: theme, appearance: appearance)
    }

    /// Quick Look reuses one controller for multiple files.  Release every
    /// prior surface and its backing render graph before installing the next
    /// document; replacing the text storage alone leaves old views, timers,
    /// constraints, and layout fragments reachable.
    @MainActor
    private func resetPreview() {
        memoryTimer?.invalidate()
        memoryTimer = nil
        stopInteractionObservation()
        view.subviews.forEach { $0.removeFromSuperview() }
        container = nil
        densityGutter = nil
        parsedDocument = nil
        fallbackTextView = nil
        sourceURL = nil
        noticeBar = nil
        contentBottomConstraint = nil
        currentHeadingIndex = nil
        if storage.length > 0 {
            storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "")
        }
    }

    @MainActor
    private func install(_ subview: NSView) {
        subview.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(subview)
        let bottom = subview.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        contentBottomConstraint = bottom
        NSLayoutConstraint.activate([
            subview.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            subview.topAnchor.constraint(equalTo: view.topAnchor),
            bottom,
        ])
    }

    @MainActor
    private func installOpenInAppBar(for url: URL, note: String) {
        noticeBar?.removeFromSuperview()

        let icon = NSImageView(image: NSImage(systemSymbolName: "doc.text.magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        icon.contentTintColor = .secondaryLabelColor
        icon.setAccessibilityHidden(true)

        let label = NSTextField(labelWithString: note)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let button = NSButton(title: "Open in Downright", target: self, action: #selector(openInApp(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.image = NSImage(systemSymbolName: "arrow.up.forward.app", accessibilityDescription: nil)
        button.imagePosition = .imageLeading
        objc_setAssociatedObject(button, &PreviewViewController.urlKey, url as NSURL, .OBJC_ASSOCIATION_RETAIN)

        let bar = NSStackView(views: [icon, label, NSView(), button])
        bar.orientation = .horizontal
        bar.alignment = .centerY
        bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 14, bottom: 8, right: 14)
        bar.translatesAutoresizingMaskIntoConstraints = false

        let background = NSVisualEffectView()
        background.material = .headerView
        background.blendingMode = .withinWindow
        background.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(bar)
        noticeBar = background

        view.addSubview(background)
        contentBottomConstraint?.isActive = false
        if let contentView = container ?? fallbackTextView?.enclosingScrollView {
            let reservedBottom = contentView.bottomAnchor.constraint(equalTo: background.topAnchor)
            reservedBottom.isActive = true
            contentBottomConstraint = reservedBottom
        }
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

    private func makeDensityGutter(
        for document: ParsedDocument, styleSheet: StyleSheet
    ) -> DensityGutterView {
        let gutter = DensityGutterView(styleSheet: styleSheet)
        gutter.delegate = self
        // Finder's compact Quick Look panel leaves no usable side margin for a
        // 320pt card. Opt into the rail's compact, translucent overlay fallback
        // so hover still communicates the target section instead of vanishing.
        gutter.allowsPreviewContentOverlap = true
        gutter.bands = DensityGutterView.bands(for: document, changes: [], searchHits: [])

        let wordCount = Metrics.documentWordCount(document)
        let readMinutes = max(1, Int(ceil(Double(wordCount) / Metrics.wordsPerMinute)))
        gutter.metricsSummary = "\(wordCount.formatted()) words · \(document.length.formatted()) characters · \(readMinutes) min read"

        let length = CGFloat(max(1, document.length))
        gutter.outlineEntries = document.headings.map { heading in
            DensityOutlineEntry(
                title: heading.title,
                level: heading.level,
                fraction: CGFloat(heading.range.location) / length
            )
        }
        return gutter
    }

    private func updateDensityGutterVisibility() {
        guard let container, let densityGutter else { return }
        let shouldShow = view.bounds.width >= QuickLookPolicy.minimumDensityGutterWidth
        if shouldShow, container.leadingAccessory !== densityGutter {
            container.leadingAccessory = densityGutter
        } else if !shouldShow, container.leadingAccessory === densityGutter {
            container.leadingAccessory = nil
        }
    }

    private func startInteractionObservation() {
        stopInteractionObservation()
        guard let container else { return }
        let clipView = container.scrollView.contentView
        clipView.postsBoundsChangedNotifications = true
        scrollObserver = NotificationCenter.default.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: clipView,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateDensityGutterState() }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.view.window else { return event }
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard modifiers.isDisjoint(with: [.command, .control, .option]) else { return event }
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "n": self.jumpToHeading(forward: true); return nil
            case "p": self.jumpToHeading(forward: false); return nil
            default: return event
            }
        }
    }

    private func stopInteractionObservation() {
        if let scrollObserver {
            NotificationCenter.default.removeObserver(scrollObserver)
            self.scrollObserver = nil
        }
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    private func updateDensityGutterState() {
        guard let container, let document = parsedDocument, let densityGutter else { return }
        let length = CGFloat(max(1, document.length))
        let top = min(1, CGFloat(container.textView.topVisibleOffset) / length)
        let visibleHeight = container.scrollView.contentView.bounds.height
        let documentHeight = max(1, container.scrollView.documentView?.bounds.height ?? 1)
        let span = min(1, visibleHeight / documentHeight)
        densityGutter.visibleRange = top...min(1, top + span)
        densityGutter.readProgress = max(densityGutter.readProgress, min(1, top + span))

        let current = document.headings.lastIndex { $0.range.location <= container.textView.topVisibleOffset }
        guard current != currentHeadingIndex else { return }
        currentHeadingIndex = current
        densityGutter.outlineEntries = densityGutter.outlineEntries.enumerated().map { index, entry in
            var updated = entry
            updated.isCurrent = index == current
            return updated
        }
    }

    private func jumpToHeading(forward: Bool) {
        guard let container, let document = parsedDocument, !document.headings.isEmpty else {
            NSSound.beep()
            return
        }
        let top = container.textView.topVisibleOffset
        let heading = forward
            ? document.headings.first(where: { $0.range.location > top + 1 })
            : document.headings.last(where: { $0.range.location < top - 1 })
        guard let heading else { NSSound.beep(); return }
        container.textView.scroll(toOffset: heading.range.location, position: .top, animated: true)
    }

    @objc private func openInApp(_ sender: NSButton) {
        guard let url = objc_getAssociatedObject(sender, &PreviewViewController.urlKey) as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private static var urlKey: UInt8 = 0

    // MARK: - Memory discipline (§10, non-negotiable)

    private func startMemoryWatch() {
        memoryTimer?.invalidate()
        memoryTimer = nil
        let generation = previewGeneration
        // TextKit lays out lazily after `present` returns. Sampling immediately
        // treats that normal first viewport as a leak and replaces a tiny file
        // with raw source. Establish the steady-state baseline after its first
        // layout turn, then watch only subsequent growth.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self, self.previewGeneration == generation,
                  self.fallbackTextView == nil else { return }
            self.memoryBaselineBytes = Self.residentBytes()
            let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
                guard let self else { return }
                guard self.previewMemoryBytes > self.memoryCeiling else { return }
                MainActor.assumeIsolated { self.fallBackToPlainText() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.memoryTimer = timer
        }
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

    private var previewMemoryBytes: Int {
        Self.previewMemoryBytes(current: Self.residentBytes(), baseline: memoryBaselineBytes)
    }

    static func previewMemoryBytes(current: Int, baseline: Int) -> Int {
        max(0, current - baseline)
    }
}

@available(macOS 14.0, *)
extension PreviewViewController: DensityGutterDelegate {
    func densityGutter(_ gutter: DensityGutterView, didRequestScrollToFraction fraction: CGFloat) {
        guard let document = parsedDocument else { return }
        let offset = min(document.length, max(0, Int(fraction * CGFloat(document.length))))
        guard let textView = container?.textView else { return }
        // QL can deliver the first click before TextKit has completed its lazy
        // layout. Force the target fragment, then use the same spring as the
        // app for normal clicks. If an interpolated rail fraction lands in a
        // collapsed/empty fragment, settle on the nearest heading instead of
        // silently leaving the page where it was.
        textView.layoutSubtreeIfNeeded()
        if textView.rect(forOffset: offset) != nil {
            textView.scroll(toOffset: offset, position: .top, animated: !gutter.isScrubbing)
            return
        }
        let fallback = document.headings.min {
            abs($0.range.location - offset) < abs($1.range.location - offset)
        }
        guard let fallback else { return }
        textView.scroll(toOffset: fallback.range.location, position: .top, animated: !gutter.isScrubbing)
    }

    func densityGutter(
        _ gutter: DensityGutterView, previewAtFraction fraction: CGFloat
    ) -> (title: String, snippet: String, context: String)? {
        guard let document = parsedDocument else { return nil }
        let offset = min(document.length, Int(fraction * CGFloat(document.length)))
        guard let index = document.headings.lastIndex(where: { $0.range.location <= offset }) else {
            return ("Document start", "", gutter.metricsSummary)
        }
        let heading = document.headings[index]
        let sectionPosition = "Section \(index + 1) of \(document.headings.count)"
        let context = heading.wordCount > 0
            ? "\(sectionPosition) · \(heading.wordCount) words"
            : sectionPosition
        return (
            heading.title,
            StructuralZoom.sectionPreview(document, headingIndex: index) ?? "Section overview",
            context
        )
    }
}
