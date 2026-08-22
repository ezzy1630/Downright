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
    /// Recreates a path that is missing or replaces one that cannot currently
    /// be read. This intent is only issued from the explicit recovery sheet;
    /// autosave, close, quit, and task toggles must never choose it.
    case recreateFile
}

enum SaveError: Error, LocalizedError {
    /// The save was refused because writing the buffer would clobber a newer
    /// on-disk version whose conflict had not been resolved.  The conflict has
    /// already been surfaced via `onExternalEvent`.
    case blockedByExternalConflict
    /// The document disappeared after it was opened. A normal save must not
    /// silently bring it back.
    case fileMissing(URL)
    /// The path still exists but could not be read, so overwriting it would be
    /// an uninformed destructive action.
    case fileUnreadable(URL, underlying: Error)

    var errorDescription: String? {
        switch self {
        case .blockedByExternalConflict:
            return "The file changed on disk. Review the conflict before saving."
        case .fileMissing:
            return "The original file is missing. Choose Save a Copy or explicitly recreate it."
        case .fileUnreadable(_, let error):
            return "The original file could not be read: \(error.localizedDescription)"
        }
    }
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
    /// The save boundary's complete view of the backing path. Read failures
    /// are data, not an absence of evidence: only `.unchanged` permits an
    /// implicit write.
    enum DiskState {
        case unchanged(data: Data, fidelity: ByteFidelity)
        case changed(text: String, hunks: [ChangeHunk], data: Data, fidelity: ByteFidelity)
        case missing
        case unreadable(Error)
    }

    /// One explicit state vocabulary for native chrome and accessibility.
    /// Provenance is intentionally a short action label rather than a second
    /// state machine; it is useful in a tooltip without cluttering the toolbar.
    struct PresentationState: Equatable {
        enum Phase: Equatable {
            case neutral
            case edited
            case saving
            case saved
            case changedOnDisk
            case conflict
            case saveFailed
        }

        var phase: Phase
        var provenance: String?
        var detail: String?

        static let neutral = PresentationState(phase: .neutral, provenance: nil, detail: nil)
    }
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
    /// Raw-byte generation token for save compare-and-swap. `diskHash` is a
    /// text/review identity and deliberately cannot distinguish BOM or CRLF.
    private var diskByteHash: String = ""
    /// Last text generation successfully read from or committed to disk.
    /// Recovery discard returns here rather than leaving discarded edits in a
    /// buffer that a later keystroke could accidentally make savable again.
    private var lastCommittedText: String = ""
    /// An external write the buffer has not yet been reconciled with.  Non-nil
    /// while a conflict bar is showing — and, critically, stays non-nil even if
    /// that bar is dismissed — so an implicit save never silently writes the
    /// buffer over the newer on-disk version.
    private(set) var pendingConflict: Conflict?
    private(set) var presentationState: PresentationState = .neutral

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
    /// Deterministic filesystem-race seam. Production never assigns it.
    var beforeSaveCommitForTesting: (() -> Void)?
    var onDirtyChanged: ((Bool) -> Void)?
    var onPresentationStateChanged: ((PresentationState) -> Void)?
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
    /// Invalidates background read/diff work when a newer filesystem event
    /// lands before the prepared snapshot reaches the main actor.
    private var externalPreparationGeneration: UInt64 = 0
    private var isAbsorbingBurst = false
    private var reparseScheduled = false
    private var isApplyingExternalChange = false
    /// NSTextStorage delivers its delegate callback on a later main-actor
    /// turn. Keep the resulting source text with each callback token so a
    /// local edit that lands before the callback cannot spend the token meant
    /// for the external transaction. This also lets a converged synchronous
    /// undo/redo consume its own callback instead of leaving a stale token
    /// behind for the next real edit.
    private var ignoredExternalStorageCallbackTexts: [String] = []
    /// Upper bound on unconsumed suppression tokens. Each one holds a
    /// whole-document string; the bound keeps a run of unmatched callbacks
    /// from accumulating unbounded state and keeps the exact-match scan in
    /// `handleTextStorageEdit` cheap.
    private static let maximumIgnoredExternalCallbackTexts = 8
    private var isApplyingBatch = false
    private var suppressReparse = false
    private let parseCoordinator: MarkdownParseCoordinator
    private let snapshotStore: SnapshotStore
    private let documentStateStore: DocumentStateStore
    private var parseTask: Task<Void, Never>?
    private var parseControlTask: Task<Void, Never>?
    private(set) var revision = MarkdownParseRevision.zero
    /// Most recent immutable snapshot accepted from the asynchronous parse
    /// lane. This distinguishes structure-only first paint from full parse
    /// convergence in diagnostics and rendered-window acceptance.
    private(set) var lastAsyncParseRevision: MarkdownParseRevision?
    private var isClosed = false
    private var preferencesObservation: NSObjectProtocol?
    private var savedStateWorkItem: DispatchWorkItem?
    private struct PendingExternalRestore {
        var previousText: String
        var selection: NSRange
        var anchor: ScrollAnchor
    }
    private var pendingExternalRestore: PendingExternalRestore?
    /// Source ranges actually mutated by an external reconciliation. Existing
    /// attributed runs move with an incremental NSTextStorage edit, so AST
    /// identity churn from shifted offsets must not force a document-wide
    /// redecorate.
    private var nextExternalDirtyOverride: DirtySet?
    /// After open's structure-only first paint, the next full async parse must
    /// restyle wholesale — structure trees are not decoration-compatible.
    private var forceNextDirtyWholesale = false

    // MARK: - Init

    override convenience init() {
        self.init(parseWorker: MarkdownParseWorker())
    }

    init(
        parseWorker: MarkdownParseWorker,
        snapshotStore: SnapshotStore = .shared,
        documentStateStore: DocumentStateStore = .shared
    ) {
        self.parseCoordinator = MarkdownParseCoordinator(worker: parseWorker)
        self.snapshotStore = snapshotStore
        self.documentStateStore = documentStateStore
        self.state = DocumentState(path: "")
        super.init()
        parseCoordinator.onBusyChange = { [weak self] busy in
            Task { @MainActor in self?.onParseActivity?(busy) }
        }
        storage.delegate = self
        undoManager.groupsByEvent = false
        // External rewrites can register whole-document undo payloads for as
        // long as a window remains open. Bound the stack like a conventional
        // editor so a busy file cannot grow memory without limit.
        undoManager.levelsOfUndo = 200
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
        savedStateWorkItem?.cancel()
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
        let snapshot = try DocumentIO.readSnapshot(contentsOf: canonical)
        let (text, fidelity) = (snapshot.text, snapshot.fidelity)

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
        self.state = documentStateStore.state(for: canonical)

        suppressReparse = true
        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: text)
        storage.endEditing()
        suppressReparse = false

        diskHash = DocumentIO.contentHash(text)
        diskByteHash = DocumentIO.contentHash(snapshot.data)
        lastCommittedText = text
        isDirty = false
        lastAsyncParseRevision = nil
        publishPresentationState(.neutral)

        // Structure-only first paint for outline/state. The controller paints
        // decorations after applying zoom/folds; full decoration converges on
        // the async parse lane.
        let structure = MarkdownParser.parse(text, options: .structureOnly)
        parsed = structure

        snapshotStore.record(text, for: canonical, kind: .baseline)
        documentStateStore.noteOpened(canonical, document: structure)

        restoreReviewState(currentText: text)

        startWatching(canonical)
        forceNextDirtyWholesale = true
        // First full paint must not depend on the serial typing lane's
        // resume/discard control messages for a document that may have just
        // been reused in place. The immutable revision gate makes this direct
        // parse safe, and subsequent edits return to the coalescing lane.
        startPriorityAsyncReparse()
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

        let stored = snapshotStore.content(forHash: storedBaseline)
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
        if !isDirty, pendingConflict == nil { publishPresentationState(.neutral) }
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
        publishPresentationState(.neutral)
    }

    func save(intent: SaveIntent = .normal) throws {
        // A closed document has no owner left to consent to a write.  Stragglers
        // (queued autosave work, occlusion events during teardown) must neither
        // touch the file nor raise a failure alert for a window that is gone.
        guard !isClosed else { return }
        guard let url else {
            let error = CocoaError(.fileNoSuchFile)
            publishSaveFailure(error)
            throw error
        }
        let text = storage.string

        // §8.1: a save that would overwrite a newer-on-disk version must not
        // happen silently.  Every implicit save path (occlusion autosave, quit,
        // checkbox toggle, close alert) funnels through here, and none of them
        // may make the keep-mine call for the user.  Surface any unresolved
        // conflict — or one detected right now — and refuse to write.
        var expectedDiskData: Data?
        if intent != .recreateFile {
            if intent == .normal, let conflict = pendingConflict {
                throw presentBlockingConflict(conflict, incoming: conflict.incomingText, incomingHash: nil)
            }
            switch inspectDiskState() {
            case .unchanged(let data, let freshFidelity):
                expectedDiskData = data
                fidelity = freshFidelity
            case .changed(let incoming, let hunks, let data, let freshFidelity):
                if intent == .normal {
                    let conflict = Conflict(
                        incomingText: incoming,
                        hunks: hunks,
                        changedBlockCount: hunks.count
                    )
                    throw presentBlockingConflict(
                        conflict, incoming: incoming,
                        incomingHash: SnapshotStore.hash(incoming)
                    )
                }
                // Keep Mine is explicit about content, not byte formatting.
                // Preserve the latest readable encoding/BOM/line-ending facts.
                expectedDiskData = data
                fidelity = freshFidelity
            case .missing:
                let error = SaveError.fileMissing(url)
                publishSaveFailure(error)
                throw error
            case .unreadable(let underlying):
                let error = SaveError.fileUnreadable(url, underlying: underlying)
                publishSaveFailure(error)
                throw error
            }
        } else {
            // The recovery choice authorizes creation only while the path is
            // still missing/unreadable. If a readable generation has appeared
            // since the sheet was shown, it is external state and wins.
            switch inspectDiskState() {
            case .missing, .unreadable:
                break
            case .unchanged(let data, let freshFidelity):
                expectedDiskData = data
                fidelity = freshFidelity
            case .changed(let incoming, let hunks, _, _):
                let conflict = Conflict(
                    incomingText: incoming, hunks: hunks, changedBlockCount: hunks.count
                )
                throw presentBlockingConflict(
                    conflict, incoming: incoming, incomingHash: SnapshotStore.hash(incoming)
                )
            }
        }

        publishPresentationState(PresentationState(
            phase: .saving, provenance: presentationState.provenance, detail: nil
        ))
        let encoded: Data
        do {
            encoded = try DocumentIO.encodedData(text, fidelity: fidelity)
        } catch {
            publishSaveFailure(error)
            throw error
        }
        beforeSaveCommitForTesting?()
        watcher?.suppressOwnWrite()
        do {
            if let expectedDiskData {
                try DocumentIO.replaceExistingAtomically(
                    with: encoded, at: url, expected: expectedDiskData
                )
            } else {
                // Only the explicit Recreate File recovery action may create
                // or replace without an inspected existing generation.
                try encoded.write(to: url, options: .atomic)
            }
        } catch {
            watcher?.cancelOwnWriteSuppression()
            if let ioError = error as? DocumentIOError,
               case .targetChanged(_, let generations) = ioError {
                for data in generations {
                    if let decoded = try? DocumentIO.decodeSnapshot(data, sourceURL: url) {
                        snapshotStore.record(decoded.text, for: url, kind: .external)
                    }
                }
            }
            switch inspectDiskState() {
            case .changed(let incoming, let hunks, _, _):
                let conflict = Conflict(
                    incomingText: incoming, hunks: hunks, changedBlockCount: hunks.count
                )
                throw presentBlockingConflict(
                    conflict, incoming: incoming, incomingHash: SnapshotStore.hash(incoming)
                )
            case .missing:
                let missing = SaveError.fileMissing(url)
                publishSaveFailure(missing)
                throw missing
            case .unreadable(let underlying):
                let unreadable = SaveError.fileUnreadable(url, underlying: underlying)
                publishSaveFailure(unreadable)
                throw unreadable
            case .unchanged:
                break
            }
            publishSaveFailure(error)
            throw error
        }
        watcher?.acknowledgeOwnWrite(contents: encoded)

        diskHash = DocumentIO.contentHash(text)
        diskByteHash = DocumentIO.contentHash(encoded)
        lastCommittedText = text
        pendingConflict = nil
        snapshotStore.record(text, for: url, kind: .local)
        setDirty(false)
        persistState()
        publishSavedState()
    }

    /// Re-reads the path at the write boundary. Missing and unreadable are
    /// distinct fail-closed states, never collapsed into "no change".
    func inspectDiskState() -> DiskState {
        guard let url else { return .missing }
        let snapshot: (text: String, fidelity: ByteFidelity, data: Data)
        do {
            snapshot = try DocumentIO.readSnapshot(contentsOf: url)
        } catch {
            if !FileManager.default.fileExists(atPath: url.path) {
                return .missing
            }
            return .unreadable(error)
        }
        let incoming = snapshot.text
        let incomingHash = SnapshotStore.hash(incoming)
        let incomingByteHash = DocumentIO.contentHash(snapshot.data)
        guard incomingByteHash != diskByteHash else {
            return .unchanged(data: snapshot.data, fidelity: snapshot.fidelity)
        }
        // The decoded generation is still the one we opened; only its byte
        // representation changed externally. Adopt those facts even when the
        // buffer has local edits, so the edit is saved using the latest BOM,
        // encoding, and line endings rather than silently reverting them.
        if incomingHash == diskHash {
            diskByteHash = incomingByteHash
            fidelity = snapshot.fidelity
            return .unchanged(data: snapshot.data, fidelity: snapshot.fidelity)
        }
        // If the disk already holds the buffer's bytes, writing is a no-op and
        // there is nothing being clobbered.  A trailing-newline-only difference
        // is likewise not a content change: it is an artifact `DocumentIO` will
        // reconcile on this very write, so it must not surface as a conflict or
        // block an autosave.
        guard incomingHash != SnapshotStore.hash(storage.string) else {
            diskHash = incomingHash
            diskByteHash = incomingByteHash
            fidelity = snapshot.fidelity
            return .unchanged(data: snapshot.data, fidelity: snapshot.fidelity)
        }
        return .changed(
            text: incoming,
            hunks: TextDiff.hunks(old: storage.string, new: incoming),
            data: snapshot.data,
            fidelity: snapshot.fidelity
        )
    }

    /// True when `a` and `b` differ only by the presence of a single trailing
    /// newline (LF, CRLF or lone CR are all counted).  Used to treat the final
    /// newline as byte-fidelity rather than as content, so an external absorb
    /// never reverts the user's trailing-newline edit and a save never blocks
    /// on a phantom conflict for one.
    private func finalNewlineDifferenceOnly(_ a: String, _ b: String) -> Bool {
        Self.finalNewlineDifferenceOnlyValue(a, b)
    }

    nonisolated private static func finalNewlineDifferenceOnlyValue(
        _ a: String,
        _ b: String
    ) -> Bool {
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
        if let url { snapshotStore.record(incoming, for: url, kind: .external) }
        publishPresentationState(PresentationState(
            phase: .conflict,
            provenance: presentationState.provenance,
            detail: "Changed on disk"
        ))
        onExternalEvent?(.conflict(conflict))
        return .blockedByExternalConflict
    }

    @discardableResult
    func saveIfNeeded(intent: SaveIntent = .normal) -> Result<Void, Error> {
        // Same lifetime rule as save(): after close() the document is inert.
        // Reporting success here keeps straggler implicit saves silent instead
        // of surfacing errors for a window that no longer exists.
        guard !isClosed else { return .success(()) }
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

    /// Explicit recovery action. No implicit path may call this.
    func recreateMissingFile() -> Result<Void, Error> {
        do {
            try save(intent: .recreateFile)
            return .success(())
        } catch {
            return .failure(error)
        }
    }

    /// Explicitly abandons unsaved local changes after a failed save. The
    /// in-memory text remains visible until the window closes, but it is no
    /// longer eligible for autosave and the missing path is never resurrected.
    func discardUnsavedChanges() {
        let replacement: String
        if let url, let snapshot = try? DocumentIO.readSnapshot(contentsOf: url) {
            replacement = snapshot.text
            fidelity = snapshot.fidelity
            diskHash = DocumentIO.contentHash(snapshot.text)
            diskByteHash = DocumentIO.contentHash(snapshot.data)
            lastCommittedText = snapshot.text
        } else {
            replacement = lastCommittedText
        }
        suppressReparse = true
        storage.beginEditing()
        storage.replaceCharacters(
            in: NSRange(location: 0, length: storage.length), with: replacement
        )
        storage.endEditing()
        suppressReparse = false
        undoManager.removeAllActions()
        reparseSynchronously(notifying: true, wholesale: true)
        pendingConflict = nil
        setDirty(false)
        publishPresentationState(.neutral)
    }

    func close() {
        isClosed = true
        savedStateWorkItem?.cancel()
        pendingExternalRestore = nil
        cancelParseWork()
        cancelPendingExternalWrite()
        // Persist *before* discarding: closing a window is not a review, and the
        // twelve marks the reader had not looked at yet must come back.
        persistState()
        // Discard change marks owned by a torn-down document so they cannot
        // leak across to the next file opened in the same window.
        changes.reset()
        // Undo registrations target `self`, so every entry retains the whole
        // document (storage, parsed tree, watcher reference). A closed
        // document can never serve another undo, and without this the stack
        // keeps it — and everything it holds — un-deallocable.
        undoManager.removeAllActions()
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
        documentStateStore.save(state, for: url)
    }

    /// Restores the reader's place from persisted state (§8.2).
    func restoredOffset() -> Int {
        ScrollAnchoring.offset(for: state.anchor, in: parsed)
    }

    /// Keep reference-valued fragment metadata aligned with the storage while
    /// the parser works on its immutable snapshot.  Mirrors the projection in
    /// MarkdownTextView's editing funnel so document-level mutations (commands,
    /// undo/redo, external absorption) cannot leave payloads pointing at
    /// pre-edit offsets.
    private func projectFragmentPayloads(across range: NSRange, insertedLength: Int) {
        var seen = Set<ObjectIdentifier>()
        let start = max(0, min(range.location, storage.length))
        storage.enumerateAttribute(
            .drFragment,
            in: NSRange(location: start, length: storage.length - start)
        ) { value, _, _ in
            guard let payload = value as? FragmentPayload else { return }
            let identity = ObjectIdentifier(payload)
            guard seen.insert(identity).inserted else { return }
            payload.projectSourceRanges(across: range, insertedLength: insertedLength)
        }
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

        // Attribute runs move with the storage edit, but the fragment payload
        // objects riding on them are reference values whose ranges do not.
        // Project them across this edit exactly as MarkdownTextView does for
        // its own editing funnel; otherwise every unchanged block below an
        // insertion keeps pointing at pre-edit offsets until some later edit
        // happens to redecorate it (stale code-block copies, image loads
        // invalidating the wrong range).
        projectFragmentPayloads(across: range, insertedLength: (replacement as NSString).length)
        storage.beginEditing()
        storage.replaceCharacters(in: range, with: replacement)
        storage.endEditing()

        let delta = (replacement as NSString).length - range.length
        changes.adjust(forEditIn: range, delta: delta)
        if !isApplyingExternalChange {
            noteMutation(undoManager.isApplyingUndoRedo ? "Undo" : (actionName ?? "Edit"))
            setDirty(true)
        }
        return true
    }

    /// Applies structural-command edits as one explicit transaction.
    ///
    /// When `tidyRules` is given, the transaction follows the documented
    /// sequence — apply edit, reparse, plan tidy rules, apply tidy edit — all
    /// inside the *same* undo group, so ⌘Z undoes the command and its
    /// automatic repair together (§6.4: indenting renumbers ordered lists).
    func apply(_ edits: [TextEdit], actionName: String, tidyRules: Set<TidyRule>? = nil) {
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

        noteMutation(actionName)
        onWillApplyEdits?(accepted)
        isApplyingBatch = true
        defer { isApplyingBatch = false }
        undoManager.beginUndoGrouping()
        for edit in accepted {
            replace(edit.range, with: edit.replacement, actionName: nil)
        }
        if let tidyRules, !tidyRules.isEmpty {
            // Reparse silently mid-batch: the plan must see the tree as the
            // landed edits shape it, and the trailing `reparseNow()` below
            // remains the single notification point.
            reparseSynchronously(notifying: false, wholesale: false)
            var tidyLastStart = Int.max
            for edit in TidyDocument.plan(parsed, rules: tidyRules)
                .sorted(by: { $0.range.location > $1.range.location }) {
                guard edit.range.upperBound <= tidyLastStart,
                      edit.range.upperBound <= storage.length
                else { continue }
                tidyLastStart = edit.range.location
                replace(edit.range, with: edit.replacement, actionName: nil)
            }
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
        if value, presentationState.phase != .conflict {
            publishPresentationState(PresentationState(
                phase: .edited,
                provenance: presentationState.provenance ?? "Edit",
                detail: nil
            ))
        }
    }

    /// Records the human-scale action that most recently changed source. This
    /// is deliberately callable from view/controller seams (Paste, Replace,
    /// panel actions) while parser and layout callbacks have no access to it.
    func noteMutation(_ provenance: String) {
        let value = provenance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        publishPresentationState(PresentationState(
            phase: isDirty ? .edited : presentationState.phase,
            provenance: value,
            detail: presentationState.detail
        ))
    }

    private func publishPresentationState(_ state: PresentationState) {
        savedStateWorkItem?.cancel()
        savedStateWorkItem = nil
        guard state != presentationState else { return }
        presentationState = state
        onPresentationStateChanged?(state)
    }

    private func publishSaveFailure(_ error: Error) {
        publishPresentationState(PresentationState(
            phase: .saveFailed,
            provenance: presentationState.provenance,
            detail: error.localizedDescription
        ))
        onSaveFailure?(error)
    }

    private func publishSavedState() {
        let provenance = presentationState.provenance
        publishPresentationState(PresentationState(
            phase: .saved, provenance: provenance, detail: nil
        ))
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.isDirty, self.pendingConflict == nil else { return }
                self.publishPresentationState(.neutral)
            }
        }
        savedStateWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.25, execute: item)
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

    func reparseNow(wholesale: Bool = false) {
        reparseScheduled = false
        reparseSynchronously(notifying: true, wholesale: wholesale)
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

    /// External replacement must not wait behind an obsolete, non-cancellable
    /// initial parse. Run this one snapshot concurrently and rely on the same
    /// immutable revision/text checks used by the serial typing lane.
    private func startPriorityAsyncReparse() {
        guard !suppressReparse, !isClosed else { return }
        let request = MarkdownParseRequest(
            text: storage.string,
            previous: parsed,
            revision: revision
        )
        let coordinator = parseCoordinator
        Task.detached(priority: .userInitiated) { [weak self, coordinator] in
            let result = await coordinator.runImmediately(request)
            await self?.applyAsyncParse(result)
        }
    }

    private func applyAsyncParse(_ result: MarkdownParseResult) {
        guard !isClosed,
              result.revision == revision,
              result.text == storage.string,
              result.document.text == result.text else { return }
        parsed = result.document
        lastAsyncParseRevision = result.revision
        let dirty = nextExternalDirtyOverride
            ?? (forceNextDirtyWholesale ? DirtySet.wholesale : result.dirty)
        nextExternalDirtyOverride = nil
        forceNextDirtyWholesale = false
        onReparse?(result.document, dirty)
        if let restore = pendingExternalRestore {
            pendingExternalRestore = nil
            let restored = ScrollAnchoring.offset(for: restore.anchor, in: result.document)
            restoreOffsetHandler?(restored)
            restoreSelection(restore.previousText, restore.selection, near: restored)
        }
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

    func handleWatchEvent(_ event: FileWatcher.Event) {
        // `FileWatcher` dispatches to the main queue; a block already in
        // flight when `close()` ran cannot be retracted, and `stop()` only
        // cancels work that has not started.  A late event on a closed
        // document would schedule a fresh absorb and fire external-change UI
        // on a window that is going away — the same guard `startAsyncReparse`
        // and `preferencesDidChange` already apply.
        guard !isClosed else { return }
        switch event {
        case .removed:
            publishPresentationState(PresentationState(
                phase: .changedOnDisk,
                provenance: presentationState.provenance,
                detail: "File missing"
            ))
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
        documentStateStore.save(state, for: canonical)
        // Seed the new key's history with what we are holding, so the timeline
        // does not start empty at the new name.
        snapshotStore.record(storage.string, for: canonical, kind: .baseline)
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
        externalPreparationGeneration &+= 1
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

    private struct PreparedExternalWrite: @unchecked Sendable {
        let generation: UInt64
        let url: URL
        let capturedText: String
        let baseline: String
        let incoming: String
        let fidelity: ByteFidelity
        let incomingHash: String
        let incomingByteHash: String
        let baselineHunks: [ChangeHunk]
        let applicationHunks: [ChangeHunk]
    }

    private func absorbExternalWrite() {
        pendingExternalWrite = nil
        guard let url else {
            endBurstIfNeeded()
            return
        }
        let generation = externalPreparationGeneration
        let capturedText = storage.string
        let baseline = effectiveBaselineText(fallback: capturedText)
        let snapshotStore = snapshotStore

        // File I/O, history reservation, and the two Myers diffs are pure or
        // internally synchronized. Keeping them off the main actor is what
        // lets a reader continue scrolling while a large agent rewrite lands.
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let snapshot = try? DocumentIO.readSnapshot(contentsOf: url) else {
                await self?.finishExternalPreparation(generation: generation, prepared: nil)
                return
            }
            let incoming = snapshot.text
            let freshFidelity = snapshot.fidelity
            let incomingHash = SnapshotStore.hash(incoming)
            let incomingByteHash = DocumentIO.contentHash(snapshot.data)
            let currentHash = SnapshotStore.hash(capturedText)
            if incomingHash != currentHash,
               !Self.finalNewlineDifferenceOnlyValue(capturedText, incoming) {
                snapshotStore.record(incoming, for: url, kind: .external)
            }
            let baselineHunks = incomingHash == currentHash
                ? [] : TextDiff.hunks(old: baseline, new: incoming)
            let applicationHunks = incomingHash == currentHash
                ? [] : TextDiff.hunks(old: capturedText, new: incoming)
            let prepared = PreparedExternalWrite(
                generation: generation,
                url: url,
                capturedText: capturedText,
                baseline: baseline,
                incoming: incoming,
                fidelity: freshFidelity,
                incomingHash: incomingHash,
                incomingByteHash: incomingByteHash,
                baselineHunks: baselineHunks,
                applicationHunks: applicationHunks
            )
            await self?.finishExternalPreparation(generation: generation, prepared: prepared)
        }
    }

    private func finishExternalPreparation(
        generation: UInt64,
        prepared: PreparedExternalWrite?
    ) {
        guard !isClosed else { return }
        guard generation == externalPreparationGeneration else { return }
        defer { endBurstIfNeeded() }
        guard let prepared, url == prepared.url else { return }

        // A local edit that landed while the background diff ran wins. The
        // captured clean snapshot is no longer safe to apply, so compute the
        // conflict against the current buffer on a fresh background turn.
        guard storage.string == prepared.capturedText else {
            let current = storage.string
            externalPreparationGeneration &+= 1
            let nextGeneration = externalPreparationGeneration
            isAbsorbingBurst = true
            Task.detached(priority: .userInitiated) { [weak self] in
                let hunks = TextDiff.hunks(old: current, new: prepared.incoming)
                await self?.finishPreparedConflict(
                    generation: nextGeneration,
                    incoming: prepared.incoming,
                    incomingHash: prepared.incomingHash,
                    hunks: hunks
                )
            }
            return
        }

        guard prepared.incomingHash != SnapshotStore.hash(prepared.capturedText) else {
            diskHash = prepared.incomingHash
            diskByteHash = prepared.incomingByteHash
            fidelity = prepared.fidelity
            if !isDirty, pendingConflict == nil { publishPresentationState(.neutral) }
            return
        }
        if finalNewlineDifferenceOnly(prepared.capturedText, prepared.incoming) {
            diskHash = prepared.incomingHash
            diskByteHash = prepared.incomingByteHash
            fidelity = prepared.fidelity
            return
        }

        diskHash = prepared.incomingHash
        diskByteHash = prepared.incomingByteHash
        if isDirty {
            presentPreparedConflict(incoming: prepared.incoming, hunks: prepared.applicationHunks)
            return
        }

        pendingConflict = nil
        fidelity = prepared.fidelity
        lastCommittedText = prepared.incoming
        applyExternalText(
            prepared.incoming,
            hunks: prepared.baselineHunks,
            baseline: prepared.baseline,
            applicationHunks: prepared.applicationHunks
        )
        unreadChanges = changes.isEmpty ? .none : .marked(count: changes.count)
        let hunks = prepared.baselineHunks
        publishPresentationState(PresentationState(
            phase: .changedOnDisk,
            provenance: nil,
            detail: hunks.isEmpty ? nil : "\(hunks.count) changed block\(hunks.count == 1 ? "" : "s")"
        ))
        onExternalEvent?(.applied(hunks: hunks))
    }

    private func finishPreparedConflict(
        generation: UInt64,
        incoming: String,
        incomingHash: String,
        hunks: [ChangeHunk]
    ) {
        guard !isClosed, generation == externalPreparationGeneration else { return }
        defer { endBurstIfNeeded() }
        diskHash = incomingHash
        presentPreparedConflict(incoming: incoming, hunks: hunks)
    }

    private func presentPreparedConflict(incoming: String, hunks: [ChangeHunk]) {
        let conflict = Conflict(
            incomingText: incoming, hunks: hunks, changedBlockCount: hunks.count
        )
        pendingConflict = conflict
        publishPresentationState(PresentationState(
            phase: .conflict,
            provenance: presentationState.provenance,
            detail: "Changed on disk"
        ))
        onExternalEvent?(.conflict(conflict))
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
    func applyExternalText(
        _ incoming: String,
        hunks: [ChangeHunk],
        baseline: String? = nil,
        applicationHunks preparedApplicationHunks: [ChangeHunk]? = nil
    ) {
        // Adopting the on-disk version resolves any outstanding conflict.
        pendingConflict = nil
        let topOffset = currentTopOffsetProvider?() ?? 0
        let anchor = ScrollAnchoring.anchor(for: topOffset, in: parsed)
        let previousText = storage.string
        let previousSelection = currentSelectionProvider?() ?? NSRange(location: 0, length: 0)

        // External replacement is a new immutable source generation just like
        // a local character edit. Without advancing here, an initial/open parse
        // still in flight can share the same revision and cause the coordinator
        // to reject this newer snapshot as a duplicate.
        invalidateParseWorkForEdit()
        let applicationHunks = preparedApplicationHunks ?? (
            (baseline ?? previousText) == previousText
                ? hunks
                : TextDiff.hunks(old: previousText, new: incoming)
        )
        adoptExternalBuffer(incoming, hunks: applicationHunks)
        setDirty(false)

        changes.apply(hunks: hunks, newText: incoming, oldText: baseline ?? previousText)
        pendingExternalRestore = PendingExternalRestore(
            previousText: previousText,
            selection: previousSelection,
            anchor: anchor
        )
        nextExternalDirtyOverride = DirtySet(
            ranges: applicationHunks.map {
                TextDiff.anchorRange(for: $0, inNewTextOfLength: (incoming as NSString).length)
            },
            isWholesale: false
        )
        startPriorityAsyncReparse()
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
    private func adoptExternalBuffer(_ incoming: String, hunks: [ChangeHunk]? = nil) {
        let previous = storage.string
        let whole = NSRange(location: 0, length: storage.length)

        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { document in
            MainActor.assumeIsolated {
                // Undo groups unwind last-in-first-out, so after newer local
                // edits have unwound the buffer contains this generation's
                // incoming text. Reading it here avoids retaining a second
                // whole-document copy in every external-change undo group.
                document.revertExternalBuffer(
                    to: previous,
                    incoming: document.storage.string
                )
            }
        }
        undoManager.setActionName("External Change")
        undoManager.endUndoGrouping()

        isApplyingExternalChange = true
        // Bounded: a token whose callback never arrives (a racing local edit
        // changed the post-edit text before delivery) must not retain a
        // whole-document copy forever, and the oldest entries are precisely
        // the ones whose transactions are already over.
        ignoredExternalStorageCallbackTexts.append(incoming)
        if ignoredExternalStorageCallbackTexts.count > Self.maximumIgnoredExternalCallbackTexts {
            ignoredExternalStorageCallbackTexts.removeFirst()
        }
        storage.beginEditing()
        if let hunks, !hunks.isEmpty {
            let incomingText = incoming as NSString
            for hunk in hunks.sorted(by: { $0.oldRange.location > $1.oldRange.location }) {
                guard hunk.oldRange.location >= 0,
                      hunk.oldRange.upperBound <= storage.length,
                      hunk.newRange.location >= 0,
                      hunk.newRange.upperBound <= incomingText.length else { continue }
                // Same reference-payload rule as replace(): hunk edits shift
                // the runs below them without moving payload ranges.
                projectFragmentPayloads(
                    across: hunk.oldRange,
                    insertedLength: incomingText.substring(with: hunk.newRange).utf16.count
                )
                storage.replaceCharacters(
                    in: hunk.oldRange,
                    with: incomingText.substring(with: hunk.newRange)
                )
            }
            // Diff hunks are an optimisation, never a source of truth. If a
            // capped/fallback diff cannot express the exact transformation,
            // repair to the byte-faithful incoming text before publishing.
            if storage.string != incoming {
                storage.replaceCharacters(
                    in: NSRange(location: 0, length: storage.length),
                    with: incoming
                )
            }
        } else {
            storage.replaceCharacters(in: whole, with: incoming)
        }
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
        publishPresentationState(.neutral)
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
        return snapshotStore.versions(for: url)
    }

    /// Whether a historical version can still be shown, so the timeline can
    /// distinguish "pruned" from "damaged" instead of showing an empty pane.
    func content(of version: SnapshotStore.VersionRecord) -> SnapshotStore.Content {
        snapshotStore.content(for: version)
    }

    /// Restores a historical version into the buffer as a normal, undoable edit.
    /// Choosing a version is a review decision, so the baseline moves with it:
    /// the next agent write is measured against what the user just chose.
    @discardableResult
    func restore(version: SnapshotStore.VersionRecord) -> Bool {
        guard case .text(let text) = snapshotStore.content(for: version) else { return false }
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
        // Capture the post-edit source while the delegate callback is still
        // describing this storage mutation. The task may run after another
        // edit, so reading `storage.string` in the task would lose the
        // transaction boundary and consume the wrong suppression token.
        let callbackText = textStorage.string
        Task { @MainActor [weak self] in
            self?.handleTextStorageEdit(callbackText: callbackText)
        }
    }

    private func handleTextStorageEdit(callbackText: String) {
        guard !suppressReparse else { return }
        if let tokenIndex = ignoredExternalStorageCallbackTexts.firstIndex(of: callbackText) {
            ignoredExternalStorageCallbackTexts.remove(at: tokenIndex)
            return
        }
        // An explicit transaction may have already published its synchronous
        // parse before this delegate hop runs. Do not schedule a second parse
        // merely because NSTextStorage delivered the callback later.
        guard parsed.text != storage.string else { return }
        // `NSTextStorageDelegate` is delivered on a later main-actor turn. The
        // external transaction already submitted this exact snapshot; consume
        // only its callback above. A subsequent user edit must take the normal
        // path, invalidate the external parse, and own the camera.
        pendingExternalRestore = nil
        nextExternalDirtyOverride = nil
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
