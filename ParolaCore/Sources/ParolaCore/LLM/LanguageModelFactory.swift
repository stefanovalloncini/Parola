import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

public enum LanguageModelFactory {
    public enum Failure: LocalizedError, CustomStringConvertible, Sendable {
        case notAvailable(String)

        public var description: String {
            switch self {
            case .notAvailable(let reason): return "Language model unavailable: \(reason)"
            }
        }

        public var errorDescription: String? { description }
    }

    public static let defaultInstructions = "You're a helpful assistant."

    /// Builds the model picked for `task`, or the on-device one when nothing is picked.
    /// A remote choice refused by policy throws rather than quietly answering on device.
    public static func make(
        for task: LanguageModelTask,
        selection: LanguageModelSelection,
        instructions: String? = nil,
        keyStore: any APIKeyStore = KeychainAPIKeyStore.shared,
        managed: ManagedConfiguration = .shared,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> any LanguageModel {
        let choice = selection[task]
        let instructions = instructions ?? defaultInstructions
        switch choice {
        case .onDevice:
            return try await makeOnDevice(instructions: instructions, clock: clock)
        case .cloud(let provider, let model):
            return try await makeBYOKCloud(
                provider: provider,
                model: model,
                instructions: instructions,
                keyStore: keyStore,
                managed: managed,
                clock: clock
            )
        case .ollama(let endpoint, let model):
            if choice.isRemote && managed.disableCloudLLM {
                throw CloudLLMError.disabledByPolicy
            }
            return await makeOllama(
                model: model,
                endpoint: endpoint,
                instructions: instructions,
                clock: clock
            )
        case .custom(let baseURL, let model):
            return try await makeCustomEndpoint(
                baseURL: baseURL,
                model: model,
                instructions: instructions,
                keyStore: keyStore,
                managed: managed,
                clock: clock
            )
        }
    }

    public static func makeBYOKCloud(
        provider: CloudLLMProviderID,
        model: String? = nil,
        instructions: String = defaultInstructions,
        keyStore: APIKeyStore = KeychainAPIKeyStore.shared,
        managed: ManagedConfiguration = .shared,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> any LanguageModel {
        if let mockProvider = MockLanguageModelStore.Provider(cloudProviderID: provider),
           let mock = await MockLanguageModelStore.shared.resolve(for: mockProvider) {
            return MockLanguageModel.make(response: mock, clock: clock)
        }
        if managed.disableCloudLLM {
            throw CloudLLMError.disabledByPolicy
        }
        guard CloudLanguageModel.isSupported(provider) else {
            throw CloudLLMError.unsupportedProvider(provider)
        }
        guard let key = try await keyStore.get(for: provider), !key.isEmpty else {
            throw CloudLLMError.missingAPIKey(provider)
        }
        return CloudLanguageModel(provider: provider, model: model, apiKey: key, instructions: instructions)
    }

    /// An OpenAI-compatible server the user runs or pays for themselves. Its key, when it wants one,
    /// lives under ``CloudLLMProviderID/custom``.
    public static func makeCustomEndpoint(
        baseURL: URL,
        model: String,
        instructions: String = defaultInstructions,
        keyStore: any APIKeyStore = KeychainAPIKeyStore.shared,
        managed: ManagedConfiguration = .shared,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> any LanguageModel {
        if let mock = await MockLanguageModelStore.shared.resolve(for: .custom) {
            return MockLanguageModel.make(response: mock, clock: clock)
        }
        if managed.disableCloudLLM {
            throw CloudLLMError.disabledByPolicy
        }
        let key = try await keyStore.get(for: .custom)
        return CloudLanguageModel(
            openAICompatibleBaseURL: baseURL,
            model: model,
            apiKey: key,
            instructions: instructions
        )
    }

    public static func makeOllama(
        model: String = "llama3",
        endpoint: URL = URL(string: "http://localhost:11434")!,
        instructions: String = defaultInstructions,
        contextTokens: Int = 8192,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> any LanguageModel {
        if let mock = await MockLanguageModelStore.shared.resolve(for: .ollama) {
            return MockLanguageModel.make(response: mock, clock: clock)
        }
        return OllamaLanguageModel(model: model, endpoint: endpoint, instructions: instructions, contextTokens: contextTokens)
    }

    /// Why the on-device model is unavailable, in a form safe to log: `unavailableMessage`'s copy
    /// is written for a person, not for an export.
    enum OnDeviceUnavailability: String, LogSafe {
        case deviceNotEligible
        case notEnabled
        case modelNotReady
        case osTooOld
        case unknown

        var logToken: String { rawValue }
    }

    static func unavailability() -> OnDeviceUnavailability {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .unknown
            case .unavailable(let reason):
                switch reason {
                case .deviceNotEligible: return .deviceNotEligible
                case .appleIntelligenceNotEnabled: return .notEnabled
                case .modelNotReady: return .modelNotReady
                @unknown default: return .unknown
                }
            }
        }
        #endif
        return .osTooOld
    }

    /// True when the on-device model can't serve a request and waiting won't change that: the device,
    /// the OS or the Apple Intelligence setting rules it out. A model still downloading is not out of reach.
    public static func onDeviceIsOutOfReach() -> Bool {
        switch unavailability() {
        case .deviceNotEligible, .notEnabled, .osTooOld: return true
        case .modelNotReady, .unknown: return false
        }
    }

    /// Whether the on-device model can serve a request right now, and why not when it can't.
    public enum OnDeviceAvailability: Sendable, Equatable {
        case available
        case unavailable(reason: String)

        public var isAvailable: Bool {
            if case .available = self { return true }
            return false
        }

        public var reason: String? {
            if case .unavailable(let reason) = self { return reason }
            return nil
        }
    }

    /// Cheap enough to call whenever a view appears: it reads cached system state, it doesn't load the model.
    public static func onDeviceAvailability() async -> OnDeviceAvailability {
        if await MockLanguageModelStore.shared.resolve(for: .foundation) != nil {
            return .available
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return .available
            case .unavailable(let reason):
                return .unavailable(reason: unavailableMessage(for: reason))
            @unknown default:
                return .unavailable(reason: "Apple Intelligence isn't available right now.")
            }
        }
        #endif
        return .unavailable(reason: "Apple Intelligence needs macOS 26 or iOS 26 or newer.")
    }

    public static func makeOnDevice(
        instructions: String = defaultInstructions,
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> any LanguageModel {
        if let mock = await MockLanguageModelStore.shared.resolve(for: .foundation) {
            await MockLanguageModelStore.shared.recordInstructions(instructions, for: .foundation)
            return MockLanguageModel.make(response: mock, clock: clock)
        }
        if let reason = await onDeviceAvailability().reason {
            ParolaLog.notice(.ai, "on-device model unavailable: \(Self.unavailability())")
            throw Failure.notAvailable(reason)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            return FoundationLanguageModel(instructions: instructions)
        }
        #endif
        throw Failure.notAvailable("Apple Intelligence needs macOS 26 or iOS 26 or newer.")
    }

    /// Whether `error` says the input was too long for the model's window, in any provider's words.
    public static func isContextOverflow(_ error: any Error) -> Bool {
        if case CloudLLMError.tokenBudgetExceeded = error { return true }
        #if canImport(FoundationModels)
        if #available(macOS 27.0, iOS 27.0, visionOS 27.0, *),
           let failure = error as? LanguageModelError, case .contextSizeExceeded = failure {
            return true
        }
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *),
           let failure = error as? LanguageModelSession.GenerationError, case .exceededContextWindowSize = failure {
            return true
        }
        #endif
        return false
    }

    #if canImport(FoundationModels)
    /// Human, actionable copy for each reason Apple Intelligence can be unavailable.
    @available(macOS 26.0, iOS 26.0, visionOS 26.0, *)
    public static func unavailableMessage(for reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible:
            return "This device doesn't support Apple Intelligence."
        case .appleIntelligenceNotEnabled:
            return "Apple Intelligence is off. Turn it on in Settings to use this feature."
        case .modelNotReady:
            return "Apple Intelligence is still preparing its model. Try again in a little while."
        @unknown default:
            return "Apple Intelligence isn't available right now."
        }
    }
    #endif
}
