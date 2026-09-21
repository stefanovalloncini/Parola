import Foundation

public actor MockLanguageModelStore {
    public static let shared = MockLanguageModelStore()

    public enum Provider: String, Sendable, Hashable {
        case openAI
        case anthropic
        case groq
        case cerebras
        case ollama
        case foundation
    }

    private var byProvider: [Provider: MockLanguageModelResponse] = [:]
    private var globalMock: MockLanguageModelResponse?
    private var lastInstructions: [Provider: String] = [:]

    public init() {}

    public func install(provider: Provider?, response: MockLanguageModelResponse) {
        if let provider {
            byProvider[provider] = response
        } else {
            globalMock = response
        }
    }

    public func clear() {
        byProvider.removeAll()
        globalMock = nil
        lastInstructions.removeAll()
    }

    public func resolve(for provider: Provider) -> MockLanguageModelResponse? {
        byProvider[provider] ?? globalMock
    }

    /// Callers that route to a mock instead of the real model record the instructions they were given here, so a test can assert on them.
    public func recordInstructions(_ instructions: String, for provider: Provider) {
        lastInstructions[provider] = instructions
    }

    public func lastInstructions(for provider: Provider) -> String? {
        lastInstructions[provider]
    }

    public func list() -> [String] {
        var keys = byProvider.keys.map(\.rawValue).sorted()
        if globalMock != nil { keys.append("*") }
        return keys
    }
}

extension MockLanguageModelStore.Provider {
    public init?(cloudProviderID: CloudLLMProviderID) {
        switch cloudProviderID {
        case .openAI: self = .openAI
        case .anthropic: self = .anthropic
        case .groq: self = .groq
        case .cerebras: self = .cerebras
        default: return nil
        }
    }
}
