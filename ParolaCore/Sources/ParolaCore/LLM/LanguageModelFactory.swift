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
        instructions: String = "You're a helpful assistant.",
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
