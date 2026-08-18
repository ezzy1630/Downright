import Foundation

// MARK: - AST diff (§3.5)
//
// "Reparse the whole document on every edit, diff the resulting AST against the
// previous one by subtree hash, and re-decorate only the changed blocks."
//
// The important property is *locality*: inserting a line near the top of a
// 5,000-line document must not dirty the whole file.  Walking the two trees in
// lockstep by position would do exactly that, because every block after the
// insertion shifts by one.  So sibling lists are matched by hash with Myers
// first, and only the blocks left unmatched are compared pairwise and
// recursed into.

public enum ASTDiff {
    public static func dirtySet(old: ParsedDocument?, new: ParsedDocument) -> DirtySet {
        guard let old else { return .wholesale }
        if old.text == new.text { return .none }

        let oldTop = old.root.children
        let newTop = new.root.children
        // A structural rewrite is cheaper to redecorate wholesale than to
        // reconcile, and the threshold is where the block-level bookkeeping
        // stops paying for itself.
        let larger = Swift.max(oldTop.count, newTop.count)
        if larger > 0, abs(oldTop.count - newTop.count) * 2 > larger { return .wholesale }

        var ranges: [NSRange] = []
        guard reconcile(old: oldTop, new: newTop, into: &ranges, oldText: old.text as NSString, newText: new.text as NSString) else { return .wholesale }
        return DirtySet(ranges: coalesce(ranges), isWholesale: false)
    }

    /// Returns false when the diff gave up and the caller should go wholesale.
    private static func reconcile(
        old: [MDBlock], new: [MDBlock], into ranges: inout [NSRange], oldText: NSString, newText: NSString
    ) -> Bool {
        guard let script = Myers.diff(old.map(\.subtreeHash), new.map(\.subtreeHash)) else {
            return false
        }

        // Collect the unmatched runs between anchors, then pair them up.
        var oldRun: [MDBlock] = []
        var newRun: [MDBlock] = []

        func flush() {
            pair(old: oldRun, new: newRun, into: &ranges, oldText: oldText, newText: newText)
            oldRun.removeAll(keepingCapacity: true)
            newRun.removeAll(keepingCapacity: true)
        }

        for step in script {
            switch step {
            case .equal:
                flush()
            case .delete(let index):
                oldRun.append(old[index])
            case .insert(let index):
                newRun.append(new[index])
            }
        }
        flush()
        return true
    }

    /// Pairs a run of changed old blocks against a run of changed new blocks.
    /// Same-kind pairs recurse so an edit inside one list item dirties that item
    /// rather than the list; everything else is dirty in full.  When the
    /// container's own bytes (markers, blank quote lines) changed underneath
    /// unchanged children, the container itself is dirtied too.
    private static func pair(
        old: [MDBlock], new: [MDBlock], into ranges: inout [NSRange], oldText: NSString, newText: NSString
    ) {
        for index in new.indices {
            guard index < old.count else {
                ranges.append(new[index].range)
                continue
            }
            let before = old[index], after = new[index]
            let sameKind = BlockIdentifier.discriminator(before.content)
                == BlockIdentifier.discriminator(after.content)
            let sameContainerSemantics = containerSemanticsMatch(
                before.content,
                after.content
            )
            if sameKind,
               sameContainerSemantics,
               !before.children.isEmpty,
               !after.children.isEmpty {
                var nested: [NSRange] = []
                if reconcile(old: before.children, new: after.children, into: &nested, oldText: oldText, newText: newText) {
                    if SubtreeHasher.frameworkHash(before, in: oldText)
                        != SubtreeHasher.frameworkHash(after, in: newText) {
                        ranges.append(after.range)
                    }
                    ranges.append(contentsOf: nested)
                    continue
                }
            }
            ranges.append(after.range)
        }
    }

    /// Child hashes do not describe a container's own marker metadata. A task
    /// toggle, list start change, or callout-kind edit can leave every child
    /// byte unchanged while still requiring the parent decoration to refresh.
    private static func containerSemanticsMatch(
        _ old: BlockContent,
        _ new: BlockContent
    ) -> Bool {
        switch (old, new) {
        case let (.callout(oldKind, oldTitle), .callout(newKind, newTitle)):
            return oldKind == newKind && oldTitle == newTitle
        case let (
            .list(oldOrdered, oldStart, oldTight, oldMarker),
            .list(newOrdered, newStart, newTight, newMarker)
        ):
            return oldOrdered == newOrdered
                && oldStart == newStart
                && oldTight == newTight
                && oldMarker == newMarker
        case let (.listItem(oldOrdinal, oldBox), .listItem(newOrdinal, newBox)):
            return oldOrdinal == newOrdinal && oldBox?.isChecked == newBox?.isChecked
        case let (.footnoteDefinition(oldID), .footnoteDefinition(newID)):
            return oldID == newID
        default:
            return true
        }
    }

    private static func coalesce(_ ranges: [NSRange]) -> [NSRange] {
        guard ranges.count > 1 else { return ranges }
        let sorted = ranges.sorted { $0.location < $1.location }
        var out: [NSRange] = [sorted[0]]
        for range in sorted.dropFirst() {
            if range.location <= out[out.count - 1].upperBound {
                out[out.count - 1] = out[out.count - 1].union(range)
            } else {
                out.append(range)
            }
        }
        return out
    }
}
