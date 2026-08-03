import AppKit

/// Indeterminate activity cue for operations that take more than a moment.
///
/// Appearing is deferred a second so a fast operation never flashes chrome;
/// hiding is immediate so the reader is never left staring at a ghost.  The
/// system spinner stays in tune with the theme and the Reduce Motion
/// accessibility setting (§12).
final class ActivityIndicatorView: NSView {
    private let spinner = NSProgressIndicator()
    private var revealWorkItem: DispatchWorkItem?

    /// Lets the toolbar collapse the item while idle so the centered rail
    /// never shifts when work starts.
    var onVisibilityChange: ((Bool) -> Void)?

    override var intrinsicContentSize: NSSize {
        isHidden ? .zero : NSSize(width: 18, height: 18)
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 18, height: 18))
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false
        addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 14),
            spinner.heightAnchor.constraint(equalToConstant: 14),
        ])
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.progressIndicator)
        setAccessibilityLabel("Working")
    }

    required init?(coder: NSCoder) { nil }

    /// Show the cue only if the operation is still running a second from now.
    func begin() {
        revealWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.setVisible(true)
            self.spinner.startAnimation(nil)
        }
        revealWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    func end() {
        revealWorkItem?.cancel()
        revealWorkItem = nil
        spinner.stopAnimation(nil)
        setVisible(false)
    }

    private func setVisible(_ visible: Bool) {
        let hide = !visible
        guard isHidden != hide else { return }
        isHidden = hide
        invalidateIntrinsicContentSize()
        onVisibilityChange?(hide)
    }
}
