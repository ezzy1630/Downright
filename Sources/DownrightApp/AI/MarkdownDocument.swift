import AppKit
import Foundation
import MarkdownCore
import MarkdownRender

/// How a save request is allowed to behave when the on-disk version is newer.
enum SaveIntent {
    /// Refuses to overwrite an unacknowledged external change and surfaces the
    /// conflict instead of deciding silently.  Used by every implicit save
    /// path: occlusion autosave, quit, checkbox toggle, and the close alert.
    case normal
    /// An explicit "keep my changes and write them over the file" decision,
    /// made by the user through the conflict bar.
    case keepMine
}

enum SaveError: Error {
    /// The save was refused because writing the buffer would clobber a newer
    /// on-disk version whose conflict had not been resolved.  The conflict has
    /// already been surfaced via `onExternalEvent`.
    case blockedByExternalConflict
}

/// The document: raw text, the tree over it, and everything that watches it.
///
/// §3.1 is enforced here and nowhere else needs to worry about it — the
/// `NSTextStorage` holds the file's exact characters at all times, and every
/// mutation goes through `replace(_:with:actionName:)`, which is a plain text
/// replacement with plain text undo.  There is no document model to
/// re-serialise, so there is nothing that can normalise a file behind the
/// user's back.
@MainActor
final class MarkdownDocument: NSObject {
    /// What an external write did while the buffer was dirty (§8.1).
    struct Conflict {
        var incomingText: String
        var hunks: [ChangeHunk]
        var changedBlockCount: Int
    }

    enum ExternalEvent {
        /// Applied in place; scroll position preserved by the delegate.
        case applied(hunks: [ChangeHunk])
        /// Buffer was dirty — never clobber.  Ask the user.
        case conflict(Conflict)
        case fileRemoved
        case fileRestored
    }

    // MARK: - State

    let storage = NSTextStorage()
    private(set) var url: URL?
    private(set) var fidelity: ByteFidelity = .default
    private(set) var parsed: ParsedDocument = .empty
    private(set) var isDirty = false
    /// Hash of what is currently on disk, as far as we know.
    private(set) var diskHash: String = ""
    /// An external write the buffer has not yet been reconciled with.  Non-nil
    /// while a conflict bar is showing — and, critically, stays non-nil even if
    /// that bar is dismissed — so an implicit save never silently writes the
    /// buffer over the newer on-disk version.
    private(set) var pendingConflict: Conflict?

    let changes = ChangeTracker()
    var state: DocumentState
    let undoManager = UndoManager()

    /// Fires after every reparse with the set of blocks needing re-decoration.
    var onReparse: ((ParsedDocument, DirtySet) -> Void)?
    /// Fired on the main actor when an async reparse becomes pending or
    /// drains.  Drives the toolbar activity cue for sustained work — a parse
    /// that runs past a second should not be silent.
    var onParseActivity: ((Bool) -> Void)?
    var onExternalEvent: ((ExternalEvent) -> Void)?
    var onDirtyChanged: ((Bool) -> Void)?
    /// Called when a save reaches the disk boundary and fails.  The buffer and
    /// dirty state remain untouched so the controller can offer recovery.
    var onSaveFailure: ((Error) -> Void)?
    /// Asked for the source offset at the top of the viewport, so an external
    /// rewrite can restore the reader's place by heading anchor (§8.1).
    var currentTopOffsetProvider: (() -> Int)?
    /// Asked to scroll to a source offset after an external rewrite.
    var restoreOffsetHandler: ((Int) -> Void)?

    private var watcher: FileWatcher?
    private var reparseScheduled = false
    private var isApplyingExternalChange = false
    private var suppressReparse = false
    private let parseCoordinator: MarkdownParseCoordinator
    private var parseTask: Task<Void, Never>?
    private var parseControlTask: Task<Void, Never>?
    private(set) var revision = MarkdownParseRevision.zero
    private var isClosed = false
    private var preferencesObservation: NSObjectProtocol?
    /// After open's structure-only first paint, the next full async parse must
    /// restyle wholesale — structure trees are not decoration-compatible.
    private var forceNextDirtyWholesale = false

    // MARK: - Init

    override convenience init() {
        self.init(parseWorker: MarkdownParseWorker())
    }

    init(parseWorker: MarkdownParseWorker) {
        self.parseCoordinator = MarkdownParseCoordinator(worker: parseWorker)
        self.state = DocumentState(path: "")
        super.init()
        parseCoordinator.onBusyChange = { [weak self] busy in
            Task { @MainActor in self?.onParseActivity?(busy) }
        }
        storage.delegate = self
        undoManager.groupsByEvent = false
        preferencesObservation = NotificationCenter.default.addObserver(
            forName: Preferences.didChange,
            object: Preferences.shared,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.preferencesDidChange() }
        }
    }

    deinit {
        if let preferencesObservation {
            NotificationCenter.default.removeObserver(preferencesObservation)
        }
        parseTask?.cancel()
        let coordinator = parseCoordinator
        Task { await coordinator.shutdown() }
    }

    var text: String { storage.string }
    var displayName: String {
        url?.deletingPathExtension().lastPathComponent ?? "Untitled"
    }

    // MARK: - Opening and saving

    func open(_ fileURL: URL) throws {
        isClosed = false
        enqueueParseControl { await $0.resume() }
        cancelParseWork()
        // In-place hops reuse this document; change marks from the previous
        // file must not decorate the next one.
        changes.clear()
        // Canonicalise once, up front.  A `.atomic` write renames a new file
        // over the destination, which would *replace a symlink with a regular
        // file* while the link's target kept its stale content.  Resolving here
        // makes the identity, the watcher, and the write path agree, so saving
        // a file opened through a symlink edits the target it points at rather
        // than clobbering the link itself (§8.1).
        let canonical = fileURL.resolvingSymlinksInPath()
        let (text, fidelity) = try DocumentIO.read(contentsOf: canonical)
        self.url = canonical
        self.fidelity = fidelity
        self.state = DocumentStateStore.shared.state(for: canonical)

        suppressReparse = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        suppressReparse = false

        diskHash = DocumentIO.contentHash(text)
        isDirty = false

        // Structure-only first paint for outline/state. The controller paints
        // decorations after applying zoom/folds; full decoration converges on
        // the async parse lane.
        let structure = MarkdownParser.parse(text, options: .structureOnly)
        parsed = structure

        SnapshotStore.shared.record(text, for: canonical, kind: .baseline)
        DocumentStateStore.shared.noteOpened(canonical, document: structure)

        // Unread-since-last-read (§8.2): if the bytes moved while the app was
        // closed, mark up what changed and offer to jump to the first one.
        if !state.lastSeenHash.isEmpty, state.lastSeenHash != diskHash,
           let previous = SnapshotStore.shared.text(forHash: state.lastSeenHash) {
            let hunks = TextDiff.hunks(old: previous, new: text)
            if !hunks.isEmpty { changes.apply(hunks: hunks) }
        }

        startWatching(canonical)
        forceNextDirtyWholesale = true
        startAsyncReparse()
    }

    /// Adopts text with no backing file — used by `Compare` windows and by the
    /// version timeline's preview pane.
    func adopt(text: String, displayURL: URL?) {
        isClosed = false
        enqueueParseControl { await $0.resume() }
        cancelParseWork()
        self.url = displayURL
        suppressReparse = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        suppressReparse = false
        reparseSynchronously(notifying: true, wholesale: true)
        isDirty = false
    }

    func save(intent: SaveIntent = .normal) throws {
        guard let url else {
            let error = CocoaError(.fileNoSuchFile)
            onSaveFailure?(error)
            throw error
        }
        let text = storage.string

        // §8.1: a save that would overwrite a newer-on-disk version must not
        // happen silently.  Every implicit save path (occlusion autosave, quit,
        // checkbox toggle, close alert) funnels through here, and none of them
        // may make the keep-mine call for the user.  Surface any unresolved
        // conflict — or one detected right now — and refuse to write.
        if intent == .normal, isDirty {
            if let conflict = pendingConflict {
                throw presentBlockingConflict(conflict, incoming: conflict.incomingText, incomingHash: nil)
            }
            if let detected = detectExternalChange() {
                let conflict = Conflict(
                    incomingText: detected.text,
                    hunks: detected.hunks,
                    changedBlockCount: detected.hunks.count
                )
                throw presentBlockingConflict(
                    conflict, incoming: detected.text,
                    incomingHash: SnapshotStore.hash(detected.text)
                )
            }
        }

        watcher?.suppressOwnWrite()
        defer { watcher?.acknowledgeOwnWrite() }
        do {
            try DocumentIO.write(text, to: url, fidelity: fidelity)
        } catch {
            onSaveFailure?(error)
            throw error
        }

        diskHash = DocumentIO.contentHash(text)
        pendingConflict = nil
        SnapshotStore.shared.record(text, for: url, kind: .local)
        setDirty(false)
        persistState()
    }

    /// Re-reads the file and decides whether saving the buffer would clobber
    /// bytes on disk that are newer than the last state we acknowledged.  A
    /// plain dirty buffer (unsaved edits, file untouched) returns `nil`.
    private func detectExternalChange() -> (text: String, hunks: [ChangeHunk])? {
        guard let url, let (incoming, _) = try? DocumentIO.read(contentsOf: url) else { return nil }
        let incomingHash = SnapshotStore.hash(incoming)
        guard incomingHash != diskHash else { return nil }
        // If the disk already holds the buffer's bytes, writing is a no-op and
        // there is nothing being clobbered.  A trailing-newline-only difference
        // is likewise not a content change: it is an artifact `DocumentIO` will
        // reconcile on this very write, so it must not surface as a conflict or
        // block an autosave.
        guard incomingHash != SnapshotStore.hash(storage.string),
              !finalNewlineDifferenceOnly(storage.string, incoming) else {
            diskHash = incomingHash
            return nil
        }
        return (incoming, TextDiff.hunks(old: storage.string, new: incoming))
    }

    /// True when `a` and `b` differ only by the presence of a single trailing
    /// newline (LF, CRLF or lone CR are all counted).  Used to treat the final
    /// newline as byte-fidelity rather than as content, so an external absorb
    /// never reverts the user's trailing-newline edit and a save never blocks
    /// on a phantom conflict for one.
    private func finalNewlineDifferenceOnly(_ a: String, _ b: String) -> Bool {
        func strippedNewline(_ s: String) -> String {
            if s.hasSuffix("\r\n") { return String(s.dropLast(2)) }
            if s.hasSuffix("\n") || s.hasSuffix("\r") { return String(s.dropLast()) }
            return s
        }
        return strippedNewline(a) == strippedNewline(b)
    }

    /// Records the external snapshot, marks the conflict pending, publishes the
    /// conflict event, and returns the blocking error that cancels the save.
    /// The event (conflict bar) is the only surface — no `onSaveFailure` alert,
    /// because a refused save here is a deliberate, visible outcome.
    private func presentBlockingConflict(
        _ conflict: Conflict, incoming: String, incomingHash: String?
    ) -> SaveError {
        pendingConflict = conflict
        if let incomingHash { diskHash = incomingHash }
        if let url { SnapshotStore.shared.record(incoming, for: url, kind: .external) }
        onExternalEvent?(.conflict(conflict))
        return .blockedByExternalConflict
    }

    @discardableResult
    func saveIfNeeded(intent: SaveIntent = .normal) -> Result<Void, Error> {
        guard isDirty else { return .success(()) }
        guard url != nil else {
            let error = CocoaError(.fileNoSuchFile)
            onSaveFailure?(error)
            return .failure(error)
        }
        do {
            try save(intent: intent)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    func close() {
        isClosed = true
        cancelParseWork()
        // Discard change marks owned by a torn-down document so they cannot
        // leak across to the next file opened in the same window.
        changes.clear()
        enqueueParseControl { await $0.suspend() }
        persistState()
        watcher?.stop()
        watcher = nil
    }

    private func persistState() {
        guard let url else { return }
        var state = self.state
        state.lastSeenHash = diskHash
        if let top = currentTopOffsetProvider?() {
            state.anchor = ScrollAnchoring.anchor(for: top, in: parsed)
        }
        state.lastOpened = Date()
        self.state = state
        DocumentStateStore.shared.save(state, for: url)
    }

    /// Restores the reader's place from persisted state (§8.2).
    func restoredOffset() -> Int {
        ScrollAnchoring.offset(for: state.anchor, in: parsed)
    }

    // MARK: - Editing
    //
    // Every mutation funnels through here so undo, dirty tracking, and change
    // mark adjustment are impossible to forget at a call site.

    @discardableResult
    func replace(_ range: NSRange, with replacement: String, actionName: String?) -> Bool {
        guard range.location >= 0, range.upperBound <= storage.length else { return false }
        let previous = (storage.string as NSString).substring(with: range)
        guard previous != replacement else { return false }

        let newRange = NSRange(location: range.location, length: (replacement as NSString).length)
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { doc in
            MainActor.assumeIsolated {
                doc.replace(newRange, with: previous, actionName: actionName)
            }
        }
        if let actionName { undoManager.setActionName(actionName) }
        undoManager.endUndoGrouping()

        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()

        let delta = (replacement as NSString).length - range.length
        changes.adjust(forEditIn: range, delta: delta)
        if !isApplyingExternalChange { setDirty(true) }
        return true
    }

    func apply(_ edits: [TextEdit], actionName: String) {
        guard !edits.isEmpty else { return }
        // Back to front so earlier offsets stay valid, matching
        // `[TextEdit].applied(to:)`.
        let ordered = edits.sorted { $0.range.location > $1.range.location }
        var lastStart = Int.max
        undoManager.beginUndoGrouping()
        for edit in ordered {
            guard edit.range.upperBound <= lastStart else { continue }
            replace(edit.range, with: edit.replacement, actionName: nil)
            lastStart = edit.range.location
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
    }

    /// Toggling a checkbox writes the file immediately (§7.1, §8.5).
    func toggleTask(atMarkOffset offset: Int) {
        ensureParsedCurrent()
        guard let edit = Restructure.toggleTask(parsed, atMarkOffset: offset) else { return }
        apply([edit], actionName: "Toggle Task")
        reparseNow()
        if url != nil { _ = saveIfNeeded() }
    }

    private func setDirty(_ value: Bool) {
        guard isDirty != value else { return }
        isDirty = value
        onDirtyChanged?(value)
    }

    // MARK: - Parsing (§3.5)

    /// Coalesced to the end of the runloop turn: a burst of keystrokes or a
    /// multi-edit command reparses once, not once per character.
    private func scheduleReparse() {
        guard !reparseScheduled, !suppressReparse else { return }
        reparseScheduled = true
        RunLoop.main.perform(inModes: [.common]) { [weak self] in
            MainActor.assumeIsolated { self?.flushScheduledReparse() }
        }
    }

    /// Starts the coalesced worker snapshot.  Kept as a small seam so tests
    /// can flush scheduled work without depending on wall-clock run-loop time.
    func flushScheduledReparse() {
        guard reparseScheduled else { return }
        reparseScheduled = false
        startAsyncReparse()
    }

    func reparseNow() {
        reparseScheduled = false
        reparseSynchronously(notifying: true, wholesale: false)
    }

    /// Forces convergence before an operation that reads the tree.  Commands
    /// that rewrite source must never plan edits from an older async parse.
    func ensureParsedCurrent() {
        guard parsed.text != storage.string else { return }
        reparseNow()
    }

    private func reparseSynchronously(notifying: Bool, wholesale: Bool) {
        cancelParseWork()
        let previous = parsed
        let fresh = MarkdownParser.parse(storage.string)
        parsed = fresh
        guard notifying else { return }
        let dirty = wholesale ? DirtySet.wholesale : ASTDiff.dirtySet(old: previous, new: fresh)
        onReparse?(fresh, dirty)
    }

    private func startAsyncReparse() {
        guard !suppressReparse, !isClosed else { return }
        let text = storage.string
        let previous = parsed
        let parseRevision = revision
        let coordinator = parseCoordinator
        enqueueParseControl { await $0.submit(MarkdownParseRequest(
            text: text, previous: previous, revision: parseRevision
        )) }

        guard parseTask == nil else { return }
        parseTask = Task.detached(priority: .userInitiated) { [weak self, coordinator] in
            while let result = await coordinator.nextResult() {
                guard !Task.isCancelled else { return }
                await self?.applyAsyncParse(result)
            }
        }
    }

    private func applyAsyncParse(_ result: MarkdownParseResult) {
        guard !isClosed,
              result.revision == revision,
              result.text == storage.string,
              result.document.text == result.text else { return }
        parsed = result.document
        let dirty = forceNextDirtyWholesale ? DirtySet.wholesale : result.dirty
        forceNextDirtyWholesale = false
        onReparse?(result.document, dirty)
    }

    private func cancelParseWork() {
        reparseScheduled = false
        revision = revision.advanced()
        enqueueParseControl { await $0.discardPending() }
    }

    private func invalidateParseWorkForEdit() {
        revision = revision.advanced()
    }

    /// Serializes lifecycle and submit messages sent from the main actor.
    /// Separate unstructured tasks have no ordering contract; this chain makes
    /// close → reopen → submit explicit and prevents a valid snapshot from
    /// reaching a coordinator that is still suspended.
    private func enqueueParseControl(
        _ operation: @escaping @Sendable (MarkdownParseCoordinator) async -> Void
    ) {
        let previous = parseControlTask
        let coordinator = parseCoordinator
        parseControlTask = Task {
            _ = await previous?.value
            await operation(coordinator)
        }
    }

    // MARK: - External changes (§8.1)

    private func startWatching(_ fileURL: URL) {
        guard Preferences.shared.values.watchFiles else {
            watcher?.stop()
            watcher = nil
            return
        }
        watcher?.stop()
        watcher = FileWatcher(url: fileURL) { [weak self] event in
            MainActor.assumeIsolated { self?.handleWatchEvent(event) }
        }
    }

    private func preferencesDidChange() {
        guard let url else { return }
        guard !isClosed, Preferences.shared.values.watchFiles else {
            watcher?.stop()
            watcher = nil
            return
        }
        startWatching(url)
    }

    private func handleWatchEvent(_ event: FileWatcher.Event) {
        switch event {
        case .removed:
            onExternalEvent?(.fileRemoved)
        case .restored:
            onExternalEvent?(.fileRestored)
            handleExternalWrite()
        case .changed:
            handleExternalWrite()
        }
    }

    private func handleExternalWrite() {
        guard let url, let (incoming, freshFidelity) = try? DocumentIO.read(contentsOf: url) else { return }
        let incomingHash = SnapshotStore.hash(incoming)
        let currentText = storage.string
        guard incomingHash != SnapshotStore.hash(currentText) else {
            diskHash = incomingHash
            return
        }

        // A newline is a byte-fidelity property (`DocumentIO` reconciles it at
        // save time), not document content.  If the on-disk bytes differ from
        // the buffer only by the presence of a final newline — the common case
        // is an external tool touching the file while the user trimmed its
        // trailing newline — rewriting the buffer wholesale would silently
        // restore the newline and revert that edit.  Acknowledge the disk state
        // and keep the buffer.
        if finalNewlineDifferenceOnly(currentText, incoming) {
            diskHash = incomingHash
            fidelity = freshFidelity
            return
        }

        SnapshotStore.shared.record(incoming, for: url, kind: .external)
        let hunks = TextDiff.hunks(old: currentText, new: incoming)
        diskHash = incomingHash

        if isDirty {  // Never clobber (§8.1).  The bar is non-modal; the buffer is
            // untouched until the user picks.  Track it at the document level
            // so implicit saves refuse to clobber even after the bar is
            // dismissed.
            let conflict = Conflict(
                incomingText: incoming, hunks: hunks, changedBlockCount: hunks.count
            )
            pendingConflict = conflict
            onExternalEvent?(.conflict(conflict))
            return
        }

        pendingConflict = nil
        fidelity = freshFidelity
        applyExternalText(incoming, hunks: hunks)
        onExternalEvent?(.applied(hunks: hunks))
    }

    /// Replaces the buffer in place, holding the reader's position by anchoring
    /// to the nearest unchanged heading rather than to a byte offset (§8.1).
    func applyExternalText(_ incoming: String, hunks: [ChangeHunk]) {
        // Adopting the on-disk version resolves any outstanding conflict.
        pendingConflict = nil
        let topOffset = currentTopOffsetProvider?() ?? 0
        let anchor = ScrollAnchoring.anchor(for: topOffset, in: parsed)

        isApplyingExternalChange = true
        let whole = NSRange(location: 0, length: storage.length)
        // Registered as undoable on purpose: ⌘Z reverts an agent's rewrite,
        // which is the fastest possible answer to "no, put it back".
        replace(whole, with: incoming, actionName: "External Change")
        isApplyingExternalChange = false
        setDirty(false)

        reparseNow()
        changes.apply(hunks: hunks)

        let restored = ScrollAnchoring.offset(for: anchor, in: parsed)
        restoreOffsetHandler?(restored)
    }

    /// Conflict resolution: take the version on disk, dropping local edits.
    func resolveConflictTakingTheirs(_ conflict: Conflict) {
        applyExternalText(conflict.incomingText, hunks: conflict.hunks)
    }

    /// Conflict resolution: keep the buffer and write it over the file.
    @discardableResult
    func resolveConflictKeepingMine() -> Result<Void, Error> {
        let result = saveIfNeeded(intent: .keepMine)
        if case .success = result {
            pendingConflict = nil
            changes.clear()
        }
        return result
    }

    // MARK: - Time travel (§8.3)

    func versions() -> [SnapshotStore.VersionRecord] {
        guard let url else { return [] }
        return SnapshotStore.shared.versions(for: url)
    }

    /// Restores a historical version into the buffer as a normal, undoable edit.
    func restore(version: SnapshotStore.VersionRecord) {
        guard let text = SnapshotStore.shared.text(for: version) else { return }
        let hunks = TextDiff.hunks(old: storage.string, new: text)
        replace(NSRange(location: 0, length: storage.length), with: text, actionName: "Restore Version")
        reparseNow()
        changes.apply(hunks: hunks)
    }
}

// MARK: - NSTextStorageDelegate

extension MarkdownDocument: NSTextStorageDelegate {
    nonisolated func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard !suppressReparse else { return }
            invalidateParseWorkForEdit()
            if !isApplyingExternalChange {
                setDirty(true)
            }
            scheduleReparse()
        }
    }
}
