import AppKit
import Foundation
import MarkdownCore
import MarkdownRender
import Testing
@testable import DownrightApp

/// Quick Look, pointed inward.
///
/// Downright already ships the extension that lets *Finder* preview a Markdown
/// file; this is the same affordance aimed at whatever the reader is pointing
/// at inside a document.  Two things are worth holding still: what each kind of
/// target routes to, and — much more important — that the key which triggers it
/// can never be a character.
@Suite(.serialized)
struct DocumentQuickLookTests {

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DocumentQuickLookTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func resolve(
        _ kind: ContextTarget.Kind,
        documentURL: URL? = nil,
        resolution: PathResolver.Resolution? = nil
    ) -> QuickLookRequest? {
        QuickLookRequest.resolve(
            ContextTarget(kind: kind, sourceRange: NSRange(location: 0, length: 0)),
            documentURL: documentURL,
            pathResolution: { _ in resolution },
            fileExists: { FileManager.default.fileExists(atPath: $0.path) }
        )
    }

    // MARK: - Routing

    /// An embedded image opens in the lightbox, not the system panel.  A click
    /// on that same image already opens the lightbox (§7.1), and force click
    /// summoning a second, different image viewer for the same picture would
    /// be two answers to one question.
    @Test func anEmbeddedImageGoesToTheAppsOwnLightbox() {
        #expect(resolve(.image("diagram.png")) == .lightbox(source: "diagram.png"))
    }

    @Test func aResolvedPathTokenGoesToTheSystemPanel() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.ts")
        try "export const x = 1\n".write(to: file, atomically: true, encoding: .utf8)

        let request = resolve(
            .pathToken(PathToken(rawPath: "src/session.ts")),
            resolution: .init(url: file, exists: true, isDirectory: false, line: nil)
        )
        #expect(request == .panel(file.standardizedFileURL))
    }

    /// §8.4 draws a path that is not there as missing.  Previewing it would be
    /// a second, contradictory answer about the same file.
    @Test func aMissingPathTokenIsNotPreviewable() {
        #expect(resolve(
            .pathToken(PathToken(rawPath: "src/gone.ts")),
            resolution: .init(url: URL(fileURLWithPath: "/nope/gone.ts"), exists: false,
                              isDirectory: false, line: nil)
        ) == nil)
        #expect(resolve(.pathToken(PathToken(rawPath: "src/gone.ts")), resolution: nil) == nil)
    }

    @Test func aRelativeLinkResolvesAgainstTheDocumentsFolder() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let documentURL = directory.appendingPathComponent("notes.md")
        let sibling = directory.appendingPathComponent("design.md")
        try "# Design\n".write(to: sibling, atomically: true, encoding: .utf8)

        #expect(resolve(.link("design.md"), documentURL: documentURL)
            == .panel(sibling.standardizedFileURL))
        // Nothing to resolve against, and no guessing.
        #expect(resolve(.link("design.md"), documentURL: nil) == nil)
        #expect(resolve(.link("missing.md"), documentURL: documentURL) == nil)
    }

    @Test func aFileURLLinkIsPreviewedDirectly() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let sibling = directory.appendingPathComponent("spec.pdf")
        try Data("%PDF-1.4\n".utf8).write(to: sibling)
        #expect(resolve(.link(sibling.absoluteString)) == .panel(sibling.standardizedFileURL))
    }

    /// Turning a preview gesture into "launch this URL" would route around the
    /// trust prompt a real click goes through.
    @Test func webAnchorAndAutomationLinksAreNeverPreviewed() {
        #expect(resolve(.link("https://example.com")) == nil)
        #expect(resolve(.link("#a-heading")) == nil)
        #expect(resolve(.link("x-downright://run")) == nil)
        #expect(resolve(.link("")) == nil)
    }

    @Test func targetsWithNoFileBehindThemAreNotPreviewable() {
        #expect(resolve(.heading(0)) == nil)
        #expect(resolve(.codeBlock(NSRange(location: 0, length: 4))) == nil)
        #expect(resolve(.table(NSRange(location: 0, length: 4))) == nil)
        #expect(resolve(.selection) == nil)
        #expect(resolve(.plain) == nil)
    }

    // MARK: - The trigger

    /// The one that matters.  A menu item carrying a bare Space as its key
    /// equivalent intercepts the space bar before the text view ever sees it,
    /// and `applyKeyEquivalent` only refuses bindings without ⌘ or ⌃ — so the
    /// guard has to hold in the table too, not just in the menu builder.
    @Test @MainActor func noCommandBindsAnUnmodifiedSpace() {
        for (command, bindings) in KeybindingDefaults.table {
            for binding in bindings where binding.key == "space" {
                #expect(
                    !binding.modifiers.isEmpty,
                    "\(command.rawValue) binds a bare Space, which is a character in Live and Source"
                )
            }
        }
    }

    @Test @MainActor func quickLookIsAFileMenuCommandOnTheStandardChord() {
        _ = NSApplication.shared
        #expect(Command.quickLook.title == "Quick Look")
        #expect(Command.quickLook.menu == .file)
        #expect(KeybindingDefaults.table[.quickLook] == [KeyBinding("y", .command)])

        var found: NSMenuItem?
        func walk(_ menu: NSMenu) {
            for item in menu.items {
                if MainMenu.command(for: item) == .quickLook { found = item }
                if let submenu = item.submenu { walk(submenu) }
            }
        }
        walk(MainMenu.build())
        #expect(found?.keyEquivalent == "y")
        #expect(found?.keyEquivalentModifierMask == [.command])
    }

    /// Enabled only when there is something to preview, so the menu never
    /// offers a command that would be a no-op.
    @Test func quickLookIsOfferedOnlyWithATargetUnderTheCaret() {
        #expect(!Command.quickLook.isEnabled(in: CommandContext(hasDocument: true)))
        #expect(Command.quickLook.isEnabled(
            in: CommandContext(hasDocument: true, hasQuickLookTarget: true)
        ))
        #expect(!Command.quickLook.isEnabled(
            in: CommandContext(hasDocument: false, hasQuickLookTarget: true)
        ))
    }

    // MARK: - The real window

    @MainActor
    private func makeController(text: String, at url: URL) throws -> DocumentWindowController {
        try text.write(to: url, atomically: true, encoding: .utf8)
        let controller = DocumentWindowController()
        try controller.open(url, mode: .live)
        return controller
    }

    @Test @MainActor func theCommandFollowsTheCaretAndReportsWhenThereIsNothingToShow() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("notes.md")
        let source = "See [the design](design.md) here.\n"
        let controller = try makeController(text: source, at: url)
        defer { controller.close() }

        let ns = source as NSString
        controller.containerTextView.setSourceSelectedRanges([
            NSRange(location: ns.range(of: "here").location, length: 0),
        ])
        #expect(!controller.hasQuickLookTarget)
        #expect(!controller.commandContext.hasQuickLookTarget)
        // Reports failure rather than swallowing the key, so a trigger that
        // resolves to nothing can still fall through to what it would
        // otherwise have done.
        #expect(!controller.quickLookAtSelection())

        controller.containerTextView.setSourceSelectedRanges([
            NSRange(location: ns.range(of: "the design").location + 2, length: 0),
        ])
        #expect(controller.hasQuickLookTarget)
        #expect(controller.commandContext.hasQuickLookTarget)
    }
}
