import AppKit
import MarkdownCore
import MarkdownRender
import ObjectiveC

private var visualDebuggerPanelKey: UInt8 = 0
private var visualDebuggerThemeKey: UInt8 = 0

/// Host hooks for the read-only Visual Debugger panel.
///
/// The extension owns only transient panel lifetime.  It does not add editor
/// commands or mutate source text; selection remains the sole navigation input.
@MainActor
extension DocumentWindowController: VisualDebuggerViewDelegate {
    private var visualDebuggerPanel: VisualDebuggerView? {
        get { objc_getAssociatedObject(self, &visualDebuggerPanelKey) as? VisualDebuggerView }
        set { objc_setAssociatedObject(self, &visualDebuggerPanelKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }

    func toggleVisualDebuggerPanel() {
        if let panel = visualDebuggerPanel {
            dismissTrailing(panel)
            visualDebuggerPanel = nil
            objc_setAssociatedObject(self, &visualDebuggerThemeKey, nil, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            return
        }

        let panel = VisualDebuggerView(styleSheet: activeStyleSheet)
        panel.delegate = self
        visualDebuggerPanel = panel
        configureVisualDebugger(panel)
        installTrailing(panel)

        let observation = ThemeStore.shared.observe { [weak self, weak panel] theme in
            guard let self, let panel, let window = self.window else { return }
            panel.styleSheet = StyleSheet(theme: theme, appearance: window.effectiveAppearance)
        }
        objc_setAssociatedObject(self, &visualDebuggerThemeKey, observation, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    func configureVisualDebugger(_ panel: VisualDebuggerView) {
        let textView = containerTextView
        let selection = textView.sourceSelectedRange
        let sourceOffset = selection.location
        // NSTextView exposes the active TextKit selection.  The source range
        // above comes from MarkdownTextView's public source-coordinate API;
        // keeping both values here makes the coordinate boundary explicit.
        let textKitRange = textView.selectedRange()
        let textKitOffset = textKitRange.location
        let attributes = styleFacts(atSourceOffset: sourceOffset, in: textView)
        let context = AssetResolutionContext(
            documentURL: markdownDocument.url,
            workspaceRoot: markdownDocument.url?.deletingLastPathComponent()
        )
        let report = MarkdownCompatibility.diagnose(markdownDocument.parsed, for: .gitHub)
        panel.model = VisualDebuggerModel(input: VisualDebuggerInput(
            document: markdownDocument.parsed,
            selection: selection,
            mode: textView.mode,
            style: attributes,
            mapping: VisualDebuggerMapping(
                sourceRange: selection,
                textKitRange: textKitRange,
                sourceOffset: sourceOffset,
                textKitOffset: textKitOffset,
                isCanonical: textView.sourceSelectedRanges.first == selection
            ),
            renderTargetReport: report,
            assets: AssetDoctor.diagnose(markdownDocument.parsed, context: context, probe: localAssetProbe())
        ))
    }

    func refreshVisualDebuggerIfVisible() {
        guard let visualDebuggerPanel else { return }
        configureVisualDebugger(visualDebuggerPanel)
    }

    func visualDebugger(_ view: VisualDebuggerView, didCopy summary: String) {
        // Copy is complete in the panel.  This hook is intentionally empty so
        // callers can observe the action without changing document state.
    }

    private func styleFacts(
        atSourceOffset sourceOffset: Int,
        in textView: MarkdownTextView
    ) -> VisualDebuggerStyleFacts {
        let storage = textView.textStorage
        let index = max(0, min(sourceOffset, max(0, storage?.length ?? 0) - 1))
        guard let storage, storage.length > 0 else {
            return VisualDebuggerStyleFacts(
                fontFamily: textView.styleSheet.bodyFont().familyName ?? "System",
                pointSize: Double(textView.styleSheet.bodyFont().pointSize),
                foregroundColor: colorDescription(textView.styleSheet.text),
                paragraphAlignment: "left",
                lineHeight: Double(textView.styleSheet.lineHeight)
            )
        }

        let attributes = storage.attributes(at: index, effectiveRange: nil)
        let font = attributes[.font] as? NSFont ?? textView.styleSheet.bodyFont()
        let paragraph = attributes[.paragraphStyle] as? NSParagraphStyle
        var facts: [String] = []
        if attributes[.drHidden] as? Bool == true { facts.append("hidden marker") }
        if attributes[.drMarker] as? Bool == true { facts.append("syntax marker") }
        if attributes[.drFragment] != nil { facts.append("render fragment") }
        if attributes[.drLink] != nil { facts.append("link") }
        if attributes[.drPathToken] != nil { facts.append("path token") }
        return VisualDebuggerStyleFacts(
            fontFamily: font.familyName ?? "System",
            pointSize: Double(font.pointSize),
            foregroundColor: colorDescription(attributes[.foregroundColor] as? NSColor ?? textView.styleSheet.text),
            paragraphAlignment: Self.alignmentName(paragraph?.alignment ?? .left),
            lineHeight: Double(paragraph?.minimumLineHeight ?? textView.styleSheet.lineHeight),
            lineSpacing: Double(paragraph?.lineSpacing ?? 0),
            attributes: facts
        )
    }

    private func colorDescription(_ color: NSColor) -> String {
        let converted = color.usingColorSpace(.sRGB) ?? color
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        converted.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return String(format: "#%02X%02X%02X%02X", Int(red * 255), Int(green * 255), Int(blue * 255), Int(alpha * 255))
    }

    private static func alignmentName(_ alignment: NSTextAlignment) -> String {
        switch alignment {
        case .right: "right"
        case .center: "center"
        case .justified: "justified"
        case .natural: "natural"
        default: "left"
        }
    }
}
