import AppKit
import Testing
import MarkdownCore
import MarkdownRender
@testable import DownrightApp

@Suite(.serialized)
@MainActor
struct FrontMatterEditorTests {
    @Test
    func rendersFlatFieldsAndUsesAccessibleLabels() {
        let editor = FrontMatterEditorView(styleSheet: .current)
        editor.document = MarkdownParser.parse("---\ntitle: Demo\ndraft: false\n---\n\n# Body\n")

        #expect(editor.renderedFieldCount == 2)
        #expect(!editor.showsSourceModePrompt)
        #expect(editor.accessibilityRole() == .group)
        #expect(editor.accessibilityLabel() == "Front matter editor")
    }

    @Test
    func complexYamlShowsSourceModePrompt() {
        let editor = FrontMatterEditorView(styleSheet: .current)
        editor.document = MarkdownParser.parse("---\ntags:\n  - one\n  - two\n---\nBody\n")

        #expect(editor.renderedFieldCount == 1)
        #expect(editor.showsSourceModePrompt)
    }

    @Test
    func missingFrontMatterDisablesAddForm() {
        let editor = FrontMatterEditorView(styleSheet: .current)
        editor.document = MarkdownParser.parse("# Body\n")

        #expect(editor.renderedFieldCount == 0)
        #expect(editor.showsSourceModePrompt)
    }

    @Test
    func editorDelegateReceivesSourceModeRequest() {
        let editor = FrontMatterEditorView(styleSheet: .current)
        let delegate = FrontMatterEditorSpy()
        editor.delegate = delegate
        delegate.editor = editor

        delegate.editorWantsSourceMode()
        #expect(delegate.didRequestSourceMode)
    }
}

@MainActor
private final class FrontMatterEditorSpy: FrontMatterEditorDelegate {
    weak var editor: FrontMatterEditorView?
    var didRequestSourceMode = false

    func frontMatterEditor(
        _ editor: FrontMatterEditorView,
        didRequest operation: FrontMatterEditOperation
    ) { }

    func frontMatterEditorWantsSourceMode(_ editor: FrontMatterEditorView) {
        didRequestSourceMode = true
    }

    func editorWantsSourceMode() {
        guard let editor else { return }
        frontMatterEditorWantsSourceMode(editor)
    }
}
