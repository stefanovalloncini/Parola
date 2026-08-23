import CoreSpotlight
import Foundation
import UniformTypeIdentifiers

struct SpotlightIndexer: LibraryIndexer {
    static let domainID = "com.parola.library"

    init() {}

    func index(id: String, title: String, text: String, createdAt: Date) async {
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
            var fields: [LogField: LogValue] = [.error: .error(error)]
            if let uuid = UUID(uuidString: id) { fields[.entry] = .id(uuid) }
            ParolaLog.error(.librarySpotlight, "spotlight index failed", fields)
        }
    }

    func deindex(id: String) async {
        do {
            try await CSSearchableIndex.default().deleteSearchableItems(withIdentifiers: [id])
        } catch {
            var fields: [LogField: LogValue] = [.error: .error(error)]
            if let uuid = UUID(uuidString: id) { fields[.entry] = .id(uuid) }
            ParolaLog.error(.librarySpotlight, "spotlight deindex failed", fields)
        }
    }
}
