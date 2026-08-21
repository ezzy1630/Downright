import AppKit
import MarkdownCore
import MarkdownRender
import ObjectiveC
import Quartz

private var quickLookSessionKey: UInt8 = 0

/// What a Quick Look gesture on the document surface should actually open.
///
/// A pure decision, separate from the panel, because the interesting part is
/// the routing and the routing has three different answers that all look alike
/// from the outside.  The panel itself is untestable in a headless suite; this
/// is not.
enum QuickLookRequest: Equatable {
    /// An embedded image opens in Downright's own lightbox, not in the system
    /// panel.  The lightbox is already what a *click* on that image does
    /// (§7.1), it zooms and pans and shows the alt text as a caption, and
    /// having force click open a second, different image viewer for the same
    /// picture would be two answers to one question.
    case lightbox(source: String)
    /// Everything else — a path token, a link to a local file — is a question
    /// about a *file*, which is exactly what `QLPreviewPanel` answers, for
    /// every type the system has a generator for.  Including Markdown: this
    /// app ships the Quick Look extension that renders it.
    case panel(URL)

    /// Resolves a target, or reports that it is not previewable.
    ///
    /// Returning nil matters as much as returning a request: a force click that
    /// resolves to nothing falls back to `NSTextView`'s Look Up popover, which
    /// is what must still happen on an ordinary word.
    static func resolve(
        _ target: ContextTarget,
        documentURL: URL?,
        pathResolution: (PathToken) -> PathResolver.Resolution?,
        fileExists: (URL) -> Bool
    ) -> QuickLookRequest? {
        switch target.kind {
        case .image(let source):
            return .lightbox(source: source)

        case .pathToken(let token):
            guard let resolution = pathResolution(token), resolution.exists,
                  let url = resolution.url else { return nil }
            return .panel(url.standardizedFileURL)

        case .link(let destination):
            switch MarkdownLinkDestination.classify(destination) {
            case .localFile(let url):
                let target = url.standardizedFileURL
                return fileExists(target) ? .panel(target) : nil
            case .relative(let relative):
                guard let base = documentURL?.deletingLastPathComponent() else { return nil }
                let target = base.appendingPathComponent(relative).standardizedFileURL
                return fileExists(target) ? .panel(target) : nil
            // A web link, an in-document anchor, and an automation URL are all
            // things Quick Look cannot preview.  Refused rather than opened:
            // turning a preview gesture into "launch this URL" would route
            // around the trust prompt that a real click goes through.
            case .web, .anchor, .automation, .invalid:
                return nil
            }

        case .heading, .codeBlock, .table, .selection, .plain:
            return nil
        }
    }
}

/// The one file the panel is currently showing, plus where it came from.
///
/// Held on the controller through an associated object because
/// `DocumentWindowController`'s stored properties live in a file this feature
/// does not own; the sharing picker next door keeps its state the same way.
private final class QuickLookSession {
    var url: URL?
    /// Source range of the thing being previewed, so the panel can zoom out of
    /// the text it came from instead of appearing from the middle of nowhere.
    var sourceRange: NSRange?
}

@MainActor
extension DocumentWindowController: @preconcurrency QLPreviewPanelDataSource,
    @preconcurrency QLPreviewPanelDelegate {

    private var quickLookSession: QuickLookSession {
        if let existing = objc_getAssociatedObject(self, &quickLookSessionKey) as? QuickLookSession {
            return existing
        }
        let session = QuickLookSession()
        objc_setAssociatedObject(self, &quickLookSessionKey, session, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return session
    }

    // MARK: - Entry points

    /// A force click landed on something (§7.1).  Reported by the text view in
    /// source coordinates; the decision about what that means is here.
    func markdownTextView(_ view: MarkdownTextView, wantsQuickLookFor target: ContextTarget) -> Bool {
        presentQuickLook(target)
    }

    /// The Quick Look command, aimed at whatever the selection is on.
    @discardableResult
    func quickLookAtSelection() -> Bool {
        guard let target = containerTextView.quickLookTargetAtSelection() else { return false }
        return presentQuickLook(target)
    }

    /// Whether the command should be offered at all.  Reading the attribute
    /// runs at the caret is cheap; resolving the file is not, so the menu asks
    /// only the first question and the command asks the second.
    var hasQuickLookTarget: Bool {
        containerTextView.quickLookTargetAtSelection() != nil
    }

    @discardableResult
    func presentQuickLook(_ target: ContextTarget) -> Bool {
        guard let request = QuickLookRequest.resolve(
            target,
            documentURL: markdownDocument.url,
            pathResolution: { [weak self] token in self?.pathResolver?.resolve(token) },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        ) else { return false }

        switch request {
        case .lightbox(let source):
            presentLightbox(source: source, caption: nil)
        case .panel(let url):
            // Reading is the least the app can ask for, and it is the same
            // effect the lightbox and the Asset Doctor request.  Opening a
            // preview is not launching the file, so this deliberately does not
            // ask for `.launchPathOrEditor`.
            authorizeLocalEffect(.readLocalAsset, target: url) { [weak self] in
                self?.showQuickLookPanel(url: url, sourceRange: target.sourceRange)
            }
        }
        // True either way: the gesture was aimed at a file and was handled,
        // including when the trust policy answered "ask" and the preview is
        // waiting on the reader.  Falling through to the dictionary here would
        // pop a Look Up card over a filename.
        return true
    }

    private func showQuickLookPanel(url: URL, sourceRange: NSRange) {
        let session = quickLookSession
        session.url = url
        session.sourceRange = sourceRange
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            // Already up on a different file — reload in place rather than
            // closing and reopening, which would flash the desktop through.
            panel.reloadData()
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // MARK: - Panel control (the responder-chain handshake)

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = self
        panel.delegate = self
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        // The panel outlives this window controller, so leaving it pointing
        // here would keep a closed document's controller alive and, worse,
        // answer for the next document opened in its place.
        if panel.dataSource === self { panel.dataSource = nil }
        if panel.delegate === self { panel.delegate = nil }
        quickLookSession.url = nil
        quickLookSession.sourceRange = nil
    }

    // MARK: - Data source

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        quickLookSession.url == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        quickLookSession.url as NSURL?
    }

    // MARK: - Delegate

    /// Zooms out of the text the preview came from.  Without this the panel
    /// scales up from the centre of the screen, which reads as an unrelated
    /// window opening rather than as the path under the pointer expanding.
    func previewPanel(
        _ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!
    ) -> NSRect {
        guard let range = quickLookSession.sourceRange,
              let rect = containerTextView.rect(forOffset: range.location),
              let window = containerTextView.window else { return .zero }
        let inWindow = containerTextView.convert(rect, to: nil)
        // Off-screen (the reader scrolled away, or the preview came from a
        // command rather than a click) means no anchor at all: `.zero` asks the
        // panel for its plain fade, which is better than an animation flying
        // out of a corner the target is not in.
        guard containerTextView.visibleRect.intersects(rect) else { return .zero }
        return window.convertToScreen(inWindow)
    }
}
