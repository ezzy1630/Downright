@preconcurrency import AVFoundation

@MainActor
protocol SpeechCoordinatorDelegate: AnyObject {
    func speechCoordinator(_ coordinator: SpeechCoordinator, willSpeak range: NSRange)
    func speechCoordinatorDidFinish(_ coordinator: SpeechCoordinator)
}

/// Small native speech boundary. It owns one synthesizer and one active text.
@MainActor
final class SpeechCoordinator: NSObject {
    weak var delegate: SpeechCoordinatorDelegate?

    private let synthesizer: AVSpeechSynthesizer
    private(set) var isSpeaking = false

    init(synthesizer: AVSpeechSynthesizer = AVSpeechSynthesizer()) {
        self.synthesizer = synthesizer
        super.init()
        synthesizer.delegate = self
    }

    @discardableResult
    func speak(_ text: String) -> Bool {
        stop()
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        synthesizer.speak(AVSpeechUtterance(string: text))
        isSpeaking = true
        return true
    }

    func stop() {
        guard isSpeaking || synthesizer.isSpeaking else { return }
        synthesizer.stopSpeaking(at: .immediate)
        isSpeaking = false
    }

}

extension SpeechCoordinator: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(
        _ synthesizer: AVSpeechSynthesizer,
        willSpeakRangeOfSpeechString characterRange: NSRange,
        utterance: AVSpeechUtterance
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            delegate?.speechCoordinator(self, willSpeak: characterRange)
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        finishSpeaking()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        finishSpeaking()
    }

    nonisolated private func finishSpeaking() {
        Task { @MainActor [weak self] in
            guard let self else { return }
            isSpeaking = false
            delegate?.speechCoordinatorDidFinish(self)
        }
    }
}
