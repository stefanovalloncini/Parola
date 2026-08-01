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

    enum LoadFailure: Sendable, Equatable {
        case unreadable
        case undecodable
    }

    private let storageURL: URL
    public private(set) var userPrompts: [Prompt]
    public private(set) var outdatedBuiltIns: [OutdatedBuiltIn]
    public private(set) var lastSaveFailed = false
    private(set) var loadFailure: LoadFailure?

    public init(storageURL: URL = PromptLibrary.defaultStorageURL) {
        self.storageURL = storageURL
        var loadedUser: [Prompt] = []
        var stale: [OutdatedBuiltIn] = []
        var failure: LoadFailure?
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
            // No file is a first run; both other failures hide prompts, but only unparseable bytes are safe to move aside.
            let code = (error as? CocoaError)?.code
            if code == .fileReadNoSuchFile || code == .fileNoSuchFile {
                failure = nil
            } else {
                failure = error is DecodingError ? .undecodable : .unreadable
            }
        }
        self.userPrompts = loadedUser
        self.outdatedBuiltIns = stale
        self.loadFailure = failure
    }

    public var allPrompts: [Prompt] { Prompt.builtIns + userPrompts }

    /// The prompt is in the library either way; `saved` is false when it only lives in memory.
    public func addUserPrompt(
        name: String,
        instructions: String,
        triggerWords: [String] = [],
        useSystemInstructions: Bool = true
    ) -> (prompt: Prompt, saved: Bool) {
        let prompt = Prompt(
            name: name,
            instructions: instructions,
            isBuiltIn: false,
            triggerWords: triggerWords,
            useSystemInstructions: useSystemInstructions
        )
        userPrompts.append(prompt)
        return (prompt, save())
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
        switch loadFailure {
        // Bytes we couldn't parse are still the user's prompts: keep them before the overwrite.
        case .undecodable where !moveUnreadableFileAside():
            lastSaveFailed = true
            return false
        // A file we couldn't even read may be intact, so nothing here may overwrite or rename it.
        case .unreadable:
            lastSaveFailed = true
            return false
        default:
            break
        }
        loadFailure = nil
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
        for attempt in 2...20 where manager.fileExists(atPath: destination.path) {
            destination = storageURL.appendingPathExtension("corrupt-\(attempt)")
        }
        if manager.fileExists(atPath: destination.path) {
            destination = storageURL.appendingPathExtension("corrupt-\(UUID().uuidString)")
        }
        return (try? manager.moveItem(at: storageURL, to: destination)) != nil
    }
}
