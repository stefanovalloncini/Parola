import Foundation

public actor PromptLibrary {
    public static var defaultStorageURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/Prompts.json")
    }

    public struct OutdatedBuiltIn: Sendable, Hashable {
        public let id: UUID
        public let name: String
        public let storedVersion: Int
        public let currentVersion: Int
    }

    private let storageURL: URL
    public private(set) var userPrompts: [Prompt]
    public private(set) var outdatedBuiltIns: [OutdatedBuiltIn]

    public init(storageURL: URL = PromptLibrary.defaultStorageURL) {
        self.storageURL = storageURL
        var loadedUser: [Prompt] = []
        var stale: [OutdatedBuiltIn] = []
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([Prompt].self, from: data) {
            let currentByID = Dictionary(uniqueKeysWithValues: Prompt.builtIns.map { ($0.id, $0) })
            for stored in decoded {
                if let current = currentByID[stored.id] {
                    if stored.version < current.version {
                        stale.append(OutdatedBuiltIn(
                            id: current.id,
                            name: current.name,
                            storedVersion: stored.version,
                            currentVersion: current.version
                        ))
                    }
                    continue
                }
                if !stored.isBuiltIn {
                    loadedUser.append(stored)
                }
            }
        }
        self.userPrompts = loadedUser
        self.outdatedBuiltIns = stale
    }

    public var allPrompts: [Prompt] { Prompt.builtIns + userPrompts }

    public func addUserPrompt(name: String, instructions: String) -> Prompt {
        let prompt = Prompt(name: name, instructions: instructions, isBuiltIn: false)
        userPrompts.append(prompt)
        save()
        return prompt
    }

    @discardableResult
    public func updateUserPrompt(_ prompt: Prompt) -> Bool {
        guard !prompt.isBuiltIn,
              let idx = userPrompts.firstIndex(where: { $0.id == prompt.id }) else {
            return false
        }
        var updated = prompt
        updated.isBuiltIn = false
        userPrompts[idx] = updated
        save()
        return true
    }

    @discardableResult
    public func removeUserPrompt(_ id: UUID) -> Bool {
        let before = userPrompts.count
        userPrompts.removeAll { $0.id == id }
        let removed = userPrompts.count != before
        if removed { save() }
        return removed
    }

    public func dismissOutdatedBuiltIn(_ id: UUID) {
        outdatedBuiltIns.removeAll { $0.id == id }
    }

    private func save() {
        let parent = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(userPrompts) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
