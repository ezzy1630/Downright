import AppKit
import MarkdownRender
import ObjectiveC

private var speechCoordinatorKey: UInt8 = 0
private var speechSourceRangeKey: UInt8 = 0

@MainActor
extension DocumentWindowController: SpeechCoordinatorDelegate {
    var isSpeakingDocument: Bool { speechCoordinator.isSpeaking }
    private var speechCoordinator: SpeechCoordinator {
        if let value = objc_getAssociatedObject(self, &speechCoordinatorKey) as? SpeechCoordinator {
            return value
        }
        let value = SpeechCoordinator()
        value.delegate = self
        objc_setAssociatedObject(self, &speechCoordinatorKey, value, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return value
    }

    private var speechSourceRange: NSRange {
        get {
            (objc_getAssociatedObject(self, &speechSourceRangeKey) as? NSValue)?.rangeValue
                ?? NSRange(location: 0, length: 0)
        }
        set { objc_setAssociatedObject(self, &speechSourceRangeKey, NSValue(range: newValue), .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func speakSelectionOrDocument() {
        let selected = containerTextView.sourceSelectedRange
        let source = selected.length > 0
            ? selected
            : NSRange(location: 0, length: markdownDocument.storage.length)
        let text = containerTextView.renderedStringForSpeech(sourceRange: source)
        speechSourceRange = source
        if !speechCoordinator.speak(text) { containerTextView.speechHighlight = nil }
    }

    func stopSpeaking() {
        speechCoordinator.stop()
        containerTextView.speechHighlight = nil
    }

    func speechCoordinator(_ coordinator: SpeechCoordinator, willSpeak range: NSRange) {
        guard let source = containerTextView.sourceRangeForSpeechRange(range, within: speechSourceRange) else { return }
        containerTextView.speechHighlight = source
        containerTextView.scroll(toOffset: source.location, position: .visible, animated: false)
    }

    func speechCoordinatorDidFinish(_ coordinator: SpeechCoordinator) {
        containerTextView.speechHighlight = nil
    }
}
