import Foundation
import Testing
import MarkdownCore
import MarkdownRender
@testable import DownrightApp

@Suite(.serialized)
struct AssetDoctorTests {
    @Test
    func extractsExactUnicodeDestinationRange() throws {
        let text = "# Café\n\n![alt](<images/naïve (copy).png> \"title\")\n"
        let document = MarkdownParser.parse(text)
        let context = AssetResolutionContext(
            documentURL: URL(fileURLWithPath: "/tmp/docs/readme.md"),
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        let reference = try #require(AssetDoctor.references(in: document, context: context).first)
        let ns = text as NSString
        #expect(ns.substring(with: reference.destinationRange) == "images/naïve (copy).png")
        #expect(reference.line == 3)
    }

    @Test
    func diagnosesKindsWithoutProbingRemoteOrData() throws {
        let text = "![x](https://example.com/a.png) ![x](data:image/png;base64,AA==) ![](/Users/me/a.png)\n"
        let document = MarkdownParser.parse(text)
        let context = AssetResolutionContext(
            documentURL: URL(fileURLWithPath: "/tmp/readme.md"),
            workspaceRoot: URL(fileURLWithPath: "/tmp")
        )
        let refs = AssetDoctor.references(in: document, context: context)
        #expect(refs.map(\.kind) == [.remoteHTTP, .dataURL, .absoluteLocal])
        let diagnostics = AssetDoctor.diagnose(document, context: context, probe: nil)
        #expect(diagnostics.contains { $0.code == .absolutePath })
        #expect(!diagnostics.contains { $0.code == .missing })
    }

    @Test
    func injectedProbeFindsMissingLargeUnsupportedAndDuplicate() {
        let text = "![a](a.bin)\n![b](b.bin)\n![same](a.bin)\n"
        let document = MarkdownParser.parse(text)
        let root = URL(fileURLWithPath: "/tmp/work")
        let context = AssetResolutionContext(
            documentURL: root.appendingPathComponent("readme.md"),
            workspaceRoot: root,
            maximumBytes: 10
        )
        let probe = AssetProbe { url in
            AssetMetadata(
                exists: true, isDirectory: false, byteSize: 20,
                fileExtension: url.pathExtension, contentIdentity: "same-content"
            )
        }
        let codes = Set(AssetDoctor.diagnose(document, context: context, probe: probe).map(\.code))
        #expect(codes.contains(.duplicate))
        #expect(codes.contains(.largeFile))
        #expect(codes.contains(.unsupportedFormat))
    }

    @Test
    func proposalRequiresExpectedSourceAndCanReverse() throws {
        let text = "![alt](old.png)\n"
        let document = MarkdownParser.parse(text)
        let reference = try #require(AssetDoctor.references(in: document).first)
        let proposal = AssetDoctor.relinkProposal(for: reference, to: "new.png")
        #expect(proposal.apply(to: text) == "![alt](new.png)\n")
        #expect(proposal.apply(to: "![alt](changed.png)\n") == nil)
        #expect(proposal.inverse(in: "![alt](new.png)\n") == text)
    }

    @Test
    func preservesTitleAndResolvesQueryFragmentAndPercentPath() throws {
        let text = "![alt](assets/a%20b.png?size=2#hero \"Title\")\n"
        let document = MarkdownParser.parse(text)
        let root = URL(fileURLWithPath: "/tmp/work")
        let reference = try #require(AssetDoctor.references(
            in: document,
            context: AssetResolutionContext(
                documentURL: root.appendingPathComponent("readme.md"),
                workspaceRoot: root
            )
        ).first)
        #expect(reference.title == "Title")
        #expect(reference.url?.path == "/tmp/work/assets/a b.png")
    }

    @Test
    func rejectsUnsafeSchemesAndReportsTraversal() throws {
        let text = "![x](javascript:alert(1))\n![x](../outside.png)\n"
        let document = MarkdownParser.parse(text)
        let root = URL(fileURLWithPath: "/tmp/work/docs")
        let context = AssetResolutionContext(
            documentURL: root.appendingPathComponent("readme.md"),
            workspaceRoot: root
        )
        let refs = AssetDoctor.references(in: document, context: context)
        #expect(refs.contains { $0.kind == .unsafe })
        let codes = Set(AssetDoctor.diagnose(document, context: context).map(\.code))
        #expect(codes.contains(.outsideWorkspace))
        #expect(codes.contains(.unsafe))
    }

    @Test
    func sharedReferenceProposalEditsDefinitionDestination() throws {
        let text = "![one][hero]\n![two][hero]\n\n[hero]: assets/hero.png \"Hero\"\n"
        let document = MarkdownParser.parse(text)
        let refs = AssetDoctor.references(in: document)
        #expect(refs.count == 2)
        let proposal = AssetDoctor.relinkProposal(for: try #require(refs.first), to: "assets/new.png")
        #expect(proposal.apply(to: text) == "![one][hero]\n![two][hero]\n\n[hero]: assets/new.png \"Hero\"\n")
    }

    @Test
    func keepsEscapedParenthesesInDestination() throws {
        let document = MarkdownParser.parse("![alt](assets/a\\(b\\).png)\n")
        let reference = try #require(AssetDoctor.references(in: document).first)
        #expect(reference.source == "assets/a\\(b\\).png")
    }

    @Test
    func marksMalformedRemoteDestination() throws {
        let document = MarkdownParser.parse("![alt](https://)\n")
        let reference = try #require(AssetDoctor.references(in: document).first)
        #expect(reference.kind == .malformed)
    }

    @Test
    func proposalUsesAngleDelimitersForLiteralLocalPaths() throws {
        let document = MarkdownParser.parse("![alt](old.png)\n")
        let reference = try #require(AssetDoctor.references(in: document).first)
        let proposal = AssetDoctor.relinkProposal(for: reference, to: "new file (copy).png")
        #expect(proposal.apply(to: "![alt](old.png)\n") == "![alt](<new file (copy).png>)\n")
    }

    @Test
    func relinkAndRenameResolveLiteralPathsAndReverseUnequalLengthEdits() throws {
        let sources = [
            "![alt](old.png \"Title\")\n",
            "![alt](<old.png> \"Title\")\n",
            "![alt][hero]\n\n[hero]: old.png \"Title\"\n",
            "![alt][hero]\n\n[hero]: <old.png> \"Title\"\n",
        ]
        let replacements = ["new file (copy).png", "résumé 🐈.png", "literal%20name.png"]
        let documentURL = URL(fileURLWithPath: "/tmp/asset-proposal/readme.md")
        for source in sources {
            let reference = try #require(AssetDoctor.references(in: MarkdownParser.parse(source)).first)
            for replacement in replacements {
                for kind in [AssetProposalKind.relink, .rename] {
                    let proposal = kind == .relink
                        ? AssetDoctor.relinkProposal(for: reference, to: replacement)
                        : AssetDoctor.renameProposal(for: reference, to: replacement)
                    let updated = try #require(proposal.apply(to: source))
                    #expect(!updated.contains("<<"))
                    #expect(updated.contains("\"Title\""))
                    #expect(proposal.inverse(in: updated) == source)
                    #expect(proposal.apply(to: source.replacingOccurrences(of: "old.png", with: "bad.png")) == nil)
                    #expect(proposal.inverse(in: updated.replacingOccurrences(of: replacement, with: "changed.png")) == nil)

                    var renderedSources: [String] = []
                    MarkdownParser.parse(updated).root.walk { block in
                        for inline in block.inlines {
                            inline.walk { span in
                                if case .image(let path, _) = span.kind { renderedSources.append(path) }
                            }
                        }
                    }
                    let renderedSource = try #require(renderedSources.first)
                    let request = try #require(LocalAssetPolicy.request(raw: renderedSource, documentURL: documentURL))
                    let expected = documentURL.deletingLastPathComponent().appendingPathComponent(replacement)
                    #expect(request.url == LocalAssetPolicy.canonicalFileURL(expected))
                    #expect(request.isSafeRelative)
                }
            }
        }
    }

    @Test
    func staleProposalRejectsCanonicallyEquivalentButDifferentSource() throws {
        let source = "![alt](cafe\u{323}\u{301}.png)\n"
        let reference = try #require(AssetDoctor.references(in: MarkdownParser.parse(source)).first)
        let proposal = AssetDoctor.relinkProposal(for: reference, to: "new.png")
        #expect(proposal.apply(to: "![alt](cafe\u{301}\u{323}.png)\n") == nil)
    }

}
