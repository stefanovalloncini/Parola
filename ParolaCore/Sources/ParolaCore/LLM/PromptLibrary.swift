import Foundation

public actor PromptLibrary {
    public static var defaultStorageURL: URL {
        URL.applicationSupportDirectory.appending(path: "Parola/Prompts.json")
    }

    private let storageURL: URL
    public private(set) var userPrompts: [Prompt]

    public init(storageURL: URL = PromptLibrary.defaultStorageURL) {
        self.storageURL = storageURL
        if let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([Prompt].self, from: data) {
            self.userPrompts = decoded.filter { !$0.isBuiltIn }
        } else {
            self.userPrompts = []
        }
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

    private func save() {
        let parent = storageURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(userPrompts) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
