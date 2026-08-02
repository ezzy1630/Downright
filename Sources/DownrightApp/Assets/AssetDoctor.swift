import Foundation
import MarkdownCore

enum AssetDiagnosticCode: String, Sendable {
    case missing
    case outsideWorkspace
    case absolutePath
    case duplicate
    case unsupportedFormat
    case largeFile
    case missingAlt
    case unsafe
    case malformed
}

enum AssetDiagnosticSeverity: String, Sendable {
    case info
    case warning
    case error
}

struct AssetDiagnostic: Sendable {
    let id: String
    let code: AssetDiagnosticCode
    let severity: AssetDiagnosticSeverity
    let message: String
    let range: NSRange
    let reference: AssetReference

    init(code: AssetDiagnosticCode, message: String, range: NSRange, reference: AssetReference) {
        self.code = code
        self.severity = switch code {
        case .malformed, .unsafe: .error
        case .missing, .outsideWorkspace, .absolutePath, .unsupportedFormat,
             .largeFile, .missingAlt: .warning
        default: .info
        }
        self.message = message
        self.range = range
        self.reference = reference
        self.id = "asset:\(code.rawValue):\(range.location):\(range.length)"
    }
}

enum AssetProposalKind: String, Sendable {
    case relink
    case rename
}

/// A reversible source edit.  Applying it validates the source before it
/// changes anything, so a stale proposal cannot overwrite a newer edit.
struct AssetSourceProposal: Sendable {
    let kind: AssetProposalKind
    let range: NSRange
    let expectedSource: String
    let replacement: String
    let inverseReplacement: String

    func apply(to source: String) -> String? {
        let text = source as NSString
        guard range.location >= 0, range.upperBound <= text.length,
              text.substring(with: range) == expectedSource else { return nil }
        let result = NSMutableString(string: source)
        result.replaceCharacters(in: range, with: replacement)
        return result as String
    }

    func inverse(in source: String) -> String? {
        let inverse = AssetSourceProposal(
            kind: kind, range: range, expectedSource: replacement,
            replacement: inverseReplacement, inverseReplacement: expectedSource
        )
        return inverse.apply(to: source)
    }
}

private func markdownSafeDestination(_ source: String) -> String {
    source.replacingOccurrences(of: "%", with: "%25")
        .replacingOccurrences(of: " ", with: "%20")
        .replacingOccurrences(of: "(", with: "%28")
        .replacingOccurrences(of: ")", with: "%29")
}

struct AssetDoctor {
    static func references(
        in document: ParsedDocument,
        context: AssetResolutionContext = .init()
    ) -> [AssetReference] {
        AssetReferenceParser.references(in: document, context: context)
    }

    static func diagnose(
        _ document: ParsedDocument,
        context: AssetResolutionContext = .init(),
        probe: AssetProbe? = nil
    ) -> [AssetDiagnostic] {
        let refs = references(in: document, context: context)
        var diagnostics: [AssetDiagnostic] = []
        var identities: [String: (url: URL, reference: AssetReference)] = [:]
        for reference in refs {
            if reference.altText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                diagnostics.append(AssetDiagnostic(
                    code: .missingAlt, message: "Image has no alt text.",
                    range: reference.imageRange, reference: reference
                ))
            }
            switch reference.kind {
            case .malformed:
                diagnostics.append(AssetDiagnostic(
                    code: .malformed, message: "Image destination is malformed.",
                    range: reference.destinationRange, reference: reference
                ))
            case .unsafe:
                diagnostics.append(AssetDiagnostic(
                    code: .unsafe, message: "Image destination is unsafe.",
                    range: reference.destinationRange, reference: reference
                ))
            case .remoteHTTP, .dataURL:
                continue
            case .absoluteLocal:
                diagnostics.append(AssetDiagnostic(
                    code: .absolutePath,
                    message: "Absolute image paths are not portable.",
                    range: reference.destinationRange, reference: reference
                ))
            case .relativeLocal, .fileURL:
                break
            }

            if let url = reference.url {
                if let root = context.workspaceRoot, !isInside(url, root: root) {
                    diagnostics.append(AssetDiagnostic(
                        code: .outsideWorkspace,
                        message: "Image is outside the workspace.",
                        range: reference.destinationRange, reference: reference
                    ))
                }
                if let probe {
                    guard let metadata = probe.metadata(url) else {
                        diagnostics.append(AssetDiagnostic(
                            code: .missing, message: "Image asset was not found.",
                            range: reference.destinationRange, reference: reference
                        ))
                        continue
                    }
                    if !metadata.exists || metadata.isDirectory {
                        diagnostics.append(AssetDiagnostic(
                            code: .missing, message: "Image asset was not found.",
                            range: reference.destinationRange, reference: reference
                        ))
                    } else if let size = metadata.byteSize, size > context.maximumBytes {
                        diagnostics.append(AssetDiagnostic(
                            code: .largeFile, message: "Image asset is larger than the configured limit.",
                            range: reference.destinationRange, reference: reference
                        ))
                    }
                    if let ext = metadata.fileExtension?.lowercased(), !context.supportedExtensions.contains(ext) {
                        diagnostics.append(AssetDiagnostic(
                            code: .unsupportedFormat,
                            message: "Image format is not supported.",
                            range: reference.destinationRange, reference: reference
                        ))
                    }
                    if let identity = metadata.contentIdentity {
                        if let previous = identities[identity], previous.url.path != url.path {
                            diagnostics.append(AssetDiagnostic(
                                code: .duplicate,
                                message: "Image has the same content as line \(previous.reference.line).",
                                range: reference.destinationRange, reference: reference
                            ))
                        } else {
                            identities[identity] = (url, reference)
                        }
                    }
                }
            }
        }
        return diagnostics
    }

    static func relinkProposal(for reference: AssetReference, to replacement: String) -> AssetSourceProposal {
        AssetSourceProposal(
            kind: .relink,
            range: reference.destinationRange,
            expectedSource: reference.sourceText,
            replacement: markdownSafeDestination(replacement),
            inverseReplacement: reference.sourceText
        )
    }

    static func renameProposal(for reference: AssetReference, to replacement: String) -> AssetSourceProposal {
        AssetSourceProposal(
            kind: .rename,
            range: reference.destinationRange,
            expectedSource: reference.sourceText,
            replacement: markdownSafeDestination(replacement),
            inverseReplacement: reference.sourceText
        )
    }

    private static func isInside(_ url: URL, root: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        return path == rootPath || path.hasPrefix(rootPath.hasSuffix("/") ? rootPath : rootPath + "/")
    }
}
