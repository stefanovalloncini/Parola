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

    /// What the editor prefills. Ollama and a custom endpoint have none to invent: the editor
    /// fills Ollama's from the server, and a custom endpoint's model is whatever it serves.
    var defaultModel: String {
        switch self {
        case .openAI, .anthropic, .groq, .cerebras: return info?.defaultModel ?? ""
        case .ollama, .custom: return ""
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
    /// Silent: the pickers read this on every redraw, and the fallback is logged once per call
    /// in ``makeLanguageModel(for:instructions:)``.
    func resolvedLanguageModelChoice(for task: LanguageModelTask) -> LanguageModelProviderChoice {
        let choice = languageModelSelection[task]
        guard choice != .onDevice else { return .onDevice }
        guard aiService(for: choice) != nil else { return .onDevice }
        guard !(choice.isRemote && managedConfiguration.disableCloudLLM) else { return .onDevice }
        return choice
    }

    // MARK: - Building models

    /// The one place a call site gets a language model: the selection, the managed policy and the
    /// key store are applied here and nowhere else.
    func makeLanguageModel(for task: LanguageModelTask, instructions: String?) async throws -> any LanguageModel {
        let choice = resolvedLanguageModelChoice(for: task)
        if choice == .onDevice, languageModelSelection[task] != .onDevice {
            ParolaLog.notice(.ai, "\(task) answers on device: the service it points at is gone or refused by policy")
        }
        return try await makeLanguageModel(choice: choice, task: task, instructions: instructions)
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
        return try await TranscriptChat.makeSession(
            transcript: transcript,
            history: history,
            budgetTokens: TranscriptChat.budgetTokens(for: choice),
            features: features,
            makeModel: { [weak self] instructions in
                guard let self else { throw CancellationError() }
                return try await self.makeLanguageModel(for: .chat, instructions: instructions)
            }
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

/// What a Test run came back with: the reply, or why there wasn't one.
struct AIServiceTestResult: Equatable, Sendable {
    let ok: Bool
    let message: String
    let milliseconds: Int
}

extension AppModel {

    // MARK: - What the pane may show

    var allowsRemoteAIServices: Bool { !managedConfiguration.disableCloudLLM }

    /// The rows the pane shows and the options its pickers offer: under `disableCloudLLM` everything
    /// that would send text off this Mac is gone, an Ollama pointed at another host included.
    var visibleAIServices: [AIServiceConfig] {
        allowsRemoteAIServices ? aiServices : aiServices.filter { !$0.choice.isRemote }
    }

    var addableAIServiceKinds: [AIServiceConfig.Kind] {
        allowsRemoteAIServices ? AIServiceConfig.Kind.allCases : [.ollama]
    }

    // MARK: - Saving a service

    /// The one way the editor saves: the key goes to the key store, the row to the list, and the
    /// row's key status is set from what was actually written.
    func saveAIService(_ service: AIServiceConfig, apiKey: String?) async {
        var saved = service
        if let provider = service.kind.keyProviderID {
            let trimmed = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                do {
                    try await apiKeyStore.set(trimmed, for: provider)
                    saved.hasKey = true
                } catch {
                    ParolaLog.error(.ai, "API key could not be saved", [.error: .error(error)])
                    saved.hasKey = false
                }
            } else {
                saved.hasKey = (try? await apiKeyStore.get(for: provider)).map { !$0.isEmpty } ?? false
            }
        }
        updateAIService(saved)
    }

    // MARK: - The one-time notice

    /// Whether picking or saving this choice has to show the "transcripts leave this Mac" notice.
    func needsRemoteAIAcknowledgement(for choice: LanguageModelProviderChoice) -> Bool {
        choice.isRemote && !remoteAIAcknowledged
    }

    func acknowledgeRemoteAI() {
        remoteAIAcknowledged = true
        defaults.set(true, forKey: "remoteAIAcknowledged")
    }

    // MARK: - Test

    static let aiTestPrompt = "Reply with the single word OK."
    static let aiTestTimeout = Duration.seconds(20)

    func testAIService(id: UUID) async -> AIServiceTestResult? {
        guard let service = aiService(id: id) else { return nil }
        return await testAIService(service, apiKey: nil)
    }

    /// Asks the service one short question. `apiKey` tests a key the editor hasn't saved yet; it is
    /// handed to the model for this call only and never written anywhere.
    func testAIService(_ service: AIServiceConfig, apiKey: String?) async -> AIServiceTestResult {
        let trimmedKey = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines)
        let keyStore: (any APIKeyStore)? = {
            guard let trimmedKey, !trimmedKey.isEmpty, let provider = service.kind.keyProviderID else { return nil }
            return InMemoryAPIKeyStore(keys: [provider: trimmedKey])
        }()
        let choice = service.choice
        var outcome: AITestOutcome?
        let elapsed = await clock.measure {
            outcome = await AsyncTimeout.run(Self.aiTestTimeout, clock: clock) { [weak self] () -> AITestOutcome in
                guard let self else { return .failed("") }
                do {
                    let model = try await self.makeLanguageModel(
                        choice: choice,
                        task: .chat,
                        instructions: LanguageModelFactory.defaultInstructions,
                        keyStore: keyStore
                    )
                    return .answered(try await model.respond(to: AppModel.aiTestPrompt))
                } catch {
                    return .failed(error.localizedDescription)
                }
            }
        }
        let milliseconds = Int(elapsed.components.seconds * 1000
            + elapsed.components.attoseconds / 1_000_000_000_000_000)
        switch outcome {
        case .answered(let text):
            let reply = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return AIServiceTestResult(ok: true, message: String(reply.prefix(200)), milliseconds: milliseconds)
        case .failed(let message):
            return AIServiceTestResult(ok: false, message: message, milliseconds: milliseconds)
        case nil:
            return AIServiceTestResult(
                ok: false,
                message: String(localized: "No answer within 20 seconds."),
                milliseconds: milliseconds
            )
        }
    }

    /// What one Test run produced, with the error already flattened to text so the race can carry it.
    enum AITestOutcome: Sendable {
        case answered(String)
        case failed(String)
    }

    // MARK: - Diagnostics

    /// One line per service. The name, the endpoint and the model the user typed stay out: none of
    /// them is structural.
    func aiServicesDiagnostics() -> [String] {
        aiServices.map { "\($0.kind.rawValue) key=\($0.hasKey ? "yes" : "no")" }
    }
}

extension AppModel {

    /// Whether the model picked for `task` can answer right now. A service the user configured is
    /// always worth trying, so Apple Intelligence's state only gates the on-device choice.
    func isAIAvailable(for task: LanguageModelTask) -> Bool {
        resolvedLanguageModelChoice(for: task) != .onDevice || isAIAvailable
    }

    /// What to call the model a task runs on, for a label next to its output: the service and the
    /// model it answers with, or Apple Intelligence when the task stays on this Mac.
    func languageModelLabel(for task: LanguageModelTask) -> String {
        languageModelLabel(for: resolvedLanguageModelChoice(for: task))
    }

    func languageModelLabel(for choice: LanguageModelProviderChoice) -> String {
        guard choice != .onDevice, let service = aiService(for: choice) else {
            return Summary.onDeviceProvider
        }
        return service.model.isEmpty ? service.name : "\(service.name) · \(service.model)"
    }
}
