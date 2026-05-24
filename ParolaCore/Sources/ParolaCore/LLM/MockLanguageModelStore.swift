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
    }

    public func resolve(for provider: Provider) -> MockLanguageModelResponse? {
        byProvider[provider] ?? globalMock
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
