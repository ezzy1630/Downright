import AppKit

/// Window actions for the Asset Doctor panel.
///
/// The panel itself only reports source ranges and proposals.  This extension
/// supplies the document, local-only file probe, and the one-edit undo path.
/// The owner may keep an `AssetDoctorView` in any inspector slot and call
/// `configureAssetDoctor(_:)` after each parse.
@MainActor
extension DocumentWindowController: AssetDoctorViewDelegate {
    func toggleAssetDoctorPanel() {
        if let assetDoctorPanel {
            dismissTrailing(assetDoctorPanel)
            self.assetDoctorPanel = nil
            return
        }
        if let folder = markdownDocument.url?.deletingLastPathComponent(),
           trustDecision(for: TrustRequest(
               effect: .readLocalAsset,
               target: TrustTarget(displayName: folder.path, canonicalPath: folder.path),
               documentURL: markdownDocument.url
           )) != .allow {
            authorizeLocalEffect(.readLocalAsset, target: folder) { [weak self] in
                self?.showAssetDoctorPanel()
            }
            return
        }
        showAssetDoctorPanel()
    }

    private func showAssetDoctorPanel() {
        frontMatterEditor = nil
        let panel = AssetDoctorView(styleSheet: activeStyleSheet)
        assetDoctorPanel = panel
        configureAssetDoctor(panel)
        installTrailing(panel)
    }

    func configureAssetDoctor(_ view: AssetDoctorView) {
        view.delegate = self
        view.styleSheet = activeStyleSheet
        let context = AssetResolutionContext(
            documentURL: markdownDocument.url,
            workspaceRoot: markdownDocument.url?.deletingLastPathComponent()
        )
        view.diagnostics = AssetDoctor.diagnose(
            markdownDocument.parsed,
            context: context,
            probe: localAssetProbe()
        )
    }

    func assetDoctorView(_ view: AssetDoctorView, didSelect diagnostic: AssetDiagnostic) {
        let range = diagnostic.reference.imageRange
        guard range.location >= 0, range.upperBound <= markdownDocument.storage.length else { return }
        containerTextView.setSourceSelectedRanges([range])
        containerTextView.scroll(toOffset: range.location, position: .center, animated: true)
        window?.makeFirstResponder(containerTextView)
    }

    func assetDoctorView(_ view: AssetDoctorView, didReveal diagnostic: AssetDiagnostic) {
        guard diagnostic.reference.kind == .relativeLocal ||
              diagnostic.reference.kind == .absoluteLocal ||
              diagnostic.reference.kind == .fileURL,
              let url = diagnostic.reference.url else { return }
        authorizeLocalEffect(.launchPathOrEditor, target: url) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        }
    }

    func assetDoctorView(
        _ view: AssetDoctorView,
        didRequestProposal kind: AssetProposalKind,
        for diagnostic: AssetDiagnostic
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = kind == .relink
            ? "Choose the replacement image."
            : "Choose the image path to use."
        guard panel.runModal() == .OK, let url = panel.url,
              let replacement = relativeAssetPath(for: url) else { return }
        let proposal = kind == .relink
            ? AssetDoctor.relinkProposal(for: diagnostic.reference, to: replacement)
            : AssetDoctor.renameProposal(for: diagnostic.reference, to: replacement)
        applyAssetProposal(proposal)
    }

    func assetDoctorView(_ view: AssetDoctorView, didApply proposal: AssetSourceProposal) {
        applyAssetProposal(proposal)
    }

    private func applyAssetProposal(_ proposal: AssetSourceProposal) {
        guard proposal.apply(to: markdownDocument.text) != nil else { return }
        let actionName = proposal.kind == .relink ? "Relink Image" : "Rename Image"
        guard markdownDocument.replace(
            proposal.range,
            with: proposal.replacement,
            actionName: actionName
        ) else { return }
        markdownDocument.reparseNow()
        refreshDerivedUI()
    }

    private func relativeAssetPath(for url: URL) -> String? {
        let target = url.standardizedFileURL.path
        guard let documentURL = markdownDocument.url else { return target }
        let base = documentURL.deletingLastPathComponent().standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        if target.hasPrefix(prefix) { return String(target.dropFirst(prefix.count)) }
        return target
    }

    func localAssetProbe() -> AssetProbe {
        AssetProbe { url in
            let values: URLResourceValues
            do {
                values = try url.resourceValues(forKeys: [
                    .isRegularFileKey, .isDirectoryKey, .fileSizeKey
                ])
            } catch {
                return nil
            }
            let exists = values.isRegularFile == true || values.isDirectory == true
            return AssetMetadata(
                exists: exists,
                isDirectory: values.isDirectory == true,
                byteSize: values.fileSize.map(Int64.init),
                fileExtension: url.pathExtension
            )
        }
    }
}
