import AppKit
import MarkdownRender
import ObjectiveC

private final class ReaderProfileControllerState: NSObject {
    var profile = ReaderProfile.builtIns[0]
    var baseTheme: Theme?
    var store: ReaderProfileStore = JSONReaderProfileStore(
        url: AppPaths.supportDirectory.appendingPathComponent("reader-profiles.json")
    )
}

private var readerProfileStateKey: UInt8 = 0

@MainActor
extension DocumentWindowController: ReaderProfilePickerDelegate {
    private var readerProfileState: ReaderProfileControllerState {
        if let state = objc_getAssociatedObject(self, &readerProfileStateKey) as? ReaderProfileControllerState {
            return state
        }
        let state = ReaderProfileControllerState()
        objc_setAssociatedObject(self, &readerProfileStateKey, state, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return state
    }

    /// The active profile is presentation state. It is not written into the
    /// markdown document and does not select or modify a color theme.
    var readerProfile: ReaderProfile { readerProfileState.profile }

    func showReaderProfiles() {
        let picker = ReaderProfilePickerView(store: readerProfileState.store, styleSheet: activeStyleSheet)
        picker.delegate = self
        picker.selectProfile(id: readerProfile.id)
        installTrailing(picker)
    }

    func applyReaderProfile(_ profile: ReaderProfile) {
        let state = readerProfileState
        state.profile = profile
        if state.baseTheme == nil || state.baseTheme?.name != activeStyleSheet.theme.name {
            state.baseTheme = activeStyleSheet.theme
        }

        var theme = state.baseTheme ?? activeStyleSheet.theme
        var typography = theme.typography
        typography.bodySize = max(10, min(28, typography.bodySize * profile.typographyScale.value))
        typography.measureCharacters = profile.measureCharacters
        theme.typography = typography
        let reduceMotion = profile.motionPreference == .reduced ? true : nil
        let sheet = StyleSheet(
            theme: theme,
            appearance: window?.effectiveAppearance ?? NSApp.effectiveAppearance,
            reduceMotionOverride: reduceMotion
        )
        activeStyleSheet = sheet
        applyStyleSheet()

        window?.toolbar?.displayMode = profile.chromeDensity == .compact
            ? .iconOnly : .iconAndLabel
        window?.toolbar?.sizeMode = profile.chromeDensity == .compact
            ? .small : .regular
        breadcrumbView.isHidden = profile.chromeDensity == .compact
    }

    func readerProfilePicker(_ picker: ReaderProfilePickerView, didPreview profile: ReaderProfile) {
        applyReaderProfile(profile)
    }

    func readerProfilePicker(_ picker: ReaderProfilePickerView, didSelect profile: ReaderProfile) {
        applyReaderProfile(profile)
    }
}
