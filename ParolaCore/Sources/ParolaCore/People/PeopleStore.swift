import Foundation

public actor PeopleStore {
    public static var defaultStorageURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/People.json")
    }

    /// How many colours a person can take. Matches the app's speaker palette.
    public static let colorCount = 7

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
        guard !trimmed.isEmpty else { return Person(name: trimmed, lastUsedAt: date) }
        let normalizedKey = Self.normalize(trimmed)
        if let idx = people.firstIndex(where: { Self.normalize($0.name) == normalizedKey }) {
            people[idx].name = trimmed
            people[idx].lastUsedAt = date
            people[idx].usageCount += 1
            save()
            return people[idx]
        } else {
            let person = Person(name: trimmed, lastUsedAt: date, colorIndex: nextColorIndex())
            people.append(person)
            save()
            return person
        }
    }

    public func suggestions(limit: Int = 10) -> [Person] {
        Array(people.sorted { $0.lastUsedAt > $1.lastUsedAt }.prefix(limit))
    }

    /// The people worth offering first: the most assigned, then the most recently used.
    public func mostUsed(limit: Int = 5) -> [Person] {
        let sorted = people.sorted {
            $0.usageCount == $1.usageCount ? $0.lastUsedAt > $1.lastUsedAt : $0.usageCount > $1.usageCount
        }
        return Array(sorted.prefix(limit))
    }

    public func person(named name: String) -> Person? {
        let key = Self.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return nil }
        return people.first { Self.normalize($0.name) == key }
    }

    /// Folds `source` into `target`: usage counts add up, the newer date wins, and `source` is gone.
    @discardableResult
    public func merge(_ source: UUID, into target: UUID) -> Person? {
        guard source != target,
              let sourceIndex = people.firstIndex(where: { $0.id == source }),
              let targetIndex = people.firstIndex(where: { $0.id == target }) else { return nil }
        let absorbed = people[sourceIndex]
        people[targetIndex].usageCount += absorbed.usageCount
        if absorbed.lastUsedAt > people[targetIndex].lastUsedAt {
            people[targetIndex].lastUsedAt = absorbed.lastUsedAt
        }
        people.remove(at: sourceIndex)
        save()
        return people.first { $0.id == target }
    }

    /// Forgets a person. The names they were assigned to stay where they are.
    @discardableResult
    public func delete(_ id: UUID) -> Bool {
        let before = people.count
        people.removeAll { $0.id == id }
        let removed = people.count != before
        if removed { save() }
        return removed
    }

    /// Renames a person while preserving `lastUsedAt` and `usageCount`.
    @discardableResult
    public func rename(_ id: UUID, to newName: String) -> Person? {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let idx = people.firstIndex(where: { $0.id == id }) else {
            return nil
        }
        let normalized = Self.normalize(trimmed)
        if let existing = people.firstIndex(where: { $0.id != id && Self.normalize($0.name) == normalized }) {
            let absorbed = people[idx]
            people[existing].usageCount += absorbed.usageCount
            if absorbed.lastUsedAt > people[existing].lastUsedAt {
                people[existing].lastUsedAt = absorbed.lastUsedAt
            }
            people[existing].name = trimmed
            people.remove(at: idx)
            save()
            return people[existing > idx ? existing - 1 : existing]
        }
        people[idx].name = trimmed
        save()
        return people[idx]
    }

    /// The lowest colour nobody holds, so a deleted person's colour comes back into use.
    private func nextColorIndex() -> Int {
        let taken = Set(people.map(\.colorIndex))
        return (0..<Self.colorCount).first { !taken.contains($0) } ?? (people.count % Self.colorCount)
    }

    static func normalize(_ name: String) -> String {
        Person.normalizedName(name)
    }

    private func save() {
        let parent = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(people) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
