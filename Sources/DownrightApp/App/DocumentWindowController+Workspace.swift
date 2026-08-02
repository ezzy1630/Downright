import AppKit
import MarkdownCore
import MarkdownRender
import ObjectiveC

private var workspaceIndexKey: UInt8 = 0
private var workspaceSidebarKey: UInt8 = 0
private var workspaceSearchKey: UInt8 = 0
private var workspaceGraphKey: UInt8 = 0

/// Optional folder workspace hooks.  The normal single-file path stays
/// unchanged until the user summons this panel.
@MainActor
extension DocumentWindowController: WorkspaceSidebarViewDelegate {
    private var workspaceIndex: WorkspaceIndex? {
        get { objc_getAssociatedObject(self, &workspaceIndexKey) as? WorkspaceIndex }
        set { objc_setAssociatedObject(self, &workspaceIndexKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var workspaceSidebar: WorkspaceSidebarView? {
        get { objc_getAssociatedObject(self, &workspaceSidebarKey) as? WorkspaceSidebarView }
        set { objc_setAssociatedObject(self, &workspaceSidebarKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var workspaceSearch: WorkspaceSearchSession? {
        get { objc_getAssociatedObject(self, &workspaceSearchKey) as? WorkspaceSearchSession }
        set { objc_setAssociatedObject(self, &workspaceSearchKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var workspaceGraph: WorkspaceLinkGraph {
        get { (objc_getAssociatedObject(self, &workspaceGraphKey) as? WorkspaceLinkGraph) ?? .empty }
        set { objc_setAssociatedObject(self, &workspaceGraphKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func toggleWorkspaceSidebar() {
        if let panel = workspaceSidebar {
            dismissTrailing(panel)
            workspaceSidebar = nil
            workspaceIndex?.cancel()
            workspaceSearch?.cancel()
            workspaceIndex = nil
            workspaceSearch = nil
            return
        }
        let panel = WorkspaceSidebarView(styleSheet: activeStyleSheet)
        panel.delegate = self
        workspaceSidebar = panel
        let index = WorkspaceIndex()
        workspaceIndex = index
        let search = WorkspaceSearchSession()
        workspaceSearch = search
        index.onUpdate = { [weak self, weak panel] snapshot in
            guard let self, let panel else { return }
            self.workspaceGraph = WorkspaceLinkGraphBuilder.build(snapshot: snapshot)
            panel.entries = snapshot.entries
            panel.searchResults = []
            let currentID = self.markdownDocument.url?.standardizedFileURL.path
            panel.selectedFileID = currentID
            panel.backlinks = currentID.map { self.workspaceGraph.linksTo(fileID: $0) } ?? []
            let symbols = snapshot.entries.flatMap { entry in
                entry.headings.map { heading in
                    QuickOpenResult(
                        id: "workspace-heading:\(entry.id):\(heading.range.location)",
                        kind: .symbol,
                        title: heading.title,
                        subtitle: entry.relativePath,
                        action: .openAt(entry.url, heading.range)
                    )
                }
            }
            self.setQuickOpenProviders([
                WorkspaceQuickOpenProvider(
                    files: snapshot.entries.map(\.url), symbols: symbols
                )
            ])
        }
        search.onUpdate = { [weak panel] results in
            panel?.searchResults = results
        }
        installTrailing(panel)
        let root = markdownDocument.url?.deletingLastPathComponent() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        index.start(rootURL: root)
    }

    /// Start an index at an explicit folder.  This is useful to the open-folder
    /// command and keeps tests independent from application state.
    func startWorkspaceIndex(at rootURL: URL, policy: WorkspaceIndexPolicy = .default) {
        let index = workspaceIndex ?? WorkspaceIndex(policy: policy)
        workspaceIndex = index
        index.start(rootURL: rootURL)
    }

    func refreshWorkspaceIndex() {
        guard let index = workspaceIndex else { return }
        index.start(rootURL: index.snapshot.rootURL)
    }

    func resetWorkspaceState(for documentURL: URL) {
        workspaceSearch?.cancel()
        workspaceGraph = .empty
        guard let index = workspaceIndex else { return }

        workspaceSidebar?.entries = []
        workspaceSidebar?.searchResults = []
        workspaceSidebar?.backlinks = []
        workspaceSidebar?.selectedFileID = documentURL.standardizedFileURL.path
        index.reroot(to: documentURL.deletingLastPathComponent())
    }

    func workspaceSidebar(_ view: WorkspaceSidebarView, didSearch query: WorkspaceSearchQuery) {
        guard let index = workspaceIndex else { return }
        view.selectedTab = .search
        workspaceSearch?.start(query: query, snapshot: index.snapshot)
    }

    func workspaceSidebar(
        _ view: WorkspaceSidebarView,
        didSelect url: URL,
        range: NSRange?,
        inNewWindow: Bool
    ) {
        if inNewWindow {
            (NSApp.delegate as? AppDelegate)?.open(url)
        } else {
            openInPlace(url)
        }
        guard let range, url.standardizedFileURL.path == markdownDocument.url?.standardizedFileURL.path else { return }
        containerTextView.setSourceSelectedRanges([range])
        containerTextView.scroll(toOffset: range.location, position: .center, animated: true)
        window?.makeFirstResponder(containerTextView)
    }

    func configureWorkspaceSidebar(_ panel: WorkspaceSidebarView) {
        panel.styleSheet = activeStyleSheet
        panel.delegate = self
        if let index = workspaceIndex {
            panel.entries = index.snapshot.entries
            panel.searchResults = []
            let currentID = markdownDocument.url?.standardizedFileURL.path
            panel.selectedFileID = currentID
            panel.backlinks = currentID.map { workspaceGraph.linksTo(fileID: $0) } ?? []
        }
    }
}
