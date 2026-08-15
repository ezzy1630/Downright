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

/// Owns the command boundary AppKit otherwise keeps private.  Storage delegate
/// callbacks arrive after the text system has already started moving the
/// selection, which is too late to remember the reader's camera.
@MainActor
final class MarkdownUndoManager: UndoManager {
    var onWillApplyUndoRedo: (() -> Void)?
    var onDidApplyUndoRedo: (() -> Void)?
    private(set) var isApplyingUndoRedo = false

    override func undo() {
        onWillApplyUndoRedo?()
        isApplyingUndoRedo = true
        defer {
            isApplyingUndoRedo = false
            onDidApplyUndoRedo?()
        }
        super.undo()
    }

    override func redo() {
        onWillApplyUndoRedo?()
        isApplyingUndoRedo = true
        defer {
            isApplyingUndoRedo = false
            onDidApplyUndoRedo?()
        }
        super.redo()
    }
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

    /// What the app can say about changes made since the reader last reviewed
    /// this document (§8.2).
    ///
    /// The third case is the point: the bytes moved, the previous text has been
    /// pruned, and the honest answer is "this changed since you last read it,
    /// but I can no longer show you what" — not silence.
    enum UnreadChanges: Equatable {
        case none
        case marked(count: Int)
        case previousVersionUnavailable(reason: Unavailable)

        /// Why the previous text cannot be shown.  Worth distinguishing: one is
        /// a normal consequence of the retention settings, the other is damage.
        enum Unavailable: Equatable {
            /// Dropped by the age or size cap.
            case pruned
            /// The object is there but does not decompress or does not hash
            /// back to its own name.
            case corrupt
        }
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

    /// The document as the reader last **finished reviewing** it.
    ///
    /// Every incoming external write is diffed against this, never against the
    /// live buffer.  Diffing against the buffer meant that after an agent wrote
    /// five times in three seconds the marks described write 5 against write 4
    /// and everything writes 1–4 did had vanished.  Only a user action moves
    /// this baseline forward — see `advanceReviewBaseline(to:)`.
    private(set) var reviewBaselineText: String = ""
    private(set) var reviewBaselineHash: String = ""
    /// What can be said about changes since that baseline, including the
    /// degraded case where the previous text is no longer in the store.
    private(set) var unreadChanges: UnreadChanges = .none

    let changes = ChangeTracker()
    var state: DocumentState
    let undoManager = MarkdownUndoManager()

    /// Fires after every reparse with the set of blocks needing re-decoration.
    var onReparse: ((ParsedDocument, DirtySet) -> Void)?
    /// Fires before a command mutates the shared storage. Text views use this
    /// boundary to capture their source camera before AppKit can relayout it.
    var onWillApplyEdits: (([TextEdit]) -> Void)?
    /// Fired on the main actor when an async reparse becomes pending or
    /// drains.  Drives the toolbar activity cue for sustained work — a parse
    /// that runs past a second should not be silent.
    var onParseActivity: ((Bool) -> Void)?
    var onExternalEvent: ((ExternalEvent) -> Void)?
    var onDirtyChanged: ((Bool) -> Void)?
    /// Undo and redo mutate storage outside `MarkdownTextView`'s source-edit
    /// path. The owner uses this boundary to lock every visible viewport before
    /// the synchronous reparse changes layout.
    var onWillApplyUndoRedo: (() -> Void)? {
        didSet { undoManager.onWillApplyUndoRedo = onWillApplyUndoRedo }
    }
    /// Called when a save reaches the disk boundary and fails.  The buffer and
    /// dirty state remain untouched so the controller can offer recovery.
    var onSaveFailure: ((Error) -> Void)?
    /// Asked for the source offset at the top of the viewport, so an external
    /// rewrite can restore the reader's place by heading anchor (§8.1).
    var currentTopOffsetProvider: (() -> Int)?
    /// Asked to scroll to a source offset after an external rewrite.
    var restoreOffsetHandler: ((Int) -> Void)?
    /// Asked for the current source selection, and asked to put it back after
    /// an external rewrite.  A burst of agent writes must not eat the reader's
    /// selection five times over.
    var currentSelectionProvider: (() -> NSRange)?
    var restoreSelectionHandler: ((NSRange) -> Void)?
    /// True while a burst of external writes is still landing, false once the
    /// document has settled.  Drives a "receiving changes" cue rather than five
    /// separate "1 new change" banners.
    var onExternalWriteActivity: ((Bool) -> Void)?
    /// The watched file was renamed or moved.  Separate from `onExternalEvent`
    /// on purpose: this is an identity change, not content to reconcile, and
    /// the owner has different work to do (title, represented URL, path
    /// resolution, sibling scan).
    var onFileRenamed: ((URL) -> Void)?

    private var watcher: FileWatcher?
    /// Trailing quiet-period debounce for external writes.  See
    /// `handleExternalWrite()`.
    private var pendingExternalWrite: DispatchWorkItem?
    private var isAbsorbingBurst = false
    private var reparseScheduled = false
    private var isApplyingExternalChange = false
    private var isApplyingBatch = false
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
        undoManager.onDidApplyUndoRedo = { [weak self] in
            self?.finishUndoRedo()
        }
        // Clearing marks *is* finishing a review, wherever the call comes from,
        // so the baseline moves with it and the next agent write is measured
        // from what the user just signed off on.
        changes.onReviewed = { [weak self] in
            guard let self else { return }
            self.advanceReviewBaseline(to: self.storage.string)
        }
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
        // Canonicalise once, up front.  A `.atomic` write renames a new file
        // over the destination, which would *replace a symlink with a regular
        // file* while the link's target kept its stale content.  Resolving here
        // makes the identity, the watcher, and the write path agree, so saving
        // a file opened through a symlink edits the target it points at rather
        // than clobbering the link itself (§8.1).
        let canonical = fileURL.resolvingSymlinksInPath()
        // Read before touching any state: a file that vanishes between the
        // link-follow and the read must leave the document exactly as the
        // caller's `close()` left it, not half-torn-down.
        let (text, fidelity) = try DocumentIO.read(contentsOf: canonical)

        isClosed = false
        enqueueParseControl { await $0.resume() }
        cancelParseWork()
        cancelPendingExternalWrite()
        // In-place hops reuse this document; change marks from the previous
        // file must not decorate the next one.  `reset`, not `clear`: dropping
        // a document is not the user reviewing it.
        changes.reset()
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

        restoreReviewState(currentText: text)

        startWatching(canonical)
        forceNextDirtyWholesale = true
        startAsyncReparse()
    }

    // MARK: - Review baseline (§8.1, §8.2)

    /// Rebuilds the unread-changes picture on open.
    ///
    /// Three independent questions, answered in order, because the old code
    /// collapsed them into one `guard` and answered "nothing changed" whenever
    /// any of them failed:
    ///
    /// 1. **Did the bytes move since the reader last reviewed?**  A hash
    ///    comparison, made without touching the object store, so a pruned
    ///    object can never be mistaken for an unchanged file.
    /// 2. **Can the previous text still be shown?**  If not, say so
    ///    (`previousVersionUnavailable`) instead of showing nothing at all.
    /// 3. **What did the reader already work through?**  Persisted marks carry
    ///    the visited flags back, so reopening a document does not silently
    ///    count twelve unreviewed changes as read.
    private func restoreReviewState(currentText: String) {
        let storedBaseline = state.reviewBaselineHash.isEmpty
            ? state.lastSeenHash
            : state.reviewBaselineHash

        guard !storedBaseline.isEmpty, storedBaseline != diskHash else {
            // Nothing outstanding: the file is exactly as the reader left it.
            adoptBaseline(text: currentText, hash: diskHash)
            changes.reset()
            unreadChanges = .none
            return
        }

        let stored = SnapshotStore.shared.content(forHash: storedBaseline)
        guard case .text(let previous) = stored else {
            // The file moved and the old text is gone.  Keep the baseline hash
            // so a later write is still measured from the right place, and let
            // the owner say what happened.
            reviewBaselineText = ""
            reviewBaselineHash = storedBaseline
            changes.reset()
            unreadChanges = .previousVersionUnavailable(reason: stored == .corrupt ? .corrupt : .pruned)
            return
        }

        adoptBaseline(text: previous, hash: storedBaseline)
        let hunks = TextDiff.hunks(old: previous, new: currentText)
        guard !hunks.isEmpty else {
            changes.reset()
            unreadChanges = .none
            return
        }
        changes.apply(hunks: hunks, newText: currentText, oldText: previous)
        // Re-anchor the persisted set over the freshly computed one so review
        // progress survives the close/reopen: same kind, same range, same mark.
        changes.merge(persisted: state.marks)
        unreadChanges = .marked(count: changes.count)
    }

    private func adoptBaseline(text: String, hash: String) {
        reviewBaselineText = text
        reviewBaselineHash = hash
    }

    /// Moves the review baseline forward.  **Only user actions call this**:
    /// finishing a review, keeping their own version in a conflict, restoring a
    /// historical version, or opening a document that has nothing outstanding.
    /// An incoming write must never advance it — that is the bug this whole
    /// mechanism exists to prevent.
    func advanceReviewBaseline(to text: String) {
        adoptBaseline(text: text, hash: SnapshotStore.hash(text))
        unreadChanges = .none
        state.reviewBaselineHash = reviewBaselineHash
        state.marks = []
    }

    /// The explicit "I have read these" action.  Equivalent to `changes.clear()`
    /// — which routes here through `ChangeTracker.onReviewed` — but named so a
    /// call site reads as intent rather than as cleanup.
    func markChangesReviewed() {
        changes.clear()
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
        cancelPendingExternalWrite()
        // Persist *before* discarding: closing a window is not a review, and the
        // twelve marks the reader had not looked at yet must come back.
        persistState()
        // Discard change marks owned by a torn-down document so they cannot
        // leak across to the next file opened in the same window.
        changes.reset()
        enqueueParseControl { await $0.suspend() }
        watcher?.stop()
        watcher = nil
    }

    private func persistState() {
        guard let url else { return }
        var state = self.state
        // `lastSeenHash` is disk bookkeeping and moves with every absorbed
        // write.  `reviewBaselineHash` is the reader's place in the review and
        // moves only when they say so — the two must never be conflated.
        state.lastSeenHash = diskHash
        state.reviewBaselineHash = reviewBaselineHash
        state.marks = changes.persistedMarks
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

        if !isApplyingBatch && !undoManager.isApplyingUndoRedo {
            onWillApplyEdits?([
                TextEdit(
                    range: range,
                    replacement: replacement,
                    summary: actionName ?? "Edit"
                )
            ])
        }

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
        var accepted: [TextEdit] = []
        var lastStart = Int.max
        for edit in ordered {
            guard edit.range.upperBound <= lastStart else { continue }
            accepted.append(edit)
            lastStart = edit.range.location
        }
        guard !accepted.isEmpty else { return }

        onWillApplyEdits?(accepted)
        isApplyingBatch = true
        defer { isApplyingBatch = false }
        undoManager.beginUndoGrouping()
        for edit in accepted {
            replace(edit.range, with: edit.replacement, actionName: nil)
        }
        undoManager.setActionName(actionName)
        undoManager.endUndoGrouping()
        // Structural commands are explicit transactions. Converge their tree
        // before returning so the renderer never spends an event-loop turn in
        // raw Markdown after the command has already completed.
        reparseNow()
    }

    /// Toggling a checkbox writes the file immediately (§7.1, §8.5).
    func toggleTask(atMarkOffset offset: Int) {
        ensureParsedCurrent()
        guard let edit = Restructure.toggleTask(parsed, atMarkOffset: offset) else { return }
        apply([edit], actionName: "Toggle Task")
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

    private func finishUndoRedo() {
        guard parsed.text != storage.string else { return }
        // A grouped undo/redo can invoke several inverse closures. Keep the
        // renderer suspended for the whole transaction, then publish exactly
        // one parsed/display-map repair after AppKit has finished mutating the
        // shared storage.
        reparseNow()
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

    private func cancelPendingExternalWrite() {
        pendingExternalWrite?.cancel()
        pendingExternalWrite = nil
        endBurstIfNeeded()
    }

    private func endBurstIfNeeded() {
        guard isAbsorbingBurst else { return }
        isAbsorbingBurst = false
        onExternalWriteActivity?(false)
    }

    private func handleWatchEvent(_ event: FileWatcher.Event) {
        // `FileWatcher` dispatches to the main queue; a block already in
        // flight when `close()` ran cannot be retracted, and `stop()` only
        // cancels work that has not started.  A late event on a closed
        // document would schedule a fresh absorb and fire external-change UI
        // on a window that is going away — the same guard `startAsyncReparse`
        // and `preferencesDidChange` already apply.
        guard !isClosed else { return }
        switch event {
        case .removed:
            onExternalEvent?(.fileRemoved)
        case .restored:
            onExternalEvent?(.fileRestored)
            handleExternalWrite()
        case .changed:
            handleExternalWrite()
        case .renamed(let newURL):
            adoptRenamedFile(newURL)
        }
    }

    /// The file was renamed under us and the watcher re-attached.  Move the
    /// document's identity with it so reading position, history, and the
    /// window's own idea of what it is showing all keep pointing at one file.
    private func adoptRenamedFile(_ newURL: URL) {
        guard url != nil else { return }
        let canonical = newURL.resolvingSymlinksInPath()
        guard canonical != url else { return }
        url = canonical
        state.path = canonical.path
        DocumentStateStore.shared.save(state, for: canonical)
        // Seed the new key's history with what we are holding, so the timeline
        // does not start empty at the new name.
        SnapshotStore.shared.record(storage.string, for: canonical, kind: .baseline)
        onFileRenamed?(canonical)
    }

    /// Trailing quiet-period debounce.
    ///
    /// `FileWatcher` already coalesces at 300 ms, but an agent that writes a
    /// file five times over three seconds clears that window between writes, so
    /// each one arrived as its own full-buffer replace, synchronous reparse and
    /// scroll restore — the document visibly rebuilding five times while the
    /// reader was mid-sentence.  Hold off until nothing has landed for 250 ms
    /// and absorb once.  Nothing is buffered: the flush re-reads the file, so
    /// it always applies the newest bytes rather than a stale copy.
    ///
    /// Internal rather than private so tests can drive an agent's write burst
    /// without racing a real filesystem watcher.
    func handleExternalWrite() {
        pendingExternalWrite?.cancel()
        if !isAbsorbingBurst {
            isAbsorbingBurst = true
            onExternalWriteActivity?(true)
        }
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.absorbExternalWrite() }
        }
        pendingExternalWrite = item
        DispatchQueue.main.asyncAfter(deadline: .now() + externalWriteQuietPeriod, execute: item)
    }

    private let externalWriteQuietPeriod: TimeInterval = 0.25

    /// Applies any external write still waiting on the quiet period.  Tests and
    /// lifecycle code use this instead of guessing at wall-clock timing.
    func flushPendingExternalWrite() {
        guard pendingExternalWrite != nil else { return }
        pendingExternalWrite?.cancel()
        pendingExternalWrite = nil
        absorbExternalWrite()
    }

    private func absorbExternalWrite() {
        pendingExternalWrite = nil
        defer { endBurstIfNeeded() }
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
        diskHash = incomingHash

        if isDirty {  // Never clobber (§8.1).  The bar is non-modal; the buffer is
            // untouched until the user picks.  Track it at the document level
            // so implicit saves refuse to clobber even after the bar is
            // dismissed.
            //
            // A conflict is diffed against the *buffer*, not against the review
            // baseline: the question on screen is "my version or theirs", and
            // the reader's own unsaved edits are one side of it.
            let hunks = TextDiff.hunks(old: currentText, new: incoming)
            let conflict = Conflict(
                incomingText: incoming, hunks: hunks, changedBlockCount: hunks.count
            )
            pendingConflict = conflict
            onExternalEvent?(.conflict(conflict))
            return
        }

        // The clean-buffer case is diffed against the review baseline.  This is
        // the fix for "five writes in three seconds": every one of them reports
        // what changed since the reader last looked, so writes 1–4 do not
        // disappear behind write 5.
        let baseline = effectiveBaselineText(fallback: currentText)
        let hunks = TextDiff.hunks(old: baseline, new: incoming)

        pendingConflict = nil
        fidelity = freshFidelity
        applyExternalText(incoming, hunks: hunks, baseline: baseline)
        unreadChanges = changes.isEmpty ? .none : .marked(count: changes.count)
        onExternalEvent?(.applied(hunks: hunks))
    }

    /// The text to diff an incoming write against.  Falls back to the buffer
    /// when the baseline text is unavailable (pruned history), which degrades
    /// to the old behaviour rather than to no marks at all.
    private func effectiveBaselineText(fallback: String) -> String {
        reviewBaselineText.isEmpty ? fallback : reviewBaselineText
    }

    /// Replaces the buffer in place, holding the reader's position by anchoring
    /// to the nearest unchanged heading rather than to a byte offset (§8.1),
    /// and putting the selection back afterwards.
    func applyExternalText(_ incoming: String, hunks: [ChangeHunk], baseline: String? = nil) {
        // Adopting the on-disk version resolves any outstanding conflict.
        pendingConflict = nil
        let topOffset = currentTopOffsetProvider?() ?? 0
        let anchor = ScrollAnchoring.anchor(for: topOffset, in: parsed)
        let previousText = storage.string
        let previousSelection = currentSelectionProvider?() ?? NSRange(location: 0, length: 0)

        adoptExternalBuffer(incoming)
        setDirty(false)

        reparseNow()
        changes.apply(hunks: hunks, newText: incoming, oldText: baseline ?? previousText)

        let restored = ScrollAnchoring.offset(for: anchor, in: parsed)
        restoreOffsetHandler?(restored)
        restoreSelection(previousText, previousSelection, near: restored)
    }

    /// Puts the buffer's whole contents behind an external write, with an undo
    /// that says what it is doing.
    ///
    /// ⌘Z reverting an agent's rewrite is the fastest possible answer to "no,
    /// put it back" and must keep working.  What it must *not* do is quietly
    /// leave a dirty buffer while `diskHash` still holds the agent's content —
    /// the next save then failed with a conflict the user could not connect to
    /// anything they had done.  So the undo restores the text *and* surfaces
    /// the disagreement it just created, through the same conflict bar that any
    /// other buffer-versus-disk disagreement uses.
    private func adoptExternalBuffer(_ incoming: String) {
        let previous = storage.string
        let whole = NSRange(location: 0, length: storage.length)

        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.revertExternalBuffer(to: previous, incoming: incoming)
            }
        }
        undoManager.setActionName("External Change")
        undoManager.endUndoGrouping()

        isApplyingExternalChange = true
        storage.beginEditing()
        storage.replaceCharacters(in: whole, with: incoming)
        storage.endEditing()
        isApplyingExternalChange = false
    }

    /// Undo of an external absorb.  The buffer goes back to what the reader had;
    /// the file on disk still holds the agent's version, so that is an
    /// unresolved conflict and is shown as one.
    private func revertExternalBuffer(to previous: String, incoming: String) {
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                document.adoptExternalBuffer(incoming)
                document.setDirty(false)
                document.pendingConflict = nil
                document.reparseNow()
            }
        }
        undoManager.setActionName("External Change")
        undoManager.endUndoGrouping()

        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: previous)
        storage.endEditing()
        reparseNow()
        changes.reset()
        setDirty(true)

        let hunks = TextDiff.hunks(old: previous, new: incoming)
        let conflict = Conflict(
            incomingText: incoming, hunks: hunks, changedBlockCount: hunks.count
        )
        pendingConflict = conflict
        unreadChanges = .none
        onExternalEvent?(.conflict(conflict))
    }

    /// Restores the reader's selection after the buffer was replaced.
    ///
    /// Matched on the selected *text* rather than on byte offsets, for the same
    /// reason the scroll position is anchored to a heading: an agent inserting
    /// two paragraphs above you must not move what you had selected.  A
    /// selection whose text is gone collapses to a caret at the restored
    /// reading position rather than jumping to the top of the file.
    private func restoreSelection(_ previousText: String, _ selection: NSRange, near offset: Int) {
        guard let restoreSelectionHandler else { return }
        let previous = previousText as NSString
        guard selection.length > 0, selection.upperBound <= previous.length,
              selection.length <= 4096 else {
            restoreSelectionHandler(NSRange(location: min(offset, storage.length), length: 0))
            return
        }
        let needle = previous.substring(with: selection)
        let haystack = storage.string as NSString
        let forward = haystack.range(
            of: needle,
            options: [.literal],
            range: NSRange(location: min(offset, haystack.length), length: haystack.length - min(offset, haystack.length))
        )
        let found = forward.location != NSNotFound
            ? forward
            : haystack.range(of: needle, options: [.literal, .backwards])
        restoreSelectionHandler(
            found.location != NSNotFound
                ? found
                : NSRange(location: min(offset, haystack.length), length: 0)
        )
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

    /// Whether a historical version can still be shown, so the timeline can
    /// distinguish "pruned" from "damaged" instead of showing an empty pane.
    func content(of version: SnapshotStore.VersionRecord) -> SnapshotStore.Content {
        SnapshotStore.shared.content(for: version)
    }

    /// Restores a historical version into the buffer as a normal, undoable edit.
    /// Choosing a version is a review decision, so the baseline moves with it:
    /// the next agent write is measured against what the user just chose.
    @discardableResult
    func restore(version: SnapshotStore.VersionRecord) -> Bool {
        guard case .text(let text) = SnapshotStore.shared.content(for: version) else { return false }
        let previous = storage.string
        let hunks = TextDiff.hunks(old: previous, new: text)
        replace(NSRange(location: 0, length: storage.length), with: text, actionName: "Restore Version")
        reparseNow()
        advanceReviewBaseline(to: text)
        changes.apply(hunks: hunks, newText: text, oldText: previous)
        unreadChanges = changes.isEmpty ? .none : .marked(count: changes.count)
        return true
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
        Task { @MainActor [weak self] in
            self?.handleTextStorageEdit()
        }
    }

    private func handleTextStorageEdit() {
        guard !suppressReparse else { return }
        // An explicit transaction may have already published its synchronous
        // parse before this delegate hop runs. Do not schedule a second parse
        // merely because NSTextStorage delivered the callback later.
        guard parsed.text != storage.string else { return }
        invalidateParseWorkForEdit()
        if !isApplyingExternalChange {
            setDirty(true)
        }
        if undoManager.isApplyingUndoRedo || isApplyingBatch {
            // The enclosing command/undo transaction publishes one coherent
            // parse after all storage edits have landed.
            return
        }
        if undoManager.isUndoing || undoManager.isRedoing {
            reparseSynchronously(notifying: true, wholesale: false)
            return
        }
        scheduleReparse()
    }
}
