import Foundation

/// The jobs a language model can be picked for, one selection each.
public enum LanguageModelTask: String, Codable, CaseIterable, Sendable {
    case summary
    case chat
    case prompts
    case dictationCleanup
}

/// Which model answers a task. Encoded as `{kind, …}`, and a kind this build doesn't know
/// decodes as `.onDevice` so a newer version's selection still opens here.
public enum LanguageModelProviderChoice: Codable, Hashable, Sendable {
    case onDevice
    case cloud(provider: CloudLLMProviderID, model: String)
    case ollama(endpoint: URL, model: String)
    case custom(baseURL: URL, model: String)

    /// Whether answering with this model sends the text off this Mac.
    public var isRemote: Bool {
        switch self {
        case .onDevice: return false
        case .cloud, .custom: return true
        case .ollama(let endpoint, _): return !Self.isLoopback(endpoint)
        }
    }

    public static func isLoopback(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host == "[::1]"
    }

    private enum CodingKeys: String, CodingKey {
        case kind, provider, model, endpoint, baseURL
    }

    private enum Kind: String, Codable {
        case onDevice, cloud, ollama, custom
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try? container.decodeIfPresent(Kind.self, forKey: .kind)
        guard let model = try? container.decode(String.self, forKey: .model) else {
            self = .onDevice
            return
        }
        switch kind {
        case .cloud:
            guard let provider = try? container.decode(CloudLLMProviderID.self, forKey: .provider) else {
                self = .onDevice
                return
            }
            self = .cloud(provider: provider, model: model)
        case .ollama:
            guard let endpoint = try? container.decode(URL.self, forKey: .endpoint) else {
                self = .onDevice
                return
            }
            self = .ollama(endpoint: endpoint, model: model)
        case .custom:
            guard let baseURL = try? container.decode(URL.self, forKey: .baseURL) else {
                self = .onDevice
                return
            }
            self = .custom(baseURL: baseURL, model: model)
        case .onDevice, .none:
            self = .onDevice
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .onDevice:
            try container.encode(Kind.onDevice, forKey: .kind)
        case .cloud(let provider, let model):
            try container.encode(Kind.cloud, forKey: .kind)
            try container.encode(provider, forKey: .provider)
            try container.encode(model, forKey: .model)
        case .ollama(let endpoint, let model):
            try container.encode(Kind.ollama, forKey: .kind)
            try container.encode(endpoint, forKey: .endpoint)
            try container.encode(model, forKey: .model)
        case .custom(let baseURL, let model):
            try container.encode(Kind.custom, forKey: .kind)
            try container.encode(baseURL, forKey: .baseURL)
            try container.encode(model, forKey: .model)
        }
    }
}

/// One model choice per task. A task nobody picked for reads as `.onDevice`.
public struct LanguageModelSelection: Codable, Equatable, Sendable {
    public private(set) var choices: [LanguageModelTask: LanguageModelProviderChoice]

    public init(choices: [LanguageModelTask: LanguageModelProviderChoice] = [:]) {
        self.choices = choices
    }

    public static let onDevice = LanguageModelSelection()

    public subscript(task: LanguageModelTask) -> LanguageModelProviderChoice {
        get { choices[task] ?? .onDevice }
        set {
            if newValue == .onDevice {
                choices.removeValue(forKey: task)
            } else {
                choices[task] = newValue
            }
        }
    }

    private enum CodingKeys: String, CodingKey { case choices }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let raw = try container.decodeIfPresent([String: LanguageModelProviderChoice].self, forKey: .choices) ?? [:]
        var choices: [LanguageModelTask: LanguageModelProviderChoice] = [:]
        for (key, choice) in raw {
            guard let task = LanguageModelTask(rawValue: key) else { continue }
            choices[task] = choice
        }
        self.choices = choices
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        let raw = Dictionary(uniqueKeysWithValues: choices.map { ($0.key.rawValue, $0.value) })
        try container.encode(raw, forKey: .choices)
    }
}
