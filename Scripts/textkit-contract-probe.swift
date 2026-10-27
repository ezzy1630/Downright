// Temporary macOS TextKit isolation probe; remove after the app regression is
// repaired. It uses no Downright package graph and never reads user documents.
import AppKit

final class PlainTextView: NSTextView {}
final class PlainContentStorage: NSTextContentStorage {}

final class ForwardingContentStorage: NSTextContentStorage {
    var retainsElements = false
    private var held: [NSTextElement] = []
    private var calls = 0
    override func enumerateTextElements(from location: NSTextLocation?,
                                       options: NSTextContentManager.EnumerationOptions = [],
                                       using block: (NSTextElement) -> Bool) -> NSTextLocation? {
        calls += 1
        let call = calls
        let result = super.enumerateTextElements(from: location, options: options) { element in
            if retainsElements { held.append(element) }
            let more = block(element)
            if call < 20 { print("ENUM call=\(call) options=\(options.rawValue) from=\(String(describing: location)) element=\(String(describing: element.elementRange)) continue=\(more)") }
            return more
        }
        if call < 20 { print("ENUM end call=\(call) result=\(String(describing: result))") }
        return result
    }
}

final class RangedParagraph: NSTextParagraph {
    private let content: NSTextRange
    private let separator: NSTextRange
    init(text: NSAttributedString, manager: NSTextContentManager,
         element: NSTextRange, separator: NSTextRange) {
        self.content = NSTextRange(location: element.location, end: separator.location)!
        self.separator = separator
        super.init(attributedString: text)
        textContentManager = manager
        elementRange = element
    }
    override var paragraphContentRange: NSTextRange? { content }
    override var paragraphSeparatorRange: NSTextRange? { separator }
}

final class ExplicitContentStorage: NSTextContentStorage {
    var usesRangedParagraph = false
    private var ranges: [NSRange] = []
    private var cache: [Int: NSTextParagraph] = [:]
    private var usesExplicitElements = false
    func prepare() {
        usesExplicitElements = true
        let text = textStorage!.string as NSString
        var cursor = 0
        while cursor < text.length {
            let range = text.paragraphRange(for: NSRange(location: cursor, length: 0))
            ranges.append(range)
            cursor = NSMaxRange(range)
        }
    }
    override func enumerateTextElements(from location: NSTextLocation?,
                                       options: NSTextContentManager.EnumerationOptions = [],
                                       using block: (NSTextElement) -> Bool) -> NSTextLocation? {
        guard usesExplicitElements else {
            return super.enumerateTextElements(from: location, options: options, using: block)
        }
        let reverse = options.contains(.reverse)
        let start = documentRange.location
        let offset = location.map { self.offset(from: start, to: $0) } ?? (reverse ? textStorage!.length : 0)
        let indices = reverse ? Array(ranges.indices.reversed()) : Array(ranges.indices)
        var edge = offset
        for index in indices {
            let range = ranges[index]
            if reverse ? range.location >= offset : NSMaxRange(range) <= offset { continue }
            let element: NSTextParagraph
            if let saved = cache[index] { element = saved }
            else {
                let first = self.location(start, offsetBy: range.location)!
                let last = self.location(start, offsetBy: NSMaxRange(range))!
                let elementRange = NSTextRange(location: first, end: last)!
                let text = textStorage!.attributedSubstring(from: range)
                if usesRangedParagraph {
                    let suffix = (text.string as NSString).hasSuffix("\n") ? 1 : 0
                    let separatorStart = self.location(start, offsetBy: NSMaxRange(range) - suffix)!
                    let separator = NSTextRange(location: separatorStart, end: last)!
                    element = RangedParagraph(text: text, manager: self, element: elementRange, separator: separator)
                } else {
                    element = NSTextParagraph(attributedString: text)
                    element.textContentManager = self
                    element.elementRange = elementRange
                }
                cache[index] = element
            }
            let more = block(element)
            edge = reverse ? range.location : NSMaxRange(range)
            if !more { break }
        }
        return self.location(start, offsetBy: edge)
    }
}

final class IdentitySubstitution: NSObject, NSTextContentStorageDelegate {
    func textContentStorage(_ storage: NSTextContentStorage, textParagraphWith range: NSRange) -> NSTextParagraph? { nil }
}
final class ForwardingFragment: NSTextLayoutFragment {
    override func draw(at point: CGPoint, in context: CGContext) { super.draw(at: point, in: context) }
}
final class FragmentDelegate: NSObject, NSTextLayoutManagerDelegate {
    var explicitRange = false
    var subclass = false
    func textLayoutManager(_ manager: NSTextLayoutManager, textLayoutFragmentFor location: NSTextLocation,
                           in element: NSTextElement) -> NSTextLayoutFragment {
        let range = explicitRange ? element.elementRange : nil
        if subclass { return ForwardingFragment(textElement: element, range: range) }
        return NSTextLayoutFragment(textElement: element, range: range)
    }
}

final class ElementDelegate: NSObject, NSTextContentStorageDelegate {
    var groupsParagraphs = false
    private var elements: [Int: NSTextParagraph] = [:]
    func textContentManager(_ manager: NSTextContentManager, textElementAt location: NSTextLocation) -> NSTextElement? {
        guard let content = manager as? NSTextContentStorage, let storage = content.textStorage else { return nil }
        let start = manager.documentRange.location
        let offset = manager.offset(from: start, to: location)
        guard offset < storage.length else { return nil }
        let text = storage.string as NSString
        let range: NSRange
        if groupsParagraphs {
            let first = (offset / 120) * 120
            range = NSRange(location: first, length: min(120, storage.length - first))
        } else { range = text.paragraphRange(for: NSRange(location: offset, length: 0)) }
        if let element = elements[range.location] { return element }
        let first = manager.location(start, offsetBy: range.location)!
        let last = manager.location(start, offsetBy: NSMaxRange(range))!
        let end = manager.location(start, offsetBy: NSMaxRange(range) - 1)!
        let element = RangedParagraph(text: storage.attributedSubstring(from: range), manager: manager,
            element: NSTextRange(location: first, end: last)!, separator: NSTextRange(location: end, end: last)!)
        elements[range.location] = element
        return element
    }
}

enum ProbeVariant: String {
    case stock
    case objcForward = "objc-forward"
    case rangeDelegate = "range-delegate"
    case groupDelegate = "group-delegate"
    case swiftView = "swift-view"
    case configuredView = "configured-view"
    case plainContent = "plain-content"
    case retainedContent = "retained-content"
    case forwardingContent = "forwarding-content"
    case explicitContent = "explicit-content"
    case rangedContent = "ranged-content"
    case substitution
    case defaultFragment = "default-fragment"
    case explicitFragment = "explicit-fragment"
    case subclassFragment = "subclass-fragment"
    case lateContent = "late-content"
    case transactionalContent = "transactional-content"
    case combined = "combined"
    case combinedAll = "combined-all"
}

@main
struct TextKitContractProbe {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2,
              let variant = ProbeVariant(rawValue: CommandLine.arguments[1]) else {
            fputs("Expected a supported TextKit probe variant\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let text = String(repeating: "Native text rendering has predictable paragraph locations.\n\n", count: 15)
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 16), .foregroundColor: NSColor.black])
        let content: NSTextContentStorage
        if variant == .objcForward {
            let type = NSClassFromString("DRForwardingContentStorage") as! NSTextContentStorage.Type
            content = type.init()
        }
        else if variant == .plainContent { content = PlainContentStorage() }
        else if variant == .forwardingContent || variant == .retainedContent {
            let forwarding = ForwardingContentStorage()
            forwarding.retainsElements = variant == .retainedContent
            content = forwarding
        }
        else if [.explicitContent, .rangedContent, .lateContent, .transactionalContent, .combined, .combinedAll].contains(variant) {
            let explicit = ExplicitContentStorage()
            explicit.usesRangedParagraph = variant != .explicitContent
            content = explicit
        } else { content = NSTextContentStorage() }
        let layout = NSTextLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 600, height: CGFloat.greatestFiniteMagnitude))
        container.widthTracksTextView = false
        container.lineFragmentPadding = 0
        layout.textContainer = container
        content.addTextLayoutManager(layout)
        content.textStorage = storage
        let configuresLate = [.lateContent, .transactionalContent, .combinedAll].contains(variant)
        if !configuresLate { (content as? ExplicitContentStorage)?.prepare() }
        let elements = ElementDelegate()
        elements.groupsParagraphs = variant == .groupDelegate
        if variant == .rangeDelegate || variant == .groupDelegate { content.delegate = elements }
        let substitution = IdentitySubstitution()
        if variant == .substitution || variant == .combinedAll { content.delegate = substitution }
        let frame = NSRect(x: 0, y: 0, width: 688, height: 480)
        let view: NSTextView = [.swiftView, .combinedAll].contains(variant) ? PlainTextView(frame: frame, textContainer: container) : NSTextView(frame: frame, textContainer: container)
        let fragment = FragmentDelegate()
        fragment.explicitRange = [.explicitFragment, .subclassFragment, .combined, .combinedAll].contains(variant)
        fragment.subclass = [.subclassFragment, .combined, .combinedAll].contains(variant)
        if [.defaultFragment, .explicitFragment, .subclassFragment, .combined, .combinedAll].contains(variant) { layout.delegate = fragment }
        if configuresLate {
            if variant == .transactionalContent {
                content.performEditingTransaction { (content as? ExplicitContentStorage)?.prepare() }
            } else { (content as? ExplicitContentStorage)?.prepare() }
            layout.invalidateLayout(for: layout.documentRange)
        }
        view.isVerticallyResizable = true
        view.isHorizontallyResizable = false
        view.minSize = NSSize(width: 600, height: 0)
        view.maxSize = NSSize(width: 688, height: CGFloat.greatestFiniteMagnitude)
        view.textContainerInset = NSSize(width: 44, height: 36)
        view.backgroundColor = .white
        if variant == .configuredView || variant == .combinedAll {
            view.allowsUndo = true
            view.isRichText = true
            view.importsGraphics = false
            view.usesFontPanel = false
            view.usesFindBar = false
            view.isAutomaticQuoteSubstitutionEnabled = false
            view.isAutomaticDashSubstitutionEnabled = false
            view.isAutomaticTextReplacementEnabled = false
            view.isAutomaticSpellingCorrectionEnabled = false
            view.smartInsertDeleteEnabled = false
            view.isIncrementalSearchingEnabled = false
            view.setAccessibilityElement(true)
            view.setAccessibilityRole(.textArea)
        }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 700, height: 480))
        scroll.documentView = view
        let window = NSWindow(contentRect: scroll.frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.title = "TextKit contract: " + variant.rawValue
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        window.layoutIfNeeded()
        scroll.layoutSubtreeIfNeeded()
        layout.ensureLayout(for: layout.documentRange)
        layout.textViewportLayoutController.layoutViewport()
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        window.displayIfNeeded()
        if variant == .rangeDelegate || variant == .groupDelegate {
            var count = 0
            _ = content.enumerateTextElements(from: nil) { element in
                if count < 4 { print("DELEGATE element=\(String(describing: element.elementRange))") }
                count += 1
                return true
            }
            print("DELEGATE count=\(count)")
        }
        let viewport = layout.textViewportLayoutController.viewportRange
        print("TEXTKIT \(variant.rawValue): viewport=\(String(describing: viewport)) bounds=\(layout.textViewportLayoutController.viewportBounds) usage=\(layout.usageBoundsForTextContainer) observerOwns=\((storage.textStorageObserver as AnyObject?) === content) bindsContent=\(view.textContentStorage === content) bindsLayout=\(view.textLayoutManager === layout) layoutDelegate=\(String(describing: layout.delegate)) contentDelegate=\(String(describing: content.delegate))")
        withExtendedLifetime((content, substitution, fragment, elements)) { window.close() }
        exit(viewport == nil ? 1 : 0)
    }
}
