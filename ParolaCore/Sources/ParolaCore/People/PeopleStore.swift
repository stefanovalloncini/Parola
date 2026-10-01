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
        if Self.spreadDefaultColours(&people) {
            Self.write(people, to: storageURL)
        }
    }

    /// A directory written before people carried a colour decodes with everybody on the first one.
    /// Spread those over the palette once; a colour already chosen stays where it is, and a single
    /// person on the default is the ordinary case, not a legacy one.
    static func spreadDefaultColours(_ people: inout [Person]) -> Bool {
        let onDefault = people.indices.filter { people[$0].colorIndex == 0 }
        guard onDefault.count > 1 else { return false }
        var taken = Set(people.map(\.colorIndex))
        for index in onDefault.dropFirst() {
            let free = (0..<colorCount).first { !taken.contains($0) } ?? (index % colorCount)
            taken.insert(free)
            people[index].colorIndex = free
        }
        return true
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

    /// The person marked as you, if anyone is.
    public var me: Person? {
        people.first(where: \.isMe)
    }

    /// Marks one person as you and clears the mark from everyone else; nil clears it. An id the
    /// directory doesn't hold changes nothing.
    public func markAsMe(_ id: UUID?) {
        if let id, !people.contains(where: { $0.id == id }) { return }
        var changed = false
        for index in people.indices where people[index].isMe != (people[index].id == id) {
            people[index].isMe.toggle()
            changed = true
        }
        if changed { save() }
    }

    public func person(named name: String) -> Person? {
        let key = Self.normalize(name.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !key.isEmpty else { return nil }
        return people.first { Self.normalize($0.name) == key }
    }

    /// Folds `source` into `target`: usage counts add up, the newer date wins, the "me" mark moves
    /// over, and `source` is gone.
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
        if absorbed.isMe { people[targetIndex].isMe = true }
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
            if absorbed.isMe { people[existing].isMe = true }
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
        Self.write(people, to: storageURL)
    }

    private static func write(_ people: [Person], to url: URL) {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(people) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
