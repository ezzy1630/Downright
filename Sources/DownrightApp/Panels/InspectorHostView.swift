import AppKit

final class InspectorHostView: NSView {
    var onHistory: (() -> Void)?

    private let picker = NSSegmentedControl(labels: ["Tasks", "Search", "History"],
                                            trackingMode: .selectOne, target: nil, action: nil)
    private let content = NSView()
    private var views: [Int: NSView] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        picker.target = self
        picker.action = #selector(selectionChanged(_:))
        picker.selectedSegment = 0
        picker.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(picker)
        addSubview(content)
        NSLayoutConstraint.activate([
            picker.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            picker.centerXAnchor.constraint(equalTo: centerXAnchor),
            content.topAnchor.constraint(equalTo: picker.bottomAnchor, constant: 8),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func setContent(_ view: NSView, segment: Int) {
        views[segment]?.removeFromSuperview()
        views[segment] = view
        picker.selectedSegment = segment
        show(segment)
    }

    func removeContent(segment: Int) {
        views.removeValue(forKey: segment)?.removeFromSuperview()
    }

    @objc private func selectionChanged(_ sender: NSSegmentedControl) {
        if sender.selectedSegment == 2 {
            onHistory?()
            sender.selectedSegment = views[1] == nil ? 0 : 1
        }
        show(sender.selectedSegment)
    }

    private func show(_ segment: Int) {
        for (index, view) in views { view.isHidden = index != segment }
        guard let view = views[segment] else { return }
        if view.superview == nil {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
            NSLayoutConstraint.activate([
                view.leadingAnchor.constraint(equalTo: content.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: content.trailingAnchor),
                view.topAnchor.constraint(equalTo: content.topAnchor),
                view.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            ])
        }
        view.isHidden = false
    }
}
