import Foundation

public struct CloudLLMProviderID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let openAI = CloudLLMProviderID("openai")
    public static let anthropic = CloudLLMProviderID("anthropic")
    public static let groq = CloudLLMProviderID("groq")

    public static let allKnown: [CloudLLMProviderID] = [.openAI, .anthropic, .groq]
}

public struct CloudLLMProviderInfo: Sendable, Hashable {
    public let id: CloudLLMProviderID
    public let displayName: String
    public let defaultModel: String
    public let keychainAccount: String
    public let apiKeyPlaceholder: String

    public static let openAI = CloudLLMProviderInfo(
        id: .openAI,
        displayName: "OpenAI",
        defaultModel: "gpt-4o-mini",
        keychainAccount: "app.parola.cloudllm.openai",
        apiKeyPlaceholder: "sk-…"
    )
    public static let anthropic = CloudLLMProviderInfo(
        id: .anthropic,
        displayName: "Anthropic",
        defaultModel: "claude-haiku-4-5",
        keychainAccount: "app.parola.cloudllm.anthropic",
        apiKeyPlaceholder: "sk-ant-…"
    )
    public static let groq = CloudLLMProviderInfo(
        id: .groq,
        displayName: "Groq",
        defaultModel: "llama-3.3-70b-versatile",
        keychainAccount: "app.parola.cloudllm.groq",
        apiKeyPlaceholder: "gsk_…"
    )

    public static func info(for id: CloudLLMProviderID) -> CloudLLMProviderInfo? {
        switch id {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .groq: return .groq
        default: return nil
        }
    }
}

public enum CloudLLMError: LocalizedError, Sendable {
    case missingAPIKey(CloudLLMProviderID)
    case requestFailed(provider: CloudLLMProviderID, status: Int, body: String)
    case malformedResponse(provider: CloudLLMProviderID)
    case disabledByPolicy

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let id):
            return "No API key configured for \(id). Add one in Settings → Cloud LLM."
        case .requestFailed(let id, let status, let body):
            return "\(id) request failed (HTTP \(status)): \(body)"
        case .malformedResponse(let id):
            return "\(id) returned a malformed response."
        case .disabledByPolicy:
            return "Cloud LLMs are disabled by your organization."
        }
    }
}
