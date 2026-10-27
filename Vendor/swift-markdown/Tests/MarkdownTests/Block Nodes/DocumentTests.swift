/*
 This source file is part of the Swift.org open source project

 Copyright (c) 2021 Apple Inc. and the Swift project authors
 Licensed under Apache License v2.0 with Runtime Library Exception

 See https://swift.org/LICENSE.txt for license information
 See https://swift.org/CONTRIBUTORS.txt for Swift project authors
*/

import XCTest
import Foundation
import Markdown

final class DocumentTests: XCTestCase {
    func testDocumentFromSequence() {
        let children = [
            Paragraph(Text("First")),
            Paragraph(Text("Second")),
        ]
        let document = Document(children)
        let expectedDump = """
            Document
            ├─ Paragraph
            │  └─ Text "First"
            └─ Paragraph
               └─ Text "Second"
            """
        XCTAssertEqual(expectedDump, document.debugDescription())
    }

    func testParseURL() {
        let readmeURL = URL(fileURLWithPath: #file)
            .deletingLastPathComponent() // Block Nodes
            .appendingPathComponent("..") // MarkupTests
            .appendingPathComponent("..") // Tests
            .appendingPathComponent("..") // Project
            .appendingPathComponent("README.md")
        XCTAssertNoThrow(try Document(parsing: readmeURL))
        XCTAssertThrowsError(try Document(parsing: URL(fileURLWithPath: #file)
            .appendingPathComponent("doesntexist")))
    }
 
    func testParseNewlineCharacters() {
        let inputParagraphString = """
        # First\n
        ## Second\r
        ### Third\r\n
        """
        let document = Document(parsing: inputParagraphString, options: [.parseBlockDirectives, .parseSymbolLinks])
        let expectedDump = """
                Document
                ├─ Heading level: 1
                │  └─ Text "First"
                ├─ Heading level: 2
                │  └─ Text "Second"
                └─ Heading level: 3
                   └─ Text "Third"
                """
        XCTAssertEqual(expectedDump, document.debugDescription())
    }
    func testConsumedBlocksMatchDocumentIncludingReferencesAndRanges() {
        let source = """
        # Héading 😀

        Text [reference][id] and **bold**.

        - [x] done
          - nested

        | a | b |
        |---|---|
        | 1 | 2 |

        > quote

        ```swift
        let x = 1
        ```

        [id]: file.md "later"
        """
        let url = URL(fileURLWithPath: "/tmp/consumed-blocks.md")
        let document = Document(parsing: source, source: url, options: [.disableSmartOpts])
        var blocks: [Markup] = []
        Document.forEachParsedBlock(in: source, source: url, options: [.disableSmartOpts]) {
            blocks.append($0)
        }
        let expected = Array(document.children)
        XCTAssertEqual(blocks.count, 6)
        XCTAssertEqual(blocks.map { $0.debugDescription() }, expected.map { $0.detachedFromParent.debugDescription() })
        XCTAssertEqual(blocks.map(\.range), expected.map(\.range))
        XCTAssertTrue(blocks.allSatisfy { $0.parent == nil })
    }

    func testConsumedLeavesAndBlockDirectives() {
        for source in ["", "---\n", "    code\n", "@Note {\ninside\n}\n"] {
            for options: ParseOptions in [[], [.parseBlockDirectives]] {
                let document = Document(parsing: source, options: options)
                var blocks: [Markup] = []
                Document.forEachParsedBlock(in: source, options: options) { blocks.append($0) }
                XCTAssertEqual(blocks.map { $0.debugDescription() }, document.children.map { $0.detachedFromParent.debugDescription() })
                XCTAssertEqual(blocks.map(\.range), document.children.map(\.range))
            }
        }
    }

    func testConsumedBlocksSurviveNestedAndConcurrentParses() async {
        let source = "# Outer\n\nText **bold** and [link](https://example.com).\n\n- [x] task\n"
        let expected = Document(parsing: source).children.map { $0.detachedFromParent.debugDescription() }
        let results = await withTaskGroup(of: [String].self, returning: [[String]].self) { group in
            for _ in 0..<16 {
                group.addTask {
                    var blocks: [Markup] = []
                    Document.forEachParsedBlock(in: source) { block in
                        Document.forEachParsedBlock(in: "> nested\n\n---\n") { _ in }
                        blocks.append(block)
                    }
                    // Read every retained Swift tree after both C scopes end.
                    return blocks.map { $0.debugDescription() }
                }
            }
            var results: [[String]] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.count, 16)
        for result in results { XCTAssertEqual(result, expected) }
    }

}
