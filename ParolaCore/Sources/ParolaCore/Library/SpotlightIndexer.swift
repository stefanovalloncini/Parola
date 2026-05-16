import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

public struct SpotlightIndexer: LibraryIndexer {
    public static let domainID = "com.parola.library"

    public init() {}

    public func index(id: String, title: String, text: String, createdAt: Date) async {
        let attributes = CSSearchableItemAttributeSet(contentType: .text)
        attributes.title = title
        attributes.contentDescription = String(text.prefix(200))
        attributes.contentCreationDate = createdAt
        let item = CSSearchableItem(
            uniqueIdentifier: id,
            domainIdentifier: Self.domainID,
            attributeSet: attributes
        )
        try? await CSSearchableIndex.default().indexSearchableItems([item])
    }

    public func deindex(id: String) async {
        try? await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id])
    }
}
