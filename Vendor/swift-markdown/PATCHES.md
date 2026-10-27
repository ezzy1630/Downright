# Vendored swift-markdown

Upstream: https://github.com/apple/swift-markdown at
`27b7fc1a19068bcea3d2072db0ce86360d1400ed`.
Sources, tests, and license notices are retained unchanged except:

- `CommonMarkConverter.swift` resolves node type once per iterator event and
  uses public C constants for core nodes. Extension nodes retain upstream name
  resolution, including task items that share the ordinary item constant.
- The converter reads source ranges only where the result is consumed;
  leaves read their range in conversion and containers retain their ENTER range.
- `MarkupChildren.Iterator` retains the raw parent once rather than repeatedly
  unpacking the public existential parent for each child. Parent metadata and
  public traversal behavior are unchanged.
- `Document.forEachParsedBlock` consumes detached top-level Swift subtrees
  during conversion. It advances the cmark iterator before freeing each
  consumed top-level C subtree, so the C and application trees do not both
  remain complete. CommonMark/reference resolution still uses the complete
  cmark parse; the ordinary Document API retains its existing behavior. Block
  directives fall back to that API. DocumentTests compares both paths including
  Unicode source ranges, later reference definitions, tables, nested tasks,
  leaves, empty documents, and block directives.
- Streaming conversion uses a synchronous thread-local allocation zone for
  its temporary cmark tree on macOS. Nested scopes restore the outer zone;
  concurrent threads own separate zones. The converter frees every C object
  before destroying the zone, while returned Swift trees remain independently
  owned. Other platforms and the ordinary Document API keep cmark's default
  allocator. DocumentTests retains results across nested and concurrent parses.
- `Package.swift` pins swift-cmark to the previously resolved revision
  `7898f1b3e4befeecee56cb4a3bc8eebd2cb63219`.

This avoids repeated string allocation in every ENTER/EXIT and conversion
precondition while preserving the public Markdown API and source ranges.
Run the upstream suite with `swift test --package-path Vendor/swift-markdown`
and the application's source gate after updating this copy.
