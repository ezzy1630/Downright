import AppKit
import MarkdownCore
import MarkdownRender

/// Outline quick-open (§7.2, `⌘⇧O`).
///
/// A floating fuzzy search over the document's headings.  Ranking prefers
/// prefix and word-boundary matches (see `FuzzyMatcher`) and the matched
/// characters are highlighted in place, so you can see *why* a result ranked
/// where it did — which is what makes a fuzzy list trustworthy rather than
/// mysterious.
final class OutlineQuickOpenPanel: NSPanel {
    private let headings: [HeadingNode]
    private var styleSheet: StyleSheet
    private let onSelect: (Int) -> Void

    private let searchField = NSTextField()
    private let table = PanelList.makeTableView(identifier: "quickOpen")
    private lazy var scroll = PanelList.makeScrollView(documentView: table)
    private let backdrop: PanelBackdrop
    private let emptyLabel = NSTextField(labelWithString: "No matching heading")

    /// Heading index plus the characters that matched, in rank order.
    private var results: [(index: Int, positions: [Int])] = []

    init(headings: [HeadingNode], styleSheet: StyleSheet, onSelect: @escaping (Int) -> Void) {
        self.headings = headings
        self.styleSheet = styleSheet
        self.onSelect = onSelect
        self.backdrop = PanelBackdrop(styleSheet: styleSheet, material: .popover)

        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered, defer: true
        )

        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        level = .floating
        animationBehavior = .utilityWindow
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        buildContent()
        updateResults(for: "")
        delegate = self
    }

    override var canBecomeKey: Bool { true }

    // MARK: - Content

    private func buildContent() {
        let container = backdrop
        container.frame = NSRect(x: 0, y: 0, width: 520, height: 360)
        contentView = container

        searchField.placeholderString = "Jump to heading"
        searchField.font = NSFont.systemFont(ofSize: 17, weight: .regular)
        searchField.isBezeled = false
        searchField.drawsBackground = false
        searchField.focusRingType = .none
        searchField.delegate = self
        searchField.textColor = styleSheet.text
        searchField.setAccessibilityLabel("Jump to heading")
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        table.dataSource = self
        table.delegate = self
        table.rowHeight = 26
        table.target = self
        table.action = #selector(rowClicked(_:))
        table.onActivate = { [weak self] in self?.activateSelection() }
        table.setAccessibilityLabel("Matching headings")
        container.addSubview(scroll)

        emptyLabel.font = PanelFont.row
        emptyLabel.textColor = styleSheet.textFaint
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 14),
            scroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 12),
            scroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
        ])
    }

    // MARK: - Presentation

    func present(over window: NSWindow) {
        let frame = window.frame
        let size = NSSize(width: min(560, max(420, frame.width * 0.5)), height: 360)
        // High in the window rather than centred: the list grows downwards, and
        // a panel that jumps around as results arrive is disorienting.
        let origin = NSPoint(
            x: frame.midX - size.width / 2,
            y: frame.maxY - size.height - min(160, frame.height * 0.18)
        )
        setFrame(NSRect(origin: origin, size: size), display: true)

        window.addChildWindow(self, ordered: .above)
        makeKeyAndOrderFront(nil)
        makeFirstResponder(searchField)
    }

    func dismiss() {
        parent?.removeChildWindow(self)
        orderOut(nil)
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    // MARK: - Results

    private func updateResults(for query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)

        if trimmed.isEmpty {
            results = headings.indices.map { ($0, []) }
        } else {
            var scored: [(index: Int, positions: [Int], score: Int)] = []
            for (index, heading) in headings.enumerated() {
                guard let match = FuzzyMatcher.match(needle: trimmed, in: heading.title) else { continue }
                // A shallow heading is usually the better answer when two
                // titles score alike — "Search" the H2 over "Search" the H4.
                let depthBonus = max(0, 6 - heading.level)
                scored.append((index, match.positions, match.score + depthBonus))
            }
            scored.sort { a, b in
                a.score == b.score ? a.index < b.index : a.score > b.score
            }
            results = scored.map { ($0.index, $0.positions) }
        }

        emptyLabel.isHidden = !results.isEmpty
        table.reloadData()
        if !results.isEmpty {
            table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
            table.scrollRowToVisible(0)
        }
    }

    private func move(by delta: Int) {
        guard !results.isEmpty else { return }
        let current = table.selectedRow
        let next = min(max(0, (current < 0 ? 0 : current) + delta), results.count - 1)
        table.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        table.scrollRowToVisible(next)
    }

    @objc private func rowClicked(_ sender: Any?) {
        guard table.clickedRow >= 0 else { return }
        activateSelection()
    }

    private func activateSelection() {
        let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
        guard row >= 0, row < results.count else { return }
        let index = results[row].index
        dismiss()
        onSelect(index)
    }
}

// MARK: - Window delegate

extension OutlineQuickOpenPanel: NSWindowDelegate {
    /// Clicking back into the document is a dismissal — a quick-open panel that
    /// lingers is a modal dialog wearing a costume (§11.4).
    func windowDidResignKey(_ notification: Notification) {
        dismiss()
    }
}

// MARK: - Field

extension OutlineQuickOpenPanel: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        updateResults(for: searchField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveUp(_:)): move(by: -1); return true
        case #selector(NSResponder.moveDown(_:)): move(by: 1); return true
        case #selector(NSResponder.insertNewline(_:)): activateSelection(); return true
        case #selector(NSResponder.cancelOperation(_:)): dismiss(); return true
        default: return false
        }
    }
}

// MARK: - Table

extension OutlineQuickOpenPanel: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { results.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < results.count else { return nil }
        let result = results[row]
        let heading = headings[result.index]

        let identifier = NSUserInterfaceItemIdentifier("quickOpenRow")
        let cell = tableView.makeView(withIdentifier: identifier, owner: self) as? QuickOpenRowView
            ?? QuickOpenRowView(identifier: identifier)
        cell.configure(heading: heading, positions: result.positions, styleSheet: styleSheet)
        return cell
    }
}

// MARK: - Row

private final class QuickOpenRowView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let levelLabel = NSTextField(labelWithString: "")
    private var titleLeading: NSLayoutConstraint!

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(titleLabel)

        levelLabel.font = PanelFont.secondary
        levelLabel.alignment = .right
        levelLabel.translatesAutoresizingMaskIntoConstraints = false
        levelLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        addSubview(levelLabel)

        titleLeading = titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        NSLayoutConstraint.activate([
            titleLeading,
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            levelLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),
            levelLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
            levelLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func configure(heading: HeadingNode, positions: [Int], styleSheet: StyleSheet) {
        titleLeading.constant = 16 + CGFloat(min(heading.level, 6) - 1) * 10

        let title = heading.title.isEmpty ? "Untitled" : heading.title
        titleLabel.attributedStringValue = FuzzyMatcher.highlighted(
            title,
            positions: positions,
            base: [
                .font: PanelFont.row,
                .foregroundColor: styleSheet.text,
            ],
            highlight: [
                .font: PanelFont.rowEmphasised,
                .foregroundColor: styleSheet.accent,
            ]
        )

        levelLabel.stringValue = "H\(heading.level)"
        levelLabel.textColor = styleSheet.textFaint
        setAccessibilityLabel("\(title), heading level \(heading.level)")
    }
}
