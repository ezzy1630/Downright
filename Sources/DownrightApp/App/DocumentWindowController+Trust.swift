import AppKit
import MarkdownRender
import ObjectiveC

private var trustStoreKey: UInt8 = 0
private var trustPromptKey: UInt8 = 0
private var trustActionKey: UInt8 = 0
private var trustThemeKey: UInt8 = 0

/// Trust hooks for external effects.  Existing link, asset, and path handlers
/// call `authorizeTrust(_:action:)`; this extension owns the decision UI only.
@MainActor
extension DocumentWindowController: TrustPromptViewDelegate {
    func configureLocalAssetAccess(
        for textView: MarkdownTextView, documentURL: URL?
    ) {
        textView.documentURL = documentURL
        textView.localAssetAuthorizer = { [weak self] target in
            self?.allowsLocalAsset(target) ?? false
        }
    }

    /// Render-time trust check. `.ask` is intentionally treated as blocked;
    /// prompts are only legal from an explicit user action, never from draw.
    private func allowsLocalAsset(_ url: URL) -> Bool {
        guard let canonical = DocumentTrust.canonicalFilePath(url) else { return false }
        let request = TrustRequest(
            effect: .readLocalAsset,
            target: TrustTarget(displayName: canonical.path, canonicalPath: canonical.path),
            documentURL: markdownDocument.url
        )
        return trustDecision(for: request) == .allow
    }

    private var trustStore: TrustStore {
        if let store = objc_getAssociatedObject(self, &trustStoreKey) as? TrustStore { return store }
        let store = TrustStore.shared
        objc_setAssociatedObject(self, &trustStoreKey, store, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return store
    }

    private var trustPrompt: TrustPromptView? {
        get { objc_getAssociatedObject(self, &trustPromptKey) as? TrustPromptView }
        set { objc_setAssociatedObject(self, &trustPromptKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    private var pendingTrustAction: (() -> Void)? {
        get { objc_getAssociatedObject(self, &trustActionKey) as? (() -> Void) }
        set { objc_setAssociatedObject(self, &trustActionKey, newValue, .OBJC_ASSOCIATION_COPY_NONATOMIC) }
    }

    func trustDecision(for request: TrustRequest) -> TrustDecision {
        let state: DocumentTrustState = containerTextView.mode == .source
            ? .rawSource
            : trustStore.state(for: markdownDocument.url)
        return trustStore.policy(state: state).decision(for: request)
    }

    @discardableResult
    func authorizeExternalURL(_ url: URL, action: @escaping () -> Void) -> TrustDecision {
        authorizeTrust(
            TrustRequest(
                effect: .openExternalLink,
                target: TrustTarget(displayName: url.absoluteString, externalURL: url.absoluteString),
                documentURL: markdownDocument.url
            ),
            action: action
        )
    }

    @discardableResult
    func authorizeRemoteAssetURL(_ url: URL, action: @escaping () -> Void) -> TrustDecision {
        authorizeTrust(
            TrustRequest(
                effect: .loadRemoteAsset,
                target: TrustTarget(displayName: url.absoluteString, externalURL: url.absoluteString),
                documentURL: markdownDocument.url
            ),
            action: action
        )
    }

    @discardableResult
    func authorizeAutomationURL(_ url: URL, action: @escaping () -> Void) -> TrustDecision {
        authorizeTrust(
            TrustRequest(
                effect: .automationAppIntent,
                target: TrustTarget(displayName: url.absoluteString, externalURL: url.absoluteString),
                documentURL: markdownDocument.url
            ),
            action: action
        )
    }

    @discardableResult
    func authorizeLocalEffect(
        _ effect: TrustEffect,
        target url: URL,
        action: @escaping () -> Void
    ) -> TrustDecision {
        let canonical = DocumentTrust.canonicalFilePath(url) ?? url.standardizedFileURL
        return authorizeTrust(
            TrustRequest(
                effect: effect,
                target: TrustTarget(displayName: canonical.path, canonicalPath: canonical.path),
                documentURL: markdownDocument.url
            ),
            action: action
        )
    }

    /// Runs `action` only after policy allows it.  An ask is non-modal and
    /// returns `.ask`; the action runs later if the user grants it.
    @discardableResult
    func authorizeTrust(_ request: TrustRequest, action: @escaping () -> Void) -> TrustDecision {
        switch trustDecision(for: request) {
        case .allow:
            action()
            return .allow
        case .deny:
            return .deny
        case .ask:
            pendingTrustAction = action
            presentTrustPrompt(request)
            return .ask
        }
    }

    func presentTrustPrompt(_ request: TrustRequest) {
        if let prompt = trustPrompt {
            prompt.request = request
            return
        }
        let prompt = TrustPromptView(styleSheet: activeStyleSheet)
        prompt.delegate = self
        prompt.request = request
        trustPrompt = prompt
        installTrailing(prompt)

        let observation = ThemeStore.shared.observe { [weak self, weak prompt] theme in
            guard let self, let prompt, let window = self.window else { return }
            prompt.styleSheet = StyleSheet(theme: theme, appearance: window.effectiveAppearance)
        }
        objc_setAssociatedObject(self, &trustThemeKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func revokeTrust(scope: TrustScope, path: URL) {
        guard trustStore.revoke(scope: scope, path: path) else {
            presentOperationError(
                "Couldn’t save the trust revocation",
                error: CocoaError(.fileWriteUnknown)
            )
            return
        }
    }

    func trustPrompt(_ view: TrustPromptView, didChoose decision: TrustPromptDecision, request: TrustRequest) {
        switch decision {
        case .allowOnce:
            finishTrustPrompt(runPending: true)
        case .allowForFile:
            grant(request: request, scope: .file)
            finishTrustPrompt(runPending: true)
        case .allowForFolder:
            grant(request: request, scope: .folder)
            finishTrustPrompt(runPending: true)
        case .deny:
            finishTrustPrompt(runPending: false)
        case .revoke:
            revokeMatching(request: request)
            finishTrustPrompt(runPending: false)
        }
    }

    private func finishTrustPrompt(runPending: Bool) {
        if let prompt = trustPrompt { dismissTrailing(prompt) }
        trustPrompt = nil
        objc_setAssociatedObject(self, &trustThemeKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        let action = pendingTrustAction
        pendingTrustAction = nil
        if runPending { action?() }
    }

    private func grant(request: TrustRequest, scope: TrustScope) {
        let path: URL?
        if let targetPath = request.target.canonicalPath {
            let targetURL = URL(fileURLWithPath: targetPath)
            path = scope == .folder ? folderScopeURL(for: targetURL) : targetURL
        } else if let documentURL = markdownDocument.url {
            path = scope == .folder ? folderScopeURL(for: documentURL) : documentURL
        } else {
            path = nil
        }
        guard let path else { return }
        guard trustStore.grant(
            scope: scope,
            path: path,
            effects: [request.effect],
            externalURL: request.target.externalURL
        ) else {
            presentOperationError(
                "Couldn’t save this trust decision",
                error: CocoaError(.fileWriteUnknown)
            )
            return
        }
    }

    private func revokeMatching(request: TrustRequest) {
        if let path = request.target.canonicalPath {
            let targetURL = URL(fileURLWithPath: path)
            revokeTrust(scope: .file, path: targetURL)
            revokeTrust(scope: .folder, path: folderScopeURL(for: targetURL))
        } else if let documentURL = markdownDocument.url {
            revokeTrust(scope: .file, path: documentURL)
            revokeTrust(scope: .folder, path: folderScopeURL(for: documentURL))
        }
    }

    /// The folder a "Allow for Folder" grant covers for a target.  A file
    /// target grants its parent directory; a directory target grants the
    /// directory itself, so consenting on a folder never widens to its parent.
    private func folderScopeURL(for target: URL) -> URL {
        let isDirectory = (try? target.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        return DocumentTrust.folderScope(for: target, isDirectory: isDirectory)
    }
}
