import Foundation

public struct CloudLLMProviderID: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(_ rawValue: String) { self.rawValue = rawValue }
    public init?(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let openAI = CloudLLMProviderID("openai")
    public static let anthropic = CloudLLMProviderID("anthropic")
    public static let groq = CloudLLMProviderID("groq")
    public static let cerebras = CloudLLMProviderID("cerebras")
    /// The one user-supplied OpenAI-compatible endpoint per install; it has no built-in URL, so it
    /// stays out of `allKnown` and only names the keychain slot its key lives in.
    public static let custom = CloudLLMProviderID("custom")

    public static let allKnown: [CloudLLMProviderID] = [.openAI, .anthropic, .groq, .cerebras]
}

public struct CloudLLMProviderInfo: Sendable, Hashable {
    public let id: CloudLLMProviderID
    public let displayName: String
    public let defaultModel: String
    public let keychainAccount: String
    public let apiKeyPlaceholder: String
    public let contextWindowTokens: Int

    public static let openAI = CloudLLMProviderInfo(
        id: .openAI,
        displayName: "OpenAI",
        defaultModel: "gpt-4o-mini",
        keychainAccount: "app.parola.cloudllm.openai",
        apiKeyPlaceholder: "sk-…",
        contextWindowTokens: 128_000
    )
    public static let anthropic = CloudLLMProviderInfo(
        id: .anthropic,
        displayName: "Anthropic",
        defaultModel: "claude-haiku-4-5",
        keychainAccount: "app.parola.cloudllm.anthropic",
        apiKeyPlaceholder: "sk-ant-…",
        contextWindowTokens: 200_000
    )
    public static let groq = CloudLLMProviderInfo(
        id: .groq,
        displayName: "Groq",
        defaultModel: "llama-3.3-70b-versatile",
        keychainAccount: "app.parola.cloudllm.groq",
        apiKeyPlaceholder: "gsk_…",
        contextWindowTokens: 128_000
    )
    public static let cerebras = CloudLLMProviderInfo(
        id: .cerebras,
        displayName: "Cerebras",
        defaultModel: "llama-3.3-70b",
        keychainAccount: "app.parola.cloudllm.cerebras",
        apiKeyPlaceholder: "csk-…",
        contextWindowTokens: 64_000
    )

    public static func info(for id: CloudLLMProviderID) -> CloudLLMProviderInfo? {
        switch id {
        case .openAI: return .openAI
        case .anthropic: return .anthropic
        case .groq: return .groq
        case .cerebras: return .cerebras
        default: return nil
        }
    }
}

public enum CloudLLMError: LocalizedError, Sendable {
    case missingAPIKey(CloudLLMProviderID)
    case requestFailed(provider: CloudLLMProviderID, status: Int, body: String)
    case streamError(provider: CloudLLMProviderID, message: String)
    case malformedResponse(provider: CloudLLMProviderID)
    case unsupportedProvider(CloudLLMProviderID)
    case disabledByPolicy
    case tokenBudgetExceeded(provider: CloudLLMProviderID, used: Int, limit: Int)

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey(let id):
            return "No API key configured for \(id)."
        case .requestFailed(let id, let status, _):
            return "\(id) request failed (HTTP \(status))."
        case .streamError(let id, let message):
            return "\(id) failed mid-response: \(message)"
        case .malformedResponse(let id):
            return "\(id) returned a malformed response."
        case .unsupportedProvider(let id):
            return "Unsupported cloud provider: \(id)."
        case .disabledByPolicy:
            return "Cloud LLMs are disabled by your organization."
        case .tokenBudgetExceeded(let id, let used, let limit):
            return "Transcript is too long for \(id) (\(used) tokens, limit \(limit))."
        }
    }

    public var debugDescription: String {
        switch self {
        case .requestFailed(let id, let status, let body):
            return "\(id) request failed (HTTP \(status)): \(body)"
        default:
            return errorDescription ?? "Cloud LLM error"
        }
    }
}
