import AppKit
import MarkdownRender
import Testing
@testable import DownrightApp

struct StarPromptUsageTests {
    @Test func onlyConsecutiveForegroundIntervalsCount() {
        var clock = StarPromptReadingClock()
        #expect(clock.sample(at: 10, isReading: true) == 0)
        #expect(clock.sample(at: 15, isReading: true) == 5)
        #expect(clock.sample(at: 20, isReading: false) == 0)
        #expect(clock.sample(at: 1000, isReading: false) == 0)
        #expect(clock.sample(at: 1005, isReading: true) == 0)
        #expect(clock.sample(at: 1010, isReading: true) == 5)
        #expect(clock.sample(at: 1009, isReading: true) == 0)
        #expect(clock.sample(at: 2000, isReading: true) == StarPromptReadingClock.maximumSampleSeconds)
    }

    @Test func bothUsageThresholdsAreRequired() {
        var usage = StarPromptUsage()
        for _ in 0..<5 { usage.recordOpen(origin: .user) }
        usage.recordForegroundTime(599)
        #expect(!usage.isEligible)
        usage.recordForegroundTime(1)
        #expect(usage.isEligible)

        var reader = StarPromptUsage()
        reader.recordForegroundTime(600)
        for _ in 0..<4 { reader.recordOpen(origin: .user) }
        #expect(!reader.isEligible)
        reader.recordOpen(origin: .user)
        #expect(reader.isEligible)
    }

    @Test func restorationAndTourDoNotCount() {
        var usage = StarPromptUsage()
        for _ in 0..<10 {
            usage.recordOpen(origin: .restoration)
            usage.recordOpen(origin: .tour)
        }
        usage.recordForegroundTime(600)
        #expect(usage.documentOpens == 0)
        #expect(!usage.isEligible)
    }

    @Test func tourIdentitySurvivesReopeningFromRecents() {
        #expect(WelcomeDocument.isTour(WelcomeDocument.materializedURL))
        let otherDocument = FileManager.default.temporaryDirectory
            .appendingPathComponent("User Notes", isDirectory: true)
            .appendingPathComponent("Welcome to Downright.md")
        #expect(!WelcomeDocument.isTour(otherDocument))
    }

    @Test func retirementSurvivesPreferencesRoundTripAndFurtherUse() throws {
        var preferences = Preferences.Values()
        preferences.starPrompt.retire()
        var restored = try JSONDecoder().decode(
            Preferences.Values.self, from: JSONEncoder().encode(preferences)
        )
        for _ in 0..<10 { restored.starPrompt.recordOpen(origin: .user) }
        restored.starPrompt.recordForegroundTime(1200)
        #expect(restored.starPrompt.hasBeenOffered)
        #expect(!restored.starPrompt.isEligible)
        #expect(restored.starPrompt == preferences.starPrompt)
    }

    @Test func legacyPreferencesStartWithoutInventedUsage() throws {
        let preferences = try JSONDecoder().decode(Preferences.Values.self, from: Data("{}".utf8))
        #expect(preferences.starPrompt == StarPromptUsage())
    }

    @Test func countersAreBoundedAndInvalidElapsedTimeIsIgnored() throws {
        var usage = StarPromptUsage()
        usage.recordForegroundTime(-1)
        usage.recordForegroundTime(.infinity)
        usage.recordForegroundTime(.nan)
        #expect(usage.foregroundSeconds == 0)
        for _ in 0..<100 { usage.recordOpen(origin: .user) }
        usage.recordForegroundTime(100_000)
        #expect(usage.documentOpens == 5)
        #expect(usage.foregroundSeconds == 600)

        let decoded = try JSONDecoder().decode(StarPromptUsage.self, from: Data(
            #"{"documentOpens":-1,"foregroundSeconds":-10,"hasBeenOffered":false}"#.utf8
        ))
        #expect(decoded == StarPromptUsage())
    }
}

@Suite(.serialized)
@MainActor
struct StarPromptNoticeTests {
    @Test func noticeTracksHostAppearanceAndThemeUntilDismissed() throws {
        let originalTheme = ThemeStore.shared.current
        defer { ThemeStore.shared.select(named: originalTheme.name) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        let notice = StarPromptNotice(parent: window, openRepository: {})
        defer { notice.dismiss(); window.close() }
        notice.show()
        #expect(notice.panel.appearance?.name == .aqua)
        window.appearance = NSAppearance(named: .darkAqua)
        #expect(notice.panel.appearance?.name == .darkAqua)
        ThemeStore.shared.select(named: "Warm Dark")
        #expect(notice.panel.appearance?.name == .darkAqua)
        let expected = StyleSheet(theme: ThemeStore.shared.current, appearance: window.effectiveAppearance)
        #expect(notice.panel.contentView?.layer?.backgroundColor == expected.background.cgColor)
    }

    @Test func successfulInPlaceOpensCountButFailedOpensDoNot() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Reading.md")
        let destination = folder.appendingPathComponent("Destination.md")
        try "# Reading\n\nA local document.\n".write(to: file, atomically: true, encoding: .utf8)
        try "# Destination\n".write(to: destination, atomically: true, encoding: .utf8)
        let controller = DocumentWindowController()
        defer { controller.close() }
        var opens = 0
        controller.onDocumentOpen = { opens += 1 }
        try controller.open(file, mode: .live)
        #expect(opens == 0)
        #expect(controller.openInPlace(destination))
        #expect(opens == 1)
        #expect(!controller.openInPlace(folder.appendingPathComponent("Missing.md")))
        #expect(controller.markdownDocument.url == destination)
        #expect(opens == 1)
    }

    @Test func noticePreservesDocumentGeometryAndFocusAndDismissesCleanly() throws {
        let controller = DocumentWindowController()
        let window = try #require(controller.window)
        let textView = controller.primaryContainer.textView
        window.contentView?.layoutSubtreeIfNeeded()
        window.makeFirstResponder(textView)
        let responder = window.firstResponder
        let frame = controller.primaryContainer.frame
        let selection = textView.selectedRange()
        let notice = StarPromptNotice(parent: window, openRepository: {})
        defer { notice.dismiss(); controller.close() }
        notice.show()
        window.contentView?.layoutSubtreeIfNeeded()
        notice.panel.contentView?.layoutSubtreeIfNeeded()
        #expect(window.firstResponder === responder)
        #expect(controller.primaryContainer.frame == frame)
        #expect(textView.selectedRange() == selection)
        #expect(notice.panel.parent === window)
        #expect(notice.panel.frame.width <= window.frame.width)
        notice.dismiss()
        #expect(notice.panel.parent == nil)
        #expect(!notice.panel.isVisible)
    }

    @Test func usagePersistenceDoesNotBroadcastVisualSettingsChanges() {
        let original = Preferences.shared.values
        defer { Preferences.shared.update { $0 = original } }
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: Preferences.didChange, object: Preferences.shared, queue: .main
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }
        Preferences.shared.update { $0.starPrompt.retire() }
        #expect(notifications == 0)
        Preferences.shared.update { $0.showInvisibles.toggle() }
        #expect(notifications == 1)
    }
}
