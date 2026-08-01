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
    public private(set) var lastSaveFailed = false
    private(set) var loadFailed: Bool

    public init(storageURL: URL = PromptLibrary.defaultStorageURL) {
        self.storageURL = storageURL
        var loadedUser: [Prompt] = []
        var stale: [OutdatedBuiltIn] = []
        var failed = false
        do {
            let data = try Data(contentsOf: storageURL)
            let decoded = try JSONDecoder().decode([Prompt].self, from: data)
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
        } catch {
            // No file is a first run; any other failure hides prompts that save() must not overwrite.
            let code = (error as? CocoaError)?.code
            failed = code != .fileReadNoSuchFile && code != .fileNoSuchFile
        }
        self.userPrompts = loadedUser
        self.outdatedBuiltIns = stale
        self.loadFailed = failed
    }

    public var allPrompts: [Prompt] { Prompt.builtIns + userPrompts }

    public func addUserPrompt(
        name: String,
        instructions: String,
        triggerWords: [String] = [],
        useSystemInstructions: Bool = true
    ) -> Prompt {
        let prompt = Prompt(
            name: name,
            instructions: instructions,
            isBuiltIn: false,
            triggerWords: triggerWords,
            useSystemInstructions: useSystemInstructions
        )
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
        return save()
    }

    @discardableResult
    public func removeUserPrompt(_ id: UUID) -> Bool {
        guard let idx = userPrompts.firstIndex(where: { $0.id == id }) else { return false }
        userPrompts.remove(at: idx)
        return save()
    }

    public func dismissOutdatedBuiltIn(_ id: UUID) {
        outdatedBuiltIns.removeAll { $0.id == id }
    }

    @discardableResult
    private func save() -> Bool {
        // A file we failed to read holds prompts we couldn't parse; move it aside before the overwrite.
        if loadFailed, !moveUnreadableFileAside() {
            lastSaveFailed = true
            return false
        }
        loadFailed = false
        let parent = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        do {
            try JSONEncoder().encode(userPrompts).write(to: storageURL, options: .atomic)
            lastSaveFailed = false
            return true
        } catch {
            lastSaveFailed = true
            return false
        }
    }

    private func moveUnreadableFileAside() -> Bool {
        let manager = FileManager.default
        guard manager.fileExists(atPath: storageURL.path) else { return true }
        var destination = storageURL.appendingPathExtension("corrupt")
        var attempt = 2
        while manager.fileExists(atPath: destination.path), attempt <= 20 {
            destination = storageURL.appendingPathExtension("corrupt-\(attempt)")
            attempt += 1
        }
        return (try? manager.moveItem(at: storageURL, to: destination)) != nil
    }
}
