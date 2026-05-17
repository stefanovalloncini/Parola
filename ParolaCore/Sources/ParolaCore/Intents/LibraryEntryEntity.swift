import AppIntents
import Foundation

public struct LibraryEntryEntity: AppEntity, Identifiable, Sendable {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transcript"
    public static let defaultQuery = LibraryEntryEntityQuery()

    public let id: String
    public let title: String
    public let createdAt: Date

    public init(id: String, title: String, createdAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }

    public init(from entry: LibraryEntry) {
        self.id = entry.id
        self.title = entry.title
        self.createdAt = entry.createdAt
    }

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(createdAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}

public struct LibraryEntryEntityQuery: EntityQuery, Sendable {
    private let store: LibraryStore

    public init() {
        self.store = LibraryStore.shared
    }

    public init(store: LibraryStore) {
        self.store = store
    }

    public func entities(for identifiers: [LibraryEntryEntity.ID]) async throws -> [LibraryEntryEntity] {
        let entries = await store.list()
        let lookup = Set(identifiers)
        return entries
            .filter { lookup.contains($0.id) }
            .map { LibraryEntryEntity(from: $0) }
    }

    public func suggestedEntities() async throws -> [LibraryEntryEntity] {
        let entries = await store.list()
        return entries.prefix(10).map { LibraryEntryEntity(from: $0) }
    }
}
