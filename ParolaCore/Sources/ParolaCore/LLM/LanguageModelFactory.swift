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

    public static func makeBYOKCloud(
        provider: CloudLLMProviderID,
        instructions: String = "You're a helpful assistant.",
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
        return CloudLanguageModel(provider: provider, apiKey: key, instructions: instructions)
    }

    public static func makeOllama(
        model: String = "llama3",
        endpoint: URL = URL(string: "http://localhost:11434")!,
        instructions: String = "You're a helpful assistant.",
        contextTokens: Int = 8192,
        clock: any Clock<Duration> = ContinuousClock()
    ) async -> any LanguageModel {
        if let mock = await MockLanguageModelStore.shared.resolve(for: .ollama) {
            return MockLanguageModel.make(response: mock, clock: clock)
        }
        return OllamaLanguageModel(model: model, endpoint: endpoint, instructions: instructions, contextTokens: contextTokens)
    }

    public static func makeOnDevice(
        instructions: String = "You're a helpful assistant.",
        clock: any Clock<Duration> = ContinuousClock()
    ) async throws -> any LanguageModel {
        if let mock = await MockLanguageModelStore.shared.resolve(for: .foundation) {
            return MockLanguageModel.make(response: mock, clock: clock)
        }
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return FoundationLanguageModel(instructions: instructions)
            case .unavailable(let reason):
                throw Failure.notAvailable(unavailableMessage(for: reason))
            @unknown default:
                throw Failure.notAvailable("Apple Intelligence isn't available right now.")
            }
        }
        #endif
        throw Failure.notAvailable("Apple Intelligence needs macOS 26 or iOS 26 or newer.")
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
