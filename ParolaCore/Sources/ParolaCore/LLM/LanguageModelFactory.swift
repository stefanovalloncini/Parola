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
        managed: ManagedConfiguration = .shared
    ) async throws -> any LanguageModel {
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
        instructions: String = "You're a helpful assistant."
    ) -> any LanguageModel {
        OllamaLanguageModel(model: model, endpoint: endpoint, instructions: instructions)
    }

    public static func makeOnDevice(instructions: String = "You're a helpful assistant.") throws -> any LanguageModel {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, iOS 26.0, visionOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return FoundationLanguageModel(instructions: instructions)
            case .unavailable(let reason):
                throw Failure.notAvailable("\(reason)")
            @unknown default:
                throw Failure.notAvailable("Unknown availability state.")
            }
        }
        #endif
        throw Failure.notAvailable("Foundation Models requires macOS 26 / iOS 26 or newer.")
    }
}
