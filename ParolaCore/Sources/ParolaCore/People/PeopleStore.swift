import Foundation

public actor PeopleStore {
    public static var defaultStorageURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/People.json")
    }

    private let storageURL: URL
    public private(set) var people: [Person]

    public init(storageURL: URL = PeopleStore.defaultStorageURL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([Person].self, from: data) {
            self.people = decoded
        } else {
            self.people = []
        }
    }

    @discardableResult
    public func recordUsage(name: String, at date: Date = Date()) -> Person {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let idx = people.firstIndex(where: { $0.name.lowercased() == trimmed.lowercased() }) {
            people[idx].name = trimmed
            people[idx].lastUsedAt = date
            people[idx].usageCount += 1
            save()
            return people[idx]
        } else {
            let person = Person(name: trimmed, lastUsedAt: date)
            people.append(person)
            save()
            return person
        }
    }

    public func suggestions(limit: Int = 10) -> [Person] {
        Array(people.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit))
    }

    @discardableResult
    public func remove(_ id: UUID) -> Bool {
        let before = people.count
        people.removeAll { $0.id == id }
        let removed = people.count != before
        if removed { save() }
        return removed
    }

    private func save() {
        let parent = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(people) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
