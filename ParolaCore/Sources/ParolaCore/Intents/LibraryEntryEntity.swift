import AppIntents
import Foundation

struct LibraryEntryEntity: AppEntity, Identifiable, Sendable {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transcript"
    static let defaultQuery = LibraryEntryEntityQuery()

    let id: String
    let title: String
    let createdAt: Date

    init(id: String, title: String, createdAt: Date) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
    }

    init(from entry: LibraryEntry) {
        self.id = entry.id
        self.title = entry.title
        self.createdAt = entry.createdAt
    }

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(title)",
            subtitle: "\(createdAt.formatted(date: .abbreviated, time: .shortened))"
        )
    }
}

struct LibraryEntryEntityQuery: EntityQuery, Sendable {
    private let store: LibraryStore

    init() {
        self.store = LibraryStore.shared
    }

    init(store: LibraryStore) {
        self.store = store
    }

    func entities(for identifiers: [LibraryEntryEntity.ID]) async throws -> [LibraryEntryEntity] {
        let entries = await store.list()
        let lookup = Set(identifiers)
        return entries
            .filter { lookup.contains($0.id) }
            .map { LibraryEntryEntity(from: $0) }
    }

    func suggestedEntities() async throws -> [LibraryEntryEntity] {
        let entries = await store.list()
        return entries.prefix(10).map { LibraryEntryEntity(from: $0) }
    }
}
