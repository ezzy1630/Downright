import AppKit
import Foundation
import Testing
import MarkdownRender
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct ReaderProfileTests {
    @Test
    func builtInsCoverTheReaderJobs() {
        #expect(ReaderProfile.builtIns.map(\.name) == ["Documentation", "Long-form", "Academic", "Specification", "GitHub", "Presentation"])
        #expect(ReaderProfile.builtIns.allSatisfy { $0.isBuiltIn })
    }

    @Test
    func profileClampsReadingMeasure() {
        #expect(ReaderProfile(id: "x", name: "x", measureCharacters: 10).measureCharacters == 68)
        #expect(ReaderProfile(id: "x", name: "x", measureCharacters: 100).measureCharacters == 72)
    }

    @Test
    func customProfilesRoundTripThroughInjectedStore() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("reader-(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = JSONReaderProfileStore(url: url)
        let profile = ReaderProfile.custom(name: "My setup")
        store.saveCustomProfiles([profile, ReaderProfile.builtIns[0]])
        #expect(store.loadCustomProfiles() == [profile])
    }

    @Test
    func pickerListsBuiltInsAndSendsLivePreview() {
        let store = InMemoryReaderProfileStore()
        let picker = ReaderProfilePickerView(store: store, styleSheet: .current)
        let delegate = ReaderProfileDelegateSpy()
        picker.delegate = delegate

        picker.selectProfile(id: ReaderProfileID.presentation.rawValue)

        #expect(picker.profiles.count == 6)
        #expect(picker.selectedProfile.name == "Presentation")
        #expect(delegate.previewed.last?.id == ReaderProfileID.presentation.rawValue)
    }

    @Test
    func savingCustomProfileUsesInjectedStore() {
        let store = InMemoryReaderProfileStore()
        let picker = ReaderProfilePickerView(store: store, styleSheet: .current)
        picker.saveCustomProfileForTesting(name: "Team")

        #expect(store.profiles.count == 1)
        #expect(store.profiles[0].name == "Team")
        #expect(!store.profiles[0].isBuiltIn)
    }
}

@MainActor
private final class ReaderProfileDelegateSpy: ReaderProfilePickerDelegate {
    var previewed: [ReaderProfile] = []
    func readerProfilePicker(_ picker: ReaderProfilePickerView, didPreview profile: ReaderProfile) {
        previewed.append(profile)
    }
    func readerProfilePicker(_ picker: ReaderProfilePickerView, didSelect profile: ReaderProfile) { }
}
