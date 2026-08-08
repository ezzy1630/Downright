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
}
