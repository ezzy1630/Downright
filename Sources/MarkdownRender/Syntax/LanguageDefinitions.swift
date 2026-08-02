import Foundation

// The language table.  Everything here is data: one `LanguageSpec` per
// language, read by the one scanner in `GenericLexer`.
//
// Word lists are the *reserved* spellings only.  Anything a program names
// itself is classified structurally — a call site, a screaming-case constant, a
// capitalised type — so the tables stay small and stay right as languages grow.

enum LanguageDefinitions {

    static func spec(for name: String) -> LanguageSpec? {
        switch name {
        case "swift": return swift
        case "typescript", "tsx": return typescript(name: name)
        case "javascript", "jsx": return javascript(name: name)
        case "python": return python
        case "rust": return rust
        case "go": return go
        case "ruby": return ruby
        case "java": return java
        case "c": return c
        case "cpp": return cpp
        case "objc": return objc
        case "bash": return bash
        case "json": return json
        case "yaml": return yaml
        case "toml": return toml
        case "sql": return sql
        case "css": return css
        default: return nil
        }
    }

    // MARK: - Swift

    private static let swift = LanguageSpec(
        name: "swift",
        words: WordTable(foldsCase: false, [
            (.keyword, [
                "actor", "associatedtype", "async", "await", "borrowing", "break", "case", "catch",
                "class", "consuming", "continue", "convenience", "default", "defer", "deinit",
                "didSet", "do", "dynamic", "each", "else", "enum", "extension", "fallthrough",
                "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in",
                "indirect", "infix", "init", "inout", "internal", "is", "lazy", "let", "macro",
                "mutating", "nonisolated", "nonmutating", "open", "operator", "optional",
                "override", "package", "postfix", "precedencegroup", "prefix", "private",
                "protocol", "public", "repeat", "required", "rethrows", "return", "set", "some",
                "static", "struct", "subscript", "super", "switch", "throw", "throws", "try",
                "typealias", "unowned", "var", "weak", "where", "while", "willSet", "as", "any",
            ]),
            (.constant, ["true", "false", "nil", "self", "Self"]),
        ]),
        capitalisedAreTypes: true,
        callsAreFunctions: true,
        lineComments: [Array("//".utf8)],
        blockComments: [BlockCommentSpec("/*", "*/", nests: true)],
        strings: [StringSpec("\"\"\"", spansLines: true), StringSpec("\"")],
        rawStrings: [.swiftHash],
        attributeSigils: [.of("@")],
        hashDirectiveToken: .attribute
    )

    // MARK: - TypeScript / JavaScript

    private static let ecmaKeywords = [
        "as", "async", "await", "break", "case", "catch", "class", "const", "continue",
        "debugger", "default", "delete", "do", "else", "export", "extends", "finally", "for",
        "from", "function", "get", "if", "import", "in", "instanceof", "let", "new", "of",
        "return", "set", "static", "super", "switch", "this", "throw", "try", "typeof", "var",
        "void", "while", "with", "yield",
    ]

    private static let typescriptKeywords = [
        "abstract", "accessor", "asserts", "declare", "enum", "implements", "infer", "interface",
        "is", "keyof", "namespace", "module", "out", "override", "private", "protected", "public",
        "readonly", "satisfies", "type", "unique", "using",
    ]

    private static func javascript(name: String) -> LanguageSpec {
        ecmaSpec(name: name, extraKeywords: [], extraTypes: [])
    }

    private static func typescript(name: String) -> LanguageSpec {
        ecmaSpec(
            name: name,
            extraKeywords: typescriptKeywords,
            extraTypes: ["any", "bigint", "boolean", "never", "number", "object", "string", "symbol", "unknown"]
        )
    }

    private static func ecmaSpec(name: String, extraKeywords: [String], extraTypes: [String]) -> LanguageSpec {
        LanguageSpec(
            name: name,
            words: WordTable(foldsCase: false, [
                (.constant, ["true", "false", "null", "undefined", "NaN", "Infinity"]),
                (.keyword, ecmaKeywords + extraKeywords),
                (.type, extraTypes + ["Array", "Object", "Promise", "Map", "Set", "Date", "RegExp", "Error"]),
            ]),
            allCapsAreConstants: true,
            capitalisedAreTypes: true,
            callsAreFunctions: true,
            lineComments: [Array("//".utf8)],
            blockComments: [BlockCommentSpec("/*", "*/")],
            strings: [
                StringSpec("`", spansLines: true),
                StringSpec("\""),
                StringSpec("'"),
            ],
            attributeSigils: [.of("@")]
        )
    }

    // MARK: - Python

    private static let python = LanguageSpec(
        name: "python",
        words: WordTable(foldsCase: false, [
            (.constant, ["True", "False", "None", "self", "cls", "NotImplemented", "Ellipsis"]),
            (.keyword, [
                "and", "as", "assert", "async", "await", "break", "case", "class", "continue",
                "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if",
                "import", "in", "is", "lambda", "match", "nonlocal", "not", "or", "pass", "raise",
                "return", "try", "while", "with", "yield",
            ]),
            (.type, [
                "bool", "bytearray", "bytes", "complex", "dict", "float", "frozenset", "int",
                "list", "object", "range", "set", "str", "tuple", "type",
            ]),
        ]),
        allCapsAreConstants: true,
        capitalisedAreTypes: true,
        callsAreFunctions: true,
        lineComments: [Array("#".utf8)],
        strings: [
            StringSpec("\"\"\"", spansLines: true),
            StringSpec("'''", spansLines: true),
            StringSpec("\""),
            StringSpec("'"),
        ],
        stringPrefixes: [
            StringPrefixSpec("f"), StringPrefixSpec("b"), StringPrefixSpec("u"),
            StringPrefixSpec("fr"), StringPrefixSpec("bf"),
            StringPrefixSpec("r", escapes: false), StringPrefixSpec("rb", escapes: false),
            StringPrefixSpec("br", escapes: false), StringPrefixSpec("rf", escapes: false),
        ],
        attributeSigils: [.of("@")]
    )

    // MARK: - Rust

    private static let rust = LanguageSpec(
        name: "rust",
        words: WordTable(foldsCase: false, [
            (.constant, ["true", "false", "None", "Some", "Ok", "Err", "self", "Self"]),
            (.keyword, [
                "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else",
                "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
                "move", "mut", "pub", "ref", "return", "static", "struct", "super", "trait",
                "type", "union", "unsafe", "use", "where", "while", "yield",
            ]),
            (.type, [
                "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str",
                "u8", "u16", "u32", "u64", "u128", "usize",
            ]),
        ]),
        allCapsAreConstants: true,
        capitalisedAreTypes: true,
        callsAreFunctions: true,
        lineComments: [Array("//".utf8)],
        blockComments: [BlockCommentSpec("/*", "*/", nests: true)],
        // Rust string literals may contain raw newlines.
        strings: [StringSpec("\"", spansLines: true), StringSpec("'")],
        stringPrefixes: [StringPrefixSpec("b")],
        rawStrings: [.rustHash],
        hashAttributes: true,
        hasLifetimes: true
    )

    // MARK: - Go

    private static let go = LanguageSpec(
        name: "go",
        words: WordTable(foldsCase: false, [
            (.constant, ["true", "false", "nil", "iota"]),
            (.keyword, [
                "break", "case", "chan", "const", "continue", "default", "defer", "else",
                "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
                "package", "range", "return", "select", "struct", "switch", "type", "var",
            ]),
            (.type, [
                "any", "bool", "byte", "comparable", "complex64", "complex128", "error",
                "float32", "float64", "int", "int8", "int16", "int32", "int64", "rune", "string",
                "uint", "uint8", "uint16", "uint32", "uint64", "uintptr",
            ]),
        ]),
        allCapsAreConstants: true,
        capitalisedAreTypes: true,
        callsAreFunctions: true,
        lineComments: [Array("//".utf8)],
        blockComments: [BlockCommentSpec("/*", "*/")],
        strings: [
            StringSpec("`", escape: nil, spansLines: true),
            StringSpec("\""),
            StringSpec("'"),
        ]
    )

    // MARK: - Ruby

    private static let ruby = LanguageSpec(
        name: "ruby",
        words: WordTable(foldsCase: false, [
            (.constant, ["true", "false", "nil", "self", "__FILE__", "__LINE__"]),
            (.keyword, [
                "BEGIN", "END", "alias", "and", "begin", "break", "case", "class", "def",
                "do", "else", "elsif", "end", "ensure", "extend", "for", "if", "in",
                "include", "lambda", "module", "next", "not", "or", "proc", "redo", "require",
                "require_relative", "rescue", "retry", "return", "super", "then", "undef",
                "unless", "until", "when", "while", "yield",
            ]),
            (.function, ["attr_accessor", "attr_reader", "attr_writer", "puts", "print", "raise", "new"]),
        ]),
        allCapsAreConstants: true,
        capitalisedAreTypes: true,
        callsAreFunctions: true,
        lineComments: [Array("#".utf8)],
        blockComments: [BlockCommentSpec("=begin", "=end", mustStartLine: true)],
        strings: [StringSpec("\"", spansLines: true), StringSpec("'", escape: nil, spansLines: true)],
        variableSigils: [.of("@"), .of("$")],
        hasSymbols: true
    )

    // MARK: - Java

    private static let java = LanguageSpec(
        name: "java",
        words: WordTable(foldsCase: false, [
            (.constant, ["true", "false", "null", "this", "super"]),
            (.keyword, [
                "abstract", "assert", "break", "case", "catch", "class", "const", "continue",
                "default", "do", "else", "enum", "extends", "final", "finally", "for", "goto",
                "if", "implements", "import", "instanceof", "interface", "native", "new",
                "package", "permits", "private", "protected", "public", "record", "return",
                "sealed", "static", "strictfp", "switch", "synchronized", "throw", "throws",
                "transient", "try", "var", "volatile", "while", "yield",
            ]),
            (.type, ["boolean", "byte", "char", "double", "float", "int", "long", "short", "void"]),
        ]),
        allCapsAreConstants: true,
        capitalisedAreTypes: true,
        callsAreFunctions: true,
        lineComments: [Array("//".utf8)],
        blockComments: [BlockCommentSpec("/*", "*/")],
        strings: [StringSpec("\"\"\"", spansLines: true), StringSpec("\""), StringSpec("'")],
        attributeSigils: [.of("@")]
    )

    // MARK: - C family

    private static let cKeywords = [
        "auto", "break", "case", "const", "continue", "default", "do", "else", "enum", "extern",
        "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof", "static",
        "struct", "switch", "typedef", "union", "volatile", "while", "_Atomic", "_Bool",
        "_Generic", "_Static_assert", "_Thread_local",
    ]

    private static let cTypes = [
        "bool", "char", "double", "float", "int", "int8_t", "int16_t", "int32_t", "int64_t",
        "long", "ptrdiff_t", "short", "signed", "size_t", "ssize_t", "uint8_t", "uint16_t",
        "uint32_t", "uint64_t", "unsigned", "void", "wchar_t",
    ]

    private static let c = LanguageSpec(
        name: "c",
        words: WordTable(foldsCase: false, [
            (.constant, ["NULL", "true", "false"]),
            (.keyword, cKeywords),
            (.type, cTypes),
        ]),
        allCapsAreConstants: true,
        callsAreFunctions: true,
        lineComments: [Array("//".utf8)],
        blockComments: [BlockCommentSpec("/*", "*/")],
        strings: [StringSpec("\""), StringSpec("'")],
        hashDirectiveToken: .attribute
    )

    private static let cpp = LanguageSpec(
        name: "cpp",
        words: WordTable(foldsCase: false, [
            (.constant, ["NULL", "nullptr", "true", "false", "this"]),
            (.keyword, cKeywords + [
                "alignas", "alignof", "asm", "catch", "class", "co_await", "co_return", "co_yield",
                "concept", "consteval", "constexpr", "constinit", "const_cast", "decltype",
                "delete", "dynamic_cast", "explicit", "export", "friend", "mutable", "namespace",
                "new", "noexcept", "operator", "private", "protected", "public",
                "reinterpret_cast", "requires", "static_assert", "static_cast", "template",
                "thread_local", "throw", "try", "typeid", "typename", "using", "virtual",
            ]),
            (.type, cTypes + [
                "char8_t", "char16_t", "char32_t", "map", "optional", "set", "shared_ptr",
                "string", "string_view", "unique_ptr", "unordered_map", "unordered_set", "vector",
            ]),
        ]),
        allCapsAreConstants: true,
        callsAreFunctions: true,
        lineComments: [Array("//".utf8)],
        blockComments: [BlockCommentSpec("/*", "*/")],
        strings: [StringSpec("\""), StringSpec("'")],
        rawStrings: [.cppDelimited],
        hashDirectiveToken: .attribute
    )

    private static let objc = LanguageSpec(
        name: "objc",
        words: WordTable(foldsCase: false, [
            (.constant, ["NULL", "nil", "Nil", "YES", "NO", "true", "false", "self", "super"]),
            (.keyword, cKeywords + [
                "assign", "atomic", "copy", "nonatomic", "nonnull", "nullable", "readonly",
                "readwrite", "retain", "strong", "unsafe_unretained", "weak",
            ]),
            (.type, cTypes + ["BOOL", "IBAction", "IBOutlet", "id", "instancetype", "SEL", "IMP", "Class"]),
        ]),
        allCapsAreConstants: true,
        capitalisedAreTypes: true,
        callsAreFunctions: true,
        lineComments: [Array("//".utf8)],
        blockComments: [BlockCommentSpec("/*", "*/")],
        strings: [StringSpec("\""), StringSpec("'")],
        attributeSigils: [.of("@")],
        objcStringSigil: true,
        hashDirectiveToken: .attribute
    )

    // MARK: - Shell

    private static let bash = LanguageSpec(
        name: "bash",
        words: WordTable(foldsCase: false, [
            (.keyword, [
                "case", "coproc", "do", "done", "elif", "else", "esac", "fi", "for", "function",
                "if", "in", "select", "then", "time", "until", "while",
            ]),
            (.constant, ["true", "false"]),
            (.function, [
                "alias", "break", "cd", "command", "continue", "declare", "echo", "eval", "exec",
                "exit", "export", "getopts", "kill", "let", "local", "popd", "printf", "pushd",
                "read", "readonly", "return", "set", "shift", "source", "test", "trap", "type",
                "typeset", "ulimit", "umask", "unalias", "unset", "wait",
            ]),
        ]),
        allCapsAreConstants: true,
        lineComments: [Array("#".utf8)],
        lineCommentNeedsWordStart: true,
        strings: [
            StringSpec("\"", spansLines: true),
            StringSpec("'", escape: nil, spansLines: true),
        ],
        variableSigils: [.of("$")]
    )

    // MARK: - Data formats

    // `//` and `/* */` are accepted because JSONC is what tooling and agents
    // actually emit; strict JSON never contains them, so nothing is mis-coloured.
    private static let json = LanguageSpec(
        name: "json",
        words: WordTable(foldsCase: false, [(.constant, ["true", "false", "null"])]),
        lineComments: [Array("//".utf8)],
        blockComments: [BlockCommentSpec("/*", "*/")],
        strings: [StringSpec("\"")],
        keyTerminators: [.of(":")],
        keysFromStrings: true
    )

    private static let yaml = LanguageSpec(
        name: "yaml",
        words: WordTable(foldsCase: true, [
            (.constant, ["true", "false", "null", "yes", "no", "on", "off", "~"]),
        ]),
        lineComments: [Array("#".utf8)],
        strings: [StringSpec("\""), StringSpec("'", escape: nil)],
        identifierExtraContinues: [.of("-"), .of(".")],
        keyTerminators: [.of(":")],
        keysFromStrings: true,
        keysFromIdentifiers: true,
        keyTerminatorNeedsSpace: true
    )

    private static let toml = LanguageSpec(
        name: "toml",
        words: WordTable(foldsCase: false, [(.constant, ["true", "false"])]),
        lineComments: [Array("#".utf8)],
        strings: [
            StringSpec("\"\"\"", spansLines: true),
            StringSpec("'''", escape: nil, spansLines: true),
            StringSpec("\""),
            StringSpec("'", escape: nil),
        ],
        identifierExtraContinues: [.of("-"), .of(".")],
        keyTerminators: [.of("=")],
        keysFromStrings: true,
        keysFromIdentifiers: true,
        bracketSectionHeaders: true
    )

    private static let sql = LanguageSpec(
        name: "sql",
        words: WordTable(foldsCase: true, [
            (.constant, ["true", "false", "null", "current_date", "current_time", "current_timestamp"]),
            (.keyword, [
                "all", "alter", "analyze", "and", "as", "asc", "begin", "between", "by",
                "cascade", "case", "check", "commit", "constraint", "create", "cross", "delete",
                "desc", "distinct", "drop", "else", "end", "exists", "explain", "foreign", "from",
                "full", "grant", "group", "having", "in", "index", "inner", "insert", "into",
                "is", "join", "key", "left", "like", "limit", "not", "offset", "on", "or",
                "order", "outer", "over", "partition", "primary", "recursive", "references",
                "returning", "revoke", "right", "rollback", "select", "set", "table", "then",
                "transaction", "truncate", "union", "unique", "update", "using", "values", "view",
                "when", "where", "window", "with",
            ]),
            (.type, [
                "array", "bigint", "boolean", "bytea", "char", "date", "decimal", "double",
                "float", "int", "integer", "json", "jsonb", "numeric", "precision", "real",
                "serial", "smallint", "text", "time", "timestamp", "timestamptz", "uuid",
                "varchar",
            ]),
        ]),
        callsAreFunctions: true,
        lineComments: [Array("--".utf8)],
        blockComments: [BlockCommentSpec("/*", "*/")],
        // `''` inside a literal reads as close-then-open; the two runs are
        // adjacent and merge, so the doubled-quote escape needs no special case.
        strings: [StringSpec("'", escape: nil), StringSpec("\"", escape: nil)]
    )

    private static let css = LanguageSpec(
        name: "css",
        words: WordTable(foldsCase: true, [
            (.constant, [
                "auto", "inherit", "initial", "none", "revert", "unset", "currentColor",
                "transparent",
            ]),
            (.keyword, ["and", "from", "important", "not", "only", "to"]),
        ]),
        callsAreFunctions: true,
        blockComments: [BlockCommentSpec("/*", "*/")],
        strings: [StringSpec("\""), StringSpec("'")],
        identifierExtraStarts: [.of("-")],
        identifierExtraContinues: [.of("-")],
        attributeSigils: [.of("@")],
        // `#fff` and `#main` are both literals in CSS, not directives.
        hashDirectiveToken: .constant,
        keyTerminators: [.of(":")],
        keysFromIdentifiers: true,
        keyTerminatorNeedsSpace: true
    )
}
