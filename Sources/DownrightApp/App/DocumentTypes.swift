import UniformTypeIdentifiers

/// The UTIs from §10, in one place so the open panel, the drag destination, and
/// the Quick Look extension can never disagree about what this app opens.
enum DocumentTypes {
    static let fileExtensions = ["md", "markdown", "mdown", "mkd", "mdx", "mdc", "qmd", "rmd"]

    static var contentTypes: [UTType] {
        var types: [UTType] = []
        if let markdown = UTType("net.daringfireball.markdown") { types.append(markdown) }
        for ext in fileExtensions {
            if let type = UTType(filenameExtension: ext), !types.contains(type) {
                types.append(type)
            }
        }
        types.append(.plainText)
        return types
    }

    static func isMarkdown(_ pathExtension: String) -> Bool {
        fileExtensions.contains(pathExtension.lowercased())
    }

    /// `.mdx` and `.qmd` carry JSX and executable chunks that this app renders
    /// but never evaluates (§2, §15 Q3).  We open them and grey the executable
    /// parts out rather than refusing the file — refusing to open a document is
    /// a worse answer than rendering the 90% of it that is plain markdown.
    static func hasExecutableExtensions(_ pathExtension: String) -> Bool {
        ["mdx", "qmd", "rmd"].contains(pathExtension.lowercased())
    }
}
