import AppKit
import MarkdownRender

@MainActor
protocol ReaderProfilePickerDelegate: AnyObject {
    func readerProfilePicker(_ picker: ReaderProfilePickerView, didPreview profile: ReaderProfile)
    func readerProfilePicker(_ picker: ReaderProfilePickerView, didSelect profile: ReaderProfile)
}

/// A transient, keyboard-first profile picker. Profiles own reader metrics;
/// themes and colors stay in ThemeStore.
@MainActor
final class ReaderProfilePickerView: NSView, PanelSurface {
    weak var delegate: ReaderProfilePickerDelegate?

    var styleSheet: StyleSheet {
        didSet { backdrop.styleSheet = styleSheet; applyStyle() }
    }

    var preferredWidth: CGFloat { 320 }
    private(set) var selectedProfile: ReaderProfile
    var profiles: [ReaderProfile] { builtIns + customProfiles }
    var customProfiles: [ReaderProfile] {
        didSet { reloadProfileList() }
    }

    private let store: ReaderProfileStore
    private let builtIns = ReaderProfile.builtIns
    private let backdrop: PanelBackdrop
    private let titleLabel = NSTextField(labelWithString: "Reader profile")
    private let detailLabel = NSTextField(labelWithString: "Presentation settings only")
    private let profilePopup = NSPopUpButton()
    private let nameField = NSTextField()
    private let saveButton = NSButton(title: "Save as custom", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete custom", target: nil, action: nil)
    private var controls: [NSPopUpButton] = []
    private var controlAction: ButtonAction?
    private var saveAction: ButtonAction?
    private var deleteAction: ButtonAction?
    private var isReloading = false

    convenience init() { self.init(store: JSONReaderProfileStore(url: AppPaths.supportDirectory.appendingPathComponent("reader-profiles.json"))) }

    init(store: ReaderProfileStore, styleSheet: StyleSheet = .current) {
        self.store = store
        self.styleSheet = styleSheet
        self.customProfiles = store.loadCustomProfiles()
        self.selectedProfile = ReaderProfile.builtIns[0]
        self.backdrop = PanelBackdrop(styleSheet: styleSheet)
        super.init(frame: .zero)
        buildInterface()
        reloadProfileList()
        applyStyle()
        setAccessibilityRole(.group)
        setAccessibilityLabel("Reader profile picker")
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func selectProfile(id: String) {
        guard let profile = profiles.first(where: { $0.id == id }) else { return }
        selectedProfile = profile
        loadControls()
        delegate?.readerProfilePicker(self, didSelect: profile)
        delegate?.readerProfilePicker(self, didPreview: profile)
    }

    func updatePreview() {
        delegate?.readerProfilePicker(self, didPreview: selectedProfile)
    }

    func saveCustomProfileForTesting(name: String) {
        nameField.stringValue = name
        saveCustom(nil)
    }

    private func buildInterface() {
        backdrop.autoresizingMask = [.width, .height]
        backdrop.frame = bounds
        addSubview(backdrop)

        for (field, font) in [(titleLabel, PanelFont.title), (detailLabel, PanelFont.secondary)] {
            field.font = font
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
        }

        profilePopup.target = self
        profilePopup.action = #selector(profileChanged(_:))
        profilePopup.setAccessibilityLabel("Reader profile")
        profilePopup.translatesAutoresizingMaskIntoConstraints = false
        addSubview(profilePopup)

        nameField.placeholderString = "Custom profile name"
        nameField.font = PanelFont.row
        nameField.setAccessibilityLabel("Custom profile name")
        nameField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(nameField)

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(saveCustom(_:))
        saveButton.setAccessibilityLabel("Save reader profile as custom")
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(saveButton)

        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(deleteCustom(_:))
        deleteButton.setAccessibilityLabel("Delete custom reader profile")
        deleteButton.translatesAutoresizingMaskIntoConstraints = false
        addSubview(deleteButton)

        addControl(label: "Typography scale", titles: ReaderTypographyScale.allCases.map(\.title))
        addControl(label: "Measure width", titles: ["68 characters", "70 characters", "72 characters"])
        addControl(label: "Chrome density", titles: ReaderChromeDensity.allCases.map(\.title))
        addControl(label: "Motion", titles: ReaderMotionPreference.allCases.map(\.title))
        addControl(label: "Code width", titles: ReaderWidthPolicy.allCases.map(\.title))
        addControl(label: "Table width", titles: ReaderWidthPolicy.allCases.map(\.title))

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            profilePopup.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            profilePopup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            profilePopup.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: 12),
            nameField.leadingAnchor.constraint(equalTo: profilePopup.leadingAnchor),
            nameField.trailingAnchor.constraint(equalTo: profilePopup.trailingAnchor),
            nameField.topAnchor.constraint(equalTo: profilePopup.bottomAnchor, constant: 8),
            saveButton.leadingAnchor.constraint(equalTo: nameField.leadingAnchor),
            saveButton.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            deleteButton.trailingAnchor.constraint(equalTo: nameField.trailingAnchor),
            deleteButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
        ])

        saveButton.keyEquivalent = "s"
        saveButton.keyEquivalentModifierMask = [.command, .shift]
    }

    private func addControl(label: String, titles: [String]) {
        let name = NSTextField(labelWithString: label)
        name.font = PanelFont.row
        name.translatesAutoresizingMaskIntoConstraints = false
        let popup = NSPopUpButton()
        popup.addItems(withTitles: titles)
        popup.target = self
        popup.action = #selector(controlChanged(_:))
        popup.setAccessibilityLabel(label)
        popup.translatesAutoresizingMaskIntoConstraints = false
        controls.append(popup)
        addSubview(name)
        addSubview(popup)
        let previous = controls.dropLast().last
        let top = previous?.bottomAnchor ?? saveButton.bottomAnchor
        NSLayoutConstraint.activate([
            name.leadingAnchor.constraint(equalTo: leadingAnchor, constant: PanelMetrics.inset),
            name.topAnchor.constraint(equalTo: top, constant: 10),
            popup.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -PanelMetrics.inset),
            popup.centerYAnchor.constraint(equalTo: name.centerYAnchor),
            popup.leadingAnchor.constraint(greaterThanOrEqualTo: name.trailingAnchor, constant: 8),
            popup.widthAnchor.constraint(equalToConstant: 150),
        ])
    }

    private func reloadProfileList() {
        isReloading = true
        profilePopup.removeAllItems()
        profilePopup.addItems(withTitles: profiles.map(\.name))
        profilePopup.selectItem(at: profiles.firstIndex(where: { $0.id == selectedProfile.id }) ?? 0)
        loadControls()
        isReloading = false
    }

    private func loadControls() {
        isReloading = true
        controls[safe: 0]?.selectItem(at: ReaderTypographyScale.allCases.firstIndex(of: selectedProfile.typographyScale) ?? 0)
        let measure = [68, 70, 72].firstIndex(of: Int(selectedProfile.measureCharacters)) ?? 1
        controls[safe: 1]?.selectItem(at: measure)
        controls[safe: 2]?.selectItem(at: ReaderChromeDensity.allCases.firstIndex(of: selectedProfile.chromeDensity) ?? 0)
        controls[safe: 3]?.selectItem(at: ReaderMotionPreference.allCases.firstIndex(of: selectedProfile.motionPreference) ?? 0)
        controls[safe: 4]?.selectItem(at: ReaderWidthPolicy.allCases.firstIndex(of: selectedProfile.codeWidthPolicy) ?? 0)
        controls[safe: 5]?.selectItem(at: ReaderWidthPolicy.allCases.firstIndex(of: selectedProfile.tableWidthPolicy) ?? 0)
        nameField.stringValue = selectedProfile.isBuiltIn ? "" : selectedProfile.name
        deleteButton.isEnabled = !selectedProfile.isBuiltIn
        isReloading = false
    }

    @objc private func profileChanged(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard !isReloading, profiles.indices.contains(index) else { return }
        selectedProfile = profiles[index]
        loadControls()
        delegate?.readerProfilePicker(self, didSelect: selectedProfile)
        updatePreview()
    }

    @objc private func controlChanged(_ sender: NSPopUpButton) {
        guard !isReloading else { return }
        guard sender.indexOfSelectedItem >= 0 else { return }
        var profile = selectedProfile
        if controls.indices.contains(0), sender === controls[0] { profile.typographyScale = ReaderTypographyScale.allCases[sender.indexOfSelectedItem] }
        else if controls.indices.contains(1), sender === controls[1] { profile.measureCharacters = CGFloat([68, 70, 72][sender.indexOfSelectedItem]) }
        else if controls.indices.contains(2), sender === controls[2] { profile.chromeDensity = ReaderChromeDensity.allCases[sender.indexOfSelectedItem] }
        else if controls.indices.contains(3), sender === controls[3] { profile.motionPreference = ReaderMotionPreference.allCases[sender.indexOfSelectedItem] }
        else if controls.indices.contains(4), sender === controls[4] { profile.codeWidthPolicy = ReaderWidthPolicy.allCases[sender.indexOfSelectedItem] }
        else if controls.indices.contains(5), sender === controls[5] { profile.tableWidthPolicy = ReaderWidthPolicy.allCases[sender.indexOfSelectedItem] }
        selectedProfile = profile
        updatePreview()
    }

    @objc private func saveCustom(_ sender: Any?) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        var profile = selectedProfile
        profile.id = UUID().uuidString
        profile.name = name.isEmpty ? "Custom" : name
        profile.isBuiltIn = false
        customProfiles.append(profile)
        store.saveCustomProfiles(customProfiles)
        selectedProfile = profile
        reloadProfileList()
        delegate?.readerProfilePicker(self, didSelect: profile)
        updatePreview()
    }

    @objc private func deleteCustom(_ sender: Any?) {
        guard !selectedProfile.isBuiltIn else { return }
        customProfiles.removeAll { $0.id == selectedProfile.id }
        store.saveCustomProfiles(customProfiles)
        selectedProfile = builtIns[0]
        reloadProfileList()
        delegate?.readerProfilePicker(self, didSelect: selectedProfile)
        updatePreview()
    }

    private func applyStyle() {
        titleLabel.textColor = styleSheet.text
        detailLabel.textColor = styleSheet.textSecondary
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
