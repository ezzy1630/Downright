import Testing
@testable import drdownright

struct MarkdownCLITests {
    @Test func defaultActionIsOpen() throws {
        let action = try MarkdownCLI.parse(["README.md"])
        #expect(action == .open(MarkdownCLI.OpenOptions(), paths: ["README.md"]))
    }

    @Test func commandsParseTheirOptions() throws {
        #expect(try MarkdownCLI.parse(["read", "--json", "-"]) == .read(json: true, paths: ["-"]))
        #expect(try MarkdownCLI.parse(["export", "-f", "html", "-o", "out.html", "doc.md"]) == .export(format: .html, output: "out.html", paths: ["doc.md"]))
        #expect(try MarkdownCLI.parse(["check", "--json", "doc.md"]) == .check(json: true, paths: ["doc.md"]))
    }

    @Test func badArgumentsHaveActionableErrors() {
        #expect(throws: MarkdownCLI.ParseError.unknownOption("--wat")) {
            try MarkdownCLI.parse(["read", "--wat"])
        }
        #expect(throws: MarkdownCLI.ParseError.missingValue("-o")) {
            try MarkdownCLI.parse(["export", "-o"])
        }
    }

    @Test func htmlExportIsSelfContainedAndEscaped() {
        let html = MarkdownCLI.html(for: "# Hello <world>\n\n- [x] done\n\n`code`")
        #expect(html.contains("<h1>Hello &lt;world&gt;</h1>"))
        #expect(html.contains("<input type=\"checkbox\" disabled checked>"))
        #expect(html.contains("<code>code</code>"))
        #expect(!html.contains("http://") && !html.contains("https://"))
    }

    @Test func healthFindingsAreDeterministic() {
        let markdown = "[broken](missing.md)\n"
        let first = MarkdownCLI.diagnostics(for: markdown)
        let second = MarkdownCLI.diagnostics(for: markdown)
        #expect(first.map(\.id) == second.map(\.id))
    }
}
