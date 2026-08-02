import AppKit
import ObjectiveC

private var commandPaletteAssociationKey: UInt8 = 0
private var quickOpenProvidersAssociationKey: UInt8 = 0

/// Floating command palette presentation.  The palette asks this controller to
/// run one `Command`; it never edits the document or dispatches actions itself.
@MainActor
extension DocumentWindowController: CommandPaletteViewDelegate {
    private var quickOpenProviders: [any QuickOpenProvider] {
        get { objc_getAssociatedObject(self, &quickOpenProvidersAssociationKey) as? [any QuickOpenProvider] ?? [] }
        set { objc_setAssociatedObject(self, &quickOpenProvidersAssociationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func setQuickOpenProviders(_ providers: [any QuickOpenProvider]) {
        quickOpenProviders = providers
    }

    private var commandPaletteWindow: NSPanel? {
        get { objc_getAssociatedObject(self, &commandPaletteAssociationKey) as? NSPanel }
        set {
            objc_setAssociatedObject(
                self,
                &commandPaletteAssociationKey,
                newValue,
                .OBJC_ASSOCIATION_RETAIN_NONATOMIC
            )
        }
    }

    /// Show or focus the palette.  Add this method to the command switch and
    /// keybinding table when the command is exposed as a first-class command.
    func showCommandPalette() {
        if let existing = commandPaletteWindow {
            existing.makeKeyAndOrderFront(nil)
            existing.contentView?.window?.makeFirstResponder(existing.contentView?.subviews.first { $0 is NSSearchField })
            return
        }

        let palette = CommandPaletteView(
            styleSheet: activeStyleSheet,
            recentStore: UserDefaultsCommandPaletteRecentStore(),
            providers: [
                CurrentDocumentQuickOpenProvider(document: markdownDocument.parsed),
                RecentFilesQuickOpenProvider(
                    files: DocumentStateStore.shared.recents(limit: 30).map { URL(fileURLWithPath: $0.path) }
                ),
            ] + quickOpenProviders
        )
        palette.delegate = self

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: palette.preferredWidth, height: 460),
            styleMask: [.titled, .fullSizeContentView, .closable],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.contentView = palette

        let closeHandler = CommandPaletteWindowDelegate { [weak self, weak panel] in
            guard let self else { return }
            if let panel { self.window?.removeChildWindow(panel) }
            if self.commandPaletteWindow === panel { self.commandPaletteWindow = nil }
        }
        panel.delegate = closeHandler
        objc_setAssociatedObject(
            panel,
            &commandPaletteAssociationKey,
            closeHandler,
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC
        )

        commandPaletteWindow = panel
        if let parent = window {
            parent.addChildWindow(panel, ordered: .above)
            let parentFrame = parent.frame
            let origin = NSPoint(
                x: parentFrame.midX - panel.frame.width / 2,
                y: parentFrame.midY - panel.frame.height / 2 + 60
            )
            panel.setFrameOrigin(origin)
        } else {
            panel.center()
        }
        panel.makeKeyAndOrderFront(nil)
    }

    func commandPalette(_ palette: CommandPaletteView, didChoose result: QuickOpenResult) {
        commandPaletteWindow?.close()
        switch result.action {
        case .command(let command):
            perform(command)
        case .select(let range):
            guard range.upperBound <= markdownDocument.storage.length else { return }
            containerTextView.setSourceSelectedRanges([range])
            containerTextView.scroll(toOffset: range.location, position: .center, animated: true)
            window?.makeFirstResponder(containerTextView)
        case .open(let url):
            (NSApp.delegate as? AppDelegate)?.open(url, mode: mode)
        case .openAt(let url, let range):
            openInPlace(url)
            guard range.upperBound <= markdownDocument.storage.length else { return }
            containerTextView.setSourceSelectedRanges([range])
            containerTextView.scroll(
                toOffset: range.location, position: .center, animated: false
            )
            window?.makeFirstResponder(containerTextView)
        }
    }

    func commandPaletteDidCancel(_ palette: CommandPaletteView) {
        commandPaletteWindow?.close()
    }
}

@MainActor
private final class CommandPaletteWindowDelegate: NSObject, NSWindowDelegate {
    private let onClose: () -> Void

    init(onClose: @escaping () -> Void) {
        self.onClose = onClose
    }

    func windowWillClose(_ notification: Notification) {
        onClose()
    }
}
