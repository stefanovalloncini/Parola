import CoreSpotlight
import Foundation
import os
import UniformTypeIdentifiers

public struct SpotlightIndexer: LibraryIndexer {
    public static let domainID = "com.parola.library"

    private static let log = Logger(subsystem: "com.parola.library", category: "spotlight")

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
        do {
            try await CSSearchableIndex.default().indexSearchableItems([item])
        } catch {
            Self.log.error("spotlight index failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    public func deindex(id: String) async {
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id])
        } catch {
            Self.log.error("spotlight deindex failed for \(id, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }
}
