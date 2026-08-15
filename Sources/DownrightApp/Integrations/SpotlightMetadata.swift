import CoreSpotlight
import DownrightSpotlightMetadata
import Foundation
import UniformTypeIdentifiers

// Keep the app-facing names stable for integrations and tests while the
// parser-backed implementation lives in the platform-neutral target shared
// with the mdimporter bundle.
public typealias SpotlightMetadataKey = DownrightSpotlightMetadata.SpotlightMetadataKey
public typealias SpotlightMetadata = DownrightSpotlightMetadata.SpotlightMetadata
public typealias SpotlightMetadataImporter = DownrightSpotlightMetadata.SpotlightMetadataImporter

/// Adds documents that the user opens to the local Core Spotlight index. The
/// filesystem importer covers unopened Markdown; this path gives an opened
/// document immediate results before the system index catches up.
@available(macOS 14.0, *)
public enum SpotlightIndexer {
    public static func indexOpenedDocument(at url: URL) {
        DispatchQueue.global(qos: .utility).async {
            guard let metadata = try? SpotlightMetadataImporter.metadata(at: url),
                  let contentType = UTType(metadata.contentType)
            else { return }

            let attributes = CSSearchableItemAttributeSet(contentType: contentType)
            attributes.title = metadata.title
            attributes.textContent = metadata.textContent
            attributes.keywords = metadata.keywords
            attributes.contentURL = url
            attributes.kind = "Markdown document"

            let item = CSSearchableItem(
                uniqueIdentifier: url.standardizedFileURL.path,
                domainIdentifier: "com.ezzy.downright.documents",
                attributeSet: attributes
            )
            CSSearchableIndex.default().indexSearchableItems([item])
        }
    }
}
