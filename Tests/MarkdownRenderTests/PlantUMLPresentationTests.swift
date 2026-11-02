import AppKit
import MarkdownCore
import Testing
@testable import MarkdownRender

@MainActor
struct PlantUMLPresentationTests {
    @Test func asynchronousImageUpdatesHeightAndCanBeRequestedAfterEviction() throws {
        let source = "```puml\n@startuml\nAlice -> Bob: Hello\n@enduml\n```\n"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        let renderer = PendingPlantUMLRenderer()
        view.plantUMLRenderer = renderer
        view.mode = .read
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        view.prepareForDisplay()
        let manager = try #require(view.textLayoutManager)
        let fragment = try #require(manager.textLayoutFragment(for: manager.documentRange.location) as? PlantUMLFragment)
        _ = fragment.overrideHeight
        #expect(!renderer.completions.isEmpty)
        renderer.image = NSImage(size: NSSize(width: 120, height: 600))
        let completions = renderer.completions
        renderer.completions.removeAll()
        completions.forEach { $0() }
        #expect(view.pendingResizeRequestForTesting == .viewport)
        #expect(try #require(fragment.overrideHeight) >= 600)
        renderer.image = nil
        _ = fragment.overrideHeight
        #expect(!renderer.completions.isEmpty, "a retained fragment must recover after cache eviction")
        #expect(storage.string == source)
        let staleCompletions = renderer.completions
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: "Other document.\n")
        view.update(document: MarkdownParser.parse(storage.string), dirty: .wholesale)
        staleCompletions.forEach { $0() }
        #expect(view.pendingResizeRequestForTesting == nil, "old image callbacks must not move the replacement document")
        #expect(storage.string == "Other document.\n")
    }

    @Test func adapterCanBeInstalledBeforeInitialParse() throws {
        let source = "```puml\n@startuml\nAlice -> Bob: Hello\n@enduml\n```\n"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(frame: .zero, storage: storage)
        view.plantUMLRenderer = FixedPlantUMLRenderer()
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        let payload = try #require(storage.attribute(.drFragment, at: 0, effectiveRange: nil) as? FragmentPayload)
        #expect(payload.kind == .plantUML)
        #expect(storage.string == source)
    }

    @Test func hostAdapterSelectsDiagramWithoutChangingSourceOrSplitPresentation() throws {
        let source = "```puml\n@startuml\nAlice -> Bob: Hello\n@enduml\n```\n"
        let storage = NSTextStorage(string: source)
        let view = MarkdownTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400), storage: storage)
        view.update(document: MarkdownParser.parse(source), dirty: .wholesale)
        func kind() -> FragmentKind? {
            (storage.attribute(.drFragment, at: 0, effectiveRange: nil) as? FragmentPayload)?.kind
        }
        #expect(kind() == .codeBlock)
        let loader = FixedPlantUMLRenderer()
        view.plantUMLRenderer = loader
        #expect(kind() == .plantUML)
        let shared = MarkdownTextView(frame: view.frame, storage: storage, styleSheet: view.styleSheet, sharingPresentationOf: view)
        #expect(shared.plantUMLRenderer === loader)
        #expect(kind() == .plantUML)
        view.mode = .source
        #expect(kind() == .codeBlock)
        view.mode = .live
        #expect(kind() == .plantUML)
        #expect(storage.string == source)
    }
}

private final class FixedPlantUMLRenderer: PlantUMLRendering {
    func cachedImage(source: String, dark: Bool) -> NSImage? { NSImage(size: NSSize(width: 100, height: 80)) }
    func hasFailed(source: String, dark: Bool) -> Bool { false }
    func render(source: String, dark: Bool, completion: @escaping @MainActor () -> Void) {}
}

private final class PendingPlantUMLRenderer: PlantUMLRendering {
    var image: NSImage?
    var completions: [@MainActor () -> Void] = []
    func cachedImage(source: String, dark: Bool) -> NSImage? { image }
    func hasFailed(source: String, dark: Bool) -> Bool { false }
    func render(source: String, dark: Bool, completion: @escaping @MainActor () -> Void) {
        completions.append(completion)
    }
}
