import Foundation
import ParolaCore

/// A model provider the user configured. `hasKey` is read back from the key store when the list
/// loads and is never written to disk; the key itself only ever lives in the store.
struct AIServiceConfig: Codable, Identifiable, Hashable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case openAI
        case anthropic
        case groq
        case cerebras
        case ollama
        case custom
    }

    var id: UUID
    var kind: Kind
    var name: String
    var endpoint: URL?
    var model: String
    /// Default here, not just in the initializer: the synthesized decoder needs one for a property
    /// `CodingKeys` leaves out.
    var hasKey: Bool = false

    init(
        id: UUID = UUID(),
        kind: Kind,
        name: String,
        endpoint: URL? = nil,
        model: String,
        hasKey: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.endpoint = endpoint
        self.model = model
        self.hasKey = hasKey
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, name, endpoint, model
    }

    /// What this row means to the factory. A custom endpoint with no URL can't be built, so it
    /// reads as on-device and a half-finished row never sends anywhere.
    var choice: LanguageModelProviderChoice {
        switch kind {
        case .openAI, .anthropic, .groq, .cerebras:
            guard let provider = kind.providerID else { return .onDevice }
            return .cloud(provider: provider, model: model)
        case .ollama:
            return .ollama(endpoint: endpoint ?? AIServiceConfig.defaultOllamaEndpoint, model: model)
        case .custom:
            guard let endpoint else { return .onDevice }
            return .custom(baseURL: endpoint, model: model)
        }
    }

    static let defaultOllamaEndpoint = URL(string: "http://127.0.0.1:11434")!
}

extension AIServiceConfig.Kind {
    var providerID: CloudLLMProviderID? {
        switch self {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .groq: return .groq
        case .cerebras: return .cerebras
        case .custom: return .custom
        case .ollama: return nil
        }
    }

    /// Where this kind's key lives. Ollama on a machine you own asks for none.
    var keyProviderID: CloudLLMProviderID? {
        self == .ollama ? nil : providerID
    }

    var info: CloudLLMProviderInfo? {
        providerID.flatMap { CloudLLMProviderInfo.info(for: $0) }
    }

    var displayName: String {
        switch self {
        case .openAI, .anthropic, .groq, .cerebras:
            return info?.displayName ?? rawValue
        case .ollama:
            return "Ollama"
        case .custom:
            return String(localized: "Custom endpoint")
        }
    }

    var defaultModel: String {
        switch self {
        case .openAI, .anthropic, .groq, .cerebras: return info?.defaultModel ?? ""
        case .ollama: return "llama3.2:3b"
        case .custom: return ""
        }
    }

    var apiKeyPlaceholder: String { info?.apiKeyPlaceholder ?? "" }

    var symbol: String {
        switch self {
        case .openAI: return "circle.hexagongrid"
        case .anthropic: return "asterisk"
        case .groq: return "bolt"
        case .cerebras: return "square.stack.3d.up"
        case .ollama: return "desktopcomputer"
        case .custom: return "network"
        }
    }

    var usesEndpoint: Bool { self == .ollama || self == .custom }

    /// Cloud and custom rows go away under `disableCloudLLM`; Ollama on this Mac stays.
    var isManagedAway: Bool { self != .ollama }
}

extension AppModel {

    var aiEnabled: Bool { features.isEnabled(.ai) }

    // MARK: - Loading

    /// Reads the configured services and the per-task selection, then fills in each row's key
    /// status from the key store.
    func loadAIServices() {
        setAIServices(readJSON([AIServiceConfig].self, forKey: "aiServices") ?? [])
        setLanguageModelSelection(readJSON(LanguageModelSelection.self, forKey: "languageModelSelection") ?? .onDevice)
        refreshAIServiceKeyStatus()
    }

    func refreshAIServiceKeyStatus() {
        guard aiEnabled, !aiServices.isEmpty else { return }
        let store = apiKeyStore
        let services = aiServices
        Task { [weak self] in
            var found: [UUID: Bool] = [:]
            for service in services {
                guard let provider = service.kind.keyProviderID else { continue }
                let key = try? await store.get(for: provider)
                found[service.id] = !(key ?? "").isEmpty
            }
            guard let self else { return }
            var updated = self.aiServices
            for index in updated.indices {
                guard let has = found[updated[index].id] else { continue }
                updated[index].hasKey = has
            }
            guard updated != self.aiServices else { return }
            self.setAIServices(updated)
        }
    }

    // MARK: - The service list

    /// The one way the service list changes: the pane, the editor, the bridge and the key-status
    /// refresh all land here. A service that was edited carries its selections over with it.
    func setAIServices(_ services: [AIServiceConfig]) {
        guard aiEnabled else { return }
        let remapped = Self.remappedSelection(languageModelSelection, from: aiServices, to: services)
        aiServices = services
        writeJSON(services, forKey: "aiServices")
        if remapped != languageModelSelection {
            setLanguageModelSelection(remapped)
        }
    }

    func addAIService(_ service: AIServiceConfig) {
        setAIServices(aiServices + [service])
    }

    func updateAIService(_ service: AIServiceConfig) {
        guard let index = aiServices.firstIndex(where: { $0.id == service.id }) else {
            addAIService(service)
            return
        }
        var updated = aiServices
        updated[index] = service
        setAIServices(updated)
    }

    /// Removing a service leaves its selections stored; they resolve back to the on-device model.
    func removeAIService(id: UUID) {
        setAIServices(aiServices.filter { $0.id != id })
    }

    func aiService(id: UUID) -> AIServiceConfig? {
        aiServices.first { $0.id == id }
    }

    func aiService(for choice: LanguageModelProviderChoice) -> AIServiceConfig? {
        aiServices.first { $0.choice == choice }
    }

    /// Keeps a task pointing at the service it was pointing at when that service's model or
    /// endpoint changes under it.
    static func remappedSelection(
        _ selection: LanguageModelSelection,
        from old: [AIServiceConfig],
        to new: [AIServiceConfig]
    ) -> LanguageModelSelection {
        let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var replacements: [LanguageModelProviderChoice: LanguageModelProviderChoice] = [:]
        for service in old {
            guard let updated = newByID[service.id], updated.choice != service.choice else { continue }
            replacements[service.choice] = updated.choice
        }
        guard !replacements.isEmpty else { return selection }
        var out = selection
        for task in LanguageModelTask.allCases {
            guard let replacement = replacements[selection[task]] else { continue }
            out[task] = replacement
        }
        return out
    }

    // MARK: - The selection

    /// The one way the per-task selection changes: the pickers and the bridge call this.
    func setLanguageModelSelection(_ selection: LanguageModelSelection) {
        guard aiEnabled else { return }
        languageModelSelection = selection
        writeJSON(selection, forKey: "languageModelSelection")
    }

    func setLanguageModel(_ choice: LanguageModelProviderChoice, for task: LanguageModelTask) {
        var updated = languageModelSelection
        updated[task] = choice
        setLanguageModelSelection(updated)
    }

    /// The model a task actually runs on. A pick whose service was removed, or one the managed
    /// policy refuses, reads as on-device, so a call site never throws over a stale choice.
    func resolvedLanguageModelChoice(for task: LanguageModelTask) -> LanguageModelProviderChoice {
        let choice = languageModelSelection[task]
        guard choice != .onDevice else { return .onDevice }
        guard aiService(for: choice) != nil else {
            ParolaLog.notice(.ai, "\(task) points at a service that is gone; answering on device")
            return .onDevice
        }
        guard !(choice.isRemote && managedConfiguration.disableCloudLLM) else {
            ParolaLog.notice(.ai, "policy refuses \(choice) for \(task); answering on device")
            return .onDevice
        }
        return choice
    }

    // MARK: - Building models

    /// The one place a call site gets a language model: the selection, the managed policy and the
    /// key store are applied here and nowhere else.
    func makeLanguageModel(for task: LanguageModelTask, instructions: String?) async throws -> any LanguageModel {
        try await makeLanguageModel(
            choice: resolvedLanguageModelChoice(for: task),
            task: task,
            instructions: instructions
        )
    }

    /// Builds one given choice — what Test uses, with the typed key it hasn't saved yet.
    func makeLanguageModel(
        choice: LanguageModelProviderChoice,
        task: LanguageModelTask,
        instructions: String?,
        keyStore: (any APIKeyStore)? = nil
    ) async throws -> any LanguageModel {
        var selection = LanguageModelSelection()
        selection[task] = choice
        return try await LanguageModelFactory.make(
            for: task,
            selection: selection,
            instructions: instructions,
            keyStore: keyStore ?? apiKeyStore,
            managed: managedConfiguration
        )
    }

    /// Chat's one entry point: the on-device path keeps its condensed-context handling, and every
    /// other choice answers through a model built for it.
    func makeChatSession(transcript: Transcript, history: [ChatMessage]) async throws -> TranscriptChatSession {
        let choice = resolvedLanguageModelChoice(for: .chat)
        guard choice != .onDevice else {
            return try TranscriptChat.makeSession(transcript: transcript, history: history, features: features)
        }
        let model = try await makeLanguageModel(
            for: .chat,
            instructions: TranscriptChat.systemInstructions(for: transcript)
        )
        return try TranscriptChat.makeSession(
            transcript: transcript,
            history: history,
            budgetTokens: TranscriptChat.budgetTokens(for: choice),
            features: features,
            model: model
        )
    }

    /// The dictation cleanup runner bound to this selection. Built on the main actor, run off it.
    func dictationCleanupRunner() -> @Sendable (Prompt, String) async -> String? {
        { [weak self] prompt, input in
            guard let self else { return nil }
            guard let model = try? await self.makeLanguageModel(
                for: .dictationCleanup,
                instructions: prompt.instructions
            ) else { return nil }
            return try? await PromptRunner.run(prompt, on: input, model: model)
        }
    }

    /// The summariser for the current selection, or nil when summaries stay on device and the
    /// service's own on-device path (structured output included) should run.
    func summaryModelMaker() -> (@Sendable (String?) async throws -> any LanguageModel)? {
        guard resolvedLanguageModelChoice(for: .summary) != .onDevice else { return nil }
        return { [weak self] instructions in
            guard let self else { throw CancellationError() }
            return try await self.makeLanguageModel(for: .summary, instructions: instructions)
        }
    }
}
