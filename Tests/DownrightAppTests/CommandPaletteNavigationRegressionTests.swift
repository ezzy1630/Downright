import AppKit
import Foundation
import Testing
@testable import DownrightApp

@MainActor
@Suite(.serialized)
struct CommandPaletteNavigationRegressionTests {
    @Test func openInPlaceReportsWhetherTheIntendedDestinationOpened() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current.md")
        let destination = root.appendingPathComponent("destination.md")
        try Data("# Current\n".utf8).write(to: current)
        try Data("# Destination\n".utf8).write(to: destination)
        let controller = DocumentWindowController()
        try controller.open(current, mode: .source)
        defer { controller.close() }
        #expect(!controller.openInPlace(root.appendingPathComponent("missing.md")))
        #expect(controller.markdownDocument.url == current.resolvingSymlinksInPath())
        #expect(controller.openInPlace(destination))
        #expect(controller.markdownDocument.url == destination.resolvingSymlinksInPath())
    }

    @Test func failedWorkspaceOpenDoesNotSelectDestinationRangeInPreviousDocument() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current.md")
        try Data("# Current\n\nThe original document remains open.\n".utf8).write(to: current)
        let controller = DocumentWindowController()
        try controller.open(current, mode: .source)
        defer { controller.close() }
        let destinationRange = NSRange(location: 15, length: 5)
        let result = QuickOpenResult(
            id: "missing-heading", kind: .symbol, title: "Missing",
            action: .openAt(root.appendingPathComponent("missing.md"), destinationRange)
        )
        controller.commandPalette(CommandPaletteView(), didChoose: result)
        #expect(controller.markdownDocument.url == current.resolvingSymlinksInPath())
        #expect(controller.containerTextView.sourceSelectedRange != destinationRange)
    }

    @Test(arguments: [false, true])
    func successfulWorkspaceOpenSelectsHeadingInDestination(viaSymlink: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let current = root.appendingPathComponent("current.md")
        let destination = root.appendingPathComponent("destination.md")
        try Data("# Current\n".utf8).write(to: current)
        try Data("# Destination\n\n## Target\n".utf8).write(to: destination)
        let controller = DocumentWindowController()
        try controller.open(current, mode: .source)
        defer { controller.close() }
        let range = NSRange(location: 15, length: 9)
        let target = viaSymlink ? root.appendingPathComponent("alias.md") : destination
        if viaSymlink { try FileManager.default.createSymbolicLink(at: target, withDestinationURL: destination) }
        let result = QuickOpenResult(id: "heading", kind: .symbol, title: "Target", action: .openAt(target, range))
        controller.commandPalette(CommandPaletteView(), didChoose: result)
        #expect(controller.markdownDocument.url == destination.resolvingSymlinksInPath())
        #expect(controller.containerTextView.sourceSelectedRange == range)
    }
}
